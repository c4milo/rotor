# 3. Where the speed is meant to come from

Status: proposed on 2026-09-19, awaiting review. Every number here is a prior from
`docs/costs.md` and none is a measurement. Each claim names the harness result that confirms or
kills it.

## Context

"Faster than libuv, libxev and std.Io" is a hope until each source of speed is named, costed,
and compared with what the others already do. This record lists seven sources. For each it
gives the cost removed, the arithmetic, the test, and which competitor already has it.

## What the others do

The `std.Io` columns come from reading the Zig 0.16.0 sources on the development machine. The
libuv and libxev columns are recalled from their sources and documentation. Milestone 4 pins a
version of each and re-reads the pinned source before any comparison is published; a cell that
turns out wrong is corrected here first.

| source | libuv (recalled) | libxev (recalled) | `std.Io.Uring` (read) | `std.Io.Threaded` (read) |
|---|---|---|---|---|
| 1. registered buffers and descriptors | no | no | no | not applicable |
| 2. multishot accept and receive | no; readiness by epoll | no | no | not applicable |
| 3. batched submission | no for sockets: one `recv` or `send` syscall each | yes | yes: every fiber that ran queues its entry, and one `submit_and_wait` sends them when the thread idles | no |
| 4. one syscall per tick | no: `epoll_wait` plus one syscall per ready socket | yes | yes when idle, plus a `submit` when it wakes another thread or a futex | no: one blocking syscall per operation |
| 5. no allocation per operation | caller-owned requests, plus an `alloc_cb` call per read | yes | fiber stacks from an allocator, reused | thread pool, allocator |
| 6. no hidden threads | no: a 4-thread pool runs file operations and DNS | yes on io_uring; a pool for files on kqueue | no: spawns threads and moves fibers between them | no: it is a thread pool |
| 7. cache-aware completion layout | not a goal | caller-owned completion of a few hundred bytes | fiber context | not applicable |

Read plainly: **against libxev on io_uring, sources 3 to 6 are parity and not advantage.**
rotor's difference from libxev is sources 1, 2 and 7, plus the threading interface of
`0004-threading.md`. Against libuv and `std.Io.Threaded`, all seven apply. Against
`std.Io.Uring`, sources 1, 2, 5, 6 and 7 apply.

## The sources

### 1. Registered buffers and descriptors

Removes: per operation, the kernel's descriptor lookup with its reference count, and for
O_DIRECT, pinning the buffer's pages for the transfer.

Arithmetic: `docs/costs.md` has no row for either cost, because neither can be measured apart
from the operation. The test is differential: C13 measured with and without registration. The
prior expectation is tens of nanoseconds for the descriptor and hundreds for the pages. Against
a 4 KiB NVMe read at C12, 20,000 ns, that is 1 to 3 percent of latency at queue depth 1. So the
claim is not about latency. It is about CPU per operation at high queue depth, where the device
is not the limit.

Test: random O_DIRECT reads at queue depth 32 and above, CPU time per operation, registered
against unregistered. If the harness cannot resolve the difference, registration stays in the
API for its other use, provided buffers, and the performance claim is dropped.

### 2. Multishot accept and receive, with provided buffers

Removes: one submission entry per accept and per receive, which is `C8`, 20 to 60 ns each.

Arithmetic: an echo message costs one receive and one send. Multishot removes the receive's
submission: `C8` out of `C7 / 32 + 2 × C8 + 2 × C9`, which is 60 to 190 ns with the priors. That
is a saving of roughly a third of the loop's own per-message cost, and under 1 percent of one
loopback round trip (C14, 10,000 to 30,000 ns). So the claim is throughput per core when the
CPU is the limit, and not latency. The accept storm is where multishot accept should show most:
every connection otherwise costs a fresh accept submission.

Cost it adds: the kernel picks the buffer, so the caller gets a buffer index with the event and
must return the buffer. That is API surface, and one more thing the simulator has to model.

Test: echo at 4 KiB, single-shot against multishot, same run. Accept storm, same pair.

### 3. Batched submission

Removes: a syscall per operation.

Arithmetic: a readiness loop pays `2 × C6` per echo message, 200 to 1,000 ns. A batch of 32 pays
`C7 / 32`, 9 to 31 ns, plus the per-entry costs. The saving, 140 to 810 ns per message, is the
largest of the seven with the priors.

Test: echo throughput as a function of batch size, 1 to 64. The curve is the evidence.

### 4. One syscall per tick

Removes: a separate submit call and wait call. `io_uring_enter` does both. On kqueue, one
`kevent` call carries the changelist in and the events out.

Arithmetic: saves `C6` per tick, or `C6 / batch` per operation: 3 to 16 ns at a batch of 32.
Small. It is here because it costs nothing to keep once the loop has this shape.

Test: a syscall count per tick from `perf trace` or `strace -c` in the harness, asserted to be 1.

### 5. No allocation per operation

Removes: an allocator call per operation, and the cache misses of memory that moves.

Arithmetic: not costed in `docs/costs.md`, because rotor never has an allocator to measure.
The heap lint rule proves the absence. It is a rule, not a race: libxev and libuv's request
structs already avoid it, so rotor claims no gain over them.

### 6. No hidden threads

Removes: a cross-thread handoff per file operation, which is at least one wake and two context
switches, several microseconds, against an O_DIRECT read that io_uring issues from the
submitting thread when the filesystem allows it.

Test: sequential and random O_DIRECT reads against libuv, where libuv uses its pool. The harness
asserts one thread per loop and reports every io_uring worker thread the kernel started
(`0004-threading.md`).

### 7. Cache-aware completion layout

Removes: cache lines touched per operation.

Arithmetic: stompy's `Completion` measures 80 bytes, by `@sizeOf` on the development machine, so
every in-flight operation spans two 64-byte lines. rotor's slot record is meant to be 64 bytes,
aligned to 64 (`completion_bytes` in `src/core/constants.zig`), and an `Event` is 16 bytes, so a
reap of 32 reads 8 lines in order. Going from two lines to one saves at most one C2 or C3 per
operation, 3 to 50 ns, and only when the record has left L1.

On the `mac` machine the cache line is 128 bytes. Two 64-byte records then share a line, which
is harmless here because one thread owns the whole table.

Test: echo at a connection count large enough that the slot table exceeds L2, records of 64
bytes against a padded 128-byte variant, last-level cache misses from `perf stat`. The comptime
assert on the record's size lands with the record.

## What is not claimed

- `IORING_SETUP_SQPOLL`. A kernel thread that polls the submission queue is a hidden thread and
  burns a core. It is not used.
- Zero-copy send. It pays off for large sends, needs a second completion per send, and is
  outside version one.
- Any latency gain on a workload whose latency is the device's or the network's. The arithmetic
  above says rotor's gains are CPU per operation. The harness reports p50, p99 and p999 anyway,
  because a loop that batches badly can lose latency, and that loss must be seen.

## Alternatives it beat

**Claim all seven against everyone.** The table above shows four of them are parity with
libxev. A claim the comparison cannot show would break the rule that a speed claim is
reproducible in the harness.

**Drop the small ones, 4 and 7.** They are cheap to hold and cheap to test, and a flat profile
is made of small ones.

## Open questions for review

1. Is CPU per operation, and the throughput per core that follows from it, the right headline,
   given that the arithmetic rules out a latency headline?
2. Should the libuv and libxev columns be verified now, before acceptance, and not at
   milestone 4?
