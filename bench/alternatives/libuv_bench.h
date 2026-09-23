/* libuv_bench.h: what the three libuv programs of the harness share. Each is one of the runs a
 * runner collects, and each prints its result as the one line bench/harness/report_parse.zig
 * reads, field for field and in order.
 *
 * The three programs once printed three copies of that line. When the harness added `p9999_ns`
 * and `peak_rss_bytes` on 2026-09-22, all three fell behind, and every libuv timer, cross-core and
 * file-read row was refused for a day. One printer and one percentile here mean a change to the
 * line is made once.
 *
 * Everything is `static inline`, so a program that uses part of it compiles under -Werror. */
#ifndef ROTOR_LIBUV_BENCH_H
#define ROTOR_LIBUV_BENCH_H

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define BENCH_NS_PER_S 1000000000ULL

/* Percentiles in parts per ten thousand, as bench/harness/percentile.zig counts them: p9999 has no
 * whole number of parts per thousand. */
#define BENCH_PER_TEN_THOUSAND 10000ULL
#define BENCH_P50 5000ULL
#define BENCH_P99 9900ULL
#define BENCH_P999 9990ULL
#define BENCH_P9999 9999ULL

/* The monotonic clock in nanoseconds, the one bench/harness/clock.zig reads. */
static inline uint64_t bench_now_ns(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * BENCH_NS_PER_S + (uint64_t)value.tv_nsec;
}

static inline int bench_compare_u64(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left;
    uint64_t b = *(const uint64_t *)right;
    if (a < b) return -1;
    return a > b ? 1 : 0;
}

/* The value at `parts` of `sorted`, by the nearest-rank rule of bench/harness/percentile.zig: the
 * rank rounds up and is clamped into the sample. An empty sample answers 0. */
static inline uint64_t bench_percentile(const uint64_t *sorted, uint64_t count, uint64_t parts) {
    if (count == 0) return 0;
    uint64_t rank = (count * parts + BENCH_PER_TEN_THOUSAND - 1) / BENCH_PER_TEN_THOUSAND;
    if (rank < 1) rank = 1;
    if (rank > count) rank = count;
    return sorted[rank - 1];
}

/* One run's result, before its percentiles. */
struct bench_result {
    const char *workload;
    const char *candidate;
    const char *version;
    unsigned cores;
    uint64_t connections;
    uint64_t payload_bytes;
    uint64_t duration_ns;
    uint64_t operations;
};

/* Sorts `samples` and prints the result line. `peak_rss_bytes` is 0, as every program of these
 * workloads prints: only the echo runner measures memory. */
static inline void bench_print_result(const struct bench_result *result, uint64_t *samples,
                                      uint64_t count) {
    qsort(samples, count, sizeof(samples[0]), bench_compare_u64);
    uint64_t span_ns = result->duration_ns < 1 ? 1 : result->duration_ns;
    uint64_t per_second = result->operations * BENCH_NS_PER_S / span_ns;

    printf("{\"workload\":\"%s\",\"candidate\":\"%s\",\"version\":\"%s\"", result->workload,
           result->candidate, result->version);
    printf(",\"cores\":%u,\"connections\":%" PRIu64 ",\"payload_bytes\":%" PRIu64
           ",\"load\":\"even\"",
           result->cores, result->connections, result->payload_bytes);
    printf(",\"duration_ns\":%" PRIu64 ",\"operations\":%" PRIu64, span_ns, result->operations);
    printf(",\"operations_per_second\":%" PRIu64, per_second);
    printf(",\"p50_ns\":%" PRIu64, bench_percentile(samples, count, BENCH_P50));
    printf(",\"p99_ns\":%" PRIu64, bench_percentile(samples, count, BENCH_P99));
    printf(",\"p999_ns\":%" PRIu64, bench_percentile(samples, count, BENCH_P999));
    printf(",\"p9999_ns\":%" PRIu64, bench_percentile(samples, count, BENCH_P9999));
    printf(",\"overflow\":0,\"peak_rss_bytes\":0}\n");
    fflush(stdout);
}

#endif
