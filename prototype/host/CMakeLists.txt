cmake_minimum_required(VERSION 3.20)

project(
    ssr_host_runtime
    VERSION 0.1.0
    LANGUAGES C CXX
)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Protobuf CONFIG REQUIRED)
find_package(gRPC CONFIG REQUIRED)

set(SSR_CONTROL_PROTO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/proto")
set(SSR_CONTROL_PROTO "${SSR_CONTROL_PROTO_DIR}/ssr_control.proto")
set(SSR_CONTROL_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(SSR_CONTROL_GENERATED_SRC 
    "${SSR_CONTROL_GENERATED_DIR}/ssr_control.pb.cc"
    "${SSR_CONTROL_GENERATED_DIR}/ssr_control.grpc.pb.cc")
set(SSR_CONTROL_GENERATED_HDR
    "${SSR_CONTROL_GENERATED_DIR}/ssr_control.pb.h"
    "${SSR_CONTROL_GENERATED_DIR}/ssr_control.grpc.pb.h")

add_custom_command(
    OUTPUT ${SSR_CONTROL_GENERATED_SRC} ${SSR_CONTROL_GENERATED_HDR}
    COMMAND ${CMAKE_COMMAND}
            -E make_directory
            "${SSR_CONTROL_GENERATED_DIR}"

    COMMAND $<TARGET_FILE:protobuf::protoc>

    ARGS 
        --proto_path=${SSR_CONTROL_PROTO_DIR}
        --cpp_out=${SSR_CONTROL_GENERATED_DIR}
        --grpc_out=${SSR_CONTROL_GENERATED_DIR}
        --plugin=protoc-gen-grpc=$<TARGET_FILE:gRPC::grpc_cpp_plugin>
        ${SSR_CONTROL_PROTO}

    DEPENDS
        "${SSR_CONTROL_PROTO}"
        protobuf::protoc
        gRPC::grpc_cpp_plugin

    COMMENT "Generating SSR control protocol buffers and gRPC code"

    VERBATIM
)

add_library(
    ssr_control_proto
    STATIC ${SSR_CONTROL_GENERATED_SRC} ${SSR_CONTROL_GENERATED_HDR}
)

target_include_directories(
    ssr_control_proto
    PUBLIC "${SSR_CONTROL_GENERATED_DIR}"
)

target_link_libraries(
    ssr_control_proto
    PUBLIC protobuf::libprotobuf gRPC::grpc++
)

##################################################
#           Device library (C): /dev/ssrN
##################################################
# The ABI header lives with the driver (kernel/ssr_uapi.h) and the register
# map with the RTL (kernel/ssr_regs.h is the copy the driver builds against).
set(SSR_KERNEL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../kernel")

add_library(
    ssr_dev
    STATIC lib/ssr_dev.c
)

target_include_directories(
    ssr_dev
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/lib" "${SSR_KERNEL_DIR}"
)

target_compile_options(
    ssr_dev
    PRIVATE -Wall -Wextra
)

##################################################
#           Host Core Library
##################################################
add_library(
    ssr_host_core
    src/proto_conversion.cpp
    src/coordinator.cpp
    src/agent.cpp
    src/agent_grpc_service.cpp
    src/agent_dataplane_backend_mock.cpp
    src/agent_dataplane_backend_dev.cpp
)

target_include_directories(
    ssr_host_core
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include" 
)

target_link_libraries(
    ssr_host_core
    PUBLIC ssr_control_proto ssr_dev
)

target_compile_options(
    ssr_host_core
    PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion
)

add_executable(
    ssr-agent
    apps/ssr_agent_main.cpp
)

target_link_libraries(
    ssr-agent
    PUBLIC ssr_host_core
)

target_compile_options(
    ssr-agent
    PUBLIC -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion
)

add_executable(
    ssr-coordinator
    apps/ssr_coordinator_main.cpp
)

target_link_libraries(
    ssr-coordinator
    PUBLIC ssr_host_core
)

target_compile_options(
    ssr-coordinator
    PUBLIC -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion
)

##################################################
#           Benchmark application (C)
##################################################
add_executable(
    ssr-bench
    apps/ssr_bench.c
)

target_link_libraries(
    ssr-bench
    PUBLIC ssr_dev pthread
)

target_compile_options(
    ssr-bench
    PRIVATE -Wall -Wextra
)
