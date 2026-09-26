# The Host Side: Driver, Library, Benchmark

**Status:** written 2026-09-25 against the first AU200 bitstream; **not yet run on
hardware**. The kernel module builds clean (W=1) against 6.8 headers, the user-space
code compiles, and the ABI matches `ssr_regs.h` / the cocotb tests. Everything below
that says "measured" is still to be measured.

**In one paragraph.** The app block has no interrupt and the host never sees the wire.
Its whole interface is three DMA rings and one register page (`ring_buffer.md`). The
driver `mqnic_app_ssr.ko` (`kernel/ssr_*.c`) allocates the rings, programs the bases, and exposes
`/dev/ssrN` with two exits onto the same rings: a *kernel-mediated* path where `write()`
copies a piece into the proposal ring and `read()` copies a decided round out of the
payload ring, and a *zero-copy* path where the process `mmap()`s the rings and the
register page and does everything itself. The control plane's agent (`ssr-agent
--device /dev/ssr0`) uses only the ioctls. `ssr-bench` exercises both data paths and
reports latency.

```
                 ssr-agent (gRPC)           application / ssr-bench
                 ioctl: ACTIVATE, DISABLE   copy: write() read() poll()
                        GET_STATUS ...      zc:   mmap() + MMIO doorbell
                        │                          │
   ─────────────────────┼──────────────────────────┼──────────  /dev/ssrN
                        │   mqnic_app_ssr.ko       │
                        │   rings (coherent DMA)   │  poller kthread (read() path only)
                        ▼                          ▼
             ┌────────────┐  ┌──────────────┐  ┌──────────────┐  ┌───────────┐
             │ regs 4 KiB │  │ proposal ring│  │ payload ring │  │verdict ring│
             │ (BAR, MMIO)│  │ 2^d × 4 KiB  │  │ 2^8 × N × 32K│  │ 2^8 × 64 B │
             └────────────┘  └──────────────┘  └──────────────┘  └───────────┘
                                host → NIC        NIC → host        NIC → host
```

---

## 1. Files

| file | what |
|---|---|
| `kernel/ssr_main.c` | the module and the auxiliary driver bound to `mqnic.app_53535201`: probe (self test, identity, bring-up order), remove |
| `kernel/ssr_rings.c` | the three rings: allocation, priming, the base/enable registers |
| `kernel/ssr_datapath.c` | `/dev/ssrN`: `write()` / `read()` / `poll()` / `mmap()`, the poller thread, the cdev |
| `kernel/ssr_control.c` | the ioctls and the sysfs attributes: the core's registers on behalf of user space |
| `kernel/ssr_drv.h` | what those four share: the device struct, register accessors, ring addressing |
| `kernel/ssr_uapi.h` | the user-space ABI: mmap offsets, `struct ssr_info/activate/status/counters/delivery`, ioctls |
| `kernel/ssr_regs.h` | the register map and the ring formats (shared with the RTL and cocotb) |
| `kernel/Makefile` | builds the patched `mqnic.ko` from `fpga/corundum/modules/mqnic`, then `mqnic_app_ssr.ko` |
| `host/lib/ssr_dev.{h,c}` | a small C library over `/dev/ssrN`: control, the copy path, the zero-copy path |
| `host/src/agent_dataplane_backend_dev.cpp` | `DeviceDataplaneBackend`: the control plane's five verbs over the ioctls |
| `host/apps/ssr_bench.c` | proposes at a rate, consumes records, reports commit / peer latency |

## 2. What the driver does at probe

1. Checks the scratch register, reads `NODE`, `ROUND_NS`, `GEOMETRY`, `PAGE_BYTES`
   (`ssr_read_identity`, `ssr_main.c`) and refuses anything implausible.
2. Allocates the three rings (`ssr_rings.c`): proposal ring `2^prop_depth_log2`
   entries of 4 KiB (module parameter, default 2^4), payload ring `2^pay_depth_log2 × N
   × 2^region_shift` (2^8 × 3 × 32 KiB = 24 MiB on this bitstream), verdict ring
   `2^ver_depth_log2 × 64 B` (16 KiB). The small two come from `dma_alloc_coherent`.
   The payload ring is six times the buddy allocator's 4 MiB limit, and the testbed
   kernel has no CMA and the IOMMU off, so `dma_alloc_coherent` cannot provide it;
   the driver scans `ZONE_NORMAL` (the NIC's NUMA node first) and takes the first
   2 MiB-aligned range that `alloc_contig_range()` can clear — the kernel's own huge-page
   mechanism — then `dma_map_page`s it. x86 DMA is cache-coherent, so nothing else changes;
   `mmap()` of that ring goes through `remap_pfn_range` instead of `dma_mmap_coherent`.
3. Fills every verdict record's `seq` with `~0`. The hardware writes seq 0, 1, 2 … so a
   slot whose seq equals the one we wait for is fresh; nothing else marks a record.
4. Programs the bases, depth and enables; sets `PROP_PRODUCER = PROP_CONSUMER`; reads
   `SEQ` as the first record to wait for; turns delivery on; leaves the core **disabled**.
5. Creates `/dev/ssrN` and sysfs `identity`, `core_status`, `fault`, `counters`, `scratch`.
6. Starts one kernel thread that polls the verdict ring every `poll_us` (default 5 µs,
   0 = spin) and wakes `read()`/`poll()` waiters. This is the price of having no
   interrupt; the zero-copy path does not use it.

The core is not touched again until an application or the agent issues `SSR_IOC_ACTIVATE`.

## 3. The two paths

### 3.1 The kernel-mediated path: `write()` / `read()`

`write(fd, piece, n)`, `1 ≤ n ≤ 4032`: the kernel checks room against the `PROP_CONSUMER`
register, zeroes the 64-byte entry header, copies the piece in, and writes
`PROP_PRODUCER`. It blocks while the ring is full (1 s timeout, `EAGAIN` with
`O_NONBLOCK`). One `write()` is one piece is one entry; a proposal never spans entries.

`read(fd, buf, cap)`: waits for the next verdict record (the poller wakes it), validates
the pages the record commits (kind 2, right node, round, fragment index; length
`≤ 4032`), and copies out a `struct ssr_delivery` followed by every committed node's
payload, node by node. `node_off[k]`/`node_len[k]` slice it. Our own node's length is 0:
the host proposed those bytes and does not need them back. `cap` too small is `EMSGSIZE`
with nothing consumed; 64 KiB is enough for this bitstream (3 nodes × 5 pages).

This path costs two copies and two syscalls per round plus the poller's period. It is
the one to use first on hardware, because every mistake is visible in `dmesg`.

### 3.2 The zero-copy path: `mmap()`

`SSR_IOC_GET_INFO` reports the ring geometry; the process maps four regions at fixed
offsets of the device's address space:

| offset | region | protection |
|---|---|---|
| `0x00000000` | proposal ring | RW |
| `0x10000000` | payload ring | R |
| `0x20000000` | verdict ring | R |
| `0x30000000` | the SSR register page (4 KiB of the BAR) | RW, uncached |

Then, with no syscall on the fast path (`host/lib/ssr_dev.c`):

- **propose** — `ssr_zc_propose()`: write the entry, `sfence`, then one 32-bit store of
  the new producer index to the mapped `PROP_PRODUCER`. Room comes from the last
  `prop_consumer` a verdict record carried; only when that says "full" does it read
  the `PROP_CONSUMER` register.
- **receive** — `ssr_zc_poll()`: spin on the `seq` field of the slot the cursor points
  at; when it matches, acquire-fence, decode the record, advance. `ssr_zc_page()`
  addresses a page in the payload ring by (round, node, fragment); the payload is read
  in place.

The register page is mapped with `pgprot_noncached` through `io_remap_pfn_range`, so
the doorbell store reaches the NIC in order after the `sfence`. The rings are coherent
DMA memory, so on x86 no cache maintenance is needed on either side.

`SSR_IOC_RESET_CURSOR` (or `ssr_zc_reset_cursor()`) repositions after a long pause:
records age out after `2^ver_depth_log2` rounds and a stale cursor would wait forever.

### 3.3 Coexistence

Both paths see the same rings and the hardware "consumes" nothing; the kernel keeps its
own cursor for `read()`, a zero-copy process keeps its own. Two writers on the proposal
ring would race on the producer index, so one process should own proposing. The agent
never touches the data path.

## 4. Control: the ioctls and the agent

| ioctl | does |
|---|---|
| `SSR_IOC_GET_INFO` | node id / count, round length, ring geometry (for `mmap`) |
| `SSR_IOC_ACTIVATE` | `run_id`, `membership`, `effective_round` (0 = now + `rounds_ahead`); the core arms and joins at that boundary |
| `SSR_IOC_DISABLE` | `CORE_CONTROL = 0` |
| `SSR_IOC_REBOOT` | clears a halt; then ACTIVATE with a fresh run id |
| `SSR_IOC_GET_STATUS` | `core_status`, run id, sound set, round / commit counts, the halt record, `fault`, ring status, next `seq` |
| `SSR_IOC_GET_COUNTERS` | the 78 counter words from `0x400` |
| `SSR_IOC_PROP_FLUSH` / `PROP_CLEAR_ERR` | proposal ring recovery |
| `SSR_IOC_SET_DELIVERY` | `DLV_CTRL` bits |
| `SSR_IOC_RESET_CURSOR` | `read()` continues from the hardware's next seq |
| `SSR_IOC_ENABLE` | timing on without a run; `CUR_ROUND` follows the PHC (it reads 0 while the core is disabled) |

`DeviceDataplaneBackend` maps the control plane's `RunConfig` onto these:

- `configure()` checks `round_length_ns == info.round_ns` and `replica_num ≤ node_count`
  (the bitstream fixes both; the run config must agree) and keeps the config.
- `start()` activates with `membership = (1 << replica_num) − 1` and
  `effective_round = start_time_ns / round_ns` — round ids are ToD / round length, so
  the coordinator's start time names a round directly — then waits until
  `cur_run_id == run_id` and `ACT_PENDING` clears, or reports the halt.
- `stop()` disables; `reset()` disables and reboots if halted.

The agent selects it with `ssr-agent --id N --listen 0.0.0.0:50051 --device /dev/ssr0`;
without `--device` it keeps the mock.

## 5. Bring-up

```
# 0. once per BAR layout: a bitstream that adds or resizes a BAR needs a host reboot
#    after flashing, so the BIOS re-sizes the bridge windows; a hot reload
#    (mqnic-fw -b) leaves the new BAR "<unassigned>" and mqnic never maps it.
#    (The payload ring, 24 MiB physically contiguous, is past the buddy allocator's
#    4 MiB; the driver gets it with alloc_contig_range(), see §2, so no CMA or
#    IOMMU boot parameter is needed. dmesg says where it landed.)

# 1. build both modules (patched mqnic first, then the app driver)
make -C prototype/kernel modules            # KDIR=/lib/modules/$(uname -r)/build

# 2. load
sudo insmod prototype/kernel/build/mqnic/mqnic.ko
sudo insmod prototype/kernel/build/mqnic_app_ssr/mqnic_app_ssr.ko poll_us=5
dmesg | tail                                # "SSR node 0 of 3, round 4000 ns, ..."
cat /sys/bus/auxiliary/devices/mqnic.app_53535201.0/identity

# 3. PTP: the round id is ToD / round_ns on every node, so the NICs' clocks must
#    agree before ACTIVATE. ptp4l on the mqnic interface, phc2sys for the host clock
#    (only needed for ssr-bench --peer).

# 4. user space
cmake --preset debug -S prototype/host && cmake --build --preset debug
sudo prototype/host/build/ssr-bench --monitor 5        # status once a second, no activation

# 5. one run, all three nodes, the copy path
sudo ssr-bench --mode copy --activate 0x77 --membership 7 --rounds-ahead 2500 \
               --count 10000 --size 256 --interval-us 100
# then the same with --mode zc
```

Order of first checks on hardware, each of which fails on its own if the previous is
wrong: scratch register readback (probe fails otherwise) → identity → `--monitor`
shows `TIME_VALID` once PTP locks → ACTIVATE on one node alone with `--membership 1`
commits its own proposals → three nodes.

## 6. What `ssr-bench` measures

Every piece carries a 32-byte header `{magic, node, seq, t_real_ns, t_mono_ns}`.

- **commit latency**: our `propose()` to the moment the record committing it is seen
  (`frag_count[self]` running past the piece's sequence). This is the number the
  paper cares about: proposal in, verdict out, through the NIC and two peers.
- **peer latency** (`--peer`): a peer's `t_real_ns` to our `CLOCK_REALTIME` when we see
  its page committed. Meaningful only with phc2sys on every host.

Both are reported as min / p50 / p90 / p99 / p99.9 / max. `--mode copy` vs `--mode zc`
under the same load is the driver's own overhead.

## 7. Open

- **Interrupt.** The app block has no interrupt line yet; the kernel path polls. When
  the `read()` path's latency matters (it does not for the benchmark, which uses zc),
  wire `DLV` completion into an mqnic event queue.
- **Halt in the data path.** A halt is visible only through `GET_STATUS`; `read()` keeps
  waiting for a record that will not come. A halted core should wake readers with
  `EIO`. Not done; the benchmark's `--monitor` shows it.
- **Membership is a prefix.** `start()` builds `membership` as the first `replica_num`
  nodes. The control plane's `RunConfig` has no node list; when it grows one, pass it
  through.
- **Not yet measured on hardware.** Every number here is from the simulator.
