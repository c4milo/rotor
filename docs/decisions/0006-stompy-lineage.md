# 6. What rotor keeps from stompy's I/O layer, what it changes, and why stompy should move

Status: accepted for implementation on 2026-09-19. Camilo gave the instruction to implement and
did not rule on the open questions below, so the implementation follows the proposed answer to
each until a ruling changes it.

Amended on 2026-09-19 by decision 10: rotor carries no simulated backend. The last row of "What
rotor changes", reason 2 of "Why stompy should depend on rotor" and open question 2 no longer
hold. stompy keeps its own simulator, which presents rotor's surface or sits behind stompy's `io`
facade.

Amended on 2026-09-27 by Camilo's ruling: one timeout entry stays armed, the loop's wait timer.
The row of "What rotor keeps" on `IORING_FEAT_EXT_ARG` gave "no timeout entry stays armed" as its
reason, and "The wait timer" below says what changed and why.

## Context

stompy carries `src/io/`, 974 lines: `io.zig` 478, `linux.zig` 374, `stub.zig` 63 and
`constants.zig` 59. It is a completion-based layer over io_uring for the journal of obi, with
three operations: read, write and `fdatasync`, all on O_DIRECT files in 4 KiB sectors. Its
simulated twin is `src/sim/disk/`, which carries the same surface; `build/modules.zig` hands
`sim` to a second `obi` module as its `io` import, so the journal runs on the simulated disk
without a changed line. rotor generalises that idea. colibri owns no I/O by its first
non-negotiable and is not a consumer.

## What rotor keeps

| kept | where it is in stompy | why |
|---|---|---|
| Completion-based, not readiness-based | `Io.read`, `Io.write`, `Io.fdatasync` | It is io_uring's own shape, and the simulator can order completions |
| A fixed entry count named at init, a power of two | `Io.init(entries)` | Bounded queues |
| `IORING_FEAT_NODROP` and `IORING_FEAT_EXT_ARG` required, else `Unsupported` | `linux.zig` `init` | No lost completion; the wait timeout is an argument and no timeout entry stays armed (amended: one does, the wait timer, below) |
| A bounded overflow queue when the submission ring is full | `unqueued_head`, `flush_unqueued` | More operations than entries can be in flight |
| Bounded resubmission on `EAGAIN` and `EINTR` | `transfer_retries_max`, `enter_retries_max` | A transient refusal is not a result the caller can act on |
| Reap before retry on `EBUSY` | `submit_and_wait` | The overflow signal clears only by reaping |
| No kernel type in the public surface | `io.zig` exports no `linux` type | The simulator implements the same surface |
| The twin swapped in by the build, not by a runtime switch | `build/modules.zig`, `obi_sim` | The code under test is the code that ships |
| Faults drawn at submit time from the seeded generator | `disk_fault.zig` | The fault schedule depends on the order the caller issued operations, not on timing |
| Completions delivered in (deadline, submission order), never inside the submitting call | `disk_queue.zig` | The scheduler decides the order, not the caller |
| Every limit named, with comptime asserts beside it | `io/constants.zig` | TigerStyle |

## What rotor changes

| stompy | rotor | why |
|---|---|---|
| One call queues one operation | `submit` takes a slice | Bulk is the default shape (`0001-interface.md`) |
| One callback per completion | `tick` fills a slice of 16-byte events; callbacks are a helper | One indirect call per completion (C5) removed from the default path |
| Caller-owned `Completion` of 80 bytes, measured on the development machine, spanning two 64-byte cache lines; `user_data` is its address | Loop-owned slot of 64 bytes; `user_data` is a slot index and a generation | One line per operation; a stale completion is detected and not dereferenced (`0005-cancellation.md`) |
| Files only, sector-aligned, asserted per call | Files, TCP, timers, cross-core messages | The consumers need sockets |
| No cancellation | Cancellation and timeouts | Sockets need them |
| Plain descriptors and buffers | Registered descriptors and buffers, provided-buffer rings | `0003-speed-sources.md` |
| Linux, with a stub elsewhere that returns `Unsupported` | Linux and macOS backends | Development happens on a Mac |
| `fault_after` inside the real layer, Debug only | No fault code in a real backend; every fault lives in the simulator | The production path carries no test branch. See the open question below |
| A simulated disk, part of stompy's simulator, which also owns the clock and a message-level network | A simulated backend for every rotor operation, with its own op clock | rotor's simulator knows sockets and timers; stompy's message-level network stays stompy's |

The sector rules move up, not away. rotor asserts what O_DIRECT itself requires, alignment to
the device's logical block. stompy's stricter rule, that every offset and length is a multiple
of its 4 KiB `sector_size`, is stompy's format decision and stays in stompy, in a thin wrapper
over rotor.

## The wait timer

**Amended on 2026-09-27: a tick's wait is bounded by one armed timeout entry, and the enter that
waits carries no timeout.** Linux arms an hrtimer when a thread sleeps in `io_uring_enter` with a
timeout and cancels it when the thread wakes, and a tick always blocked with one, because its wait is
bounded (`wait_ns_max`) even when no deadline is due. The same cost moved kqueue and epoll to a
timer of their own (decision 12, point 7; decision 20, "The wait timer"). Measured without rotor,
with two threads on two rings waking each other with `IORING_OP_MSG_RING`, 200,000 round trips a run,
five runs a mode. The kernel was the `orbstack` machine's, Linux 7.0.14, booted under QEMU with a
plugin that counts every instruction the two threads execute, user and kernel together, because the
`orbstack` virtual machine offers no hardware counters. The change is per blocking wait, against the
same enter with no timeout:

| how each side bounds its wait | instructions per wait |
|---|---:|
| `EXT_ARG` with a 1 ms timeout | +608 |
| `EXT_ARG` with a 10 s timeout | +581 |
| `EXT_ARG` with no timeout | +23 |
| no timeout, and one `IORING_OP_TIMEOUT` armed once | -9 |
| no timeout, and that timeout moved with `TIMEOUT_UPDATE` before every wait | +1,004 |
| no timeout, and a new `IORING_OP_TIMEOUT` before every wait | +1,774 |

So an armed timeout costs a wait nothing, and arming one before every wait costs more than the
timeout argument. The design is kqueue's, which arms the timer rarely:

- Each loop has one `IORING_OP_TIMEOUT`, with a count of 0 and an absolute time on
  `CLOCK_MONOTONIC`, the clock the tick reads. `Loop.wait_timer_deadline_ns` records when it fires,
  or 0 when it is not armed. Its entry rides in the same enter as the tick's other entries, so
  arming it costs no system call, and the enter waits for one completion with no timeout.
- The timer is left in place when it fires no later than this wait's deadline. A loop that waits
  often, such as the two loops of a ping-pong, arms it about once per wait bound. One that fires
  after this deadline is moved earlier with `TIMEOUT_UPDATE`.
- A timer that fires before this tick's deadline, or a move that answers, leaves the ring holding
  the timer's completions and nothing else. The tick takes them, arms the timer again if it fired,
  and waits for the time that is left, at most `wait_timer_rearms_max` times, so a quiet tick still
  takes its whole wait.
- A submission ring with no room for the timer's entry makes the enter carry the timeout, as before,
  which is why `EXT_ARG` stays required.
- The reap turns the timer's completions into no event, and a fired timer's sets the deadline back
  to 0. Neither reaches the path of an operation that succeeded, in `uring_reap.zig`, one of
  decision 7's hot files.

Absolute and not relative, because an entry can wait in the submission ring past its tick when the
completion ring is full, and a relative time would then fire late. A move is answered with a
completion, which ends the wait it was made for; the tick takes it and waits again, one more enter.
`IOSQE_CQE_SKIP_SUCCESS` would spare that enter, and would add a feature to decision 2's table; a
loop that keeps one wait bound never moves its timer.

What it costs: 24 bytes in `Loop`, `TIMEOUT` and `TIMEOUT_REMOVE` among the opcodes `init` probes,
and in a loop that waits often, one more enter about once per wait bound, when the timer fires
before a later tick's deadline.

Measured on 2026-09-27 with `post_uring` in `waiting` mode, the two loops of a ping-pong, 20,000
round trips a run, five runs of each build alternating, counted as decision 20's wait timer was:
the `orbstack` machine's kernel under QEMU, the plugin counting both threads between markers placed
around the measured round trips in a copy of `rotor_post.zig` built for the count alone.
Instructions per round trip, user and kernel together, median and range:

| build | instructions per round trip |
|---|---:|
| before, `0d0634b` | 13,701 (13,689 to 13,711) |
| with the wait timer | 12,888 (12,830 to 12,903) |

The ranges do not overlap. The kernel's share fell by about 1,040, and user space rose by about 190,
which is the tick reading the completion ring after each wait.

The time was measured on `github`, an AMD EPYC 7763 under Azure with Linux 6.17, the same day:
`post_uring` built at `5e376b2` and with the wait timer, fifteen alternating rounds
(`bench/results/wait-timer-linux-github-2026-09-27.md`). Medians over the rounds, and the median of
the paired differences:

| measure | before | with the wait timer | change | rounds better |
|---|---:|---:|---:|---:|
| the answering loop's CPU per round trip | 15,818 ns | 13,131 ns | -16.1 percent | 15 of 15 |
| messages per second | 63,959 | 76,920 | +20.3 percent | 15 of 15 |
| p50 | 16,767 ns | 11,839 ns | -29.4 percent | 15 of 15 |
| p99 | 18,559 ns | 19,071 ns | +2.8 percent | 1 of 15 |

The time fell by more than the instructions did. Arming and cancelling an hrtimer on every wait
reprograms the timer, and on a virtual machine that can cost more than its instructions. The p99
rose a little in 14 rounds of 15: the timer, armed for the benchmark's 1 ms wait, fires about once a
millisecond in each loop, and a round trip that meets a fire waits for it.

Mutations, measured against `zig build test-uring` and against the `uring` test executable in the
Linux gate:

| mutation | caught by | result |
|---|---|---|
| the timer armed again on every wait | `uring`, Linux gate | CAUGHT |
| no second wait after a timer that fired early | `uring`, Linux gate | CAUGHT |
| the reap leaves the deadline set | `test-uring` | CAUGHT |
| no timeout when the ring has no room for the timer | `uring`, Linux gate: the test hangs | CAUGHT |
| no timeout when there is no room to arm it again | `uring`, Linux gate: the test hangs | CAUGHT |
| no check that the deadline passed before arming again | `uring`, Linux gate: the assertion | CAUGHT |
| a second wait whatever the ring holds | `uring`, Linux gate: the assertion | CAUGHT |
| other completions counted as the timer's | `uring`, Linux gate: the assertion | CAUGHT |
| a wake counted as the timer | `test-uring` | CAUGHT |
| the timer armed with a relative time | `uring`, Linux gate: the test hangs | CAUGHT |
| the timer moved with a relative time | `uring`, Linux gate: the test hangs | CAUGHT |

## Why stompy should depend on rotor

1. **stompy's layer is about to grow along the same path.** stompy is one binary with proxy,
   wal and pagestore roles and an S3 client in `stdx`. Those need sockets, timers and
   cancellation. Growing `src/io/` to carry them means writing rotor inside stompy, tested by
   one consumer.
2. **One simulator surface.** Today stompy simulates the disk at the I/O surface and the network
   at the message level, above any socket code. On rotor's simulator, the socket code itself
   runs under short reads, partial writes and resets, in the same seeded run as the disk faults.
3. **The measurements carry over.** `docs/costs.md` and the harness are work stompy would
   otherwise repeat for its own layer.
4. **A second consumer tests the API.** An interface with one caller fits that caller's
   accidents. stompy's journal is a demanding first caller, because its crash harness already
   exists and will catch a rotor that loses a write.

## What it costs stompy, and when

- stompy's CLAUDE.md says to ask before adding a dependency, because the platform is a static
  binary with a small surface. rotor must stay dependency-free itself, which
  `build.zig.zon` holds: its one dependency is lazy tooling that a consumer never fetches.
- The journal embeds its completions in its own structures today. It would hold handles.
- The move happens after rotor's milestone 2, never before. The gate for the move belongs to
  stompy: the crash harness at both tiers, 64 and 256 seeds, and all six simulator gates pass
  on rotor unchanged, and the journal's throughput does not drop in rotor's harness.
- Until then stompy keeps its layer. rotor does not import stompy and never names it in source.

## Alternatives it beat

**Extract stompy's layer as is and grow it.** The callback-per-operation shape and the
caller-owned 80-byte completion are the two things the performance discipline asks to change,
and changing them later means changing every call site twice.

**Keep two layers.** Two simulators, two sets of fault classes, two harnesses.

## Open questions for review

1. stompy's crash harness uses `fault_after` on a real disk to stop writes at an operation
   boundary. rotor proposes no fault code in real backends. Either stompy's harness keeps a
   small wrapper that refuses operations above rotor, or rotor carries a Debug-only fault hook
   as stompy does. The wrapper is proposed, because it keeps the production path clean.
2. Should rotor's simulator own the op clock alone, or should it accept stompy's scheduler as
   the owner, so that one clock drives disk, sockets and stompy's message network together?
