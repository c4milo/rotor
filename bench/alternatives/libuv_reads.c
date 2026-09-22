/* libuv_reads: O_DIRECT reads, sequential and random, the libuv side of the file workload.
 *
 * Run:  libuv_reads PATH [--transfer read|write] [--pattern seq|random] [--depth N]
 *                        [--block-bytes B]
 *                        [--backend threadpool|uring] [--seconds S] [--file-bytes N]
 *
 * It keeps `depth` reads in flight against one file and re-issues each as it completes, as
 * bench/files/rotor_reads.zig does, so the two measure the same shape.
 *
 * TWO CONFIGURATIONS, AND WHAT SELECTS THEM. libuv v1.52.1 reads a file on its thread pool unless
 * the program opts into an io_uring ring, and the opt-in has two halves, both required:
 *
 *   1. The program calls uv_loop_configure(loop, UV_LOOP_USE_IO_URING_SQPOLL). Without it,
 *      src/unix/linux.c uv__iou_get_sqe leaves the ring at -1 and every read falls to the pool.
 *   2. The environment sets UV_USE_IO_URING to a positive number, and the kernel is at least
 *      5.10.186. src/unix/linux.c uv__use_io_uring checks both, for SQPOLL alone.
 *
 * `--backend uring` does the first. The runner does the second. Neither is enough alone, and the
 * program prints which it got rather than assuming: a row that claims io_uring while running on
 * the pool would be the whole comparison wrong. There is no io_uring on macOS, so `--backend
 * uring` there is refused rather than silently answered by the pool.
 *
 * SAME BLOCKS, SAME ORDER. The random pattern draws offsets from splitmix64 with the seed
 * bench/files/rotor_reads.zig uses, and the constants are copied from src/core/random.zig. Two
 * candidates reading different blocks would compare which blocks the device had cached.
 *
 * O_DIRECT MEANS ALIGNMENT. Every buffer address, offset and length is a multiple of the block
 * size, or the kernel refuses the read. macOS has no O_DIRECT and gets F_NOCACHE, which is what
 * rotor's kqueue backend does; decision 2 says no file number from macOS is published as a claim.
 */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <uv.h>

#define VERSION "v1.52.1"

#define DEPTH_MAX 128
#define SAMPLES_MAX (1 << 17)
#define NS_PER_S 1000000000ULL
#define PER_MILLE 1000ULL
#define P50 500ULL
#define P99 990ULL
#define P999 999ULL

/* The seed bench/files/rotor_reads.zig draws its offsets from. Zig writes it 0x5eed_da7a; C has
 * no digit separator, so the same value is spelled without one here. */
#define SEED 0x5eedda7aULL

/* splitmix64, as src/core/random.zig writes it. */
#define SPLITMIX_STEP 0x9E3779B97F4A7C15ULL
#define SPLITMIX_FIRST 0xBF58476D1CE4E5B9ULL
#define SPLITMIX_SECOND 0x94D049BB133111EBULL

static uint64_t random_state = SEED;

static uint64_t random_next(void) {
    random_state += SPLITMIX_STEP;
    uint64_t mixed = random_state;
    mixed = (mixed ^ (mixed >> 30)) * SPLITMIX_FIRST;
    mixed = (mixed ^ (mixed >> 27)) * SPLITMIX_SECOND;
    return mixed ^ (mixed >> 31);
}

enum pattern { PATTERN_SEQ, PATTERN_RANDOM };

/* Which direction the run measures. rotor_reads takes the same option and names the two workloads
 * apart, so a read row and a write row never share a series. */
enum transfer { TRANSFER_READ, TRANSFER_WRITE };

/* What a write run appends to the path it was given, so it writes its own file and never overwrites
 * one the caller named. rotor_reads uses the same suffix and the same rule. */
#define WRITE_SUFFIX ".rotor_write"

/* The byte every block of the file holds before a run. rotor_reads writes the same one, so both
 * programs read and overwrite the same content whichever of them created the file. */
#define FILL_BYTE 0x5a
enum backend { BACKEND_THREADPOOL, BACKEND_URING };

struct options {
    enum transfer transfer;
    const char *path;
    enum pattern pattern;
    enum backend backend;
    uint32_t depth;
    uint32_t block_bytes;
    uint64_t seconds;
    uint64_t file_bytes;
};

/* One read in flight: libuv needs a request and a buffer per read. */
struct slot {
    uv_fs_t request;
    uv_buf_t buffer;
    char *bytes;
    uint64_t started_ns;
};

static struct slot slots[DEPTH_MAX];
static uint64_t latency_ns[SAMPLES_MAX];
static uint32_t taken;
static uint64_t reads;
static uint64_t blocks;
static uint64_t next_block;
static uint64_t deadline_ns;
static bool stopping;
static uv_file file_handle;
static uv_loop_t *loop_handle;
static struct options run_options;

static uint64_t now_ns(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * NS_PER_S + (uint64_t)value.tv_nsec;
}

/* The offset of the next read, in bytes, aligned by construction. */
static uint64_t next_offset(void) {
    uint64_t block;
    if (run_options.pattern == PATTERN_SEQ) {
        block = next_block;
        next_block = (next_block + 1) % blocks;
    } else {
        block = random_next() % blocks;
    }
    return block * run_options.block_bytes;
}

static void on_read(uv_fs_t *request);

/* Issues one transfer from `slot`, unless the run is over. A write issues no fdatasync: O_DIRECT
 * bypasses the page cache and not the device's own, so the row is the write path and not a flush. */
static int issue(struct slot *slot) {
    if (stopping) return 0;
    uv_fs_req_cleanup(&slot->request);
    slot->buffer = uv_buf_init(slot->bytes, run_options.block_bytes);
    slot->started_ns = now_ns();
    slot->request.data = slot;
    if (run_options.transfer == TRANSFER_WRITE) {
        return uv_fs_write(loop_handle, &slot->request, file_handle, &slot->buffer, 1,
                           (int64_t)next_offset(), on_read);
    }
    return uv_fs_read(loop_handle, &slot->request, file_handle, &slot->buffer, 1,
                      (int64_t)next_offset(), on_read);
}

static void on_read(uv_fs_t *request) {
    struct slot *slot = (struct slot *)request->data;
    if (request->result < 0) {
        fprintf(stderr, "libuv_reads: transfer failed: %s\n", uv_strerror((int)request->result));
        stopping = true;
        uv_fs_req_cleanup(request);
        return;
    }
    uint64_t at_ns = now_ns();
    reads++;
    if (taken < SAMPLES_MAX) latency_ns[taken++] = at_ns - slot->started_ns;
    if (at_ns >= deadline_ns) stopping = true;
    if (issue(slot) != 0) stopping = true;
}

static int compare_u64(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left;
    uint64_t b = *(const uint64_t *)right;
    if (a < b) return -1;
    return a > b ? 1 : 0;
}

static uint64_t percentile(uint32_t count, uint64_t parts_per_thousand) {
    if (count == 0) return 0;
    uint64_t rank = ((uint64_t)count * parts_per_thousand + PER_MILLE - 1) / PER_MILLE;
    if (rank < 1) rank = 1;
    if (rank > count) rank = count;
    return latency_ns[rank - 1];
}

/* The JSON object bench/harness/report.zig writes, field for field and in its order.
 * `connections` carries the queue depth and `payload_bytes` the block size, because those are
 * what this workload's rows vary; the workload's name says which is which. */
static void report(uint64_t span_ns, bool on_uring) {
    qsort(latency_ns, taken, sizeof(latency_ns[0]), compare_u64);
    if (span_ns < 1) span_ns = 1;
    uint64_t per_second = reads * NS_PER_S / span_ns;
    const char *name = on_uring ? "libuv (io_uring)" : "libuv (thread pool)";

    printf("{\"workload\":\"file-%s-%s\",\"candidate\":\"%s\",\"version\":\"" VERSION "\"",
           run_options.transfer == TRANSFER_WRITE ? "write" : "read",
           run_options.pattern == PATTERN_SEQ ? "seq" : "random", name);
    printf(",\"cores\":0,\"connections\":%u,\"payload_bytes\":%u,\"load\":\"even\"",
           run_options.depth, run_options.block_bytes);
    printf(",\"duration_ns\":%" PRIu64 ",\"operations\":%" PRIu64, span_ns, reads);
    printf(",\"operations_per_second\":%" PRIu64, per_second);
    printf(",\"p50_ns\":%" PRIu64, percentile(taken, P50));
    printf(",\"p99_ns\":%" PRIu64, percentile(taken, P99));
    printf(",\"p999_ns\":%" PRIu64 ",\"overflow\":0}\n", percentile(taken, P999));
    fflush(stdout);
}

/* True when the file's last block already holds FILL_BYTE, so the fill can be skipped. The last
 * block is the one an interrupted fill leaves unwritten, so sampling it is enough. */
static bool already_filled(int descriptor, const struct options *options, void *block) {
    off_t last = (off_t)(options->file_bytes - options->block_bytes);
    ssize_t count = pread(descriptor, block, options->block_bytes, last);
    if (count != (ssize_t)options->block_bytes) return false;
    const unsigned char *bytes = (const unsigned char *)block;
    for (uint32_t index = 0; index < options->block_bytes; index++) {
        if (bytes[index] != FILL_BYTE) return false;
    }
    return true;
}

/* Opens the file, creating and filling it when it is missing, short or unwritten, and sets the
 * nearest thing the host has to O_DIRECT. */
static int open_and_fill(const struct options *options) {
    int flags = O_RDWR | O_CREAT;
#ifdef O_DIRECT
    flags |= O_DIRECT;
#endif
    /* A write run appends WRITE_SUFFIX, so it writes a file of its own and can never overwrite the
     * one the caller named. rotor_reads follows the same rule with the same suffix. */
    char path[PATH_MAX];
    if (options->transfer == TRANSFER_WRITE) {
        int written = snprintf(path, sizeof(path), "%s%s", options->path, WRITE_SUFFIX);
        if (written < 0 || (size_t)written >= sizeof(path)) {
            fprintf(stderr, "libuv_reads: path too long for a write run\n");
            return -1;
        }
    } else {
        int written = snprintf(path, sizeof(path), "%s", options->path);
        if (written < 0 || (size_t)written >= sizeof(path)) {
            fprintf(stderr, "libuv_reads: path too long\n");
            return -1;
        }
    }
    int descriptor = open(path, flags, 0644);
    if (descriptor < 0) {
        fprintf(stderr, "libuv_reads: cannot open %s: %s\n", path, strerror(errno));
        return -1;
    }
#ifdef F_NOCACHE
    /* macOS has no O_DIRECT. This is what rotor's kqueue backend sets. */
    fcntl(descriptor, F_NOCACHE, 1);
#endif

    off_t size = lseek(descriptor, 0, SEEK_END);

    void *block = NULL;
    if (posix_memalign(&block, options->block_bytes, options->block_bytes) != 0) {
        close(descriptor);
        return -1;
    }

    /* THE RIGHT SIZE IS NOT ENOUGH. A file that is already file_bytes long may still be unwritten:
     * fallocate and ftruncate allocate blocks and write none, and `truncate -s 256M` does the same.
     * An O_DIRECT read of an unwritten extent on ext4 or XFS is answered by the filesystem with
     * zeros and never reaches the device, so a read row would measure an extent flag. rotor_reads
     * samples the same block for the same reason; before 2026-09-22 this early return skipped the
     * fill whenever rotor had already created the file at full size, and both programs then read
     * holes. */
    if (size >= 0 && (uint64_t)size >= options->file_bytes &&
        already_filled(descriptor, options, block)) {
        free(block);
        return descriptor;
    }

    if (size < 0 || (uint64_t)size < options->file_bytes) {
        if (ftruncate(descriptor, (off_t)options->file_bytes) != 0) {
            free(block);
            close(descriptor);
            return -1;
        }
    }

    memset(block, FILL_BYTE, options->block_bytes);
    for (uint64_t offset = 0; offset < options->file_bytes; offset += options->block_bytes) {
        if (pwrite(descriptor, block, options->block_bytes, (off_t)offset) < 0) {
            free(block);
            close(descriptor);
            return -1;
        }
    }
    free(block);
    return descriptor;
}

static int parse_cpu_free_options(int argc, char **argv, struct options *options) {
    options->pattern = PATTERN_SEQ;
    options->transfer = TRANSFER_READ;
    options->backend = BACKEND_THREADPOOL;
    options->depth = 32;
    options->block_bytes = 4096;
    options->seconds = 3;
    options->file_bytes = 256ULL << 20;
    if (argc < 2) {
        fprintf(stderr, "libuv_reads: a path is required\n");
        return 1;
    }
    options->path = argv[1];

    for (int index = 2; index + 1 < argc; index += 2) {
        const char *name = argv[index];
        const char *value = argv[index + 1];
        if (strcmp(name, "--transfer") == 0) {
            if (strcmp(value, "read") == 0) options->transfer = TRANSFER_READ;
            else if (strcmp(value, "write") == 0) options->transfer = TRANSFER_WRITE;
            else { fprintf(stderr, "libuv_reads: unknown transfer %s\n", value); return 1; }
        } else if (strcmp(name, "--pattern") == 0) {
            if (strcmp(value, "seq") == 0) options->pattern = PATTERN_SEQ;
            else if (strcmp(value, "random") == 0) options->pattern = PATTERN_RANDOM;
            else { fprintf(stderr, "libuv_reads: unknown pattern %s\n", value); return 1; }
        } else if (strcmp(name, "--backend") == 0) {
            if (strcmp(value, "threadpool") == 0) options->backend = BACKEND_THREADPOOL;
            else if (strcmp(value, "uring") == 0) options->backend = BACKEND_URING;
            else { fprintf(stderr, "libuv_reads: unknown backend %s\n", value); return 1; }
        } else if (strcmp(name, "--depth") == 0) {
            options->depth = (uint32_t)strtoul(value, NULL, 10);
        } else if (strcmp(name, "--block-bytes") == 0) {
            options->block_bytes = (uint32_t)strtoul(value, NULL, 10);
        } else if (strcmp(name, "--seconds") == 0) {
            options->seconds = strtoull(value, NULL, 10);
        } else if (strcmp(name, "--file-bytes") == 0) {
            options->file_bytes = strtoull(value, NULL, 10);
        } else {
            fprintf(stderr, "libuv_reads: unknown argument %s\n", name);
            return 1;
        }
    }

    if (options->depth < 1 || options->depth > DEPTH_MAX) {
        fprintf(stderr, "libuv_reads: depth must be 1 to %d\n", DEPTH_MAX);
        return 1;
    }
    if (options->block_bytes < 512 || (options->block_bytes & (options->block_bytes - 1)) != 0) {
        fprintf(stderr, "libuv_reads: block bytes must be a power of two, 512 or more\n");
        return 1;
    }
    if (options->file_bytes < (uint64_t)options->block_bytes * options->depth) {
        fprintf(stderr, "libuv_reads: the file is smaller than one round of reads\n");
        return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (parse_cpu_free_options(argc, argv, &run_options) != 0) return 1;

#ifndef __linux__
    if (run_options.backend == BACKEND_URING) {
        fprintf(stderr, "libuv_reads: there is no io_uring on this host\n");
        return 1;
    }
#endif

    uv_loop_t loop;
    if (uv_loop_init(&loop) != 0) return 1;
    loop_handle = &loop;
    if (run_options.backend == BACKEND_URING) {
        if (uv_loop_configure(&loop, UV_LOOP_USE_IO_URING_SQPOLL) != 0) {
            fprintf(stderr, "libuv_reads: this libuv refused UV_LOOP_USE_IO_URING_SQPOLL\n");
            return 1;
        }
        /* The other half is the environment, which the runner sets. Saying so here means a row
         * taken by hand without it is not mistaken for an io_uring row. */
        const char *value = getenv("UV_USE_IO_URING");
        if (value == NULL || atoi(value) <= 0) {
            fprintf(stderr, "libuv_reads: UV_USE_IO_URING is not set, so reads use the pool\n");
            return 1;
        }
    }

    int descriptor = open_and_fill(&run_options);
    if (descriptor < 0) return 1;
    file_handle = descriptor;
    blocks = run_options.file_bytes / run_options.block_bytes;

    for (uint32_t index = 0; index < run_options.depth; index++) {
        void *bytes = NULL;
        if (posix_memalign(&bytes, run_options.block_bytes, run_options.block_bytes) != 0) {
            return 1;
        }
        slots[index].bytes = (char *)bytes;
    }

    uint64_t started_ns = now_ns();
    deadline_ns = started_ns + run_options.seconds * NS_PER_S;
    for (uint32_t index = 0; index < run_options.depth; index++) {
        if (issue(&slots[index]) != 0) return 1;
    }

    uv_run(&loop, UV_RUN_DEFAULT);
    uint64_t span_ns = now_ns() - started_ns;

    for (uint32_t index = 0; index < run_options.depth; index++) {
        uv_fs_req_cleanup(&slots[index].request);
        free(slots[index].bytes);
    }
    close(descriptor);
    uv_loop_close(&loop);

    report(span_ns, run_options.backend == BACKEND_URING);
    return 0;
}
