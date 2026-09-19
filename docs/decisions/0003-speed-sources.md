# 3. Where the speed is meant to come from

Status: accepted for implementation on 2026-09-19. The owner gave the instruction to implement and
did not rule on the open questions below, so the implementation follows the proposed answer to
each until a ruling changes it. Every number here is a prior from `docs/costs.md` and none is a
measurement. Each claim names the harness result that confirms or kills it.

## Context

"Faster than libuv, libxev and std.Io" is a hope until each source of speed is named, costed,
and compared with what the others already do. This record lists seven sources. For each it
gives the cost removed, the arithmetic, the test, and which competitor already has it.

## What the others do

Every cell was read from a pinned source or measured against one, and the citations under the
table name the file and line that settles each. The pins:

- libuv: `https://github.com/libuv/libuv` at the tag `v1.52.1`, the stable release of 2026-03-06,
  which names commit `1cfa32ff59c076ffb6ed735bbc8c18361558661f`.
- libxev: `https://github.com/mitchellh/libxev` at commit
  `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf`, the head of `main` on 2026-09-19. libxev has no
  release tag. This commit builds with Zig 0.16.0.
- `std.Io`: the Zig 0.16.0 sources on the development machine.

`zig build bench-competitors` builds both libraries from these pins, and
`bench/competitors/README.md` records how each cell was settled. The libuv and libxev columns were
first written from memory. Reading the sources left five of their fourteen cells as they were,
added detail to four, and corrected five: libuv's rows 3 and 7, and libxev's rows 3, 4 and 7. It
also corrected row 5 of `std.Io.Threaded`. When a pin moves, the columns are read again before any
comparison is published, and a cell that turns out wrong is corrected here first.

| source | libuv v1.52.1 | libxev `9ce8e8e` | `std.Io.Uring` 0.16.0 | `std.Io.Threaded` 0.16.0 |
|---|---|---|---|---|
| 1. registered buffers and descriptors | no: it defines `uv__io_uring_register` and nothing calls it | no: the ring is created with no flags, and nothing is registered | no | not applicable |
| 2. multishot accept and receive | no: a socket never reaches io_uring. `epoll_pwait` reports readiness, then one `accept4` per event on a listening socket and one `read` per ready socket | no: `accept` and `recv` are single-shot entries, and a callback that rearms queues a fresh entry | no | not applicable |
| 3. batched submission | no for socket I/O: one `read`, and one `write` or `writev`, per operation. Registrations are batched: on Linux `epoll_ctl` goes through an io_uring ring, on by default, and on macOS the changelist rides in the `kevent` call that waits | yes on io_uring: `add` fills an entry and one `submit_and_wait` sends them all. On kqueue only registrations batch, up to 256 per `kevent`, and each ready operation is its own `recv` or `send` | yes: every fiber that ran queues its entry, and one `submit_and_wait` sends them when the thread idles | no |
| 4. one syscall per tick | no: `epoll_pwait`, plus one `io_uring_enter` when registrations changed, plus one syscall per ready socket | yes on io_uring: one `io_uring_enter` submits and waits. No on kqueue: one `kevent` submits, a second waits, then one syscall per ready operation | yes when idle, plus a `submit` when it wakes another thread or a futex | no: one blocking syscall per operation |
| 5. no allocation per operation | caller-owned requests, plus an `alloc_cb` call per read, which the caller can serve from a fixed buffer. libuv calls `malloc` itself for a write of more than 4 buffers and for every asynchronous file operation that names a path | yes: no backend or watcher names an allocator, and the caller owns the completion | fiber stacks from an allocator, reused | none per operation: a blocking syscall on the calling thread. One allocator call per task that `async` or `concurrent` starts |
| 6. no hidden threads | no: one pool per process, 4 threads by default, runs every file operation and DNS lookup, on Linux and on macOS. On Linux a loop option plus `UV_USE_IO_URING=1` moves up to 15 file operations, `read` and `write` among them, to an io_uring ring. That is off by default, and the ring uses `IORING_SETUP_SQPOLL`, a kernel thread | yes on io_uring: a file operation goes to the ring. On kqueue and epoll it runs on a thread pool that the caller creates and hands to the loop, and it fails with `error.ThreadPoolRequired` when there is none | no: spawns threads and moves fibers between them | no: it is a thread pool, spawned on demand |
| 7. cache-aware completion layout | measured: `uv_write_t` is 192 bytes and `uv_fs_t` 440; the handle `uv_tcp_t` is 248 on Linux and 264 on macOS | measured: the caller-owned `Completion` is 128 bytes on io_uring, 176 on kqueue and 184 on epoll. libxev's own test pins the 128 | fiber context | not applicable |

Citations, by row. A libuv path is relative to the root of the v1.52.1 tree, a libxev path to the
root of the `9ce8e8e` tree, and a Zig path to `lib/zig/std` of the 0.16.0 installation.

1. Registered buffers and descriptors.
   - libuv `src/unix/linux.c:450`: defines `uv__io_uring_register`; a search of `src` and
     `include` finds no caller.
   - libuv `src/unix/linux.c:138`: the 13 io_uring opcodes libuv names; none is a fixed-buffer
     read or write.
   - libxev `src/backend/io_uring.zig:72`: `linux.IoUring.init(entries, 0)`, no setup flags. A
     search of `src` finds no `register_buffers`, `register_files` or provided-buffer call.
2. Multishot accept and receive.
   - libuv `src/unix/linux.c:138`: the opcode list has no accept, receive or send.
   - libuv `src/unix/linux.c:1451`: `epoll_pwait` reports readiness.
   - libuv `src/unix/stream.c:518`: one `uv__accept` per event. `src/unix/core.c:568`: it is
     `accept4` where `src/unix/core.c:97` defines it, which covers Linux. macOS has no `accept4`,
     so there it is `accept` at `:570`, then `uv__cloexec` and `uv__nonblock` at `:578`.
   - libuv `src/unix/stream.c:1061`: `read` on the ready socket.
   - libxev `src/backend/io_uring.zig:405`: `prep_accept`, single-shot; `:456`: `prep_recv`;
     `:199`: `.rearm` calls `add` again, which takes a new entry.
3. Batched submission.
   - libuv `src/unix/stream.c:1061` and `src/unix/stream.c:661`: `read`, and `write` or `writev`,
     one call per operation.
   - libuv `src/unix/linux.c:651`: every loop creates a 256-entry ring for `epoll_ctl`;
     `:479`: `uv__use_io_uring` answers yes for that ring without reading the environment;
     `:1271`: `IORING_OP_EPOLL_CTL`; `:1297`: one `io_uring_enter` flushes the batch; `:544` and
     `:1423`: a kernel older than 5.13 gets no ring, and libuv calls `epoll_ctl` directly.
   - libuv `src/unix/kqueue.c:270`: one `kevent` call carries the changelist in and the events out.
   - libxev `src/backend/io_uring.zig:371`: `add` takes an entry and makes no syscall; `:172`:
     one `submit_and_wait`.
   - libxev `src/backend/kqueue.zig:181` and `:234`: up to 256 changes per `kevent`; `:1146` to
     `:1242`: `perform` makes one `accept`, `recv`, `send`, `read` or `write` call per ready
     completion.
4. One syscall per tick.
   - libuv `src/unix/linux.c:1446`, `:1451` and `:1546`: flush the registrations, `epoll_pwait`,
     then one callback per ready descriptor, which reads.
   - libxev `src/backend/io_uring.zig:168` to `:175`: "exactly once syscall" when nothing
     overflowed the submission queue; `:176` to `:191`: otherwise a `submit` and then a wait.
   - libxev `src/backend/kqueue.zig:355`: the tick calls `submit`, whose `kevent` is at `:234`;
     `:493`: a second `kevent` waits; `:352`: a TODO says the two are not merged yet.
   - Zig `Io/Threaded.zig:12604`: `netReadPosix` calls `readv` on the calling thread and blocks.
5. No allocation per operation.
   - libuv `src/unix/stream.c:1049`: `alloc_cb` before every read.
   - libuv `src/unix/stream.c:1370` and `include/uv/unix.h:262`: a write copies its buffer list
     into `bufsml[4]`, and calls `uv__malloc` only past 4 buffers.
   - libuv `src/unix/fs.c:112`: the `PATH` macro calls `uv__strdup` for every asynchronous file
     operation that names a path; `src/unix/fs.c:2039`: `uv_fs_read` allocates only past 4
     buffers.
   - libuv `src/timer.c` and `src/unix/tcp.c`: a search finds no allocation call in either.
   - libxev: a search of `src/backend` and `src/watcher` finds no allocator outside tests;
     `src/backend/io_uring.zig:611`: the caller owns the completion and keeps its address stable.
   - Zig `Io/Threaded.zig:676`: `Future.create` calls `alignedAlloc` once per task; `:1608` to
     `:1614`: `init` documents its allocator as used only by `async`, `concurrent` and their group
     forms; `:12557`: a network read builds its `iovec` list in an array on the stack.
6. No hidden threads.
   - libuv `src/threadpool.c:39` and `:204`: `default_threads[4]`, one static pool for the
     process; `:207`: `UV_THREADPOOL_SIZE` resizes it, up to 1024 at `:30`.
   - libuv `src/unix/fs.c:139`: the `POST` macro sends a file operation to the pool;
     `src/unix/getaddrinfo.c:211`: DNS goes the same way.
   - libuv `src/unix/linux.c:766` to `:777` and `:479` to `:494`: the file-operation ring needs
     the loop option `UV_LOOP_USE_IO_URING_SQPOLL`, `UV_USE_IO_URING` set to a positive number,
     and Linux 5.10.186 or later; `docs/src/fs.rst:19`: v1.49.0 turned it off by default.
   - libuv `src/unix/fs.c:1820` to `:2234`: the 15 `uv_fs_*` functions that try the ring first;
     `src/unix/linux.c:843`, `:869` and `:914`: `close`, `ftruncate` and `link` also need a newer
     kernel.
   - libuv `src/unix/internal.h:436` to `:447`: off Linux every `uv__iou_fs_*` call is the
     constant 0, so every file operation takes the pool.
   - libxev `src/watcher/file.zig:125` to `:145`: io_uring sends a file read to the ring; epoll
     and kqueue set `flags.threadpool`.
   - libxev `src/loop.zig:18` to `:26`: the pool is the caller's, passed in `Options`;
     `src/backend/kqueue.zig:870`: with no pool the operation fails; `src/ThreadPool.zig:215`:
     the pool spawns its threads on demand.
   - Zig `Io/Threaded.zig:2112` and `Io/Uring.zig:1054`: both spawn threads on demand.
7. Cache-aware completion layout.
   - libuv: `sizeof` printed by a C program built with `zig cc` against the pinned headers, run on
     aarch64 macOS, and read as constants from the assembly for x86_64 and aarch64 Linux with
     glibc. `uv_write_t` is 192 and `uv_fs_t` 440 on all three.
   - libxev: `@sizeOf` printed by a Zig 0.16.0 program on aarch64 macOS, and read as constants
     from the assembly for x86_64 and aarch64 Linux. `src/backend/io_uring.zig:1126`: libxev's own
     test expects 128.

Read plainly: **against libxev on io_uring, sources 3 to 6 are parity and not advantage**, and the
pinned source confirms it. rotor's difference from libxev there is sources 1 and 2, plus the
threading interface of `0004-threading.md`. Source 7 is a smaller difference than this record
first assumed. libxev's completion is 128 bytes with 8-byte alignment, not a few hundred bytes: it
covers two 64-byte lines, or three when it straddles a boundary, against rotor's one. Sources 1
and 2 are io_uring features, so on kqueue they do not apply. Source 4 becomes a difference there,
because libxev makes two `kevent` calls per tick.

Against libuv, six sources apply. Source 5 does not: on the harness's workloads libuv allocates
nothing per operation, as section 5 already grants. Source 6 holds against libuv's default, the
thread pool. libuv can also send file reads to an io_uring ring, so the harness must run libuv
both ways. Against that configuration the cross-thread handoff is gone, and what libuv pays for it
is a kernel thread that polls the ring, which "What is not claimed" rules out for rotor. Against
`std.Io.Threaded`, sources 3, 4 and 6 apply to every operation, source 5 applies per task and not
per operation, and sources 1, 2 and 7 have no counterpart to compare with. Against
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

Test: sequential and random O_DIRECT reads against libuv twice: with its default thread pool,
and with its opt-in io_uring path for file operations, which starts a kernel polling thread
(`IORING_SETUP_SQPOLL`). The harness asserts one thread per loop and reports every io_uring
worker thread the kernel started (`0004-threading.md`).

### 7. Cache-aware completion layout

Removes: cache lines touched per operation.

Arithmetic: stompy's `Completion` measures 80 bytes, by `@sizeOf` on the development machine, so
every in-flight operation spans two 64-byte lines. rotor's slot record is meant to be 64 bytes,
aligned to 64 (`slot_bytes` in `src/core/constants.zig`), and an `Event` is 16 bytes, so a
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
2. Answered on 2026-09-19: the libuv and libxev columns are verified against the pinned sources
   above, and five cells changed. `bench/competitors/README.md` holds the pins.
