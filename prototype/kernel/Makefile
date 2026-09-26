# SPDX-License-Identifier: BSD-2-Clause-Views

ifneq ($(KERNELRELEASE),)

MQNIC_DIR ?= $(src)/../mqnic

KBUILD_EXTRA_SYMBOLS := $(MQNIC_DIR)/Module.symvers

# mqnic.h from the patched mqnic tree next to us; our sources and headers
# are symlinked into the build directory by prepare-ssr.
ccflags-y += -I$(MQNIC_DIR)
ccflags-y += -I$(src)

obj-m += mqnic_app_ssr.o
mqnic_app_ssr-y := ssr_main.o ssr_rings.o ssr_datapath.o ssr_control.o

else

ifneq ($(KERNEL_SRC),)
KDIR ?= $(KERNEL_SRC)
endif

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# kernel/ sits in prototype/; the corundum submodule is prototype/fpga/corundum
PROJECT_ROOT := $(abspath $(PWD)/..)
CORUNDUM_MQNIC_DIR := $(PROJECT_ROOT)/fpga/corundum/modules/mqnic

BUILD_DIR := $(PWD)/build
MQNIC_DIR := $(BUILD_DIR)/mqnic
SSR_BUILD_DIR := $(BUILD_DIR)/mqnic_app_ssr
PATCH_DIR := $(PWD)/patches

.PHONY: all prepare-mqnic patch-mqnic mqnic prepare-ssr modules clean clean-ssr clean-mqnic distclean help

all: modules

prepare-mqnic:
	mkdir -p $(BUILD_DIR)
	rsync -a --delete $(CORUNDUM_MQNIC_DIR)/ $(MQNIC_DIR)/

patch-mqnic: prepare-mqnic
	@if [ -d "$(PATCH_DIR)" ]; then \
		for p in $(PATCH_DIR)/*.patch; do \
			if [ -f "$$p" ]; then \
				echo "Applying patch $$p"; \
				patch -d $(MQNIC_DIR) -p0 -N < "$$p" || true; \
			fi; \
		done; \
	fi

mqnic: patch-mqnic
	$(MAKE) -C $(MQNIC_DIR) KDIR=$(KDIR)

SSR_SOURCES := ssr_main.c ssr_rings.c ssr_datapath.c ssr_control.c \
               ssr_drv.h ssr_regs.h ssr_uapi.h Makefile

prepare-ssr:
	mkdir -p $(SSR_BUILD_DIR)
	for f in $(SSR_SOURCES); do ln -sf $(PWD)/$$f $(SSR_BUILD_DIR)/$$f; done

modules: mqnic prepare-ssr
	$(MAKE) -C $(KDIR) M=$(SSR_BUILD_DIR) modules

clean-ssr:
	@if [ -d "$(SSR_BUILD_DIR)" ]; then \
		$(MAKE) -C $(KDIR) M=$(SSR_BUILD_DIR) clean; \
	fi

clean-mqnic:
	@if [ -d "$(MQNIC_DIR)" ]; then \
		$(MAKE) -C $(MQNIC_DIR) KDIR=$(KDIR) clean; \
	fi

clean: clean-ssr

distclean:
	rm -rf $(BUILD_DIR)

help:
	$(MAKE) -C $(KDIR) M=$(SSR_BUILD_DIR) help

endif
