#include "ssr/ssr.h"
#include "ssr/agent.hpp"
#include "ssr/agent_grpc_service.hpp"
#include "ssr/agent_dataplane_backend_mock.hpp"
#include "ssr/agent_dataplane_backend_dev.hpp"

#include <grpcpp/grpcpp.h>

#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <fstream>

namespace {

struct AgentOptions {
    std::uint32_t node_id = 0;
    std::string listen_address;
    std::string coordinator_address;
    std::string device_path;    // empty: the mock backend
};

void print_usage_and_exit(
    const std::string_view program,
    const int exit_code
)
{
    std::cerr
        << "Usage:\n"
        << "  " << program 
        << " --id <node_id>"
        << " --listen <ip:port>"
        << " [--device /dev/ssr0]\n"
        << "  --device selects the SSR NIC; without it the agent drives a mock dataplane.\n"
        << "Example:\n"
        << "  " << program
        << " --id 1"
        << " --listen 0.0.0.0:50051";

    std::exit(exit_code);
}

AgentOptions parse_options(
    const int argc,
    char* argv[]
)
{
    AgentOptions options{};

    for (int index = 1; index < argc; ++index) {
        const std::string_view arg = argv[index];

        const auto require_value = [&](const std::string_view option) -> std::string {
            if (index + 1 >= argc) {
                throw std::invalid_argument(
                    std::string("Missing value for option '") + std::string(option) + "'"
                );
            }

            ++index;
            return argv[index];
        };

        if (arg == "--id") {
            options.node_id = static_cast<std::uint32_t>(std::stoul(require_value(arg)));
        } else if (arg == "--listen") {
            options.listen_address = require_value(arg);
        } else if (arg == "--device") {
            options.device_path = require_value(arg);
        } else if (arg == "--help" || arg == "-h") {
            print_usage_and_exit(argv[0], 0);
        } else {
            throw std::invalid_argument(
                std::string("Unknown option: '") + std::string(arg) + "'"
            );
        }
    }

    if (options.listen_address.empty()) {
        throw std::invalid_argument("Missing required option: --listen");
    }

    return options;
}
}// namespace

int main(const int argc, char* argv[])
{
    try {
        const AgentOptions options = parse_options(argc, argv);

        const auto node_id = static_cast<ssr::NodeId>(options.node_id);
        std::unique_ptr<ssr::DataplaneBackend> dataplane_backend;
        if (options.device_path.empty()) {
            dataplane_backend = std::make_unique<ssr::MockDataplaneBackend>();
        } else {
            dataplane_backend = std::make_unique<ssr::DeviceDataplaneBackend>(options.device_path);
        }
        ssr::SSRAgent ssr_agent(node_id, *dataplane_backend);
        ssr::AgentRPCServiceImpl service(ssr_agent);

        grpc::ServerBuilder builder;

        int selected_port = 0;
        builder.AddListeningPort(options.listen_address, grpc::InsecureServerCredentials(), &selected_port);
        builder.RegisterService(&service);

        std::unique_ptr<grpc::Server> server = builder.BuildAndStart();

        if (server == nullptr || selected_port <= 0) {
            throw std::runtime_error("Failed to start gRPC server");
        }

        std::cout
            << "SSR Node Agent started\n"
            << "  Node ID: " << node_id << "\n"
            << "  Listening on: " << options.listen_address << "\n"
            << "  Dataplane: " << (options.device_path.empty() ? "mock" : options.device_path) << "\n"
            << "  Coordinator: " << options.coordinator_address << "\n";
        
        server->Wait();
    } catch (const std::exception& ex) {
        std::cerr
            << "ssr-agent failed: "
            << ex.what() << "\n"; 
        return 1;
    }
}
