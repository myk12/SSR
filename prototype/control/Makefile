# control/Makefile - ssrd and ssrctl, into a host-local build directory (B).
#
# gRPC and protobuf come in two shapes and this file takes either:
#
#   DEPS set (default ~/opt/ssr-deps if it exists)  a self-built static
#     install, one prefix for protoc, grpc_cpp_plugin, headers and every
#     archive. pkg-config cannot describe it (its grpc .pc asks for an re2.pc
#     that was never installed), so the link line is every archive in
#     DEPS/lib in one group: the linker takes what is referenced.
#   DEPS empty  the distribution's packages (libgrpc++-dev,
#     protobuf-compiler-grpc): tools on PATH, libraries from pkg-config.
#
# grpc_cpp_plugin is gRPC's own protoc plugin; it writes the service stubs
# (ssr_control.grpc.pb.cc) that protoc alone does not know how to make.
#
#   make            everything
#   make clean
#   make DEPS=      force the distribution's install
#   make B=...      another build directory (default /var/tmp/$USER/ssr/<host>/control)

DEPS   ?= $(wildcard $(HOME)/opt/ssr-deps)
KERNEL := ../kernel
B      ?= bin

CXXFLAGS := -O2 -g -Wall -Wextra -std=c++20 -I. -I$(KERNEL) -I$(B)
CFLAGS   := -O2 -g -Wall -Wextra -I. -I$(KERNEL)

ifneq ($(DEPS),)
PROTOC   := $(DEPS)/bin/protoc
PLUGIN   := $(DEPS)/bin/grpc_cpp_plugin
CXXFLAGS += -isystem $(DEPS)/include
GRPCLIBS := -Wl,--start-group $(wildcard $(DEPS)/lib/*.a) -Wl,--end-group -lpthread -lrt -ldl -lm
else
PROTOC   := protoc
PLUGIN   := $(shell which grpc_cpp_plugin)
CXXFLAGS += $(shell pkg-config --cflags grpc++ protobuf)
GRPCLIBS := $(shell pkg-config --libs grpc++ protobuf) -lpthread
endif

GEN    := $(B)/ssr_control.pb.cc $(B)/ssr_control.grpc.pb.cc
PB_OBJ := $(B)/ssr_control.pb.o $(B)/ssr_control.grpc.pb.o
UAPI   := ssr_dev.h $(KERNEL)/ssr_uapi.h $(KERNEL)/ssr_regs.h

all: $(B)/ssrd $(B)/ssrctl

$(B):
	mkdir -p $(B)

# one protoc run makes both files (grouped target, GNU make >= 4.3)
$(GEN) &: ssr_control.proto | $(B)
	$(PROTOC) -I. --cpp_out=$(B) --grpc_out=$(B) --plugin=protoc-gen-grpc=$(PLUGIN) $<

# generated code is not ours to warn about
$(B)/%.pb.o: $(B)/%.pb.cc
	$(CXX) $(CXXFLAGS) -w -c -o $@ $<

$(B)/ssr_dev.o: ssr_dev.c $(UAPI) | $(B)
	$(CC) $(CFLAGS) -c -o $@ $<

$(B)/ssrd.o: ssrd.cpp ssr_cfg.h $(UAPI) $(GEN)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(B)/ssrctl.o: ssrctl.cpp ssr_cfg.h $(KERNEL)/ssr_regs.h $(GEN)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(B)/ssrd: $(B)/ssrd.o $(PB_OBJ) $(B)/ssr_dev.o
	@echo "  LD $@"
	@$(CXX) -o $@ $^ $(GRPCLIBS)

$(B)/ssrctl: $(B)/ssrctl.o $(PB_OBJ)
	@echo "  LD $@"
	@$(CXX) -o $@ $^ $(GRPCLIBS)

clean:
	rm -rf $(B)

.PHONY: all clean
