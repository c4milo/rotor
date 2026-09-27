# 22. A std.Io adapter

Status: **accepted** on 2026-09-27 by Camilo, to be built on two conditions: it keeps rotor's
performance, and its API follows rotor's own primitives (open question 1). **Deferred** the same
day: nothing is started, the fiber switch's measurement included, until Camilo asks for it.
Proposed on 2026-09-26. Decision 1 chose a completion-based core with a
`std.Io` adapter over it, and decision 2 left the adapter out of version one: "deferred, not
refused". Version one is built, and on 2026-09-26 Camilo asked whether rotor can be offered through
the `std.Io` interface. This record says what the adapter would be, what it would cost, and what
must be measured before it is built. Building it adds a module to the graph and builds something
decision 2 leaves out of version one, and CLAUDE.md asks Camilo about both first.

## Context

### What `std.Io` is in Zig 0.16.0

`std.Io` is a pointer to state and a table of function pointers, `Io.VTable`, at lines 51 to 255 of
`std/Io.zig`. Code that takes an `io: std.Io` runs on whatever fills the table: `std.Io.Threaded`,
one of the evented implementations, or a table of rotor's. Read on 2026-09-26, the table holds 109
functions, as decision 1 counted:

| group | functions | examples |
|---|---:|---|
| tasks, groups, cancellation | 11 | `async`, `concurrent`, `await`, `cancel`, `groupAsync`, `checkCancel` |
| futexes | 3 | `futexWait`, `futexWake` |
| batches | 4 | `operate`, `batchAwaitAsync`, `batchAwaitConcurrent`, `batchCancel` |
| crash handler | 1 | `crashHandler` |
| directories | 26 | `dirOpenFile`, `dirRename`, `dirSetPermissions` |
| files | 28 | `fileReadPositional`, `fileWritePositional`, `fileSync`, `fileLock`, `fileMemoryMapCreate` |
| processes, children, stderr, progress | 15 | `processSpawn`, `childWait`, `lockStderr` |
| time and randomness | 5 | `now`, `sleep`, `random` |
| network | 16 | `netAccept`, `netConnectIp`, `netRead`, `netWrite`, `netSend`, `netLookup` |

Every call blocks its caller: `netRead` returns the bytes. An implementation needs something to
suspend while the kernel works, a thread or a fiber, as decision 1 says.

### What has changed since decision 1

Decision 1 was written on 2026-09-19. Three things in the Zig 0.16.0 installed on the development
machine bear on it, read on 2026-09-26:

1. **`std.Io.fiber` is public.** It holds a context switch for aarch64, riscv64 and x86_64 in a few
   lines of assembly each: save the stack pointer, frame pointer and resume address of one context,
   load another's, and jump. The adapter can use it and write no assembly of its own.
2. **The table has a batch.** `operate` takes an `Io.Operation`, and a `Batch` holds several. The
   operations a batch can carry are four: `file_read_streaming`, `file_write_streaming`,
   `device_io_control` and `net_receive`. It is not a way to reach the speed sources below.
3. **std's evented implementations.** `std.Io.Evented` is `Uring` on Linux, `Dispatch`, over Grand
   Central Dispatch, on macOS, and `Kqueue` on the BSDs. `Uring` does not compile on 0.16.0
   (`bench/alternatives/README.md`). `Dispatch` compiles and runs: a program that initialised it and
   slept 1 ms ran on `mac` on 2026-09-26. `Kqueue` has 56 lines that say `TODO`. All three allocate
   each fiber from a general-purpose allocator, `Kqueue` with a stack of at least 4 MiB. `Uring` and
   `Kqueue` start threads of their own that take fibers from each other's ready queues, and
   `Dispatch` runs its fibers on the threads Grand Central Dispatch keeps.

### What decision 1 already settled

- The core is not the table. Implementing the table in the core would put fibers in the core, write
  79 functions that gain nothing, and still leave the speed sources out of reach.
- **The table cannot express the speed sources.** No call registers a buffer or a descriptor, arms a
  multishot accept or receive, or hands the caller a buffer the kernel picked
  (`0003-speed-sources.md`). Code written against `std.Io` can run on rotor's loop and its
  threading model, and cannot use those.
- "No adapter ever" was rejected: it shuts out code that already speaks `std.Io`, and it loses the
  one fair comparison with `std.Io` on a program written once.

### Why now

- A library written against `std.Io`, such as an HTTP client, would run on a rotor loop unchanged,
  beside code written against rotor's own API on the same loop.
- The comparison the harness owes decision 3 is `std.Io.Uring`, which does not compile on 0.16.0.
  An adapter over rotor's io_uring backend would be a working evented `std.Io` on Linux today.
- The harness already holds `std.Io` programs: `bench/alternatives/std_io_echo.zig` and
  `std_io_timers.zig`. They run on the adapter as written.

## Decision, proposed

A module `adapter`, in `src/adapter/`, returns a `std.Io` whose state is one rotor loop and a pool
of fibers. The core never imports it. The shape a caller would see:

```zig
var adapter: rotor.adapter.Adapter = undefined;
try adapter.init(&loop, &adapter_memory, .{
    .fibers = 256,
    .stack_bytes = 64 * 1024,
    .rest = threaded.io(),
});
const io = adapter.io();
```

### The rules it keeps

- **It allocates nothing per call.** The caller hands `init` one block: the fibers' records and
  their stacks, `fibers × stack_bytes` plus a record each. `fibers` and `stack_bytes` are bounded by
  named limits.
- **It starts no thread and moves no work between cores.** Every fiber of an adapter runs on the
  thread that owns its loop. There is no second queue to take fibers from.
- **It needs one loop, and the loop keeps its own rules.** Every operation still ends with one final
  event (decision 5). A call from another thread halts, as a call on the loop does (decision 4).
- **What it cannot do on rotor, it hands to a `std.Io` the caller supplies**, `rest`. The caller
  chooses it, usually `std.Io.Threaded`, and owns its threads: decision 18's model, a pool the loop
  uses and never starts.

### Which calls run on rotor

33 of the 109 run on the adapter and the loop. The other 76 go to `rest`.

| `std.Io` calls | on rotor |
|---|---|
| `async`, `concurrent`, `await`, `cancel`, the four `group` calls, `recancel`, `swapCancelProtection`, `checkCancel` | the adapter's fiber scheduler. `async` runs its function inline when no fiber is free, which the interface allows. `concurrent` with no fiber free returns `ConcurrencyUnavailable`. `cancel` cancels the operation the fiber waits on, and that operation's final event resumes it with `error.Canceled`. |
| `futexWait`, `futexWaitUncancelable`, `futexWake` | wait lists in the adapter. A wake from another thread is a `post` or a `Remote` (decision 4). |
| `operate` and the three `batch` calls | the scheduler, and one operation per entry: `net_receive` is `receive` |
| `netAccept`, `netConnectIp`, `netRead`, `netWrite`, `netSend`, `netClose`, `netShutdown` | `accept`, `connect`, `receive`, `send` and `send_to`, `close`, `shutdown` |
| `netListenIp`, `netBindIp` | `sync.listen` and `sync.open_datagram`, which set a socket up without the loop |
| `fileReadPositional`, `fileWritePositional`, `fileSync`, `fileClose` | `read`, `write`, `fsync`, `close`, under the loop's file policy (decision 18) |
| `now` for the `awake` and `boot` clocks, `sleep` | `Loop.now_ns`, and a timer |

The crash handler, the directories, the rest of the files, the processes, the other clocks,
randomness, name lookup and Unix sockets go to `rest`. A future resolver on rotor, such as cocuyo
(decision 17), could take `netLookup` later.

### How a blocking call runs

1. A fiber calls, say, `netRead`. The adapter submits a `receive` whose `user_data` names the fiber,
   and switches to the scheduler.
2. The scheduler resumes the next ready fiber. When none is ready, it ticks the loop.
3. The tick hands over events. For each, the scheduler marks its fiber ready with the result.
4. The fiber resumes where it switched out, and `netRead` returns.

So a blocking call costs two fiber switches, the calls through the table, and the operation itself.

### Where the table and rotor do not meet

1. **Vectors.** `netRead` takes several buffers and `netWrite` a header, several buffers and a
   repeat count. rotor's `receive` and `send` take one buffer. The adapter would issue one
   operation per buffer, or copy into one. Neither is free, and rotor has no vectored send or
   receive to offer instead.
2. **Streaming files.** The batch's file operations read and write at the file's current position,
   and rotor's `read` and `write` take an offset. The adapter hands them to `rest`.
3. **The speed sources**, above. They stay rotor's own API.

## What it costs

Nothing below is measured. Each cost is an estimate from recorded rows where one exists.

- **Per blocking call:** two fiber switches, not measured on any machine here; one or two indirect
  calls through the table, C5, 1.50 ns each on `mac`; and the scheduler's bookkeeping. Against the
  calls they wrap, a `kevent` wait or a `send` and `recv` of 64 KiB (C22, 11,204 ns on `github`),
  the adapter is cheap if a switch costs tens of nanoseconds, a figure recalled and not measured.
  The first measurement below decides it.
- **Memory:** `fibers × stack_bytes`, fixed at init. 256 fibers of 64 KiB is 16 MiB. std's `Kqueue`
  gives each fiber at least 4 MiB. A stack too small overflows into the next fiber's memory, so a
  guard page below each stack is proposed (open question 3).
- **Maintenance.** `std.Io` is new in Zig 0.16 and will change. The adapter fills the table at
  comptime, so a Zig release that changes the table fails to compile until the adapter follows it.
- **A module and an edge.** Decision 1 drew `adapter` over `core` and one backend. Since decision 20
  the public module chooses the backend when the process starts, so the adapter would import the
  public module `rotor`, an edge the graph does not have yet (open question 2).

## Alternatives it beats

1. **The table in the core.** Rejected by decision 1: fibers in the core, 79 functions with nothing
   to gain, and the speed sources still out of reach.
2. **No adapter.** Rejected by decision 1, as above.
3. **A thread per blocking call, as `std.Io.Threaded` does.** It breaks one loop per thread, and it
   would be `std.Io.Threaded` with a loop added and nothing gained.
4. **std's evented machinery with rotor as its poller.** `Uring`, `Dispatch` and `Kqueue` allocate
   each fiber from a general-purpose allocator and run fibers on threads rotor does not own, and
   `Uring` and `Kqueue` move fibers between those threads. Each breaks a rule of CLAUDE.md, so the
   adapter keeps std's context switch and nothing else.
5. **Stackless coroutines.** Zig 0.16 has none.

## How it is checked

1. **The switch, first, before anything is built.** `docs/costs.md` gains a row: one fiber switch
   out and back with `std.Io.fiber`, on `mac`, `orbstack` and `github`.
2. **The harness.** `std_io_echo` and `std_io_timers`, unchanged, run on the adapter beside
   `std.Io.Threaded`, beside `std.Io.Evented` where it compiles (`Dispatch` on macOS today), and
   beside `rotor_echo` and `rotor_timers` on rotor's own API. The gap to rotor's own programs is the
   adapter's cost; the gap to the other two is its reason to exist.
3. **Conformance.** std's own tests for `std.Io` use a fixed `std.Io.Threaded` and cannot be
   pointed at another implementation, so the adapter gets scenarios of its own against the table:
   every call of the 33 in the table above, a cancel of each blocking one, `concurrent` with no fiber
   free, a futex woken from another thread, and a call of the 76 reaching `rest`. They run on
   kqueue, io_uring and epoll.
4. **An example.** An echo server written against `std.Io` alone, under `examples/`, run by
   `zig build test` and the Linux gate against `tools/echo_check.zig`.
5. **Halt scenarios:** a call from another thread, a stack that overflows into its guard page, and
   an adapter given memory smaller than its options need.

## Open questions

1. **Build it, and when?** Proposed: after the macOS cross-core work and a number on the Linux
   machine, and only if the fiber switch measures small against the calls it wraps.
   **Answered on 2026-09-27: build it**, on two conditions Camilo set: it keeps rotor's performance,
   and its API follows rotor's own primitives. The fiber switch is measured first, as check 1 asks.
2. **The edge from `adapter` to the public module.** Proposed: allow it. The adapter needs the
   backend the process chose, and only the public module knows it.
   **Answered on 2026-09-27: allowed, as proposed**, with the ruling to build the adapter.
3. **Guard pages.** One page below each stack, protected with `mprotect` at init, turns an overflow
   into a fault. It costs a page per fiber and one system call per fiber at init. Proposed: yes.
   **Answered on 2026-09-27: yes, as proposed.**
4. **Vectored send and receive in rotor**, so that `netRead` and `netWrite` need no copy and no
   extra operations. io_uring has `sendmsg` and `recvmsg`, and kqueue and epoll have `writev` and
   `readv`. It changes the core's `Operation`, so it is its own record if the harness shows the cost.
   **Deferred on 2026-09-27** by Camilo, until the adapter's numbers show whether the copy matters.
5. **`fsync` in rotor**, so that `fileSync` runs on the loop. **Answered on 2026-09-26:** Camilo
   ruled it in, and rotor has an `fsync` operation beside `fdatasync` (decision 2, its amendment of
   that day).
6. **Which Zig versions.** Proposed: the adapter follows the Zig version rotor pins, 0.16.0 today,
   and a Zig upgrade reads the table again.
   **Answered on 2026-09-27: as proposed.**
