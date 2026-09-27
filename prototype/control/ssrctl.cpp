// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * ssrctl - every ssrd from one shell.
 *
 * It keeps no state machine of its own. Each command is fanned out to all
 * nodes in parallel and every reply is the hardware's status at that moment;
 * that printout IS the cluster's state, and a command is always allowed - the
 * node's driver refuses what the core cannot do.
 *
 *   status                          GetStatus everywhere
 *   prepare [run_id] [membership]   Prepare: a fresh run id (default: the next
 *                                   one, seeded from the clock so a restart
 *                                   never reuses one) and a membership bitmap
 *                                   (default: every configured node)
 *   start [rounds_ahead]            check the clocks (below), read CUR_ROUND
 *                                   from the first node that answers, add the
 *                                   margin ([cluster] rounds_ahead, 2500 =
 *                                   10 ms at 4 us), Start every node at that
 *                                   round. Round ids are PTP time / round
 *                                   length on every node, so one number is
 *                                   the same instant everywhere; the hosts'
 *                                   own clocks never enter into it.
 *   stop                            Stop everywhere
 *   quit
 *
 * THE CLOCK GATE. A run only works if every node's PHC agrees to within the
 * core's guard time (GUARD_TIME_NS, 50 ns): that is the skew the round
 * structure was designed for, and the FPGA cannot tell for itself (its
 * TIME_VALID is tied high). So start refuses unless every node's ptp4l
 * answers, they all name the same grandmaster, and every |master_offset| is
 * within [cluster] ptp_max_offset_ns (50; 0 turns the gate off, for a
 * single-node test). A step after the start is the core's own time_fault.
 *
 *   ssrctl [--cfg ssr.cfg]
 *
 * The nodes are the [nodeN] sections of the file, reached at their ctl
 * addresses.
 */
#include "ssr_cfg.h"
#include "ssr_control.grpc.pb.h"

#include <grpcpp/grpcpp.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <future>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

/* From kernel/ssr_regs.h, for the status bits. */
extern "C" {
#include "ssr_regs.h"
}

namespace {

struct Node {
    uint32_t id;
    std::string addr;
    std::unique_ptr<ssr::Node::Stub> stub;
};

struct Reply {
    uint32_t id;
    grpc::Status rpc;
    ssr::Status st;
};

/* One RPC on every node at once; the result in node order. */
template <class Rpc>
std::vector<Reply> fan_out(std::vector<Node> &nodes, std::chrono::milliseconds timeout, Rpc rpc)
{
    std::vector<std::future<Reply>> futures;
    for (Node &n : nodes)
        futures.push_back(std::async(std::launch::async, [&n, timeout, &rpc] {
            grpc::ClientContext ctx;
            ctx.set_deadline(std::chrono::system_clock::now() + timeout);
            Reply r{n.id, grpc::Status::OK, {}};
            r.rpc = rpc(*n.stub, ctx, &r.st);
            return r;
        }));
    std::vector<Reply> out;
    for (auto &f : futures)
        out.push_back(f.get());
    return out;
}

void print(const std::vector<Node> &nodes, const std::vector<Reply> &replies)
{
    for (size_t i = 0; i < replies.size(); i++) {
        const Reply &r = replies[i];
        printf("node %u @ %s: ", r.id, nodes[i].addr.c_str());
        if (!r.rpc.ok()) {
            printf("RPC failed: %s\n", r.rpc.error_message().c_str());
            continue;
        }
        const ssr::Status &s = r.st;
        printf("status 0x%02x run 0x%x sound 0x%02x member 0x%02x round %llu commits %llu halts %u fault 0x%x seq %llu\n",
               s.core_status(), s.cur_run_id(), s.sound_set(), s.membership(),
               (unsigned long long)s.cur_round(), (unsigned long long)s.commit_count(),
               s.halt_count(), s.fault(), (unsigned long long)s.seq());
        if (s.core_status() & SSR_CORE_STATUS_HALTED)
            printf("    HALTED: reason %u round %llu witness 0x%02x\n", s.halt_reason(),
                   (unsigned long long)s.halt_round(), s.halt_witness());
        if (s.ptp_ok())
            printf("    ptp: offset %lld ns, gm %s%s\n", (long long)s.ptp_offset_ns(), s.ptp_gm().c_str(),
                   s.ptp_gm_present() ? "" : " (self)");
        else
            printf("    ptp: ptp4l does not answer\n");
    }
}

/* The clock gate: every node synced to one grandmaster within max_offset_ns.
 * Prints why not; true if the cluster may start. */
bool clocks_agree(const std::vector<Reply> &replies, long long max_offset_ns)
{
    bool ok = true;
    const std::string *gm = nullptr;

    for (const Reply &r : replies) {
        if (!r.rpc.ok() || !r.st.ptp_ok()) {
            printf("node %u: no ptp4l status\n", r.id);
            ok = false;
            continue;
        }
        if (!gm)
            gm = &r.st.ptp_gm();
        else if (r.st.ptp_gm() != *gm) {
            printf("node %u: grandmaster %s, but node %u has %s\n", r.id, r.st.ptp_gm().c_str(),
                   replies[0].id, gm->c_str());
            ok = false;
        }
        const long long off = r.st.ptp_offset_ns();
        if (off > max_offset_ns || off < -max_offset_ns) {
            printf("node %u: offset %lld ns, more than %lld\n", r.id, off, max_offset_ns);
            ok = false;
        }
    }
    return ok;
}

} // namespace

int main(int argc, char **argv)
{
    const char *cfg_path = "ssr.cfg";

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--cfg") && i + 1 < argc)
            cfg_path = argv[++i];
        else {
            fprintf(stderr, "usage: %s [--cfg ssr.cfg]\n", argv[0]);
            return 2;
        }
    }
    const Cfg cfg = Cfg::load(cfg_path);
    const long long ptp_max_offset_ns = cfg.num("cluster", "ptp_max_offset_ns");
    const uint64_t default_ahead = (uint64_t)cfg.num("cluster", "rounds_ahead");

    std::vector<Node> nodes;
    uint32_t everyone = 0;
    for (auto &[sec, keys] : cfg.s) {
        if (sec.rfind("node", 0) != 0)
            continue;
        const uint32_t id = (uint32_t)strtoul(sec.c_str() + 4, nullptr, 10);
        const std::string &addr = cfg.get(sec, "ctl");
        nodes.push_back({id, addr, ssr::Node::NewStub(grpc::CreateChannel(addr, grpc::InsecureChannelCredentials()))});
        everyone |= 1u << id;
    }
    if (nodes.empty()) {
        fprintf(stderr, "%s: no [nodeN] sections\n", cfg_path);
        return 2;
    }

    /* Run ids must never repeat within a cluster; the clock is the cheapest
     * source of a fresh one across ssrctl restarts. */
    uint32_t next_run_id = (uint32_t)time(nullptr);
    const std::chrono::milliseconds rpc_timeout(5000);

    printf("ssrctl: %zu nodes; commands: status, prepare [run_id] [membership], start [rounds_ahead], stop, quit\n",
           nodes.size());
    std::string line;
    while (std::cout << "ssr> " && std::getline(std::cin, line)) {
        std::istringstream in(line);
        std::string cmd;
        in >> cmd;
        if (cmd.empty())
            continue;
        if (cmd == "quit" || cmd == "exit")
            break;

        if (cmd == "status") {
            print(nodes, fan_out(nodes, rpc_timeout, [](ssr::Node::Stub &s, grpc::ClientContext &c, ssr::Status *o) {
                return s.GetStatus(&c, ssr::Empty(), o);
            }));
        } else if (cmd == "prepare") {
            std::string a, b;
            in >> a >> b;
            ssr::RunConfig cfg;
            cfg.set_run_id(a.empty() ? next_run_id++ : (uint32_t)strtoul(a.c_str(), nullptr, 0));
            cfg.set_membership(b.empty() ? everyone : (uint32_t)strtoul(b.c_str(), nullptr, 0));
            printf("prepare: run 0x%x membership 0x%02x\n", cfg.run_id(), cfg.membership());
            print(nodes, fan_out(nodes, rpc_timeout, [&cfg](ssr::Node::Stub &s, grpc::ClientContext &c, ssr::Status *o) {
                return s.Prepare(&c, cfg, o);
            }));
        } else if (cmd == "start") {
            std::string a;
            in >> a;
            const uint64_t ahead = a.empty() ? default_ahead : strtoull(a.c_str(), nullptr, 0);

            /* The effective round has to be one number for the whole cluster,
             * read from a clock every node shares: any one node's CUR_ROUND. */
            auto now = fan_out(nodes, rpc_timeout, [](ssr::Node::Stub &s, grpc::ClientContext &c, ssr::Status *o) {
                return s.GetStatus(&c, ssr::Empty(), o);
            });
            const Reply *ref = nullptr;
            for (const Reply &r : now)
                if (r.rpc.ok() && (r.st.core_status() & SSR_CORE_STATUS_TIMING_ARMED)) {
                    ref = &r;
                    break;
                }
            if (!ref) {
                printf("no node has its timing armed; prepare first\n");
                print(nodes, now);
                continue;
            }
            if (ptp_max_offset_ns > 0 && !clocks_agree(now, ptp_max_offset_ns)) {
                printf("clocks not synced; not starting (ptp_max_offset_ns = 0 in ssr.cfg starts anyway)\n");
                continue;
            }
            ssr::StartRequest req;
            req.set_effective_round(ref->st.cur_round() + ahead);
            printf("start: round %llu (node %u is at %llu, +%llu)\n", (unsigned long long)req.effective_round(),
                   ref->id, (unsigned long long)ref->st.cur_round(), (unsigned long long)ahead);
            /* ssrd waits until that round arrives, so the RPC may too. */
            const auto timeout = rpc_timeout + std::chrono::milliseconds(ahead * ref->st.round_ns() / 1000000);
            print(nodes, fan_out(nodes, timeout, [&req](ssr::Node::Stub &s, grpc::ClientContext &c, ssr::Status *o) {
                return s.Start(&c, req, o);
            }));
        } else if (cmd == "stop") {
            print(nodes, fan_out(nodes, rpc_timeout, [](ssr::Node::Stub &s, grpc::ClientContext &c, ssr::Status *o) {
                return s.Stop(&c, ssr::Empty(), o);
            }));
        } else {
            printf("commands: status, prepare [run_id] [membership], start [rounds_ahead], stop, quit\n");
        }
    }
    return 0;
}
