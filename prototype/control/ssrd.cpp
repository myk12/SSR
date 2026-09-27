// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * ssrd - the control plane's foothold on one host.
 *
 * One gRPC service over /dev/ssrN (ssr_dev.h). It remembers only the run id
 * and membership it was handed at Prepare; everything else in a reply is read
 * back from the driver on the spot, so ssrctl sees the hardware and
 * not a copy of it. There is no state machine here: the core's own state
 * (disabled / armed / activation pending / running / halted) is the state.
 *
 *   Prepare(run_id, membership)  DISABLE, REBOOT, ENABLE so that
 *                                CUR_ROUND is live for ssrctl to
 *                                pick a start round; keep the config
 *   Start(effective_round)       ACTIVATE, then wait until the run is in
 *   Stop()                       DISABLE
 *   GetStatus()                  identity + SSR_IOC_GET_STATUS + ptp4l's view
 *
 * WHO WE ARE, AND THE ROUND (ssr.cfg). The dataplane is one bitstream for
 * the whole cluster: node id, node count, quorum, source MAC, round length
 * and the three instants of a round are registers (ssr_csr 0x040), and ssrd
 * writes them at start-up. It finds its own [nodeN] section by hostname,
 * derives the instants from [cluster] (round_ns, prop_ns, guard_ns,
 * frags_per_round) and the bitstream's BUILD constants - the arithmetic that
 * used to be localparams in ssr_dataplane.v - checks that a round's paced
 * payload fits, and hands the numbers to the driver (SSR_IOC_CONFIGURE).
 * The FPGA derives nothing.
 *
 * THE TWO PORTS (ssr.cfg). Port 0, ssr_iface, carries the SSR protocol and
 * nothing else; port 1, ctl_iface, carries everything else - PTP, this
 * service, ssh. The testbed keeps every port in its own network namespace
 * (ncs-fabric: fpgaN_p1, fpgaN_p2), so ssrd runs in ctl_iface's namespace -
 * that is where PTP and its listener live - and reaches over into ssr_netns
 * only to bring ssr_iface up (the MAC has to run for the core's frames).
 *
 * THE CLOCK. The whole replica runs on the NIC's PHC: the core reads it for
 * the round ids, and the host's CLOCK_REALTIME is locked to it so that an
 * application reads the same time through the vDSO instead of a PCIe round
 * trip per timestamp. Both ports share that one PHC, so PTP on ctl_iface
 * disciplines the clock the core stamps rounds with on ssr_iface. ssrd owns
 * the two linuxptp daemons, as children that die with it:
 *
 *   ptp4l -i ctl_iface -H -2 [-s]              hardware timestamps, L2; -s
 *                                              unless this node is the
 *                                              cluster's grandmaster
 *   phc2sys -s ctl_iface -c CLOCK_REALTIME -w  the host clock follows the PHC
 *
 * (mqnic sets the PHC from the system time at probe, so the grandmaster's
 * free-running PHC is already wall-clock time.) GetStatus asks ptp4l (pmc
 * over its management socket) and passes the answer up; whether the cluster
 * is synced enough to start is ssrctl's call.
 *
 * The data path is not ssrd's business: an application (ssr-bench, or
 * whatever replaces it) opens the same device and uses write()/read() or
 * mmap() itself.
 *
 *   ssrd [--cfg ssr.cfg] [--dev /dev/ssrN] [--node N]
 *
 * --node overrides the hostname match, for a test on one box. Without --dev
 * the device is the /dev/ssrN on the same card as ctl_iface (a host may hold
 * two SSR cards): both hang off one PCI device in sysfs.
 */
#include "ssr_cfg.h"
#include "ssr_control.grpc.pb.h"

#include <grpcpp/grpcpp.h>

extern "C" {
#include "ssr_dev.h"
}

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <string>
#include <vector>

#include <signal.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <climits>

namespace {

/* A child that dies with us (PDEATHSIG), output on our terminal. */
pid_t spawn(std::vector<const char *> argv)
{
    pid_t pid = fork();

    if (pid == 0) {
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        argv.push_back(nullptr);
        execvp(argv[0], const_cast<char *const *>(argv.data()));
        fprintf(stderr, "exec %s: %s\n", argv[0], strerror(errno));
        _exit(127);
    }
    return pid;
}

/* ptp4l and phc2sys on the control port; see the header. */
void start_ptp(const char *iface, bool gm)
{
    std::vector<const char *> ptp4l = {"ptp4l", "-i", iface, "-H", "-2", "-m", "-q"};
    if (!gm)
        ptp4l.push_back("-s");
    spawn(ptp4l);
    spawn({"phc2sys", "-s", iface, "-c", "CLOCK_REALTIME", "-w", "-m", "-q"});
}

grpc::Status errno_status(const char *what, int err)
{
    return grpc::Status(grpc::StatusCode::INTERNAL, std::string(what) + ": " + std::strerror(-err));
}

/* ptp4l's TIME_STATUS_NP, through pmc. Once per GetStatus, nowhere near a
 * fast path, so a popen is the whole implementation. On the grandmaster
 * gmPresent is false and gmIdentity is its own clock; on a slave that lost
 * its master gmIdentity falls back to its own clock too, which is why ssrctl
 * only asks "does everyone name the same gmIdentity". */
struct Ptp {
    bool ok = false;
    bool gm_present = false;
    long long offset_ns = 0;
    std::string gm;
};

Ptp ptp_query(const std::string &uds)
{
    Ptp p;
    std::string cmd = "pmc -u -b 0 -s " + uds + " 'GET TIME_STATUS_NP' 2>/dev/null";
    FILE *f = popen(cmd.c_str(), "r");
    char line[256], word[64];
    long long v;

    if (!f)
        return p;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, " master_offset %lld", &v) == 1) {
            p.offset_ns = v;
            p.ok = true;
        } else if (sscanf(line, " gmPresent %63s", word) == 1) {
            p.gm_present = !strcmp(word, "true");
        } else if (sscanf(line, " gmIdentity %63s", word) == 1) {
            p.gm = word;
        }
    }
    pclose(f);
    return p;
}

/* THE ROUND, DERIVED. The inputs are the physical facts in ssr.cfg and the
 * bitstream's own constants (ssr_info); the outputs are the instants the
 * core and the tx engine compare against. docs/round_structure.md section 3
 * and docs/count_ack.md section 5 are the argument; this is the arithmetic:
 *
 *   frame_ns     one 4 KiB frame on the wire (327 at 100G)
 *   ctrl_ns      one 64 B control frame (6)
 *   tx_start     guard + settle. Our control frame carries the counts of the
 *                previous round, which are final once the last fragment has
 *                landed and the tracker has settled - and the cutoff already
 *                guarantees every fragment lands before the boundary, skew
 *                included. The guard keeps a fast peer's control frame from
 *                reaching us before our own boundary. The old dead zone of a
 *                whole prop here dated from before the cutoff existed, when
 *                payload ran to the boundary and its tail was still in flight
 *                (docs/round_structure.md 2); count_ack.md 5 carried it over
 *                unexamined, and on the board it cost a full one-hop delay of
 *                every round for nothing.
 *   deadline     a peer's control frame left at its tx_start on a clock up to
 *                guard behind ours, arrived prop later, N-1 of them serialised,
 *                and the ladder's settle
 *   pay_gap      after our control frame, before payload: 2*guard + ctrl_ns,
 *                so our payload cannot queue ahead of a late peer's control
 *                frame at a switch egress
 *   pace_gap     the rate cap: (N-2) frame times of silence per fragment,
 *                so a receiver taking from N-1 peers never exceeds line rate
 *   cutoff       the last start whose fragment is counted at every peer
 *                before that peer's boundary
 *
 * and the checks that used to be $error()s at elaboration. */
ssr_config derive_round(const Cfg &cfg, const ssr_info &info, uint32_t node_id, uint32_t node_count)
{
    const long long round = cfg.num("cluster", "round_ns"), prop = cfg.num("cluster", "prop_ns"),
                    guard = cfg.num("cluster", "guard_ns"), frags = cfg.num("cluster", "frags_per_round");
    const long long settle = info.settle_ns, clk = info.clk_mhz, rate = info.line_rate_gbps;
    const long long frame_bits = 4096 * 8, ctrl_bits = 64 * 8;
    const long long frame_ns = frame_bits / rate, ctrl_ns = (ctrl_bits + rate - 1) / rate;
    auto cycles = [&](long long ns) { return (ns * clk + 999) / 1000; };
    auto fail = [](const std::string &why) { fprintf(stderr, "ssr.cfg: %s\n", why.c_str()); exit(2); };

    ssr_config c{};
    c.node_id = node_id;
    c.node_count = node_count;
    c.quorum = cfg.s.at("cluster").count("quorum") ? (uint32_t)cfg.num("cluster", "quorum") : node_count / 2 + 1;
    const uint8_t mac[6] = {0x02, 0x53, 0x53, 0x52, 0x00, (uint8_t)node_id};   /* "SSR", then who */
    memcpy(c.src_mac, mac, 6);
    c.round_ns = round;
    c.rounds_per_sec = 1000000000LL / round;
    c.tx_start_ns = guard + settle;
    c.ctrl_deadline_ns = c.tx_start_ns + guard + prop + (node_count - 1) * ctrl_ns + settle;
    c.pay_gap = cycles(2 * guard + ctrl_ns);
    c.pace_gap = (frame_bits * (node_count - 2) * clk + rate * 1000 - 1) / (rate * 1000);
    c.pay_cutoff_ns = round - frame_ns - prop - guard - settle;
    c.frags_per_round = frags;

    const long long pay_gap_ns = c.pay_gap * 1000 / clk, pace_gap_ns = c.pace_gap * 1000 / clk;
    const long long last_start = c.tx_start_ns + ctrl_ns + pay_gap_ns + (frags - 1) * (frame_ns + pace_gap_ns);
    if (node_count < 2 || node_count > 8) fail("node count must be 2..8 (the ack vector is 8 bytes)");
    if (node_id >= node_count) fail("node id past the node count");
    if (c.quorum < 1 || c.quorum > node_count) fail("quorum must be 1..N");
    if (1000000000LL % round) fail("round_ns must divide 1e9, or every second ends with a short round");
    if (c.ctrl_deadline_ns <= c.tx_start_ns + prop) fail("no control frame could ever be in time: raise round_ns or cut prop_ns");
    if (c.ctrl_deadline_ns + info.eval_settle_cycles * 1000 / clk + 100 >= round)
        fail("the control deadline plus the evaluation settle leaves no payload period");
    if (c.pay_cutoff_ns <= c.tx_start_ns) fail("the payload cutoff is before the control frame: round_ns is too short");
    if (frags < 1 || frags > (long long)info.region_pages)
        fail("frags_per_round must be 1.." + std::to_string(info.region_pages) + " (a region's pages)");
    if ((node_count - 1) * frags > (long long)info.stage_slots)
        fail("(N-1) x frags_per_round exceeds the " + std::to_string(info.stage_slots) + " staging slots");
    if (last_start > c.pay_cutoff_ns)
        fail("a round's paced payload does not fit: the last of " + std::to_string(frags) + " fragments would start at " +
             std::to_string(last_start) + " ns, past the cutoff at " + std::to_string(c.pay_cutoff_ns) +
             " ns; fewer frags_per_round or a longer round_ns");
    printf("round: %u ns, N %u, quorum %u; ctrl frame at %u, deadline %u, payload [%lld, %u], %u frags, "
           "pace %u cycles, skew gap %u cycles (prop %lld, guard %lld, settle %lld, frame %lld ns)\n",
           c.round_ns, node_count, c.quorum, c.tx_start_ns, c.ctrl_deadline_ns,
           c.tx_start_ns + ctrl_ns + pay_gap_ns, c.pay_cutoff_ns, c.frags_per_round, c.pace_gap, c.pay_gap,
           prop, guard, settle, frame_ns);
    return c;
}

/* The /dev/ssrN that belongs to the card ctl_iface is a port of. Both are
 * children of the same PCI device: /sys/class/ssr/ssrN/device is the
 * auxiliary device under it, /sys/class/net/IF/device is it. Empty if none;
 * IF must be visible in this namespace, which the control port is. */
std::string dev_for_iface(const std::string &iface)
{
    char buf[PATH_MAX];
    std::string pci;
    if (realpath(("/sys/class/net/" + iface + "/device").c_str(), buf))
        pci = buf;
    for (int n = 0; n < 16 && !pci.empty(); n++) {
        const std::string sys = "/sys/class/ssr/ssr" + std::to_string(n) + "/device/..";
        if (realpath(sys.c_str(), buf) && pci == buf)
            return "/dev/ssr" + std::to_string(n);
    }
    return "";
}

class Node final : public ssr::Node::Service {
public:
    /* The PTP status is refreshed by a thread once a second and only read
     * from a reply. Asking pmc inline used to put tens of milliseconds into
     * every GetStatus, and ssrctl derives the cluster's start round from a
     * GetStatus - the round was stale by ~100 ms and the nodes activated one
     * by one instead of together. */
    Node(ssr_dev *dev, std::string ptp_uds) : dev_(dev), ptp_uds_(std::move(ptp_uds)),
        ptp_thread_([this] {
            for (;;) {
                Ptp p = ptp_query(ptp_uds_);
                { std::scoped_lock lock(ptp_mu_); ptp_ = p; }
                sleep(1);
            }
        }) { ptp_thread_.detach(); }

    grpc::Status Prepare(grpc::ServerContext *, const ssr::RunConfig *cfg, ssr::Status *out) override
    {
        std::scoped_lock lock(mu_);
        int ret;

        printf("prepare: run 0x%x membership 0x%02x\n", cfg->run_id(), cfg->membership());
        /* Always reboot: it forgets the halt record and the installed run, so
         * the status reflects this run and not the last one. (Checking HALTED
         * first does not work - DISABLE already leaves S_HALT, clearing the bit.) */
        if ((ret = ssr_dev_disable(dev_)))
            return errno_status("SSR_IOC_DISABLE", ret);
        if ((ret = ssr_dev_reboot(dev_)))
            return errno_status("SSR_IOC_REBOOT", ret);
        /* Timing on now: ssrctl reads CUR_ROUND between Prepare and
         * Start to choose the cluster's effective round. */
        if ((ret = ssr_dev_enable(dev_)))
            return errno_status("SSR_IOC_ENABLE", ret);
        run_id_ = cfg->run_id();
        membership_ = cfg->membership();
        return fill(out);
    }

    grpc::Status Start(grpc::ServerContext *, const ssr::StartRequest *req, ssr::Status *out) override
    {
        std::scoped_lock lock(mu_);
        const uint64_t eff = req->effective_round();
        ssr_status s;
        int ret;

        if ((ret = ssr_dev_status(dev_, &s)))
            return errno_status("SSR_IOC_GET_STATUS", ret);
        printf("start: run 0x%x membership 0x%02x at round %llu (now %llu: %lld rounds of slack)\n", run_id_,
               membership_, (unsigned long long)eff, (unsigned long long)s.cur_round,
               (long long)(eff - s.cur_round));
        if ((ret = ssr_dev_activate(dev_, run_id_, membership_, eff, 0)))
            return errno_status("SSR_IOC_ACTIVATE", ret);

        /* The activation stays pending until the effective round arrives; a
         * halt on the way is not an RPC error, the status carries it. */
        const uint64_t ahead_ms = eff > s.cur_round ? (eff - s.cur_round) * dev_->info.round_ns / 1000000 : 0;
        ret = ssr_dev_wait_running(dev_, run_id_, (int)ahead_ms + 2000);
        if (ret && ret != -EIO)
            return errno_status("waiting for the run to become active", ret);
        return fill(out);
    }

    grpc::Status Stop(grpc::ServerContext *, const ssr::Empty *, ssr::Status *out) override
    {
        std::scoped_lock lock(mu_);
        int ret = ssr_dev_disable(dev_);

        printf("stop\n");
        if (ret)
            return errno_status("SSR_IOC_DISABLE", ret);
        return fill(out);
    }

    grpc::Status GetStatus(grpc::ServerContext *, const ssr::Empty *, ssr::Status *out) override
    {
        std::scoped_lock lock(mu_);
        return fill(out);
    }

private:
    grpc::Status fill(ssr::Status *out)
    {
        ssr_status s;
        int ret = ssr_dev_status(dev_, &s);

        if (ret)
            return errno_status("SSR_IOC_GET_STATUS", ret);
        out->set_node_id(dev_->info.node_id);
        out->set_node_count(dev_->info.node_count);
        out->set_round_ns(dev_->info.round_ns);
        out->set_core_status(s.core_status);
        out->set_cur_run_id(s.cur_run_id);
        out->set_sound_set(s.sound_set);
        out->set_membership(s.membership);
        out->set_cur_round(s.cur_round);
        out->set_round_count(s.round_count);
        out->set_commit_count(s.commit_count);
        out->set_halt_count(s.halt_count);
        out->set_halt_reason(s.halt_reason);
        out->set_halt_round(s.halt_round);
        out->set_halt_witness(s.halt_witness);
        out->set_fault(s.fault);
        out->set_seq(s.seq);

        Ptp p;
        { std::scoped_lock lock(ptp_mu_); p = ptp_; }
        out->set_ptp_ok(p.ok);
        out->set_ptp_offset_ns(p.offset_ns);
        out->set_ptp_gm_present(p.gm_present);
        out->set_ptp_gm(p.gm);
        return grpc::Status::OK;
    }

    ssr_dev *dev_;
    std::string ptp_uds_;
    std::mutex mu_;
    std::mutex ptp_mu_;
    Ptp ptp_;
    std::thread ptp_thread_;
    uint32_t run_id_ = 0;
    uint32_t membership_ = 0;
};

} // namespace

int main(int argc, char **argv)
{
    const char *cfg_path = "ssr.cfg", *path = nullptr;
    int node_override = -1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--cfg") && i + 1 < argc)
            cfg_path = argv[++i];
        else if (!strcmp(argv[i], "--dev") && i + 1 < argc)
            path = argv[++i];
        else if (!strcmp(argv[i], "--node") && i + 1 < argc)
            node_override = atoi(argv[++i]);
        else {
            fprintf(stderr, "usage: %s [--cfg ssr.cfg] [--dev /dev/ssrN] [--node N]\n", argv[0]);
            return 2;
        }
    }

    /* Which node we are: the [nodeN] section naming this host. */
    const Cfg cfg = Cfg::load(cfg_path);
    char hostname[256] = "";
    gethostname(hostname, sizeof hostname - 1);
    std::string me;
    uint32_t node_count = 0;
    for (auto &[sec, keys] : cfg.s) {
        if (sec.rfind("node", 0) != 0)
            continue;
        node_count++;
        if (node_override >= 0 ? sec == "node" + std::to_string(node_override)
                               : keys.count("host") && keys.at("host") == hostname)
            me = sec;
    }
    if (me.empty()) {
        fprintf(stderr, "%s: no [nodeN] section with host = %s\n", cfg_path, hostname);
        return 2;
    }
    const uint32_t node_id = (uint32_t)strtoul(me.c_str() + 4, nullptr, 10);
    const std::string ctl = cfg.get(me, "ctl"), ssr_iface = cfg.get(me, "ssr_iface"),
                      ctl_iface = cfg.get(me, "ctl_iface"), ssr_netns = cfg.get(me, "ssr_netns");
    const bool gm = cfg.num("cluster", "grandmaster") == node_id;

    /* The device: the one on ctl_iface's card unless told otherwise. */
    std::string dev_path = path ? path : dev_for_iface(ctl_iface);
    if (dev_path.empty()) {
        fprintf(stderr, "no /dev/ssrN on the same card as %s (is %s in this namespace? is the card flashed?)\n",
                ctl_iface.c_str(), ctl_iface.c_str());
        return 1;
    }
    ssr_dev dev;
    int ret = ssr_dev_open(&dev, dev_path.c_str());
    if (ret) {
        fprintf(stderr, "open %s: %s\n", dev_path.c_str(), strerror(-ret));
        return 1;
    }
    /* Whatever the last process left: the core is quiet until Prepare. */
    ssr_dev_disable(&dev);

    /* The cluster and the round into the dataplane, before anything else. */
    const ssr_config conf = derive_round(cfg, dev.info, node_id, node_count);
    if ((ret = ssr_dev_configure(&dev, &conf))) {
        fprintf(stderr, "SSR_IOC_CONFIGURE: %s\n", strerror(-ret));
        return 1;
    }

    int st;
    waitpid(spawn({"ip", "-n", ssr_netns.c_str(), "link", "set", ssr_iface.c_str(), "up"}), &st, 0);
    start_ptp(ctl_iface.c_str(), gm);

    Node node(&dev, "/var/run/ptp4l");
    grpc::ServerBuilder builder;
    int port = 0;
    builder.AddListeningPort(ctl, grpc::InsecureServerCredentials(), &port);
    builder.RegisterService(&node);
    std::unique_ptr<grpc::Server> server = builder.BuildAndStart();
    if (!server || port <= 0) {
        fprintf(stderr, "cannot listen on %s (an address on %s?)\n", ctl.c_str(), ctl_iface.c_str());
        return 1;
    }
    printf("ssrd: %s is node %u of %u, round %u ns; SSR on %s (netns %s), control on %s, listening on %s, PTP %s\n",
           dev_path.c_str(), dev.info.node_id, dev.info.node_count, dev.info.round_ns, ssr_iface.c_str(), ssr_netns.c_str(),
           ctl_iface.c_str(), ctl.c_str(), gm ? "grandmaster" : "slave");
    server->Wait();
    ssr_dev_close(&dev);
    return 0;
}
