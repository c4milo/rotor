# 6. What rotor keeps from stompy's I/O layer, what it changes, and why stompy should move

Status: accepted for implementation on 2026-09-19. The owner gave the instruction to implement and
did not rule on the open questions below, so the implementation follows the proposed answer to
each until a ruling changes it.

Amended on 2026-09-19 by decision 10: rotor carries no simulated backend. The last row of "What
rotor changes", reason 2 of "Why stompy should depend on rotor" and open question 2 no longer
hold. stompy keeps its own simulator, which presents rotor's surface or sits behind stompy's `io`
facade.

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
| `IORING_FEAT_NODROP` and `IORING_FEAT_EXT_ARG` required, else `Unsupported` | `linux.zig` `init` | No lost completion; the wait timeout is an argument and no timeout entry stays armed |
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
