// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * ssr_bench - propose, watch the verdicts, measure the host side.
 *
 * The same experiment on both paths of /dev/ssrN:
 *
 *   --mode copy   write() / read(): the kernel copies, a poller thread wakes us
 *   --mode zc     mmap(): we write the ring entry and the doorbell, poll the
 *                 verdict ring, read the peers' pages in place
 *
 * Every proposal piece starts with a bench header carrying the sender's node,
 * a sequence number and two timestamps. Two latencies come out:
 *
 *   commit latency   from our own propose() to the moment the record that
 *                    commits that fragment is seen here (CLOCK_MONOTONIC,
 *                    same host). Our fragments commit in order, so the
 *                    running total of frag_count[self] maps records to
 *                    sequence numbers.
 *   peer latency     from a peer's send timestamp (CLOCK_REALTIME on its
 *                    host, PTP-disciplined) to our seeing its page committed.
 *                    Only meaningful when the hosts' clocks are synchronised
 *                    (phc2sys); --peer turns it on.
 *
 * Usage:
 *   ssr_bench --dev /dev/ssr0 --mode zc --activate 0x77 --membership 7 \
 *             --count 10000 --interval-us 100 --size 256 [--peer] [--verbose]
 *   ssr_bench --dev /dev/ssr0 --monitor 10          # just print records for 10 s
 */
#define _GNU_SOURCE
#include "ssr_dev.h"

#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define BENCH_MAGIC 0x53535242454e4348ULL   /* "SSRBENCH" */

struct bench_hdr {
	uint64_t magic;
	uint32_t node;
	uint32_t seq;
	uint64_t t_real_ns;         /* CLOCK_REALTIME at propose */
	uint64_t t_mono_ns;         /* CLOCK_MONOTONIC at propose */
};

struct opts {
	const char *dev;
	int zc;
	int activate;
	uint32_t run_id;
	uint32_t membership;
	uint32_t rounds_ahead;
	uint64_t count;
	uint32_t size;
	uint32_t interval_us;
	int peer;
	int verbose;
	int monitor_s;
	int pin_cpu;
};

static struct opts o = {
	.dev = "/dev/ssr0", .membership = 0x7, .rounds_ahead = 2500, .count = 1000,
	.size = 64, .interval_us = 100, .pin_cpu = -1,
};

static struct ssr_dev dev;
static volatile sig_atomic_t stop_flag;

static uint64_t mono_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static uint64_t real_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void on_signal(int sig)
{
	(void)sig;
	stop_flag = 1;
}

/* ---- samples ---- */
struct samples {
	uint64_t *v;
	size_t n, cap;
};

static void sample_add(struct samples *s, uint64_t x)
{
	if (s->n == s->cap) {
		s->cap = s->cap ? s->cap * 2 : 4096;
		s->v = realloc(s->v, s->cap * sizeof(*s->v));
		if (!s->v) {
			perror("realloc");
			exit(1);
		}
	}
	s->v[s->n++] = x;
}

static int cmp_u64(const void *a, const void *b)
{
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return x < y ? -1 : x > y;
}

static void sample_report(const char *name, struct samples *s)
{
	if (!s->n) {
		printf("%-16s no samples\n", name);
		return;
	}
	qsort(s->v, s->n, sizeof(*s->v), cmp_u64);
	printf("%-16s n=%zu  min %.2f  p50 %.2f  p90 %.2f  p99 %.2f  p99.9 %.2f  max %.2f  (us)\n",
	       name, s->n,
	       s->v[0] / 1e3, s->v[s->n / 2] / 1e3, s->v[s->n * 9 / 10] / 1e3,
	       s->v[s->n * 99 / 100] / 1e3, s->v[s->n * 999 / 1000] / 1e3, s->v[s->n - 1] / 1e3);
}

/* ---- shared state between the producer and the consumer ---- */
static uint64_t *t_propose;         /* CLOCK_MONOTONIC per sequence number */
static uint64_t proposed, committed;
static struct samples commit_lat, peer_lat, record_gap;
static uint64_t records_seen, halted_at_seq;
static uint64_t last_record_mono;

static void on_record(const struct ssr_record *r,
		      const uint8_t *(*page)(void *, uint64_t, uint32_t, uint32_t, uint32_t *), void *ctx)
{
	uint64_t now = mono_ns();
	uint64_t nowr = real_ns();
	uint32_t self = r->self_index, k, f, n;

	records_seen++;
	if (last_record_mono)
		sample_add(&record_gap, now - last_record_mono);
	last_record_mono = now;

	/* our own fragments, in order */
	for (n = r->frag_count[self]; n; n--, committed++)
		if (committed < proposed)
			sample_add(&commit_lat, now - t_propose[committed]);

	if (o.peer)
		for (k = 0; k < r->node_count; k++) {
			if (k == self || !(r->present_set & (1u << k)))
				continue;
			for (f = 0; f < r->frag_count[k]; f++) {
				uint32_t len;
				const uint8_t *p = page(ctx, r->round_id, k, f, &len);
				struct bench_hdr h;

				if (!p || len < sizeof(h))
					continue;
				memcpy(&h, p, sizeof(h));
				if (h.magic == BENCH_MAGIC && nowr > h.t_real_ns)
					sample_add(&peer_lat, nowr - h.t_real_ns);
			}
		}

	if (o.verbose)
		printf("seq %" PRIu64 " round %" PRIu64 " run 0x%x commit 0x%02x present 0x%02x frags [%u %u %u] consumer %u\n",
		       r->seq, r->round_id, r->run_id, r->commit_set, r->present_set,
		       r->frag_count[0], r->frag_count[1], r->frag_count[2], r->prop_consumer);
}

/* ---- the zero-copy path ---- */
static const uint8_t *zc_page(void *ctx, uint64_t round, uint32_t node, uint32_t frag, uint32_t *len)
{
	const uint8_t *p = ssr_zc_page(ctx, round, node, frag, len);
	return p + SSR_PAGE_PAYLOAD_OFFSET;
}

static void *zc_consumer(void *arg)
{
	struct ssr_record r;
	(void)arg;

	while (!stop_flag) {
		if (ssr_zc_poll(&dev, &r, NULL))
			on_record(&r, zc_page, &dev);
		else if (o.interval_us >= 1000)
			usleep(1);          /* a slow experiment need not burn a core */
	}
	return NULL;
}

/* ---- the kernel path ---- */
struct copy_ctx {
	struct ssr_delivery *d;
	const uint8_t *payload;
};

static const uint8_t *copy_page(void *ctx, uint64_t round, uint32_t node, uint32_t frag, uint32_t *len)
{
	struct copy_ctx *c = ctx;
	(void)round;
	/* read() concatenated the node's pages; the bench header is at the start
	 * of each 4032-byte piece (pieces are full unless the sender sent less) */
	if (!c->d->node_len[node])
		return NULL;
	*len = SSR_PROPOSAL_PIECE_BYTES;
	if ((uint64_t)frag * SSR_PROPOSAL_PIECE_BYTES + sizeof(struct bench_hdr) > c->d->node_len[node]) {
		*len = 0;
		return NULL;
	}
	return c->payload + c->d->node_off[node] + (size_t)frag * SSR_PROPOSAL_PIECE_BYTES;
}

static void *copy_consumer(void *arg)
{
	size_t cap = sizeof(struct ssr_delivery) + 8 * 5 * SSR_PROPOSAL_PIECE_BYTES;
	uint8_t *buf = malloc(cap);
	(void)arg;

	while (!stop_flag) {
		int n = ssr_dev_recv_copy(&dev, buf, cap);
		struct ssr_delivery *d = (struct ssr_delivery *)buf;
		struct ssr_record r;
		struct copy_ctx c = { d, buf + sizeof(*d) };

		if (n == -EINTR)
			continue;
		if (n < 0) {
			fprintf(stderr, "read: %s\n", strerror(-n));
			break;
		}
		ssr_record_decode(d->record, &r);
		on_record(&r, copy_page, &c);
	}
	free(buf);
	return NULL;
}

/* ---- the producer ---- */
static int propose_one(uint32_t seq, uint8_t *piece)
{
	struct bench_hdr h = {
		.magic = BENCH_MAGIC, .node = dev.info.node_id, .seq = seq,
		.t_real_ns = real_ns(), .t_mono_ns = mono_ns(),
	};
	int ret;

	memcpy(piece, &h, sizeof(h));
	t_propose[seq] = h.t_mono_ns;
	for (;;) {
		ret = o.zc ? ssr_zc_propose(&dev, piece, o.size) : ssr_dev_propose_copy(&dev, piece, o.size);
		if (ret != -EAGAIN)
			break;
		usleep(1);              /* ring full: the NIC drains 5 a round */
	}
	return ret < 0 ? ret : 0;
}

static void print_status(void)
{
	struct ssr_status s;

	if (ssr_dev_status(&dev, &s))
		return;
	printf("status 0x%02x run 0x%x sound 0x%02x round %llu commits %llu halts %u fault 0x%x seq %llu prop %u/%u\n",
	       s.core_status, s.cur_run_id, s.sound_set, (unsigned long long)s.cur_round,
	       (unsigned long long)s.commit_count, s.halt_count, s.fault,
	       (unsigned long long)s.seq, s.prop_producer, s.prop_consumer);
	if (s.core_status & SSR_CORE_STATUS_HALTED)
		printf("HALTED: reason %u round %llu witness 0x%02x sound before 0x%02x\n",
		       s.halt_reason, (unsigned long long)s.halt_round, s.halt_witness,
		       (s.halt_sound_set >> 8) & 0xff);
}

static void usage(const char *p)
{
	fprintf(stderr,
		"usage: %s [--dev /dev/ssr0] [--mode copy|zc] [--activate RUN --membership M [--rounds-ahead N]]\n"
		"          [--count N] [--size B] [--interval-us U] [--peer] [--verbose] [--cpu C]\n"
		"       %s --monitor SECONDS\n", p, p);
	exit(2);
}

int main(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "dev", 1, 0, 'd' }, { "mode", 1, 0, 'm' }, { "activate", 1, 0, 'a' },
		{ "membership", 1, 0, 'M' }, { "rounds-ahead", 1, 0, 'r' }, { "count", 1, 0, 'c' },
		{ "size", 1, 0, 's' }, { "interval-us", 1, 0, 'i' }, { "peer", 0, 0, 'p' },
		{ "verbose", 0, 0, 'v' }, { "monitor", 1, 0, 'w' }, { "cpu", 1, 0, 'C' }, { 0, 0, 0, 0 },
	};
	int c, ret;
	pthread_t consumer;
	uint8_t *piece;
	uint64_t t0, t1, deadline;

	while ((c = getopt_long(argc, argv, "d:m:a:M:r:c:s:i:pvw:C:", lo, NULL)) != -1) {
		switch (c) {
		case 'd': o.dev = optarg; break;
		case 'm': o.zc = strcmp(optarg, "zc") == 0; if (!o.zc && strcmp(optarg, "copy")) usage(argv[0]); break;
		case 'a': o.activate = 1; o.run_id = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'M': o.membership = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'r': o.rounds_ahead = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'c': o.count = strtoull(optarg, NULL, 0); break;
		case 's': o.size = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'i': o.interval_us = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'p': o.peer = 1; break;
		case 'v': o.verbose = 1; break;
		case 'w': o.monitor_s = atoi(optarg); break;
		case 'C': o.pin_cpu = atoi(optarg); break;
		default: usage(argv[0]);
		}
	}
	if (o.size < sizeof(struct bench_hdr) || o.size > SSR_PROPOSAL_PIECE_BYTES) {
		fprintf(stderr, "--size must be %zu..%d\n", sizeof(struct bench_hdr), SSR_PROPOSAL_PIECE_BYTES);
		return 2;
	}
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	if (o.pin_cpu >= 0) {
		cpu_set_t set;
		CPU_ZERO(&set);
		CPU_SET(o.pin_cpu, &set);
		sched_setaffinity(0, sizeof(set), &set);
	}

	ret = ssr_dev_open(&dev, o.dev);
	if (ret) {
		fprintf(stderr, "open %s: %s\n", o.dev, strerror(-ret));
		return 1;
	}
	printf("%s: node %u of %u, round %u ns, proposal ring 2^%u, mode %s\n", o.dev,
	       dev.info.node_id, dev.info.node_count, dev.info.round_ns, dev.info.prop_depth_log2,
	       o.zc ? "zero-copy" : "kernel copy");

	if (o.activate) {
		ret = ssr_dev_activate(&dev, o.run_id, o.membership, 0, o.rounds_ahead);
		if (!ret)
			ret = ssr_dev_wait_running(&dev, o.run_id, (int)(o.rounds_ahead * dev.info.round_ns / 1000000) + 2000);
		if (ret) {
			fprintf(stderr, "activate run 0x%x: %s\n", o.run_id, strerror(-ret));
			print_status();
			return 1;
		}
		printf("running run 0x%x membership 0x%02x\n", o.run_id, o.membership);
	}

	if (o.zc) {
		ret = ssr_dev_map(&dev);
		if (ret) {
			fprintf(stderr, "mmap: %s\n", strerror(-ret));
			return 1;
		}
	}

	if (o.monitor_s) {
		o.verbose = 1;
		pthread_create(&consumer, NULL, o.zc ? zc_consumer : copy_consumer, NULL);
		for (int s = 0; s < o.monitor_s && !stop_flag; s++) {
			sleep(1);
			print_status();
		}
		stop_flag = 1;
		pthread_cancel(consumer);
		pthread_join(consumer, NULL);
		ssr_dev_close(&dev);
		return 0;
	}

	t_propose = calloc(o.count, sizeof(*t_propose));
	piece = calloc(1, o.size);
	if (!t_propose || !piece)
		return 1;
	pthread_create(&consumer, NULL, o.zc ? zc_consumer : copy_consumer, NULL);

	t0 = mono_ns();
	for (uint64_t i = 0; i < o.count && !stop_flag; i++) {
		ret = propose_one((uint32_t)i, piece);
		if (ret) {
			fprintf(stderr, "propose %" PRIu64 ": %s\n", i, strerror(-ret));
			break;
		}
		proposed = i + 1;
		if (o.interval_us) {
			uint64_t until = t_propose[i] + (uint64_t)o.interval_us * 1000;
			while (mono_ns() < until && !stop_flag)
				if (o.interval_us >= 50)
					usleep(1);
		}
	}
	t1 = mono_ns();

	/* let the last ones commit: a round plus the control period, generously */
	deadline = mono_ns() + 200000000ULL;
	while (committed < proposed && mono_ns() < deadline && !stop_flag)
		usleep(100);
	stop_flag = 1;
	if (!o.zc)
		pthread_cancel(consumer);           /* read() may be blocked */
	pthread_join(consumer, NULL);

	printf("\nproposed %" PRIu64 " pieces of %u B in %.3f ms (%.1f/s), committed %" PRIu64 ", records %" PRIu64 "\n",
	       proposed, o.size, (t1 - t0) / 1e6, proposed * 1e9 / (double)(t1 - t0 ? t1 - t0 : 1), committed, records_seen);
	sample_report("commit latency", &commit_lat);
	if (o.peer)
		sample_report("peer latency", &peer_lat);
	sample_report("record gap", &record_gap);
	print_status();
	if (halted_at_seq)
		printf("halted at record %" PRIu64 "\n", halted_at_seq);

	ssr_dev_close(&dev);
	return committed == proposed ? 0 : 3;
}
