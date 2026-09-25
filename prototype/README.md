# Host-Side Components

This directory contains the host-side software stack for the SSR FPGA application.

The host-side stack is responsible for interacting with the SSR dataplane implemented as a Corundum FPGA application. It includes the kernel driver, userspace control-plane library, shared register definitions, and optional command-line tools for bring-up and debugging.

## Directory Structure

```text
host/
├── include/
│   └── ssr_regs.h
├── kernel/
│   ├── Makefile
│   └── mqnic_app_ssr.c
├── python/
│   └── ssr/
│       ├── __init__.py
│       ├── regs.py
│       ├── device.py
│       └── mock_device.py
└── tools/
    ├── ssr-read-reg
    ├── ssr-write-reg
    └── ssr-config
```

Some subdirectories may be added incrementally as the project evolves. 

## Overview

The SSR system is split into three major parts:

1. **FPGA dataplane**

   The SSR dataplane is implemented as a Corundum FPGA application. It exposes a register block through the Corundum application BAR.

2. **Kernel driver**

   The kernel driver binds to the auxiliary device created by the parent `mqnic` PCIe driver. It accesses the application BAR, locates the SSR register block, and exposes a host-facing control interface.

3. **Userspace control plane**

   The userspace control plane configures the SSR dataplane, performs initialization, manages reconfiguration, and later handles recovery logic.

## `include/`

The `include/` directory contains shared host-side ABI definitions.

```text
include/
└── ssr_regs.h
```

`ssr_regs.h` defines the SSR application ID, register block type, version, register offsets, and bit definitions.

Every register lives in one RTL module, `fpga/rtl/ssr_csr.v`, in one 4 KiB page; its header comment is the map and this file copies it. If the map changes in RTL, this header (and `fpga/tb/mqnic_core_pcie_us/ssr_dataplane.py`) must change with it.

Example contents include:

```c
#define SSR_APP_ID              0x53535201
#define SSR_RB_TYPE             0x53535201
#define SSR_RB_VERSION          0x00000200

#define SSR_REG_SCRATCH         0x00c
#define SSR_REG_NODE            0x010   /* [7:0] node id, [15:8] node count */
#define SSR_REG_ROUND_NS        0x014
#define SSR_REG_FAULT           0x020

#define SSR_REG_CORE_CONTROL    0x100   /* consensus: 0x100, halt record: 0x140 */
#define SSR_REG_PROP_CONTROL    0x200   /* the proposal ring */
#define SSR_REG_DLV_CONTROL     0x300   /* delivery to the host */
                                        /* counters from 0x400 */
```

The node id, the cluster size and the round length are build-time parameters of the bitstream: software reads them, it does not configure them.

## `kernel/`

The `kernel/` directory contains the Linux kernel module for the SSR Corundum application.

Expected files:

```text
kernel/
├── Makefile
└── mqnic_app_ssr.c
```

The SSR kernel driver is implemented as an auxiliary bus driver. The parent `mqnic` PCIe driver detects the FPGA application ID and creates an auxiliary device such as:

```text
mqnic.app_53535201.0
```

The SSR auxiliary driver should bind to this device and perform the following tasks:

1. Obtain the parent `mqnic` device structure.
2. Access the already-mapped application BAR.
3. Enumerate the SSR register block.
4. Validate `TYPE` and `VERSION`, and log `NODE` and `ROUND_NS`.
5. Run a scratch register read/write test.
6. Expose a minimal host-facing interface through sysfs or, later, a character device.


### Build

From the `host/kernel/` directory:

```bash
make
```

The Makefile should point to the Corundum `mqnic` driver headers and the currently running kernel build directory.

### Load

After the parent `mqnic` driver has been loaded and the FPGA firmware has been detected:

```bash
sudo insmod mqnic_app_ssr.ko
```

Check the kernel log:

```bash
dmesg | tail -100
```

Expected messages include:

```text
mqnic_app_ssr_probe() called
SSR TYPE: 0x53535201
SSR VERSION: 0x00000200
SSR node 0 of 3, round 4000 ns
SSR self-test passed
SSR application driver loaded
```

## `python/`

The `python/` directory contains the userspace Python library for controlling and testing the SSR application.

Expected structure:

```text
python/
└── ssr/
    ├── __init__.py
    ├── regs.py
    ├── device.py
    └── mock_device.py
```

### `ssr/regs.py`

This file contains Python-side register definitions that mirror the kernel and RTL register map.

It should define constants such as:

```python
SSR_APP_ID = 0x53535201
SSR_RB_TYPE = 0x53535201
SSR_RB_VERSION = 0x00000200

SSR_REG_SCRATCH = 0x00C
SSR_REG_NODE = 0x010
SSR_REG_CORE_CONTROL = 0x100
```

The Python register definitions must remain consistent with `host/include/ssr_regs.h` and the FPGA RTL.

### `ssr/device.py`

This file implements the real userspace device abstraction.

In the v0 stage, it can access the kernel driver through sysfs. Later, it may be extended to use a character device, ioctl, mmap, or DMA buffers.

Typical methods may include:

```python
read_identity()        # node id, node count, round length, geometry
read_core_status()
read_fault()
write_scratch(value)
read_scratch()
activate(run_id, membership, effective_round)
```

### `ssr/mock_device.py`

This file implements a software mock version of the SSR device.

It is useful for testing userspace control-plane logic without requiring an FPGA, kernel driver, or real hardware.

The mock device should implement the same high-level interface as `device.py`.

## `tools/`

The `tools/` directory contains small command-line utilities for bring-up and debugging.

Expected tools may include:

```text
tools/
├── ssr-read-reg
├── ssr-write-reg
└── ssr-config
```

These tools should be thin wrappers around the Python library. They should not duplicate register-access logic.

Example usage:

```bash
./host/tools/ssr-read-reg 0x010     # NODE
```

## Current Bring-Up Plan

The current hardware bring-up plan is:

1. Build and flash the FPGA firmware with the SSR application enabled.

2. Confirm that the parent `mqnic` driver reports:

   ```text
   Application ID: 0x53535201
   Registered auxiliary bus device mqnic.app_53535201.0
   ```

3. Load the SSR auxiliary driver.

4. Verify that the driver can find the SSR register block.

5. Run a scratch register test.

6. Read `NODE` and `ROUND_NS` and check them against the cluster plan (they are fixed in the bitstream).

7. Program the rings and activate the core (`CFG_*`, then `CORE_CONTROL = enable | activate`); confirm that `CORE_STATUS` shows timing armed and not halted.

## Development Guidelines

Keep the hardware/software ABI explicit and stable.

When adding new registers:

1. Update the FPGA RTL register map.
2. Update `host/include/ssr_regs.h`.
3. Update `host/python/ssr/regs.py`.
4. Update the README or register map documentation.
5. Add a bring-up test in userspace or the kernel driver.

Do not add DMA, queue, or packet-path interfaces to the driver until the basic register path has been validated on real hardware.
