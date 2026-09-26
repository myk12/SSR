#include "ssr/agent_dataplane_backend_dev.hpp"

#include <cerrno>
#include <cstring>
#include <ctime>
#include <string>
#include <utility>

namespace ssr {

namespace {

[[noreturn]] void fail(const std::string& what, const int err)
{
    throw DataplaneError(what + ": " + std::strerror(-err));
}

std::uint64_t realtime_ns()
{
    timespec ts{};
    clock_gettime(CLOCK_REALTIME, &ts);
    return static_cast<std::uint64_t>(ts.tv_sec) * 1000000000ULL +
           static_cast<std::uint64_t>(ts.tv_nsec);
}

} // namespace

DeviceDataplaneBackend::DeviceDataplaneBackend(std::string device_path)
    : path_(std::move(device_path))
{
    dev_.fd = -1;
}

DeviceDataplaneBackend::~DeviceDataplaneBackend()
{
    close();
}

void DeviceDataplaneBackend::require_open() const
{
    if (state_ == DataplaneState::Closed) {
        throw DataplaneError("Dataplane is closed");
    }
}

ssr_status DeviceDataplaneBackend::hw_status() const
{
    ssr_status s{};
    // ssr_dev_status only issues an ioctl; the const_cast keeps the C API's
    // non-const signature out of the C++ interface.
    const int ret = ssr_dev_status(const_cast<ssr_dev*>(&dev_), &s);
    if (ret != 0) {
        fail("SSR_IOC_GET_STATUS", ret);
    }
    return s;
}

void DeviceDataplaneBackend::open()
{
    if (state_ != DataplaneState::Closed) {
        throw DataplaneError("Dataplane is already open");
    }

    const int ret = ssr_dev_open(&dev_, path_.c_str());
    if (ret != 0) {
        fail("open " + path_, ret);
    }

    // A previous process may have left the core running or halted.
    ssr_dev_disable(&dev_);
    const ssr_status s = hw_status();
    if (s.core_status & SSR_CORE_STATUS_HALTED) {
        ssr_dev_reboot(&dev_);
    }

    state_ = DataplaneState::Open;
    printf("DeviceDataplaneBackend: %s is node %u of %u, round %u ns\n",
           path_.c_str(), dev_.info.node_id, dev_.info.node_count, dev_.info.round_ns);
}

void DeviceDataplaneBackend::close() noexcept
{
    if (state_ == DataplaneState::Closed) {
        return;
    }
    if (state_ == DataplaneState::Running) {
        ssr_dev_disable(&dev_);
    }
    ssr_dev_close(&dev_);
    config_.reset();
    state_ = DataplaneState::Closed;
}

void DeviceDataplaneBackend::reset()
{
    require_open();

    int ret = ssr_dev_disable(&dev_);
    if (ret != 0) {
        fail("SSR_IOC_DISABLE", ret);
    }
    if (hw_status().core_status & SSR_CORE_STATUS_HALTED) {
        ret = ssr_dev_reboot(&dev_);
        if (ret != 0) {
            fail("SSR_IOC_REBOOT", ret);
        }
    }

    config_.reset();
    state_ = DataplaneState::Open;
}

void DeviceDataplaneBackend::configure(const RunConfig& config)
{
    require_open();
    if (state_ != DataplaneState::Open) {
        throw DataplaneError("Dataplane must be in Open state to configure");
    }

    config.validate();

    // The bitstream fixes the round length and the cluster size; the run
    // config has to agree with it rather than the other way round.
    if (config.round_length_ns != dev_.info.round_ns) {
        throw DataplaneError(
            "round_length_ns " + std::to_string(config.round_length_ns) +
            " does not match the bitstream's " + std::to_string(dev_.info.round_ns));
    }
    if (config.replica_num > dev_.info.node_count) {
        throw DataplaneError(
            "replica_num " + std::to_string(config.replica_num) +
            " exceeds the bitstream's NODE_COUNT " + std::to_string(dev_.info.node_count));
    }
    if (config.run_id == 0 || config.run_id > 0xffffffffULL) {
        throw DataplaneError("run_id must fit in 32 bits and be non-zero");
    }

    config_ = config;
    state_ = DataplaneState::Configured;
}

void DeviceDataplaneBackend::start()
{
    require_open();
    if (state_ != DataplaneState::Configured || !config_.has_value()) {
        throw DataplaneError("Dataplane must be configured before starting");
    }

    const RunConfig& c = *config_;
    const auto run_id = static_cast<std::uint32_t>(c.run_id);
    const std::uint32_t membership =
        c.replica_num >= 32 ? 0xffffffffu : (1u << c.replica_num) - 1u;
    // Round ids are ToD / round length, so the start time names a round.
    const std::uint64_t effective_round = c.start_time_ns / dev_.info.round_ns;

    int ret = ssr_dev_activate(&dev_, run_id, membership, effective_round, 0);
    if (ret != 0) {
        fail("SSR_IOC_ACTIVATE", ret);
    }

    // The activation stays pending until the effective round arrives; wait
    // that long plus a margin for the core to arm and settle.
    const std::uint64_t now = realtime_ns();
    const std::uint64_t until_start_ms =
        c.start_time_ns > now ? (c.start_time_ns - now) / 1000000ULL : 0;
    const int timeout_ms = static_cast<int>(until_start_ms) + 2000;

    ret = ssr_dev_wait_running(&dev_, run_id, timeout_ms);
    if (ret == -EIO) {
        const ssr_status s = hw_status();
        state_ = DataplaneState::Halted;
        throw DataplaneError(
            "core halted during activation: reason " + std::to_string(s.halt_reason) +
            " round " + std::to_string(s.halt_round));
    }
    if (ret != 0) {
        ssr_dev_disable(&dev_);
        fail("waiting for run " + std::to_string(run_id) + " to become active", ret);
    }

    state_ = DataplaneState::Running;
    printf("DeviceDataplaneBackend: run 0x%x active, membership 0x%x, effective round %llu\n",
           run_id, membership, static_cast<unsigned long long>(effective_round));
}

void DeviceDataplaneBackend::stop()
{
    require_open();
    if (state_ != DataplaneState::Running) {
        throw DataplaneError("Dataplane must be in Running state to stop");
    }

    const int ret = ssr_dev_disable(&dev_);
    if (ret != 0) {
        fail("SSR_IOC_DISABLE", ret);
    }

    // The configuration is kept; a new run needs a fresh run id anyway, so
    // the agent will configure() again before the next start().
    state_ = DataplaneState::Open;
}

DataplaneStatus DeviceDataplaneBackend::status() const
{
    DataplaneStatus result;
    result.state = state_;
    result.config_valid = config_.has_value();

    if (state_ != DataplaneState::Closed) {
        const ssr_status s = hw_status();
        if (s.core_status & SSR_CORE_STATUS_HALTED) {
            result.state = DataplaneState::Halted;
            result.error_code = s.halt_reason;
        } else if (s.fault != 0) {
            result.error_code = s.fault;
        }
    }

    result.running = (result.state == DataplaneState::Running);
    result.idle = (result.state == DataplaneState::Open ||
                   result.state == DataplaneState::Configured);
    return result;
}

} // namespace ssr
