/* libuv_async: one cross-core message on its own, the libuv side of the cross-core comparison.
 *
 * Run:  libuv_async [--samples N] [--warmup N] [--cpu N] [--peer-cpu N]
 *
 * It is written the way that is fastest for libuv, as bench/alternatives/libuv_echo.c is, so that
 * no result of the harness comes from this file. `uv_async_send` is the one call libuv offers for
 * waking another loop, and libuv's documentation says it is the only API that is safe to call
 * from a thread that does not own the loop. This uses it the way libuv's own tests do: one
 * `uv_async_t` per loop, initialised once, sent to many times.
 *
 * Both loops block in `uv_run(UV_RUN_ONCE)` between messages, which is the mode rotor's
 * `rotor_post` is compared in. libuv has no call that polls for a notification without sleeping,
 * so a comparison against a spinning rotor would not be one.
 *
 * `uv_async_send` coalesces: several sends before the loop wakes deliver one callback. That costs
 * this program nothing, because it is a strict ping-pong with one message in flight.
 *
 * A round trip is two messages, so one message is half of it, which is what the samples hold.
 *
 * THE RESULT LINE. This program prints the JSON object bench/harness/report.zig writes, by hand,
 * because a C program cannot import that file. The field order there is the format, and the
 * parser refuses anything else, so a change to `render_json_line` has to be made here too. The
 * runner reports a parse failure by name, which is what catches it. */
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <uv.h>

#ifdef __linux__
/* `_GNU_SOURCE` is on the command line (build/alternatives.zig): defining it here would come
 * after the first system header, and glibc would already have read `features.h`. */
#include <sched.h>
#endif

/* The pinned release of libuv, which bench/alternatives/README.md records. */
#define VERSION "v1.52.1"

#define SAMPLES_DEFAULT 20000
#define WARMUP_DEFAULT 2000
/* Bounds the sample array, which is static: nothing here allocates per message. */
#define SAMPLES_MAX 1000000

/* The messages one round trip carries: the ping and the pong. */
#define MESSAGES_PER_ROUND_TRIP 2

/* Loops this program runs: the measuring one and its peer. */
#define LOOPS 2

#define NS_PER_S 1000000000ULL

/* Percentiles the report carries, in parts per thousand. */
#define P50 500
#define P99 990
#define P999 999
#define PER_MILLE 1000

static uv_loop_t loop_first;
static uv_loop_t loop_second;
static uv_async_t async_first;  /* the measuring side waits on this one */
static uv_async_t async_second; /* the peer waits on this one */

static uint64_t samples_ns[SAMPLES_MAX];

static volatile bool woken_first = false;
static volatile bool woken_second = false;
static volatile bool stopping = false;
static volatile bool peer_ready = false;
static volatile int peer_failure = 0;

/* Whether each thread was pinned to the core it was given. A row may name a core count only when
 * both were: two threads the scheduler placed may have shared one core, and then the row would be
 * measuring something else. This mirrors bench/harness/placement.zig. */
static bool pinned_first = false;
static bool pinned_second = false;

static uint64_t now_ns(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * NS_PER_S + (uint64_t)value.tv_nsec;
}

/* Pins the calling thread to `cpu`. Returns true only for a pin that took. Apple silicon has no
 * hard affinity, so this always returns false there, and the row then says 0 cores. */
static bool pin_to(long cpu) {
    if (cpu < 0) return false;
#ifdef __linux__
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET((int)cpu, &set);
    return pthread_setaffinity_np(pthread_self(), sizeof(set), &set) == 0;
#else
    (void)cpu;
    return false;
#endif
}

static void on_wake_first(uv_async_t *handle) {
    (void)handle;
    woken_first = true;
}

static void on_wake_second(uv_async_t *handle) {
    (void)handle;
    woken_second = true;
}

/* Runs `loop` until its notification arrives. `uv_run(UV_RUN_ONCE)` blocks for one iteration, so
 * a side that has nothing else armed sleeps until its peer sends. */
static void receive(uv_loop_t *loop, volatile bool *woken) {
    *woken = false;
    while (!*woken) uv_run(loop, UV_RUN_ONCE);
}

struct peer_options {
    long cpu;
};

/* The peer: it answers every notification with one of its own until it is told to stop. */
static void *serve(void *argument) {
    struct peer_options *options = (struct peer_options *)argument;
    pinned_second = pin_to(options->cpu);

    int status = uv_loop_init(&loop_second);
    if (status == 0) status = uv_async_init(&loop_second, &async_second, on_wake_second);
    if (status != 0) {
        peer_failure = status;
        peer_ready = true;
        return NULL;
    }
    peer_ready = true;

    for (;;) {
        receive(&loop_second, &woken_second);
        if (stopping) break;
        int sent = uv_async_send(&async_first);
        if (sent != 0) {
            peer_failure = sent;
            break;
        }
    }

    uv_close((uv_handle_t *)&async_second, NULL);
    uv_run(&loop_second, UV_RUN_DEFAULT);
    uv_loop_close(&loop_second);
    return NULL;
}

static int compare_u64(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left;
    uint64_t b = *(const uint64_t *)right;
    if (a < b) return -1;
    return a > b ? 1 : 0;
}

/* The value at `parts_per_thousand` of a sorted array, by the rank bench/harness/histogram.zig
 * uses: the first value at or above the rank, and never past the end. */
static uint64_t percentile(const uint64_t *sorted, uint32_t count, uint32_t parts_per_thousand) {
    uint64_t rank = ((uint64_t)count * parts_per_thousand + PER_MILLE - 1) / PER_MILLE;
    if (rank < 1) rank = 1;
    if (rank > count) rank = count;
    return sorted[rank - 1];
}

/* The JSON object bench/harness/report.zig writes, field for field and in its order. */
static void report(uint32_t samples, uint64_t span_ns) {
    qsort(samples_ns, samples, sizeof(samples_ns[0]), compare_u64);
    uint64_t operations = (uint64_t)samples * MESSAGES_PER_ROUND_TRIP;
    if (span_ns < 1) span_ns = 1;
    uint64_t per_second = operations * NS_PER_S / span_ns;
    unsigned cores = (pinned_first && pinned_second) ? LOOPS : 0;

    printf("{\"workload\":\"cross-core\",\"candidate\":\"libuv\",\"version\":\"" VERSION "\"");
    printf(",\"cores\":%u,\"connections\":1,\"payload_bytes\":0,\"load\":\"even\"", cores);
    printf(",\"duration_ns\":%" PRIu64 ",\"operations\":%" PRIu64, span_ns, operations);
    printf(",\"operations_per_second\":%" PRIu64, per_second);
    printf(",\"p50_ns\":%" PRIu64, percentile(samples_ns, samples, P50));
    printf(",\"p99_ns\":%" PRIu64, percentile(samples_ns, samples, P99));
    printf(",\"p999_ns\":%" PRIu64 ",\"overflow\":0}\n", percentile(samples_ns, samples, P999));
}

struct options {
    uint32_t samples;
    uint32_t warmup;
    long cpu;
    long peer_cpu;
};

/* A core, or -1 for the word `none`, which places nothing. */
static long parse_cpu(const char *value) {
    if (strcmp(value, "none") == 0) return -1;
    return strtol(value, NULL, 10);
}

static int parse(int argc, char **argv, struct options *options) {
    options->samples = SAMPLES_DEFAULT;
    options->warmup = WARMUP_DEFAULT;
    options->cpu = 0;
    options->peer_cpu = 1;
    for (int index = 1; index + 1 < argc; index += 2) {
        const char *name = argv[index];
        const char *value = argv[index + 1];
        if (strcmp(name, "--samples") == 0) {
            options->samples = (uint32_t)strtoul(value, NULL, 10);
        } else if (strcmp(name, "--warmup") == 0) {
            options->warmup = (uint32_t)strtoul(value, NULL, 10);
        } else if (strcmp(name, "--cpu") == 0) {
            options->cpu = parse_cpu(value);
        } else if (strcmp(name, "--peer-cpu") == 0) {
            options->peer_cpu = parse_cpu(value);
        } else {
            fprintf(stderr, "libuv_async: unknown argument %s\n", name);
            return 1;
        }
    }
    if (options->samples < 1 || options->samples > SAMPLES_MAX) {
        fprintf(stderr, "libuv_async: samples out of range\n");
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    struct options options;
    if (parse(argc, argv, &options) != 0) return 1;

    pinned_first = pin_to(options.cpu);
    if (uv_loop_init(&loop_first) != 0) return 1;
    if (uv_async_init(&loop_first, &async_first, on_wake_first) != 0) return 1;

    struct peer_options peer = {.cpu = options.peer_cpu};
    pthread_t thread;
    if (pthread_create(&thread, NULL, serve, &peer) != 0) return 1;
    while (!peer_ready) { /* the peer's loop and handle must exist before the first send */ }
    if (peer_failure != 0) {
        pthread_join(thread, NULL);
        return 1;
    }

    uint64_t span_ns = 0;
    uint32_t taken = 0;
    for (uint32_t round = 0; round < options.warmup + options.samples; round++) {
        uint64_t before = now_ns();
        if (uv_async_send(&async_second) != 0) return 1;
        receive(&loop_first, &woken_first);
        uint64_t elapsed = now_ns() - before;
        if (round >= options.warmup) {
            samples_ns[taken++] = elapsed / MESSAGES_PER_ROUND_TRIP;
            span_ns += elapsed;
        }
    }

    /* One last notification, which the peer answers by leaving rather than by notifying back. */
    stopping = true;
    if (uv_async_send(&async_second) != 0) return 1;
    pthread_join(thread, NULL);
    if (peer_failure != 0) return 1;

    uv_close((uv_handle_t *)&async_first, NULL);
    uv_run(&loop_first, UV_RUN_DEFAULT);
    uv_loop_close(&loop_first);

    report(taken, span_ns);
    fflush(stdout);
    return 0;
}
