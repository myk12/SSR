#pragma once

/*
 * DeviceDataplaneBackend - the DataplaneBackend over /dev/ssrN.
 *
 * The control plane's five verbs map onto the driver's control ioctls
 * (kernel/ssr_uapi.h, wrapped by host/lib/ssr_dev.h):
 *
 *   open()       open the device, read its identity (node id, node count,
 *                round length, ring geometry)
 *   configure()  keep the RunConfig; the hardware is not touched yet
 *   start()      ACTIVATE with membership = the first replica_num nodes and
 *                effective_round = start_time_ns / round_ns, then wait until
 *                the activation is no longer pending
 *   stop()       DISABLE
 *   reset()      DISABLE, and REBOOT if the core is halted
 *
 * The data path (proposals in, verdicts out) is not the agent's business; an
 * application opens the same device and uses write()/read() or mmap().
 */

#include "ssr/ssr.h"
#include "ssr/agent_dataplane_backend.hpp"

#include <optional>
#include <string>

extern "C" {
#include "ssr_dev.h"
}

namespace ssr {

class DeviceDataplaneBackend final : public DataplaneBackend {
public:
    explicit DeviceDataplaneBackend(std::string device_path);
    ~DeviceDataplaneBackend() override;

    DeviceDataplaneBackend(const DeviceDataplaneBackend&) = delete;
    DeviceDataplaneBackend& operator=(const DeviceDataplaneBackend&) = delete;

    void open() override;
    void close() noexcept override;
    void reset() override;
    void configure(const RunConfig& config) override;
    void start() override;
    void stop() override;

    [[nodiscard]] DataplaneStatus status() const override;

    // Valid after open().
    [[nodiscard]] const ssr_info& info() const noexcept { return dev_.info; }
    [[nodiscard]] const std::optional<RunConfig>& config() const noexcept { return config_; }

private:
    void require_open() const;
    [[nodiscard]] ssr_status hw_status() const;

    std::string path_;
    ssr_dev dev_{};
    DataplaneState state_ = DataplaneState::Closed;
    std::optional<RunConfig> config_;
};

} // namespace ssr
