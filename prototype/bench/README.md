# Measuring SSR

Everything that measures the prototype lives here, apart from the system itself
(`../fpga`, `../kernel`, `../control`). `make` here builds `ssr-bench` into a
host-local directory (`/var/tmp/$USER/ssr/<host>/bench`, the tree being shared over
NFS); it needs only `../control/ssr_dev.c` and the driver's headers, no gRPC.

- `ssr_bench.c` — the benchmark: proposes at a rate on the copy or the zero-copy
  path, consumes verdict records, reports commit latency (own proposal in, record
  out) and, with `--peer`, peer latency (a peer's send time to our seeing its
  page committed). Its header comment is the manual.
- `scripts/` — run a sweep, collect the output (to come). Bringing the hosts
  and the switch up is the testbed's job (ncs-fabric: `ops.host_setup`,
  `ops.tofino_setup --mode domains --manifest ../testbed/manifest.yaml`).
- `results/` — raw output, one directory per run, named by date and bitstream
  git hash (to come).
- `plots/` — figures and the scripts that draw them (to come).

Every timestamp on every node is the NIC's PHC: ssrd runs ptp4l on the non-SSR
port and phc2sys locks `CLOCK_REALTIME` to that PHC, so `ssr_bench` reads the
same clock through the vDSO that the core reads for its round ids. No host
clock is ever used on its own.
