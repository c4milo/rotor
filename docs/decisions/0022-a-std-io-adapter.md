# 22. A std.Io adapter

Status: **accepted** on 2026-09-27 by Camilo, to be built on two conditions: it keeps rotor's
performance, and its API follows rotor's own primitives (open question 1). **Deferred** the same
day: nothing is started, the fiber switch's measurement included, until Camilo asks for it.
**Started** on 2026-11-04 with check 1, and **built** from 2026-11-05 by Camilo's choice of that
day, in the steps of "How it is built". **Removed** the same day, after step 3, by Camilo's
choice: "Why it was removed" says why. Check 1, row C26 of `docs/costs.md` and its probe
(`b2bcf60`), went with it, because only the adapter needed a fiber switch. Proposed on
2026-09-26. Decision 1 chose a completion-based core with a
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

An adapter returns a `std.Io` whose state is one rotor loop and a pool of fibers. Its files are in
`src/rotor/adapter/`, inside the public module, by Camilo's ruling of 2026-11-05 (open question 2).
The core never imports it. The shape a caller would see:

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
   **Started on 2026-11-04**, by Camilo's choice of that day, after colibri's decision 150 made
   its `serve` module run on this adapter by default. The row is C26, and its probe is
   `bench/costs/probes/probes_fiber.zig`. No quiet run has filled a cell yet. The probe found that
   std's `contextSwitch` faults in an optimized build on aarch64, from three errors in its clobber
   lists, which the probe's comment names: two on macOS and Linux, and one on Linux only. Zig
   0.17.1 has the same lists. So the adapter cannot call std's switch as it is: it needs its own
   copy with the lists corrected, as the probe has, or a fixed std.
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

## How it is built

Each step is one commit, and each commit passes `zig build test`.

1. **Fibers, the scheduler, tasks and waits.** The pool on the caller's memory, the corrected
   switch of check 1, the task, group and cancel calls, the futexes, `now` and `sleep`, and the
   halt scenarios for what a caller can do wrong with them. Cancellation, groups and futexes are in
   this step, because `sleep` and a futex wait are cancel points. Every other call goes to `rest`.
   **Built on 2026-11-05.**
2. **The network.** The nine network calls of the table above, and an echo server written against
   `std.Io` alone, `examples/std_io_echo.zig`, which `tools/echo_check.zig` checks (check 4).
   **Built on 2026-11-05.**
3. **Batches and files.** `operate`, the three `batch` calls, and the four file calls.
4. **The checks.** Guard pages, a futex woken from another thread, and the scenarios on io_uring and
   epoll in the Linux gate.
5. **The numbers.** Check 2 of "How it is checked": `std_io_echo` and `std_io_timers` of the
   harness on the adapter. **The echo half ran early, on 2026-11-05**, after steps 1 and 2, because
   Camilo asked whether the adapter harms rotor before step 3. The echo runner's candidate
   `std.Io on rotor` is `std_io_echo` on the adapter. On GitHub's Linux runners it ran at 86 to 96
   percent of rotor's own server on x86-64 and 71 to 91 percent on arm64, and ahead of
   `std.Io.Threaded` on 13 of 16 rows; macOS gave no usable row
   (`bench/results/adapter-echo-github-2026-11-05.md`). Camilo chose that day to go on with step 3.
   kqueue's numbers wait for a quiet `mac`.

What step 1 decided:

- **There is no scheduler context.** A context that blocks switches straight to the first ready
  context, and ticks the loop on its own stack when none is ready. A blocking call so costs one
  switch out and one back, where "How a blocking call runs" counted two switches to and from a
  scheduler.
- **A task's arguments and result live at the top of its fiber's stack**: at most 1,024 bytes of
  arguments and 512 of result, as std's `Dispatch` allows. A larger task runs inline under `async`
  and is refused under `concurrent`.
- **Stacks are a whole number of 64 KiB granules**, a multiple of every page size rotor's hosts use, so a
  guard page fits below each in step 4. The caller's memory needs only 16-byte alignment: `init`
  moves the stacks up to a granule boundary, because a Mach-O build placed a static declared with
  an alignment of 64 KiB off that boundary.
- **A timer waits for the loop's first clock reading.** On io_uring `Loop.now_ns` is 0 until the
  first tick, and a timer's delay runs from it (decision 14, rule 6), so a sleep before the first
  tick was due at once. The Linux gate found it. The adapter polls the loop once before it submits
  an operation to a loop that has read no clock.
- **An event of the caller's own operations goes to a handler** the caller names in the options.
  Each operation of the adapter carries `0xADA7` in the top 16 bits of its `user_data`.
- **A context that waits while nothing is in flight halts**, because nothing could wake it. A futex
  woken from another thread, in step 4, changes this.
- **The public module's tests also run in ReleaseSafe**, in `zig build test` and in the Linux gate,
  because the switch's faults showed only in an optimized build.

Step 1's mutations. Each breaks one check, and each is measured against the narrowest step that
can catch it. Every one is CAUGHT.

| mutation | step |
|---|---|
| `x1` back in the switch's clobber list; `lr` left out of it | `test-rotor-release` |
| a canceled wait not acknowledged; a cancel point that ignores the acknowledgement | `test-rotor` |
| a cancel that does not end the operation a task waits for | `test-rotor` |
| a futex wake that takes one waiter too many; waiters woken in the reverse order | `test-rotor` |
| a futex wake that leaves the wait's timer running | `test-rotor` |
| a futex wait that ignores the expected value | `test-rotor` |
| a wait that ignores the task's protection; `recancel` that keeps the flag | `test-rotor` |
| a group member or a future that does not wake its awaiter | `test-rotor` |
| a group cancel that cancels no member; `groupAwait` that does not pass a cancel on | `test-rotor` |
| an event of the caller's operation taken as the adapter's | `test-rotor` |
| a result too large for the stack's top taken onto a fiber | `test-rotor` |
| the awake clock read from `rest`; a fiber not freed by `await` | `test-rotor` |
| a forwarder that drops `rest`'s `userdata` | `test-rotor` |
| no poll before an operation on a loop that has read no clock | the Linux gate |
| each of the 13 assertions the halt scenarios name, deleted | `halt-check` |

The first `x1` mutation was NOT CAUGHT. The broken switch never loads its argument, and the tests
passed because `x1` held a usable pointer by chance. `adapter_switch_test.zig` now clears `x1`, or
`rsi` on x86-64, before it switches. The first forwarder mutation was NOT CAUGHT too, until the
test's `rest` checked the `userdata` it receives.

What step 2 decided:

- **A read or a write moves one buffer.** `netRead` receives into the first buffer with room, and
  `netWrite` sends the header, else the first buffer with bytes, else the repeated last buffer
  once. `std.Io.Reader` and `std.Io.Writer` take a short count and call again. Open question 4
  stays deferred until the harness shows what that costs.
- **An accepted socket's address costs a `getpeername` call**, because the loop's accept reports
  the descriptor alone. A peer that left before that call ends the accept with
  `ConnectionAborted`.
- **A listen and a bind refuse what `sync` cannot open**: a listen takes a TCP stream, and a bind
  a UDP datagram socket. A bind refuses `ip6_only` and `allow_broadcast` with `OptionUnsupported`.
- **A connect's timeout is the operation's deadline** (decision 5, rule 4), at most
  `timeout_ns_max`.
- **std 0.16.0's `Socket.closeMany` does not compile**: it hands the table sockets where the table
  takes handles. A caller closes through the table, or one socket at a time.

Step 2's mutations, all against `test-rotor` and all CAUGHT: a read into an empty buffer; a write
that skips the header, or sends the repeated buffer when `splat` is 0; an accept that reports an
address the kernel did not give; no cancel point before an operation; a refused connect answered
as a reset; a shutdown of the sending side that shuts the receiving side; a close that does not
wait for its event; a bind that takes a stream socket and a listen that takes a datagram one; a
read left to `rest`; an address that loses its port. The first two NOT CAUGHT, the read into an
empty buffer and the shutdown, each gained a test.

## Why it was removed

Camilo removed the adapter on 2026-11-05, after steps 1 to 3 were on main (`dfbb644`, `8f76dd7`,
`89b0a8a`), and asked that rotor keep its own interface, checked at compile time, lean. The record
of what was built stays above. The facts the choice rested on:

- **It changed nothing of rotor's own paths, and it was large.** Steps 1 to 3 touched no file of
  `core` or of a backend, and the instruction gate held. They added about 2,300 lines of library
  code and 1,500 of tests and halt scenarios to a `src/` of about 26,500 lines.
- **Most of its cost was upkeep.** `std.Io` is new, and Zig 0.17.1 was already installed. The
  adapter carried its own copy of std's context switch, and each Zig upgrade would mean reading
  the table's 109 calls again.
- **It bent rotor's rules.** The determinism lint skipped its directory, `zig build test` ran the
  public module's tests twice, and step 4's wake from another thread needed a way across threads
  that decision 4 does not give.
- **What it gave was measured on Linux only.** `std.Io` code ran on it at 71 to 96 percent of
  rotor's own echo server, and ahead of `std.Io.Threaded` on 13 of 16 rows. macOS gave no usable
  row (`bench/results/adapter-echo-github-2026-11-05.md`).
- **rotor's own interface is already the lean one.** `core/surface.zig` checks at compile time that
  every backend carries the same names, so a consumer swaps backends, or a twin of its own, with
  no call through a table, and keeps the speed sources. Code written against `std.Io` does not run
  on it without changes. That is what rotor gives up.

The alternatives were to move the adapter into a package of its own that depends on rotor's public
module, and to keep it in rotor and build no further step. colibri's decision 150 had chosen the
adapter for its `serve` module, so colibri needs another path.

## Open questions

1. **Build it, and when?** Proposed: after the macOS cross-core work and a number on the Linux
   machine, and only if the fiber switch measures small against the calls it wraps.
   **Answered on 2026-09-27: build it**, on two conditions Camilo set: it keeps rotor's performance,
   and its API follows rotor's own primitives. The fiber switch is measured first, as check 1 asks.
2. **The edge from `adapter` to the public module.** Proposed: allow it. The adapter needs the
   backend the process chose, and only the public module knows it.
   **Answered on 2026-09-27: allowed, as proposed**, with the ruling to build the adapter.
   **Changed on 2026-11-05.** The public module is the only module a dependent package can name,
   so it must export the adapter, and the edge from the adapter to it would then be a cycle. Camilo
   chose to put the adapter's files in the public module, in `src/rotor/adapter/`, and the graph
   gains no module and no edge. The alternatives were an adapter generic over a `Loop` type, which
   the public module imports, and a second public module.
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
