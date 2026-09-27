# bench/Makefile - ssr-bench, into a host-local build directory (B).
#
# The benchmark is an application: it needs only the device library
# (../control/ssr_dev.c) and the driver's ABI headers (../kernel), no gRPC.

CONTROL := ../control
KERNEL  := ../kernel
# Host-local, like control/: the tree is shared over NFS.
B       ?= bin

CFLAGS := -O2 -g -Wall -Wextra -I$(CONTROL) -I$(KERNEL)
UAPI   := $(CONTROL)/ssr_dev.h $(KERNEL)/ssr_uapi.h $(KERNEL)/ssr_regs.h

all: $(B)/ssr-bench

$(B):
	mkdir -p $(B)

$(B)/ssr_bench.o: ssr_bench.c $(UAPI) | $(B)
	$(CC) $(CFLAGS) -c -o $@ $<

$(B)/ssr_dev.o: $(CONTROL)/ssr_dev.c $(UAPI) | $(B)
	$(CC) $(CFLAGS) -c -o $@ $<

$(B)/ssr-bench: $(B)/ssr_bench.o $(B)/ssr_dev.o
	$(CC) -o $@ $^ -lpthread

clean:
	rm -rf $(B)

.PHONY: all clean
