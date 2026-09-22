# 1. Interface: a completion-based core, with a std.Io adapter over it

Status: accepted for implementation on 2026-09-19. The owner gave the instruction to implement and
did not rule on the open questions below, so the implementation follows the proposed answer to
each until a ruling changes it.

Amended on 2026-09-19 by decision 10: rotor carries no simulated backend, so the `sim` row of the
module table and the phrase "the three backends" no longer hold. The backends are `uring` and
`kqueue`, and a consumer that needs a deterministic twin of the surface brings its own.

Amended on 2026-09-22 by the owner: rotor exports one module, `rotor`, and that module chooses
this host's backend itself. The sentence below saying a backend is chosen by the consumer's build
no longer holds for a consumer outside this tree, because the backends are no longer modules it
can name: exporting them would export how a backend performs an operation, which is nobody else's
business. Inside this tree the build still hands a backend to the conformance suite, which is what
that sentence was written for. A consumer that needs a twin still brings its own, as decision 10
says, and imports it in place of `rotor` rather than around it.

## Context

Zig 0.16 defines `std.Io`, an interface of function pointers. rotor can implement that table
directly, or rotor can be a completion-based core with an adapter that implements the table on
top of it.

The table in the Zig 0.16.0 installed on the development machine holds 109 function pointers,
counted from `std/Io.zig` lines 51 to 255. The brief said 112; the count here is 109. They
divide as follows.

| group | functions | examples | hot path |
|---|---|---|---|
| tasks, groups, futexes, batches | 19 | `async`, `await`, `cancel`, `operate`, `batchAwaitConcurrent` | yes, all of it |
| directories | 26 | `dirOpenFile`, `dirRename`, `dirSetPermissions` | no |
| files | 28 | `fileReadPositional`, `fileWritePositional`, `fileSync`, `fileLock`, `fileMemoryMapCreate` | 3 of 28 |
| processes and stderr | 15 | `processSpawn`, `childWait`, `lockStderr` | no |
| time and randomness | 5 | `now`, `sleep`, `random` | 2 of 5 |
| network | 16 | `netAccept`, `netRead`, `netWrite`, `netSend`, `netLookup` | 6 of 16 |

About 30 functions are hot-path work. The other 79 are paths, permissions, processes and
terminals.

Two facts about the table matter more than its size.

1. **Its calls block the caller.** `netRead` returns the bytes. An implementation therefore needs
   something to suspend: a thread, as `std.Io.Threaded` uses, or a stackful fiber, as
   `std.Io.Uring` and `std.Io.Kqueue` use. Both std implementations allocate fiber stacks from a
   general-purpose allocator, start threads of their own, and move ready fibers between threads
   (both files call `std.Thread.spawn`, and both name `max_steal_ready_search` and take fibers
   from another thread's ready queue). Each of those three breaks a rotor rule:
   no allocation per operation, no hidden threads, no work moving between cores
   (`0004-threading.md`).
2. **Its shape cannot express the speed sources.** No function of the table registers a buffer
   or a file, none arms a multishot accept or receive, and none hands the caller a buffer the
   kernel picked. `grep` finds no `REGISTER_BUFFERS`, no `REGISTER_FILES`, no multishot flag and
   no buffer ring in `std/Io/Uring.zig`. Every gain `0003-speed-sources.md` claims from those
   mechanisms is unreachable through the table.

## Decision

rotor is a completion-based core. A std.Io adapter sits over it, as a separate module that the
core never imports.

### The core

The core's surface is batch-shaped by default.

- `submit(operations: []const Operation) u32` queues a batch and returns how many it took. It
  makes no syscall.
- `tick(events: []Event, wait: Wait) u32` makes the one syscall of the tick: it submits
  everything queued, optionally waits, and copies out up to `events.len` completions.
- An `Event` is 16 bytes: a 64-bit `user_data` the caller chose, a 32-bit result, and 32 bits of
  flags. It is the kernel's completion entry with rotor's error mapping applied.
- An in-flight operation lives in a table the loop owns, sized at init by a named limit. The
  caller holds a 64-bit `Handle`: a 32-bit slot index and a 32-bit generation. The caller does
  not hold a pointer into the loop.
- The one-operation call and the callback style are helpers built on the batch calls, in their
  own file. The dispatch helper reads a callback from a table the caller registers once and
  calls it per event. It is the special case, as the brief asks.

This changes stompy's shape, which is one caller-owned `Completion` per call with a callback
inside it. `0006-stompy-lineage.md` gives the reasons.

### The adapter

The adapter implements the `std.Io` table for code that wants to run on rotor without learning
its API.

- The hot functions, about 30, map to core operations. The adapter suspends the calling fiber,
  submits, and resumes the fiber when the event arrives.
- The other 79 delegate to `std.Io.Threaded`. rotor cannot make `dirRename` or `processSpawn`
  faster, and the brief's rule applies: what cannot beat std.Io delegates to it.
- The adapter needs fibers, so it allocates stacks. That allocation happens in the adapter's
  init from memory the caller hands it, never per operation.
- The adapter is not part of version one (`0002-scope.md`). Its cost is measured before it is
  built: one fiber switch out and one back per blocking call, plus one indirect call (C5).

### Modules

The build enforces the direction (`build/modules.zig`).

| module | imports | holds |
|---|---|---|
| `core` | nothing | `Operation`, `Event`, `Handle`, the slot table, the timer heap, the named limits |
| `sim` | `core` | the simulated backend: op clock, seeded completion order, fault injection |
| `uring` | `core` | the Linux backend |
| `kqueue` | `core` | the macOS backend |
| `adapter` | `core`, one backend | the std.Io table, after version one |
| `bench` | everything | the harness; never linked into the library |

A backend is chosen at comptime by the consumer's build, the way stompy's build hands `sim` to
`obi` as its `io` import. The three backends carry the same surface, and a comptime check in
each compares its declarations against `core`'s list.

## Alternatives it beat

**Implement the std.Io table directly.** Cost: 109 functions to write and keep current against
a std that is still changing, 79 of them with no gain available; fibers and their stacks in the
core; and none of the registered or multishot mechanisms reachable. Benefit: every Zig program
written against `std.Io` runs on rotor unchanged. The adapter keeps that benefit for the code
that wants it and does not make the core pay for it.

**Core only, no adapter ever.** Cheaper, and enough for stompy. It loses the one fair way to
compare rotor with `std.Io.Uring` on a program written once, and it shuts out consumers that
already speak `std.Io`. The adapter is deferred, not refused.

**Callbacks as the primary shape, as stompy and libxev have.** A callback per completion is an
indirect call per completion (C5) into code the loop cannot batch, and it puts a function
pointer and a context pointer, 16 bytes, in every in-flight record. The event batch lets the
caller process 32 completions in one loop over one contiguous array of 512 bytes, which is 8
cache lines of 64 bytes read in order. The callback helper remains for callers that prefer it.

## Costs

- The slot table adds one indexed load per completion to map `user_data` to the operation's
  record. When the table is hot that is C1 or C2, 0.5 to 3 ns with the priors. stompy avoids it
  by using the completion's address as `user_data`, and pays 8 bytes of pointer for it.
- A caller that wants per-operation context keeps its own array indexed by the slot index. That
  is the caller's load, and it is the same load a callback's context pointer would cause.

## How it is checked

- The adapter's cost is a harness number: the echo workload written once against `std.Io`, run
  on the adapter and on `std.Io.Uring`, beside the same workload written against the core.
- `zig build test` compiles the three backends' surfaces against `core`'s list on every host.

## Open questions for review

1. Is a loop-owned slot table acceptable for stompy's journal, which today embeds its
   completions in its own structures?
2. Should the adapter be promised at all before the harness shows what a fiber switch costs?
