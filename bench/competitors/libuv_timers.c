/* libuv_timers: the timer churn workload on libuv, the same measurement rotor_timers makes.
 *
 * Run:  libuv_timers [--timers N] [--period-us U] [--seconds S]
 *
 * `timers` timers are armed at once for `period_us`, and each is armed again as it fires, so the
 * count in flight never changes and the loop's timer structure is worked continuously.
 *
 * It prints the line every candidate of this workload prints:
 *
 *     timer-churn <candidate> <version> <timers> <fires> <span_ns> <p50> <p99> <p999>
 *
 * **libuv timers are milliseconds.** `uv_timer_start` takes its timeout as a whole number of
 * milliseconds, so a period this program cannot express is one under 1,000 microseconds, and a
 * period that is not a whole number of them is rounded down. rotor's timer takes nanoseconds.
 * That is a difference in what the two can be asked for and not only in what they do, and the
 * comparison is only fair at periods libuv can state exactly. The program refuses any other, so
 * a run cannot silently compare a 1,500 microsecond timer against a 1,000 microsecond one. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <uv.h>

#define TIMERS_MAX 16384
#define SAMPLES_MAX (1 << 17)
#define NS_PER_US 1000ull
#define NS_PER_MS 1000000ull
#define NS_PER_S 1000000000ull
#define US_PER_MS 1000ull
#define PER_MILLE 1000ull

static uv_timer_t timers[TIMERS_MAX];
/* When each armed timer is due. */
static uint64_t due_ns[TIMERS_MAX];
static uint64_t lateness_ns[SAMPLES_MAX];
static unsigned samples_taken;
static uint64_t fired;

static uint64_t period_ns;
static uint64_t deadline_ns;
static unsigned in_flight;

static uint64_t now_ns(void)
{
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * NS_PER_S + (uint64_t)value.tv_nsec;
}

static void arm(uv_timer_t *handle)
{
    size_t index = (size_t)(handle - timers);
    due_ns[index] = now_ns() + period_ns;
    uv_timer_start(handle, (uv_timer_cb)handle->data, period_ns / NS_PER_MS, 0);
}

static void on_timer(uv_timer_t *handle)
{
    size_t index = (size_t)(handle - timers);
    uint64_t at_ns = now_ns();
    fired++;
    if (samples_taken < SAMPLES_MAX) {
        /* A timer that fired early would give a negative, which this reads as zero, as
         * rotor_timers does. */
        lateness_ns[samples_taken++] =
            at_ns > due_ns[index] ? at_ns - due_ns[index] : 0;
    }
    if (at_ns >= deadline_ns) {
        uv_timer_stop(handle);
        uv_close((uv_handle_t *)handle, NULL);
        in_flight--;
        return;
    }
    arm(handle);
}

static int compare_u64(const void *left, const void *right)
{
    uint64_t a = *(const uint64_t *)left;
    uint64_t b = *(const uint64_t *)right;
    if (a < b) {
        return -1;
    }
    return a > b ? 1 : 0;
}

/* The nearest-rank percentile of sorted samples, in parts per thousand, as rotor_timers takes
 * it, so the two report one definition. */
static uint64_t percentile(uint64_t parts_per_thousand)
{
    if (samples_taken == 0) {
        return 0;
    }
    uint64_t rank = ((uint64_t)samples_taken * parts_per_thousand + PER_MILLE - 1) / PER_MILLE;
    if (rank == 0) {
        rank = 1;
    }
    if (rank > samples_taken) {
        rank = samples_taken;
    }
    return lateness_ns[rank - 1];
}

static int parse_number(const char *text, uint64_t *out)
{
    char *end = NULL;
    long long value = strtoll(text, &end, 10);
    if (end == text || *end != '\0' || value <= 0) {
        return 0;
    }
    *out = (uint64_t)value;
    return 1;
}

int main(int argc, char **argv)
{
    uint64_t wanted_timers = 1024;
    uint64_t period_us = 1000;
    uint64_t seconds = 3;

    for (int index = 1; index + 1 < argc; index += 2) {
        uint64_t value = 0;
        if (!parse_number(argv[index + 1], &value)) {
            fprintf(stderr, "libuv_timers: %s needs a positive number\n", argv[index]);
            return 1;
        }
        if (strcmp(argv[index], "--timers") == 0) {
            wanted_timers = value;
        } else if (strcmp(argv[index], "--period-us") == 0) {
            period_us = value;
        } else if (strcmp(argv[index], "--seconds") == 0) {
            seconds = value;
        } else {
            fprintf(stderr, "libuv_timers: unknown argument %s\n", argv[index]);
            return 1;
        }
    }
    if (wanted_timers > TIMERS_MAX) {
        fprintf(stderr, "libuv_timers: at most %d timers\n", TIMERS_MAX);
        return 1;
    }
    /* See the header: libuv cannot be asked for a period that is not whole milliseconds, so a
     * run that would round one down is refused rather than compared. */
    if (period_us % US_PER_MS != 0) {
        fprintf(stderr,
                "libuv_timers: libuv timers are milliseconds; %llu us is not a whole one\n",
                (unsigned long long)period_us);
        return 1;
    }

    period_ns = period_us * NS_PER_US;
    uv_loop_t *loop = uv_default_loop();
    uint64_t started_ns = now_ns();
    deadline_ns = started_ns + seconds * NS_PER_S;
    in_flight = (unsigned)wanted_timers;

    for (unsigned index = 0; index < wanted_timers; index++) {
        if (uv_timer_init(loop, &timers[index])) {
            return 1;
        }
        timers[index].data = (void *)on_timer;
        arm(&timers[index]);
    }

    uv_run(loop, UV_RUN_DEFAULT);
    uint64_t span_ns = now_ns() - started_ns;

    qsort(lateness_ns, samples_taken, sizeof(lateness_ns[0]), compare_u64);
    printf("timer-churn libuv %s %llu %llu %llu %llu %llu %llu\n",
           uv_version_string(),
           (unsigned long long)wanted_timers,
           (unsigned long long)fired,
           (unsigned long long)span_ns,
           (unsigned long long)percentile(500),
           (unsigned long long)percentile(990),
           (unsigned long long)percentile(999));
    fflush(stdout);
    return 0;
}
