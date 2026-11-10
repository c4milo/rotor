# 34. A package of its own for `std.Io` and its Future API

Status: **proposed** on 2026-11-10, and revised the same day after two reviews. Nothing is built,
and no repository exists. On 2026-11-09 Camilo ruled where this work goes ("Ruling, 2026-11-09").
He did not rule on the design below. Each open question has a proposed answer. Nothing is built
before Camilo accepts this record.

Nothing was measured for this record. Each number is a row of `docs/costs.md`, a row of
`bench/baseline/work.txt`, a number that decision 22 measured, or a prior. A prior is arithmetic
over such rows. Each table says where its numbers come from.

If it is accepted, it changes no source file of rotor. It amends decision 1, which still says that
the `std.Io` table is a module of rotor, and decision 2 gains a note ("What changes in rotor").
Decision 22 gained one note that points here, in the first commit of this record. "Ask before"
lists each item that needs Camilo's word first.

## Ruling, 2026-11-09

On 2026-11-09 Camilo wrote to this session: "Let's also use Zig's Futures API for the reactor".

The session told him three facts:

- Zig's Future API is `io.async`, `future.await` and `future.cancel`. It works only through a
  `std.Io`.
- `await` needs fibers.
- Decision 22 built that `std.Io` over rotor. Camilo removed it on 2026-11-05, for its size, its
  upkeep and the rules it bent.

The session then put four choices to him:

1. A package of its own. The session recommended this choice.
2. Inside rotor's `reactor` module.
3. Future-shaped names with no `std.Io`.
4. An explanation first.

Camilo chose "A package of its own". The text of that choice said: "A separate package gives a
std.Io over rotor.Reactor, with fibers that run as tasks in a scheduling group. rotor stays lean and
takes no upkeep from std.Io. This is the alternative you did not pick on 2026-11-05. I draft a
proposed decision first, and build nothing."

He gave no reason with the choice.

The session asked Camilo where the Future API goes, and he chose one of the four choices. So this
record takes two things as ruled:

1. The `std.Io` is in a package of its own, outside rotor.
2. A proposed decision comes first, and nothing is built.

The other sentences of the text are the session's words. They describe a design: a `std.Io` "over
rotor.Reactor, with fibers that run as tasks in a scheduling group". Camilo chose the text whole,
and he ruled on no part of that design. So this record proposes the design, and does not use the
text as a reason for it:

- Open question 2 asks who calls `tick`. The answer decides whether a fiber runs inside a
  `rotor.Task`.
- Open question 3 asks about `rotor.Reactor`. That type is decision 33's, which is proposed and not
  built.
- Item 7 of the decision proposes that rotor does not depend on the package.

## Context

### What the Future API is in Zig 0.16.0

These facts were read from `std/Io.zig` of the Zig 0.16.0 on the development machine, on
2026-11-10:

- `io.async(function, args)` (line 2326) returns a `Future(Result)` (line 1176). It calls `async` of
  the table. The table may run the function at once, on the caller's stack.
- `io.concurrent` (line 2365) calls `concurrent` of the table. That call gives the function a unit
  of concurrency, or it returns `error.ConcurrencyUnavailable`.
- `future.await(io)` and `future.cancel(io)` call `await` and `cancel` of the table. Each returns
  the function's result, so each stops its caller until the function returns.
- A `Group` (line 1218) holds functions that a caller awaits or cancels together, through four more
  calls of the table.
- The table is `Io.VTable` (line 51). It holds 109 function pointers, counted again for this record.
- The table marks `async`, `concurrent`, `await`, `cancel`, `groupAsync` and `groupConcurrent` as
  "Thread-safe". std also marks `io.random`, `io.randomSecure` and the `Queue` type as safe from
  several threads (lines 2465, 2482 and 2181).

So a caller gets the Future API only through a `std.Io`. A `std.Io` whose `await` stops its caller
needs something to suspend: a thread or a fiber (decision 1).

### Words

std and rotor each use the words "task" and "group". This record keeps them apart, and it gives
four more words one meaning each:

| word | meaning |
|---|---|
| **std task** | a function that `io.async`, `io.concurrent`, `Group.async` or `Group.concurrent` starts. std's own word is "task" |
| **rotor task** | a `rotor.Task`: a record that the loop calls once, in a later part of a tick (decision 27) |
| **`Io.Group`** | std's set of std tasks, which a caller awaits or cancels together |
| **scheduling group** | rotor's queue of rotor tasks, with shares (decision 30) |
| a call **blocks** | its fiber stops until an event. The thread does not stop: it goes on with the tick |
| a tick **waits** | its thread sleeps in the kernel |
| a fiber is **active** | from the start of its std task until the function of that std task returns |
| a fiber is **in use** | from the start of its std task until the fiber is free again |

rotor's documents say "a tick that blocks" for a tick whose thread sleeps in the kernel. This
record says "a tick waits" for that. It keeps "blocks" for a call, as std's own comments do
(`std/Io.zig`, line 1272).

A fiber of an `Io.Group` is free when its function returns. A fiber of a future stays in use after
its function returns, until `await` or `cancel` takes the result. The result is in that fiber's
stack. Decision 22's code worked the same way (`adapter_tasks.zig`).

### What decision 22 built, and why it went

Decision 22 built a `std.Io` whose state was one `rotor.Loop` and a pool of fibers. Its files were
in `src/rotor/adapter/`. Steps 1 to 3 landed on 2026-11-05 (`dfbb644`, `8f76dd7`, `89b0a8a`): the
calls for std tasks, the network calls, then datagrams, batches and files. Camilo removed it the
same day (`46235cb`). The fiber switch probe and row C26 of `docs/costs.md` went too (`85d5e67`).

Decision 22, "Why it was removed", gives the facts of that choice:

- It added about 2,300 lines of library code, and 1,500 of tests and halt scenarios, to rotor.
- Most of its cost was upkeep. It carried its own copy of std's context switch. Each Zig upgrade
  meant a new read of the 109 calls.
- It bent rotor's rules. The determinism lint skipped its directory, and `zig build test` ran the
  public module's tests twice. Its wake from another thread needed a way across threads that
  decision 4 does not give.
- Its numbers came from Linux only.

That section names two alternatives. One is a package of its own that depends on rotor's public
module. This record is that alternative.

Camilo accepted decision 22 on 2026-09-27 on two conditions: "it keeps rotor's performance, and its
API follows rotor's own primitives" (its open question 1). The removal of 2026-11-05 withdrew
neither. Open question 10 asks whether they bind the package.

How that code worked matters for this record:

- **It ticked the loop itself.** A context that blocked switched to the next ready fiber. When none
  was ready, it called `tick` on its own stack.
- **It read each event from `tick`.** Each of its operations carried the tag `0xADA7` and the
  fiber's index in `user_data`. An event without the tag went to a handler of the caller.

### What rotor gained since the removal

Each row was read from the record it names, and from `src/rotor/rotor.zig` at `2b165b8`.

| since 2026-11-05 | record | what the package takes from it |
|---|---|---|
| an operation names a `Completion`, and the tick calls it for each event | 26 | each fiber's operation names a record, so the package reads no event from `tick` |
| only the program calls `tick`, and a library holds a `*SharedLoop` | 27, 28 | the package ticks nothing |
| a `rotor.Task`, which the loop runs once in a later part of a tick | 27 | each resume of a fiber |
| `Message.wake`, a message that wakes a loop and makes no event | 29 | a `futexWake` from another thread |
| a poller answers a `WaitLimit` | 29 | a bound on the wait of the tick |
| scheduling groups with shares, and `schedule_in` | 30 | the scheduling group of the package's rotor tasks |
| cross-core calls: `Service` and `CallRecord` | 32 | a fiber that waits for the reply of a call |

v0.10.0 holds each of them. It was tagged on 2026-11-08 at `9339858`.

### Decision 33

Decision 33 is proposed and not accepted. It splits rotor into a plain `rotor.Loop` and
`rotor.Reactor(rotor.Loop)`, which holds the records, the pollers, the rotor tasks, the scheduling
groups and the calls. A program's reactor gives the same `*rotor.SharedLoop`, with the same 21
library calls. It would ship as v0.11.0. "What the package needs from rotor" checks each name
against both surfaces.

## The decision, as proposed

1. **A package outside rotor gives a `std.Io` on fibers.** Its state is the view of one loop, on one
   thread, and a pool of fibers. Under decision 33 that loop is a `rotor.Reactor(rotor.Loop)`. So
   `io.async`, `future.await`, `future.cancel` and the `Io.Group` calls work on that thread.
2. **The package is a library on a `*rotor.SharedLoop`.** The program owns the loop and ticks it.
   The package ticks nothing. "Who calls `tick`" gives the other shape, and open question 2 asks
   Camilo to choose.
3. **Each resume of a fiber is one rotor task** in the scheduling group that the program hands the
   package (decisions 27 and 30).
4. **Each operation of a fiber names a record** in the fiber's own struct (decision 26). The package
   puts no tag in `user_data`.
5. **The package runs 34 of the 109 calls.** The other 75 go to `rest`, a `std.Io` that the program
   hands to `init`. One of the 34, `netLookup`, is a wrapper around the call of `rest`.
6. **The package adds calls of its own** for what the table cannot say. One blocks a fiber on a
   rotor operation, and one blocks it on a cross-core call. One names how another thread posts a
   wake.
7. **rotor does not depend on the package.** rotor names it in no source file, and adds nothing for
   it without Camilo's word.
8. **Each release of the package pins one Zig version and one rotor tag.**

### What the package is, and is not

It is:

- A `std.Io` for one thread. Each fiber of one value runs on the thread that owns the loop.
- Bounded at `init`. The program hands over one block of memory: a struct for each fiber, then the
  stacks. The package names no allocator.
- A library on a shared loop, as decisions 26 to 28 describe one. It submits, returns, and goes on
  in records and rotor tasks.

It is not:

- A thread pool. It starts no thread, and no fiber moves to another thread or another loop.
- A module of rotor. It is outside rotor's module graph, outside its lint and outside its releases.
- A way to the speed sources through `std.Io`. The table cannot register a buffer or arm a multishot
  receive (decision 1). Code that wants them calls rotor ("`perform`, and a multishot operation").
- A `std.Io` for several threads. Each call that the package runs halts from another thread,
  `futexWake` aside. A call that goes to `rest` has no owner check: `rest` decides what another
  thread may do there. "How a wake from another thread arrives" lists what another thread may call.

### The shape a caller sees

This is a sketch. The name `tejedor` and the type `Fibers` are the proposed answer to open question
1, and Camilo chooses them.

```zig
const std = @import("std");
const rotor = @import("rotor");
const tejedor = @import("tejedor"); // a proposed name: open question 1

fn run(loop: *rotor.Loop, memory: []align(tejedor.memory_alignment) u8, rest: std.Io) !void {
    // The program reserves a scheduling group, and hands it to the package.
    const scheduling_group = try loop.reserve_scheduling_group(100);
    const options: tejedor.Fibers.Options = .{ .scheduling_group = scheduling_group };
    var fibers: tejedor.Fibers = undefined;
    try fibers.init(loop.shared(), memory, rest, &options);

    const io = fibers.io();
    var served = try io.concurrent(serve, .{io}); // `serve` runs on a fiber
    var events: [64]rotor.Event = undefined;
    while (fibers.active() != 0) _ = try loop.tick(&events, rotor.constants.wait_ns_max);
    try served.await(io); // `serve` returned: the call does not block, and frees the fiber
    fibers.deinit(); // no fiber is in use
}
```

The calls of the package, as a sketch:

```zig
pub const Fibers = struct {
    pub const Options = struct {
        /// The fibers, at most `constants.fibers_max`.
        count: u16 = 256,
        /// The stack of each fiber, its guard page included: a whole number of 64 KiB, and at
        /// least 128 KiB.
        stack_bytes: u32 = 256 * 1024,
        /// The scheduling group that takes each resume of a fiber (decision 30). A scheduling
        /// group that only this value uses never fills.
        scheduling_group: rotor.SchedulingGroup = .default,
        /// The loop's id in its registry, for a `futexWake` from another thread. Null refuses one.
        loop_id: ?rotor.LoopId = null,
    };
    pub const InitError = error{ SystemResources, PollersFull };
    pub const PerformError = error{ Canceled, OperationsFull };

    pub fn memory_bytes(options: *const Options) usize;
    /// The most operations that the package holds in flight, for the program's `operations`.
    pub fn operations(options: *const Options) u32;
    /// `rest` runs each call that the package does not run. Its threads are the program's.
    pub fn init(
        fibers: *Fibers,
        shared: *rotor.SharedLoop,
        memory: []align(memory_alignment) u8,
        rest: std.Io,
        options: *const Options,
    ) InitError!void;
    /// Halts while a fiber is in use.
    pub fn deinit(fibers: *Fibers) void;
    pub fn io(fibers: *Fibers) std.Io;
    /// The active fibers: each one from its start until its function returns. The program ticks
    /// while it is above 0.
    pub fn active(fibers: *const Fibers) u32;
    /// Asks each std task to cancel, and returns at once.
    pub fn cancel_all(fibers: *Fibers) void;
    /// Submits `operation`, which makes one event, and blocks the fiber that calls it until that
    /// event.
    pub fn perform(fibers: *Fibers, operation: *const rotor.Operation) PerformError!rotor.Event;
};

/// How a thread that does not own the loop posts the wake of a `futexWake`: through its own
/// `rotor.Remote`, or through the view of its own loop.
pub const WakePath = union(enum) { remote: *rotor.Remote, loop: *rotor.SharedLoop };

/// Stores `path` for the thread that calls it, in a `threadlocal` variable. Null clears it. The
/// thread clears it before the `deinit` of that remote or of that loop.
pub fn set_wake_path(path: ?WakePath) void;
```

It follows the API rules of the Zig projects:

- `init` starts the value in place and takes `*const Options`.
- Each option has a default, and the type copies what it keeps.
- `rest` has no safe default, so it is a parameter of `init` (open question 7).
- `deinit` ends what `init` starts. The memory is the caller's.

`active` and `deinit` count different fibers ("Words"):

- `active` counts each fiber from its start until its function returns. So the loop of the sketch
  ends when `serve` returns.
- `deinit` halts while a fiber is in use, as a loop's `deinit` halts while an operation is in
  flight. The fiber of `serve` is in use until `served.await(io)` takes the result. So the sketch
  awaits before `deinit`, and that call does not block.
- A future that no caller awaits keeps its fiber. std asks for an `await` or a `cancel` of each
  future.

The sketch calls `deinit` on the success path only. After an error from `tick`, fibers are still in
use, and `deinit` would halt. The sketch then returns the error and leaves the value as it is.

#### `perform`, and a multishot operation

`perform` takes an operation that makes one event. A multishot operation gives its record many
events before the final one (decision 26). `perform` returns one `rotor.Event`, so it refuses such
an operation:

- It halts at the call for `accept_multishot`, `receive_group`, `receive_from` and a timer that
  repeats.
- Its record asserts that each event is the final one.

So `perform` reaches the speed sources that make one event, such as a receive into a registered
buffer. Code that wants a multishot receive names a record of its own, as each library does. That
record wakes a fiber with `Event.set`, which is a `futexWake` on the loop's thread.

### Which calls run where

The counts are of the 109 fields of `Io.VTable` at Zig 0.16.0. "Step" is the step of "Build order"
that builds the row. Until its step is built, a row goes to `rest`.

| calls of `Io.VTable` | count | what runs them | step |
|---|---:|---|---:|
| `async`, `concurrent`, `await`, `cancel`, `groupAsync`, `groupConcurrent`, `groupAwait`, `groupCancel`, `recancel`, `swapCancelProtection`, `checkCancel` | 11 | the package. A std task takes a free fiber. With no fiber free, `async` and `groupAsync` run the function on the caller's stack, which std allows. `concurrent` and `groupConcurrent` then return `ConcurrencyUnavailable` | 1 |
| `futexWait`, `futexWaitUncancelable`, `futexWake` | 3 | the package: one list of the fibers that wait. A timeout is one `timer` operation. `futexWake` is the one call that another thread may make | 1, and 2 for another thread |
| `now` for the `awake` and `boot` clocks, `sleep` | 2 | `now_ns` of the view, and one `timer` operation | 1 |
| `netLookup` | 1 | the package, as a wrapper around the call of `rest` ("Why `netLookup` is a wrapper") | 1 |
| `netListenIp`, `netBindIp` | 2 | `rotor.sync.listen` and `rotor.sync.open_datagram`, at once, on the caller's stack | 5 |
| `netAccept`, `netConnectIp`, `netRead`, `netWrite`, `netSend`, `netShutdown` | 6 | one operation each: `accept`, `connect`, `receive`, `send`, `send_to`, `shutdown` | 5 |
| `netClose`, `fileClose` | 2 | one `close` operation, on a fiber. Outside a fiber, and with a full table of operations, `rotor.sync.close_now` | 5 |
| `operate`, `batchAwaitAsync`, `batchAwaitConcurrent`, `batchCancel` | 4 | the package, for `net_receive`. The other three kinds of `Io.Operation` go to `rest` | 7 |
| `fileReadPositional`, `fileWritePositional`, `fileSync` | 3 | `read`, `write`, `fsync`, under the loop's file policy (decision 18). A file operation that the loop refuses goes to `rest` | 7 |
| `crashHandler`, the 26 directory calls, 24 file calls, the 15 process calls, `clockResolution`, `random`, `randomSecure`, 6 network calls, and `now` for the other clocks | 75 | `rest` | none |

The first nine rows hold 34 calls: the 33 that decision 22 ran on the loop, and `netLookup`. The
package runs 17 of them after step 1, 27 after step 5, and all 34 after step 7. `fileClose` was in
decision 22's step for files. Here it is in step 5 with `netClose`, because no file policy refuses a
close, and `std.Io.failing` halts on each close.

#### Why `netLookup` is a wrapper

`netLookup` takes a `Queue` of the caller. No other call that goes to `rest` takes a std object that
a fiber can wait on. The connect by host name of std starts the lookup with `io.async`. Then it
waits on that queue with the same `io` (`HostName.connectMany`, lines 343 to 352). So the fiber that
waits is on the package's futex list. `rest` cannot wake it:

- `std.Io.Threaded` fills and closes the queue with its own `io` (`Threaded.zig`, lines 13472 and
  13502 to 13520). So `Queue` wakes the getter through `Threaded`'s futex (`Io.zig`, line 1989). The
  package's list never sees that wake.
- `std.Io.failing` returns `error.NetworkDown` and does not close the queue (`Io.zig`, lines 3430
  to 3436). std's rule is that the call closes it, also on an error (`HostName.zig`, line 155).

With each one the fiber never resumes. Decision 22's code had the same path. So the package runs
`netLookup` itself:

1. It makes a queue of its own on the caller's stack, with room for 32 results. That is the room
   that `connectMany` gives its own queue. The rule of std is that a lookup does not block on a
   queue of 16 or more (`HostName.zig`, line 153).
2. It calls `netLookup` of `rest` with that queue. No fiber waits on it, so `rest` wakes nothing.
3. It moves each result to the caller's queue with the package's own `io`.
4. It closes the caller's queue with the package's own `io`, also when `rest` returned an error.
   Then it returns what `rest` returned.

It costs two things. The caller gets no result before the whole lookup ends. With a `Threaded`, the
lookup holds the loop's thread for its length, as each call of `rest` that blocks.

#### What `rest` is

`rest` is a `std.Io` that the program hands to `init`, as in decision 22. It has no default (open
question 7). The package starts no thread with either value below.

The forwarders are built from `Io.VTable` at comptime, as `adapter_rest.zig` built them. A forwarder
has no owner check, as in that file. It reads only `rest`, which no call changes after `init`. So
`io.random` and `io.randomSecure` stay safe from each thread when `rest` makes them so.

**A `std.Io.Threaded` of the program's.** A call then runs on the thread that makes it, or on
threads that the program's value owns (decision 22, `adapter.zig`). A call that blocks there holds
the loop's thread for its length. The stall count of decision 28 sees it.

**`std.Io.failing`** (`std/Io.zig`, lines 2512 to 2638), for a program that wants no thread. std
describes it as a system that supports no `Io` operation. This table was read from the function of
each of the 75 calls:

| what `failing` does | calls | which |
|---|---:|---|
| returns an error | 54 | each call that is in no row below |
| halts, because its function is `unreachable` | 14 | `dirClose`, `fileIsTty`, `fileEnableAnsiEscapeCodes`, `fileSupportsAnsiEscapeCodes`, `fileUnlock`, `fileMemoryMapDestroy`, `fileMemoryMapSetLength`, `fileMemoryMapRead`, `fileMemoryMapWrite`, `lockStderr`, `unlockStderr`, `childWait`, `childKill`, `netInterfaceName` |
| returns with no error, and does nothing | 6 | `crashHandler`, `dirSetTimestamps`, `fileSetTimestamps`, `fileDowngradeLock`, `dirRead`, which reports no entry, and `tryLockStderr`, which answers null |
| returns with no error, and its answer is not true | 1 | `random` fills its buffer with 0 (lines 3297 to 3300) |

Three more facts hold with `failing`:

- `now` for the other clocks answers time 0, with no error (lines 3308 to 3312). A `sleep` or a
  futex wait to a deadline on the `real` clock then computes its wait from time 0.
- So a program that hands over `failing` uses none of those clocks, no `random`, and no call of
  the second row.
- Until its step is built, a call of the package goes to `rest` too. `failing` halts on five of
  them: `netClose` and `fileClose` before step 5, and the three batch calls before step 7.

### How one call that blocks runs

Each fiber has a struct, `Fiber`, in the caller's memory. It holds the fiber's saved context, one
`rotor.Completion` and one `rotor.Task`. The example is `io.sleep` on a fiber F, on the surface of
v0.10.0.

1. F calls `io.sleep`. The table calls the package's function on F's stack.
2. The function is a cancel point. It returns `error.Canceled` when a cancel waits for F.
3. It builds `rotor.Operation.timer(0, after_ns, 0).completion(&fiber.completion)` and calls
   `shared.submit`. It keeps the handle in `Fiber`.
4. It marks F blocked. It switches from F's stack to the thread's own stack. There the rotor task
   that ran F returns to the tick.
5. A later tick takes the timer's final event. The tick calls F's record with the event (decision
   26).
6. The record's function stores the result in `Fiber`. It calls
   `shared.schedule_in(scheduling_group, &fiber.task)`. A rotor task that a record queues runs in
   the same tick (decision 27).
7. The tick runs the rotor task after the records. Its function switches from the thread's own
   stack to F's stack.
8. F goes on inside `io.sleep`, which returns.

So a call that blocks costs two fiber switches, the calls through the table, one record and one
rotor task. "What it costs" gives the rows.

Three rules follow from rotor's own:

- **A fiber runs only inside a rotor task.** A rotor task runs inside a tick, after the tick read
  its clock. So `now_ns` is not 0 when a fiber submits a timer. Decision 22's adapter polled the
  loop once for that case (its step 1), and the package does not.
- **A wake between two fibers costs one tick.** A `futexWake`, a future that ends and a member of
  an `Io.Group` that ends each queue the rotor task of the fiber that waits. A rotor task that a
  rotor task queues runs in the next tick (decision 27). That tick does not wait.
- **One tick resumes at most 64 fibers.** `tasks_per_tick_max` bounds the rotor tasks of one tick,
  for all libraries of the loop. The fibers that are left run in the next tick, which does not
  wait.

### When the loop is full

The loop's table of operations and each scheduling group have a limit, and the package shares both
with the program and with each other library.

**The table of operations.** `submit` takes no operation when the table is full. Decision 22's
adapter then ticked until an operation ended, and a library cannot tick. So `Fibers.operations`
states the most operations that the package holds in flight: one for each fiber. Step 7 adds one for
each socket that receives datagrams. The program adds that count to its loop's `operations`, as the
guide asks of each library.

Another library can still fill the table. This table says what a call does then:

| call | with a full table |
|---|---|
| `netAccept`, `netConnectIp`, `netRead`, `netWrite`, `netSend`, `netShutdown` | returns `error.SystemResources`, which the error set of each one holds |
| `perform` | returns `error.OperationsFull` |
| `netClose`, `fileClose` | calls `rotor.sync.close_now`, which needs no operation |
| the three file calls of step 7 | go to `rest`, as when the loop refuses a file operation |
| `sleep`, and a futex wait with a timeout | halts, and the message states what `Fibers.operations` asks for. Each has no error but `Canceled` |

**A scheduling group.** `schedule_in` returns `TasksFull` when the scheduling group holds
`tasks_queued_max` (65,536) rotor tasks. A fiber has one rotor task, and a comptime assert holds
`fibers_max` below that limit. So a scheduling group that only the package uses never fills.

A scheduling group that the program shares can fill. `.default`, the default of the option, holds
the program's own rotor tasks. In a full scheduling group:

- A start with `concurrent` or `Group.concurrent` answers `ConcurrencyUnavailable`.
- A start with `async` or `Group.async` runs the function on the caller's stack.
- A resume halts, because no caller can take the error.

"The rules of rotor that the package keeps, and those it cannot keep" lists each halt of this
section.

### How a wake from another thread arrives

A thread that does not own the loop may call `futexWake` for a fiber that waits. It may make no
other call that the package runs. So it may use only a part of std's types:

| a call of std, from another thread | what it calls | result |
|---|---|---|
| `Event.set`, `Condition.signal`, `Condition.broadcast`, `Mutex.unlock` | `futexWake` alone (`Io.zig`, lines 1855, 1726, 1745 and 1641) | works |
| `Event.isSet`, `Mutex.tryLock` | no call of the table | works |
| `Mutex.lock`, `Condition.wait`, `Event.wait` | `futexWait`, when the call must wait | halts then. `Mutex.lock` waits only while another holder has the lock (lines 1602 to 1618), so the halt depends on when each thread runs |
| `Queue.put`, `Queue.get`, `Queue.close` | a lock of the queue's `Mutex` first (lines 1941, 2045 and 1919) | the same |

So a thread hands a result to a fiber with `Event.set`, after it stores the result. It shares no
`Mutex` and no `Queue` with a fiber. A test can pass for a long time before a fiber holds the lock
at the wrong moment. A second `io` on the other thread does not help: its futex is its own, and the
fiber waits on the package's list.

How the wake runs:

1. The program turns it on: `Options.loop_id` holds the loop's id in its registry. The package then
   adds one `rotor.Poller` at `init`.
2. Each other thread names how it posts, once: `set_wake_path` with its own `rotor.Remote`, or with
   the view of its own loop. The package keeps that value in a `threadlocal` variable. The thread
   calls `set_wake_path(null)` before the `deinit` of that remote or of that loop.
3. `futexWake` on that thread reads and writes no list. It swaps a flag in the `Fibers` value to
   true, with release order. When the flag was false, it posts `rotor.Message.wake` to `loop_id`.
4. The loop drops the wake. A loop that sleeps in `tick` wakes, and its next tick calls the poller
   (decision 29).
5. The poller swaps the flag to false, with acquire order. When it was true, the poller ends the
   futex wait of each fiber on the list, as a `futexWake` on the loop's thread does.
6. Each such fiber reads its futex word again. std allows a wake with no cause (`std/Io.zig`, line
   1543).

Four facts come with it:

- `MailboxFull` on the wake is safe to drop, as decision 29 says of each wake. No address crosses
  the threads.
- One wake from another thread resumes each fiber that waits on a futex: at most `count` rotor
  tasks.
- A thread that named no path halts in `futexWake`.
- **A host that owns the wait does not wake.** `Message.wake` wakes only a loop that sleeps in
  `tick` (decisions 23 and 29). The package's poller answers `.none`, so `wait_limit` gives such a
  host no bound for it. The thread that calls `futexWake` must also wake the host by the host's own
  means. The package cannot.

### How the wait of the tick is bounded

Decision 22's adapter chose the wait of each tick. The package calls no `tick`, so it can only bound
the program's wait. Three things do that:

1. **A queued rotor task.** A fiber that is ready has its rotor task in the queue, and a tick does
   not wait while one is queued (decision 27).
2. **A timer.** A `sleep` and a futex wait with a timeout are each one `timer` operation. The tick
   ends its wait at the nearest timer, as for each timer of the loop.
3. **A wake.** `Message.wake` ends the wait of a loop that sleeps in `tick`. The package's poller
   then answers `.none`, because the rotor tasks that it queued already keep the tick from a wait.

A poller can also answer `.at(deadline)` (decision 29). The package could keep its fibers' deadlines
itself, and bound the tick at the nearest one. Then:

- a `sleep` takes no operation, so it cannot meet a full table;
- a futex wake before its timeout needs no cancel;
- the package holds a heap of deadlines, and a poller runs in each tick.

This record does not propose it: rotor's timer heap exists and has a proof. The measurement of step
1 can reopen it.

### How cancel works

`future.cancel(io)` marks the fiber of the std task, acts on the wait of that fiber, and then
blocks as `await` does. The next cancel point of the std task returns `error.Canceled` once, as std
asks.

| the fiber waits for | a cancel does | the wait ends |
|---|---|---|
| an operation: a `sleep` with a time, a network call, `perform` | `shared.cancel(handle)`, which is a request (decision 5, rule 2) | at the operation's final event: `Canceled` when nothing moved, or the bytes that moved |
| a futex with no timeout, a `sleep` with no time | queues the fiber's rotor task | at the run of that rotor task, with `error.Canceled` |
| a futex with a timeout | takes the fiber off the list, and cancels its timer | at the timer's final event, so no event of the package comes after its wait |
| the members of an `Io.Group`, in `Group.await` | queues the fiber's rotor task. `Group.await` then asks each member to cancel, and blocks again with no cancel point | after the last member returns. Only then `Group.await` returns `error.Canceled` |
| another future, in `await` | nothing: `await` is no cancel point | when that future ends |
| a cross-core call | nothing: the target owns the record until it answers (decision 32) | at `finish`. The next cancel point returns `error.Canceled` |

The row for an `Io.Group` is std's rule (`std/Io.zig`, lines 1272 to 1275), and decision 22's
`group_await` did the same. A member writes the `Io.Group`, so the caller must not leave before the
last member returns. `Group.cancel` asks each member to cancel and blocks until the last one
returns. It is no cancel point.

So each operation of a fiber still ends with exactly one final event, and the fiber does not go on
before it (decision 5).

### A call outside a fiber

The program's own code between ticks is on no fiber. So is a record, a poller or a rotor task of
another library. Such code holds the same `io`, and its stack cannot block.

| call outside a fiber | result |
|---|---|
| `concurrent`, `Group.concurrent` | starts a fiber, as on a fiber. With no fiber free, `ConcurrencyUnavailable` |
| `async`, `Group.async` | starts a fiber. With no fiber free, std's rule leaves one choice: the function runs on the caller's stack. The first call of that function that must block halts |
| `await` or `cancel` of a future whose fiber is not active | returns the result, and frees the fiber |
| `Group.await` or `Group.cancel` of an `Io.Group` with no active member | returns |
| `futexWake`, `checkCancel`, `netListenIp`, `netBindIp` | work, because none blocks |
| `netClose`, `fileClose` | `rotor.sync.close_now`, at once. So a program can close what it opened outside a fiber |
| `now` for the `awake` and `boot` clocks | returns `now_ns`. Before the loop's first tick `now_ns` is 0, and the package cannot poll as decision 22's code did. The call then halts, and its message says: tick once first |
| `netLookup` | calls `rest`, and works while the caller's queue has room for each result. A put that must block halts |
| each call that must block: `await` of a future whose fiber is active, `Group.await` with an active member, `sleep`, `futexWait`, a network operation, `perform`, `call` | halts, with a message that states the rule: only the program ticks (decision 27, ruling 1) |

No fiber takes a std task whose arguments or result are larger than a fiber holds. Decision 22's
limits were 1,024 B of arguments and 512 B of result. So the first two rows apply to such a std
task with free fibers too. The halt of the second row names the rule and the limit that the `async`
met.

So the program starts its work with `concurrent`, and ticks while `active()` is above 0. To stop,
it calls `cancel_all` and ticks until `active()` is 0. It awaits each future it holds. Then it calls
`deinit`.

## Who calls `tick`

rotor's rule is that only the program ticks, and a library takes a `*SharedLoop` (decisions 27 and
28). Decision 22's adapter ticked the loop itself when no fiber was ready. So there are two shapes.

- **(a) The package owns the tick.** The program's own code runs on the thread's own stack, as the
  main context of decision 22. A context that blocks with no fiber ready calls `tick`.
- **(b) The package is a library on a `*SharedLoop`.** The program ticks. Each fiber resumes inside
  a rotor task.

Under (a) a fiber cannot be a rotor task. A rotor task runs inside a tick, and a fiber that blocks
there with no fiber ready would call `tick` inside that tick. That halts (`Dispatch.begin`, and the
guide's rule for a callback that ticks). So (a) keeps a ready list of its own, as decision 22 did,
and the loop sees no fiber.

| | (a) the package owns the tick | (b) a library on a `*SharedLoop` |
|---|---|---|
| who calls `tick` | the package | the program, as for each library |
| a fiber | a context on the package's own ready list. It is no rotor task | resumes inside a rotor task, in a scheduling group |
| a call that must block, in the program's own code | blocks: the package ticks until the call can return | halts |
| the same call in a record, a poller or a rotor task of another library | halts: a tick inside a tick | halts |
| `async` with no fiber free | the program's own code can run it and block. Another library's callback cannot | no code outside a fiber can block in it |
| other libraries on the loop | the package is the one caller of `tick`. It hands out the view, and it passes on `drain`, the heartbeat, the statistics and the scheduling groups | they take the same view from the program. Nothing passes through the package |
| a program with its own tick loop: a host that owns the wait (decision 23), or fixed turns after each tick | gives its loop up, or does not use the package | keeps its loop. A wake from another thread does not end such a host's sleep ("How a wake from another thread arrives"). Such a host sets `stall_turn_ns = null`, so rotor counts no stall there |
| an event with no record, and a post | comes to the package, which needs a handler for it, as decision 22's `Handler`: one indirect call each (C5) | goes to the program, as today |
| a wake between two fibers | no tick | one tick with a wait of 0. The `task` row counts such a tick in `.default`: 545 to 668 instructions |
| fibers that one tick resumes | the package's own limit | `tasks_per_tick_max`, 64, for all rotor tasks of the loop |
| a fiber that runs long | a stall with no name, as the program's own code between ticks. No scheduling group's shares bound it | a stall that names the package's rotor task and its scheduling group (decisions 28 and 30) |
| the package's calls beside `io` | more: each call that only the program may make needs a way through | `active`, `cancel_all`, and the calls of its own |
| under decision 33 | it holds a `rotor.Reactor(rotor.Loop)`, with its options and its error sets | one call changes: `Completion.mark` |
| rotor's rules | none breaks, and the package is the program for that loop | none bends |

The `task` row is one tick that exists only to run one rotor task (`bench/baseline/work.txt`). It
counts 545 on arm64 io_uring and 668 on x86-64 epoll, in user instructions. On macOS it counts 615,
the kernel's instructions included.

**Proposed: (b).** The reasons:

- It keeps ruling 1 of decision 27 with no exception. The package is then one more library, and
  rotor's records need no new case for it.
- Decision 30's shares bound the fibers, and decision 28's stall count names them.
- It needs no name that rotor lacks, at v0.10.0 and under decision 33.
- Its surface is small, so its upkeep is small.

The text of Camilo's choice describes (b): "fibers that run as tasks in a scheduling group". That
text is the session's, and it is no ruling on the shape ("Ruling, 2026-11-09").

Shape (b) gives up three things:

- a call that blocks on the thread's own stack;
- a wake between two fibers with no tick;
- a limit of its own for the resumes of one tick.

Step 6 measures the last two on the echo workload. Open question 2 asks Camilo to choose.

## What the package needs from rotor

Each name was checked against `src/rotor/rotor.zig` and `src/core/shared_loop.zig` at `2b165b8`.
Neither file changed since v0.10.0. The last column is decision 33's surface, as that record
proposes it.

| the package names | at v0.10.0 | under decision 33 |
|---|---|---|
| `rotor.SharedLoop`, from the program's `loop.shared()` | exported | the same name. The program's `reactor.shared()` gives it |
| on the view: `submit`, `cancel`, `now_ns`, `schedule_in`, `add_poller`, `remove_poller`, `post` | each is a library call | the same 21 library calls |
| on the view, for datagrams: `reserve_buffer_group`, `provide_datagram_buffers`, `datagram`, `give_back_buffer`, `release_buffers` | each is a library call | no change |
| `rotor.Operation`, with `timer`, `accept`, `connect`, `receive`, `send`, `send_to`, `shutdown`, `close`, `read`, `write`, `fsync`, `receive_from`, and its `kind`, which `perform` reads | exported | no change: the core's |
| the call that names a record, `operation.completion(&record)` | a method of `Operation` | `rotor.Completion.mark(&record, operation)` |
| `rotor.Completion`, `rotor.Task`, `rotor.Poller`, each with `init` | exported | the same names, from the `reactor` module |
| `rotor.WaitLimit`, `rotor.SchedulingGroup` | exported | no change |
| `rotor.Event`, with `is_final`, `rotor.Handle`, `rotor.Code`, `rotor.Error`, `rotor.Address`, `rotor.Descriptor` | exported | no change |
| `rotor.Message.wake`, `rotor.Remote`, `rotor.LoopId` | exported | no change |
| `rotor.sync`: `listen`, `open_socket`, `open_datagram`, `local_address`, `close_now` | exported | no change |
| `rotor.Service`, `rotor.CallRecord`, `rotor.CallResult`, `rotor.CallOptions`, `rotor.CallError`, `rotor.NamedSchedulingGroup` | exported | the same names. `Service` and `CallRecord` are those of the host's reactor |
| `rotor.constants`: `timeout_ns_max`, `tasks_queued_max` | exported | `timeout_ns_max` stays. Decision 33 moves `tasks_queued_max` to `src/reactor/constants.zig`, and does not say how the public module exports it |

So shape (b) needs nothing that rotor's public module does not give today. Under decision 33 one
call changes its form, and the program makes a `rotor.Reactor(rotor.Loop)`. A plain `rotor.Loop` of
decision 33 has no rotor task and no view, so the package does not run on one.

Shape (a) would also name `rotor.Loop`, with `tick`, `in_flight`, `drain` and `shared`. Each is
public at v0.10.0. Under decision 33 it would name `rotor.Reactor(rotor.Loop)` and its `Options`.

### What rotor does not give

Each row is an ask-before item. rotor adds none of them for the package without Camilo's word. The
column "without it" says what the package does today, so no row stops a step.

| the package would use | rotor today | without it | cost to rotor |
|---|---|---|---|
| a send and a receive of several buffers, for `netRead` and `netWrite` | `receive` and `send` take one buffer | one buffer for each call. std's `Reader` and `Writer` take the short count and call again (decision 22, step 2) | a change to the core's `Operation`, in a record of its own. Decision 22, open question 4, deferred it until the numbers show the cost |
| the peer's address of an accepted socket | `accept` reports the descriptor alone. `sync` has `local_address` and no call for the peer | the package calls `getpeername` itself, one system call for each accept | one more name on `sync`, on each backend. The test of its 24 names changes |
| the options `ip6_only` and `allow_broadcast` at a bind | `sync.open_datagram` sets neither | the bind answers `OptionUnsupported`, as in decision 22 | fields in `DatagramOptions`, on each backend |
| a wake from a thread that holds no `Remote` and no loop | none. Decision 29 rejected a second call across threads | the program gives each such thread a `Remote`: one id of the registry each, of `loops_max` (256) | an amendment of non-negotiable 4, decision 4 and the wake model. This record does not ask for it |
| a row of its own in the echo comparison | `bench/echo/echo_runner_setup.zig` holds a fixed list of candidates. rotor's package holds no `bench/` (`build.zig.zon`, `.paths`) | the package builds rotor's bench programs from a checkout at the pinned tag. It drives `echo_client` itself, with the runner's rules | an option of the runner that adds one candidate by name and path. rotor still names no package |
| the name of a fiber's function in a stall | a stall names a static `Task.Call`. Each fiber's rotor task has the package's one entry | a stall names the package, its scheduling group and no function | names that are not static, which decision 28 rules out. This record does not ask for it |
| under decision 33, the limit `tasks_queued_max` | exported today as `rotor.constants.tasks_queued_max` | one comptime assert of the package reads it | decision 33 states where the public module exports the reactor's limits |

### Decision 22's gap at step 4, and decision 29

Decision 22 says that its wake from another thread "needed a way across threads that decision 4 does
not give". It does not say which way. Decision 4 gives one call across threads: `post`, from a
thread's own loop or its own `Remote`. So a wake from another thread needs two things, and decision
29 gives one of them:

- **A way for the wake to reach the code that waits: closed.** Decision 22's adapter called `tick`,
  so a post came to it as an event. A library on a shared loop gets no message: each one goes to
  the program (decision 26). Since decision 29, a thread stores a flag and posts `Message.wake`,
  and the library reads the flag in its poller. That is the path of "How a wake from another
  thread arrives".
- **A way for each thread to post: not closed.** `futexWake` has no parameter for a `Remote`. A
  thread that holds neither a `Remote` nor a loop has no way to post, as on 2026-11-05. A worker of
  the program's `std.Io.Threaded` is such a thread. Decision 29 rejected a second call across
  threads. The package asks rotor for nothing here: the program names each thread's path with
  `set_wake_path`, and a thread that named none halts.

## A Future for a cross-core call

A fiber can wait for the reply of a call of decision 32. It needs a call of the package's own,
because `std.Io`'s table has no such call. A sketch, as a method of `Fibers`:

```zig
/// Sends `request` to `target` through `service`, and blocks the fiber that calls it until the
/// call's `finish` runs. It is no cancel point while the call is out.
pub fn call(
    fibers: *Fibers,
    comptime Service: type,
    service: *Service,
    target: rotor.LoopId,
    request: *const @FieldType(Service.Call, "request"),
    options: rotor.CallOptions,
) (rotor.CallError || error{ Expired, TargetStopped })!@FieldType(Service.Call, "reply");
```

`Service` is a type that `rotor.Service` returns. It declares `Call`, its `CallRecord`, whose fields
`request` and `reply` give the two types.

How it runs, on today's names:

1. The function holds a `rotor.CallRecord(Request, Reply)` in a struct on the fiber's own stack. The
   stack is memory that the caller handed over, and it does not move while the fiber waits.
2. It calls `service.send(shared, target, &record, request, options)`. `CallsFull`, `MailboxFull`
   and `LoopNotFound` come back as error values, and then nothing waits.
3. The fiber switches out.
4. The record's `finish` runs as a rotor task on the caller's loop, in the call's named scheduling
   group (decision 32). It copies the result, and queues the fiber's rotor task. So the fiber
   resumes one tick later.
5. The function returns the reply by value, or `error.Expired` or `error.TargetStopped`.

What it needs:

- **From rotor, nothing new.** `Service`, `CallRecord`, `CallResult`, `CallOptions`, `CallError` and
  `NamedSchedulingGroup` are exported at v0.10.0, and keep their names under decision 33.
- **From the program,** a named scheduling group for each call, as each call of decision 32 needs.
- **A rule for cancel.** The target owns the record until it answers, and decision 32 rejected
  `cancel_call`. So a cancel waits for `finish`.

`io.async` of a function that calls `call` gives a `std.Io.Future` for the reply. That future costs
one fiber for each call in flight, with a stack of `stack_bytes`. A `CallRecord` alone is 64 B, the
request and the reply. Decision 32 rejected a future for the memory of each call. Here the memory is
the fiber's stack, which the caller handed over at `init`. A fiber that only needs the reply calls
`call` directly, and uses no second fiber.

On the target, a handler that answers `.later` may start a fiber for the work. That fiber calls
`record.answer(shared, &reply)` once, on the target's thread, as decision 32 asks.

## What it costs

### Each call that blocks

Shape (b). Each instruction count is a prior, by arithmetic over rows that were counted on other
workloads.

| part | count | cost | source |
|---|---:|---|---|
| a fiber switch | 2: out to the thread's own stack, and back in | not measured. No row of `docs/costs.md` holds it | row C26 went with its probe (`85d5e67`) |
| a call through `std.Io`'s table | 1 or 2 | C5: 1.50 ns on `mac`, 1.53 on `orbstack`, 1.34 on `github` | `docs/costs.md` |
| the owner check of each call that the package runs | 1 | C21: 1.55 ns on `mac`, 0.93 on `orbstack`, 1.00 on `github` | `docs/costs.md` |
| the record, which the tick calls for the final event | 1 | 117 to 142 instructions: the `record` row less the `timer` row, in each section | `bench/baseline/work.txt` |
| the rotor task in `.default`, in a tick where no other scheduling group holds one: decision 27's run | 1 | 53 to 63 instructions: the `tasks-64` row less the `task` row, over 63 | `bench/baseline/work.txt` |
| the rotor task in a reserved scheduling group, as in the sketch: the run of the scheduling groups | 1 | no row counts one reserved scheduling group alone. The nearest rows give 191 to 202 and 203 to 213 instructions: `tasks-groups-4` and `tasks-groups-16`, each over 64, with the tick's own work in the count | `bench/baseline/work.txt` |
| the submit and the kernel's work for the operation | 1 | as for each operation of a library | none |

So rotor's own work for one such call has two priors:

- about 170 to 205 instructions, when the package's scheduling group is `.default` and no other
  scheduling group holds a rotor task;
- about 308 to 355 instructions on the run of the scheduling groups. A program with scheduling
  groups takes that run in each tick where one other than `.default` holds a rotor task (decision
  30, "The path with one group"). The sketch reserves one, so each resume of its fibers takes it.

Decision 22's adapter paid neither part. It read the event from `tick` and put the fiber on a list.
So the prior is that the package is slower than that adapter on the same workload. How much is not
known.

Three more costs come with shape (b):

- **A wake between two fibers** costs one tick with a wait of 0. The `task` row counts such a tick
  with one rotor task in `.default`: 545 to 668 instructions. No row counts it with a reserved
  scheduling group. What such a tick costs in the kernel was not measured for this record.
- **A busy loop takes more ticks.** One tick resumes at most 64 fibers. With 512 fibers ready, the
  loop makes 8 ticks, and each one may make the backend's call. C7 is 300 ns on `github`, and C10 is
  294 ns on `mac`. That is at most about 5 ns for each resume, by arithmetic.
- **The poller, which exists only when `Options.loop_id` holds an id.** The loop calls it once in
  each tick, for the life of the value. Its own work is one indirect call (C5) and one swap of the
  flag. A loop with a poller never takes the short path of a tick with nothing to dispatch
  (`Dispatch.idle`). The `poller` row counts a whole tick with one poller that reports no work: 505
  to 634 instructions. No row counts the same tick with no poller, so the poller's share is not
  known.

### Memory

- `count × stack_bytes`, one more 64 KiB for the alignment of the stacks, and one `Fiber` for each
  fiber and one for the thread's own stack.
- Decision 22's `Fiber` was 72 B. A `Completion` adds 8 B and a `Task` 16 B, so the prior is 96 B.
- The proposed defaults are 256 fibers of 256 KiB: 64 MiB. Decision 22's sketch had 256 fibers of
  64 KiB: 16 MiB.
- A guard page takes one page of each stack: 4, 16 or 64 KiB, by the host.

### What decision 22 measured

The only measurement of a `std.Io` on rotor is decision 22's echo run. It ran after steps 1 and 2,
on GitHub's runners (`bench/results/adapter-echo-github-2026-11-05.md`). A row's number is the
median of three runs, and each range below is over the 8 rows of a machine. None of them is a cell
of `docs/costs.md`.

| machine | `std.Io` on the adapter, as a share of rotor's own server | against `std.Io.Threaded` |
|---|---|---|
| Linux x86-64, 8 rows | 86 to 96 percent | ahead on 8 of 8 rows, at 111 to 162 percent of its rate |
| Linux arm64, 8 rows | 71 to 91 percent | ahead on 5 of 8 rows, at 81 to 142 percent of its rate |
| macOS | no row to use: 79 of 80 rows were flagged | no row to use |

Each run of the adapter reached about 135 MB of resident memory, for 512 fibers of 256 KiB. The
server of rotor's own reached 4 to 12 MB, and `std.Io.Threaded` about 27 MB.

That adapter ticked the loop itself and used no record and no rotor task. So these numbers are not a
number of the package. They are the bar that step 6 compares with.

### The fiber switch has no measured cell

Row C26 was decision 22's first check. Its probe landed as `b2bcf60` and went as `85d5e67`, both on
2026-11-05. No quiet run filled a cell. `docs/costs.md` at `b2bcf60` holds one run on a busy `mac`,
at a load average of 45. It read 4.96 ns for one switch out and back, and 1.52 ns for a call of an
empty function. That file says that the run is not a cell.

The package measures the switch first, at step 0, before it builds a call of the table:

- It takes the probe of `b2bcf60`, `bench/costs/probes/probes_fiber.zig`, with the corrected switch.
- The probe times a loop of switches out and back against a loop of calls of an empty function.
- It runs on a quiet `mac`, on `orbstack` and on a GitHub runner. A result names its machine.
- The number stays in the package's own results. Rule 1 of `docs/costs.md` takes a number only from
  a probe in rotor's `bench/costs/`. If a record of rotor needs the row, the probe comes back to
  rotor, and that is Camilo's choice.

## The rules of rotor that the package keeps, and those it cannot keep

The package is outside rotor's module graph and outside its lint. So rotor's gates check none of
this. The package runs pepegrillo's rules with a configuration of its own.

It keeps:

- **No allocator.** No file of the package names one. The caller hands over the memory at `init`.
- **Bounded, with named limits.** `fibers_max`, the least and the most stack, and the bytes of the
  arguments and the result of a std task are in its `constants.zig`. Each loop over fibers has a
  bound.
- **Assertions on.** It builds in the two modes that rotor's build offers, Debug and ReleaseSafe.
- **One thread, and shared nothing.** Each fiber of a value runs on the loop's thread. No fiber
  moves to another loop. A program with one loop for each core makes one value for each loop.
- **One final event** for each operation (decision 5), as "How cancel works" says.
- **An error value for a limit, where std's call has one.** A refused start is
  `ConcurrencyUnavailable`. A network call on a full table is `SystemResources`. A refused call
  across cores is `CallsFull`.
- **The API rules** of the Zig projects, as "The shape a caller sees" says.
- **Tests on the real kernel**, through rotor, on kqueue, io_uring and epoll (decision 10). Each
  check is proved by mutation.
- **Ugly code only in a named file, with a ledger row (decision 7).** The context switch is
  assembly, in one file. The package keeps a ledger of its own for it.

It cannot keep:

- **An error value for each limit.** rotor's rule is that a limit reached returns an error value.
  Three paths end in a halt, because no error value can reach a caller there:
  - a `sleep`, or a futex wait with a timeout, when the loop's table of operations is full;
  - a resume, when the program fills the scheduling group that it shares with the package;
  - a call that blocks inside a std task that `async` ran on a stack outside a fiber, because no
    fiber could take it.

  "When the loop is full" and "A call outside a fiber" describe them. Open question 9
  asks whether Camilo accepts them.
- **Determinism (non-negotiable 2), for the clocks and the random bytes.** `std.Io` has `now` for
  the real clock and the CPU clocks, `random` and `randomSecure`. Each goes to `rest`, which reads
  the host. `now` for the `awake` and `boot` clocks reads `now_ns`, so it keeps the rule. Decision
  22's adapter needed the determinism lint to skip its directory for this.
- **std's rules for threads.** std marks six calls of the table as safe from each thread, and
  `Queue` as safe for many producers and consumers. rotor's rule is one thread for each loop
  (non-negotiable 4). The package keeps rotor's rule. So `Mutex.lock` and each `Queue` call can halt
  on another thread, and that halt depends on when each thread runs. Code that hands one `io` to
  several threads does not run on the package.
- **A true cost for each rotor task (decision 30).** `std.Io` has no call by which a std task states
  its cost. So each resume counts as 1 unit, however long the fiber runs. A fiber that computes for
  long holds the loop. rotor counts the stall and names the package's rotor task. A host that owns
  the wait sets `stall_turn_ns = null` (the guide), so rotor counts no stall there.
- **A halt for each broken invariant (non-negotiable 6).** No assertion sees a stack that overflows.
  A guard page turns it into a fault that ends the process (open question 5). Without the page, it
  writes the next fiber's stack.
- **A halt for a fiber that nothing can wake.** Decision 22's adapter halted when each context
  waited and nothing was in flight. The package cannot: the program ticks, and another thread may
  still call `futexWake`. Such a fiber stays blocked, and `active()` stays above 0.
- **The name of the work that stalls (decision 28).** A stall names the package's one rotor task,
  and not the function that the fiber runs.
- **snake_case for each function.** The fields of `Io.VTable` are std's, in camelCase. The
  package's own functions are in snake_case.

## Upkeep

- **Each release pins one Zig version and one rotor tag.** `build.zig.zon` holds the rotor tag and
  its hash. A comptime check refuses each other Zig version, because the table differs between
  versions.
- **The table is held at comptime.** The package fills `Io.VTable` field by field, as decision 22
  did. A call whose signature changed fails the build. Decision 22's code sent a new call of std to
  `rest` with no message, and dropped an own call whose name std removed. So the package adds two
  checks:
  - a comptime check holds each of its own calls to a field of the table;
  - a test holds the count of the fields, 109 at 0.16.0.
- **A Zig upgrade is a job of the package, with a release of its own.** Whoever makes that release
  reads `Io.VTable` again, call by call, against the list of the last release. That read covers
  three more things:
  - each parameter of a call that goes to `rest`, for a std object that a fiber can wait on, as
    `netLookup` has;
  - the table of `std.Io.failing`, against "What `rest` is";
  - std's context switch, against the package's copy. Decision 22 found three errors in std's
    clobber lists at 0.16.0, and the same lists in 0.17.1.

  rotor's own Zig upgrade holds none of this work.
- **rotor's upgrade does not wait.** rotor does not depend on the package. A program that uses both
  builds with one Zig, so it waits for the slower of the two.
- **A rotor release is a job of the package too.** The move to v0.11.0 is one call form, if Camilo
  accepts decision 33 and shape (b).
- **Its CI is its own.** What it runs:
  - the package's tests on the three kinds of runner of rotor's CI: macOS on Apple silicon, Linux
    on x86-64, and Linux on arm64;
  - each test in Debug and in ReleaseSafe, because the switch's faults showed only in an optimized
    build (decision 22);
  - on Linux, each test with io_uring and with epoll, as rotor's Linux gate runs rotor's;
  - the wake from another thread under ThreadSanitizer;
  - each halt scenario in a child process, which must die by a signal.

## What changes in rotor

- **No source file, no build file and no dependency.** rotor does not depend on the package. No file
  under `src/`, `build/`, `bench/`, `tools/` or `examples/` names it.
- **No module and no edge.** The package is not decision 1's `adapter` module.
- **Decision 1 gains an amendment, when Camilo accepts this record.** Decision 1 is accepted, and
  four parts of it still put the `std.Io` table in rotor:
  - its title, "with a std.Io adapter over it";
  - its decision, "A std.Io adapter sits over it, as a separate module that the core never
    imports";
  - its section "The adapter";
  - the `adapter` row of its module table.

  Its header holds no amendment for the removal of 2026-11-05. The amendment says that rotor holds
  no `std.Io` table, and names decisions 22 and 34. This commit does not write it, because this
  record is a proposal. It is an ask-before item.
- **Decision 2 gains a note with it.** Its line "The std.Io adapter" stays under "Not in version
  one", because rotor still holds no `std.Io`. That line points at decision 1's module, so the note
  points here.
- **Decision 22 gained one note** under "Why it was removed", which points here. It is in the first
  commit of this record.
- **`docs/using.md` and the README each gain one sentence, and only after the package's first
  release.** Each says today that a `std.Io` adapter is not in version one, and that decision 2
  says what would bring it in. The sentence would say where code written against `std.Io` runs.
  Before a release there is no package to name. This is an ask-before item.
- **The README's list of records is not changed here.** It stops at record 24, and its row for
  record 22 still reads "accepted, deferred".
- **`docs/costs.md` gains no row.** "The fiber switch has no measured cell" says why.

## Where the code starts

The package starts from the tree before `46235cb`. The line counts are from that commit's own
summary.

| removed file | lines | what the package takes | what changes |
|---|---:|---|---|
| `adapter_switch.zig`, `adapter_switch_test.zig` | 323 | the corrected switch, the entry of a new fiber, and their tests | nothing but the names |
| `constants.zig` | 64 | the limits of the fibers and their stacks | the tag of `user_data` goes, with `events_per_tick`. The least stack becomes two granules, 128 KiB, for the guard page (open question 5). `fibers_max` rises (open question 4) |
| `adapter.zig` | 361 | `Fiber`, the options, the layout of the memory, and the code that fills the table | it holds a `*rotor.SharedLoop`, and no `*rotor.Loop`. `Fiber` gains a `Completion` and a `Task`. `Handler` and the array of events go. `rest` becomes a parameter of `init`. The options go by `*const` |
| `adapter_scheduler.zig` | 283 | the free list, `block`, `end_wait`, `interrupt`, and the futex list's unlink | `tick`, `poll` and `hand_over` go. The ready list goes: `make_ready` becomes `schedule_in`. `block` switches to the thread's own stack, and never ticks. The halt for "nothing is in flight" goes. A `submit` that takes none no longer ticks ("When the loop is full") |
| `adapter_tasks.zig` | 290 | `async`, `concurrent`, `await`, `cancel`, the `Io.Group` calls and the cancel protection. `await` still frees a future's fiber, and `group_await` still passes a cancel to each member | a fiber starts inside a rotor task. The cases of the main context become the rules of "A call outside a fiber" |
| `adapter_wait.zig` | 121 | the futex list, `sleep` and `now` | `now` polls nothing, and halts before the loop's first tick. The wake from another thread is new |
| `adapter_rest.zig` | 102 | the forwarders, as they are, with no owner check | `netLookup` leaves them: the package wraps the call of `rest` |
| `adapter_net.zig`, `adapter_net_errors.zig` | 347 | the nine network calls and the maps of their errors | each operation names the fiber's record. A full table is `SystemResources`. A close outside a fiber is `close_now` |
| `adapter_datagram.zig`, `adapter_batch.zig`, `adapter_file.zig` | 480 | step 7, and `fileClose` in step 5 | the receive that each socket keeps in flight names a record of its own, where it had a bit of `user_data`. The view reserves the buffer group |
| the five other test files, `tools/halt/adapter_scenarios.zig`, `examples/std_io_echo.zig` | 1,438 | the scenarios and the mutation lists of decision 22 | each test ticks the loop itself, as a program does. Each test of a call on the main context changes |

The library files hold 2,300 lines together, which is decision 22's count. The removed code read
events and chose fibers itself. The package reads records and queues rotor tasks, so most of the
change is in `adapter_scheduler.zig`.

## colibri, cocuyo and stompy

This section holds only what rotor's tree shows. It claims nothing more about the three projects.

- **colibri.** Decision 22 says that colibri's decision 150 chose the adapter for its `serve`
  module, and that colibri needs another path since the removal. Decision 33 says that colibri's
  decision 159, of 2026-11-08, gives colibri a host interface of its own, and that colibri calls no
  host. So colibri's library does not need a `std.Io` from rotor. The tree does not say whether
  its `serve` module still wants one. If it does, the package is the path that decision 22 named.
- **cocuyo.** The tree shows no request of cocuyo for a `std.Io`. Decision 22 says that a resolver
  on rotor, such as cocuyo, could take `netLookup` later. In the package, `netLookup` is a wrapper
  around the call of `rest`, and such a resolver could replace what the wrapper calls.
- **stompy.** The tree shows no request of stompy for a `std.Io`. Decision 32 says that stompy runs
  one loop for each CPU core, and sends requests between cores. Decision 27 says that stompy keeps
  turns in a fixed order after each tick. Shape (b) lets such a program keep its tick loop, and make
  one `Fibers` for each loop. `call` gives a fiber the reply of a call to another core.

On one loop, the package, colibri and cocuyo are three libraries on one view. Each has its
scheduling group, and decision 30's shares bound the three.

## Alternatives it beat

1. **The `std.Io` inside rotor's `reactor` module.** It is decision 22's shape in decision 33's
   module. It would reach the reactor's state, so a resume could cost less than a rotor task. Camilo
   did not choose it. It brings back what the removal named:
   - about 2,300 lines and their tests in rotor;
   - a new read of the table in each Zig upgrade of rotor;
   - a determinism lint that skips a directory.
2. **Future-shaped names with no `std.Io`.** rotor would export a `Future` with `await` and
   `cancel`. Without a fiber, `await` cannot stop its caller. Such a future is a record with a
   callback under another name, and rotor has those: `Completion`, `Task` and `CallRecord`. A Zig
   programmer would find a `Future` that does not block strange, and code written against `std.Io`
   would still not run. Camilo did not choose it.
3. **std's own evented machinery, with rotor as its poller.** Decision 22 rejected it as its
   alternative 4, with these facts about `Uring`, `Dispatch` and `Kqueue` of std:
   - each allocates its fibers from a general-purpose allocator;
   - each runs fibers on threads that rotor does not own;
   - `Uring` and `Kqueue` move fibers between threads;
   - `Uring` does not compile on 0.16.0.

   Each of the first three breaks a rule that the package keeps.
4. **No futures.** rotor stays as it is, and code on the reactor writes records, pollers and rotor
   tasks. It costs nothing. Code written against `std.Io` does not run on rotor, which decision 22
   names as what rotor gives up. Camilo asked for the Future API on 2026-11-09.
5. **A resume inside the record's callback, with no rotor task.** It saves the rotor task of each
   call that blocks. A record must do a small, fixed amount of work, and put the rest in a rotor
   task (decision 30). A fiber's run is not such work, and no scheduling group's shares would bound
   it.
6. **One rotor task for the package, which runs each ready fiber.** One run may then resume several
   fibers and charge its cost with `charge_task`. A wake between fibers then costs no tick inside
   one run. It needs a ready list in the package, beside the loop's queue. The first version is the
   plain one. Step 6's numbers can reopen it.

## Build order

Nothing starts before Camilo accepts this record and chooses the name (open question 1). Each step
is one or more commits in the package's repository, and each step states how it is checked. Each
check is proved by mutation, as rotor's are. No step changes rotor.

0. **The switch, and its number.** The corrected switch and its tests, and the probe of "The fiber
   switch has no measured cell". Check: the switch's tests pass in Debug and in ReleaseSafe, on
   aarch64 macOS, aarch64 Linux and x86-64 Linux. Decision 22's three mutations of the clobber
   lists are each caught. Camilo reads the probe's numbers before step 1.
1. **Fibers, std tasks, `Io.Group`s, cancel, futexes, `now`, `sleep` and the `netLookup` wrapper, on
   one thread.** The pool on the caller's memory, a record and a rotor task for each fiber, and the
   rules of "A call outside a fiber". Its checks:
   - A test of each of the 17 calls, and of a cancel of each wait, on kqueue, io_uring and epoll.
   - A cancel of a fiber in `Group.await` reaches each member, and the call returns after the last
     member.
   - A lookup through `failing` returns `NetworkDown`, and the caller's queue is closed. With a
     `rest` of the test that puts two addresses, the caller gets both.
   - Each test reads `loop.statistics().stalls` as 0 at its end.
   - A halt scenario for each of these six cases:
     - a call from another thread;
     - a call that blocks outside a fiber;
     - `now` before the loop's first tick;
     - memory smaller than the options need;
     - a `deinit` while a fiber is in use;
     - a `sleep` on a full table.
   - The mutations of decision 22's step 1, each caught.
   - The first numbers: the program of `bench/alternatives/std_io_timers.zig`, beside `rotor_timers`
     and `std.Io.Threaded`. "The timer program" says what changes in it.
2. **The wake from another thread.** The flag, the poller, and `set_wake_path`. Its checks:
   - A thread with a `Remote` wakes a futex, also under ThreadSanitizer on Linux.
   - A halt scenario: a `futexWake` from a thread that named no path.
   - A halt scenario: a `Mutex.lock` from another thread while a fiber holds the lock.
3. **Guard pages,** if open question 5 is answered yes. Check: a halt scenario whose fiber overflows
   its stack and dies by a signal. A test reads the deepest stack that each test fiber used, and
   that number sets the default of `stack_bytes`.
4. **The calls of its own: `perform` and `call`.** Its checks:
   - A fiber waits for a timer through `perform`. On a full table it gets `OperationsFull`.
   - A halt scenario: `perform` with a multishot operation.
   - Two loops on two threads: a fiber on one waits for a call to the other, and gets a reply,
     `Expired` and `TargetStopped`. A full pair gives `CallsFull`.
   - A cancel while a call is out arrives after `finish`.
5. **The network calls, and `fileClose`.** The nine network calls of the table, and an echo server
   written against `std.Io` alone. Check: a test of each call and of its cancel, and the mutations
   of decision 22's step 2. A network call on a full table returns `SystemResources`. A checker
   drives the echo server on each backend.
6. **The numbers.** "The measurement plan", below. Camilo reads the table before a release.
7. **Datagrams, batches and files,** when a consumer asks. Decision 22's step 3 is the start.
8. **v0.11.0,** when rotor ships it: the package pins it in a release of its own.

### The timer program

Step 1 runs `bench/alternatives/std_io_timers.zig` on the package. Three things change for it:

- **Its `main`.** `churn` starts one std task for each timer with `Group.concurrent`, and then calls
  `Group.await`, which blocks. So `main` starts `churn` on a fiber with `concurrent`, and ticks
  while `active()` is above 0. Decision 22's main context ran `churn`, and it was no fiber.
- **The count of fibers.** The runner's rows are 256 and 4,096 timers
  (`bench/timers/timers_runner.zig`). Each row needs one fiber more, for `churn`: 257 and 4,097.
  The program sets `count` itself. The default of 256 is one short for the first row.
- **`fibers_max`.** Decision 22's limit of 4,096 is one short for the second row. Open question 4
  proposes 8,192.

At the least stack of 128 KiB, 4,097 fibers take 512 MiB. At the default of 256 KiB they take about
1 GiB.

### The measurement plan

The workload is decision 22's: the echo workload through `std.Io`.

- **The program.** The `serve` function of `bench/alternatives/std_io_echo.zig`, with no changed
  line. Its `main` differs, as decision 22's did. Here `main` starts `serve` on a fiber with
  `concurrent`, and ticks while `active()` is above 0.
- **The candidates.** rotor's own `rotor_echo`, `std_io_echo --backend threaded`, and the package's
  server. The first two are built with `zig build bench-echo` in a checkout of rotor at the pinned
  tag, because rotor's package holds no `bench/`.
- **The method.** rotor's `echo_client` measures each server. The rounds alternate between the
  candidates, so that drift moves each one alike. Each row holds the median and the spread of its
  rounds. The table holds each row that the package loses.
- **The rows.** 16 and 64 connections, at 4, 8, 16 and 64 KiB, on one core, as decision 22's run.
- **The machines.** GitHub's Linux runners on x86-64 and arm64, with io_uring, as decision 22's
  run. A quiet `mac` for kqueue, which decision 22 never got.
- **What it must show.** The gap to `rotor_echo` is the package's cost. The gap to
  `std.Io.Threaded` is the package's reason to exist. The shares of decision 22's run are a rough
  guide to the cost of the record, the rotor task and shape (b). They come from other runs on other
  processors, so they prove nothing.
- **Where the numbers go.** They stay in the package's results. No number from CI enters
  `docs/costs.md`.

This record sets no bar for the result. Open question 10 asks whether decision 22's first condition
sets one. Camilo reads the table before a release. If shape (b) costs more than he accepts, open
question 2 opens again, with the numbers.

## Open questions

Each has a proposed answer.

1. **What are the package's name and its repository?** They are Camilo's to choose. No repository
   exists under any name below. This record did not check whether another project holds one of
   them. Camilo's rule on names applies: a name that a programmer types does not repeat its
   namespace. The candidates:
   - `tejedor`, with the type `tejedor.Fibers`. It is Spanish for a weaver, and the name of a
     weaver bird. It follows colibri, cocuyo, chapulin and pepegrillo. No file under `docs/` or
     `src/` of rotor uses the word.
   - `rotor-fibers`, imported as `rotor_fibers`. It says what the package is. Its type cannot be
     `Fibers`, by the rule. `Pool` names a thread pool in decision 18, and `Adapter` names decision
     22's code and colibri's adapters in decision 33.
   - `fibra`, Spanish for fiber. Its type `fibra.Fibers` repeats the word in a second language.

   Proposed: `tejedor`, with `Fibers` in its root file, so that the compiler prints
   `tejedor.Fibers`. A program names its value `fibers`. An import named `fibers` would refuse that
   name. Zig refuses a variable with the name of a declaration of its file (decision 33,
   "Sources").

   The names `WakePath` and `set_wake_path` are proposals too. `attach` and `Waker` already have a
   meaning in rotor's tree.

   The option `count` is a proposal too. Decision 22's code named that field `fibers`, as rotor's
   `Loop.Options` names `operations`. With the type `Fibers`, a program would then type
   `Fibers.Options` and `.fibers`, which repeats the word. Proposed: `count` while the type is
   `Fibers`, and `fibers` if the type takes another name.
2. **Who calls `tick`?** Proposed: the program. The package is a library on a `*SharedLoop`, shape
   (b) of "Who calls `tick`". The other answer is shape (a). There the program's own code may block
   on the thread's own stack. The package is then the one caller of `tick`, and a fiber is no rotor
   task.
3. **Does the package start on v0.10.0, or wait for v0.11.0?** The text of Camilo's choice names
   `rotor.Reactor`, which exists only after decision 33 is accepted and built. Proposed: start on
   v0.10.0. Under shape (b) the package names the view and not the reactor, and one call changes
   form at v0.11.0. Steps 0 and 1 then give the fiber switch's number early. The other answer waits,
   so that the first release matches the words of the choice and each user moves once.
4. **What are the default count of fibers, the default stack, and `fibers_max`?** Proposed: 256
   fibers of 256 KiB, 64 MiB, until step 3 reads the deepest stack of the tests. Decision 22's
   sketch had 64 KiB. Its echo run used 256 KiB, because `echo` keeps two buffers of 64 KiB on its
   stack. No number says what other `std.Io` code needs.

   Proposed for `fibers_max`: 8,192, the next power of two above the 4,097 fibers of the timer row
   ("The timer program"). Decision 22's limit was 4,096.
5. **Does each stack have a guard page?** Proposed: yes, always, with `mprotect` at `init` and again
   at `deinit`. Decision 22's open question 3 had the same answer on 2026-09-27. What it costs:
   - One page of each stack: 4, 16 or 64 KiB, by the host. A fiber can use `stack_bytes` less that
     page.
   - A least stack of two granules, 128 KiB. Decision 22's least stack was one granule of 64 KiB.
     On a host with 64 KiB pages the guard page would take all of it.
   - Two system calls for each fiber. The prior for each call is C6 or more, 112 ns on `mac`.
     `init` returns `SystemResources` when the kernel refuses a call.
6. **Does the first release hold only the calls for std tasks, or the socket and file calls too?**
   Proposed: steps 0 to 6. That is the calls for std tasks, the wake, the package's own calls, the
   nine network calls and `fileClose`, with the echo numbers. The file calls, the batches and the
   datagrams wait for a consumer. Until then `failing` halts on the three batch calls.

   The smaller answer is steps 0 to 4: the Future API that Camilo named, with the timer numbers
   alone. A network call then goes to `rest`. `failing` returns an error for it, or halts on a
   close.
7. **Does `rest` have a default?** Proposed: no. `rest` is a parameter of `init`, so each option
   still has a default, as the API rules ask. No value is safe for each program:
   - `std.Io.failing` halts on 14 of the 75 calls. It answers `random` and `now` with no error and
     no true value ("What `rest` is").
   - A `std.Io.Threaded` brings threads, which the program must own.

   The other answer is a default of `failing`, with those facts in the option's comment. Decision
   22's `rest` had no default.
8. **May another thread make a call other than `futexWake`?** Proposed: no call that the package
   runs. Six calls carry the mark "Thread-safe" in std, and the package halts on each of them from
   another thread. To allow `async` from another thread, the package would need a queue between
   threads. Non-negotiable 4 keeps such a queue out of a loop, and decision 29 rejected a second
   call across threads. The cost is the table of "How a wake from another thread arrives": a thread
   shares no `Mutex` and no `Queue` with a fiber.
9. **Does Camilo accept the three halts at a limit?** The list of what the package cannot keep
   holds them. Proposed: yes, for the first version. Each has a rule that keeps a program away from
   it:
   - The program adds `Fibers.operations` to its loop's `operations`.
   - The program reserves a scheduling group for the package alone.
   - Code outside a fiber starts std tasks with `concurrent`, which returns an error value.

   Two of them have another answer, at a cost. Deadlines in the package, behind a poller, end the
   halt of `sleep` ("How the wait of the tick is bounded"). A list of resumes that a poller tries
   again ends the halt of a resume, and puts a poller in each tick. Under shape (b) nothing ends the
   third.
10. **Do decision 22's two conditions bind the package?** Camilo set them for an adapter inside
    rotor, and the removal withdrew neither. Proposed: both bind.
    - **"It keeps rotor's performance."** The condition has two readings, and Camilo says which he
      meant. In the first, rotor's own paths do not slow down. That holds: rotor changes no source
      file, so no row of `bench/baseline/work.txt` moves. In the second, code on the `std.Io` runs
      near rotor's own speed. Then Camilo names a bar for step 6's table. The prior is that the
      package is slower than decision 22's adapter, which ran at 71 to 96 percent of rotor's own
      server.
    - **"Its API follows rotor's own primitives."** The package's own calls take and return
      rotor's types: `rotor.Operation`, `rotor.Event`, `rotor.SchedulingGroup`, `rotor.LoopId` and
      the types of a cross-core call. The fields of `Io.VTable` are std's, and no rule of rotor
      changes them.

## Ask before

For rotor:

- Each row of "What rotor does not give". This record asks for none of them now.
- An amendment in the header of decision 1, and a note in decision 2, when Camilo accepts this
  record ("What changes in rotor").
- One sentence in `docs/using.md` and one in the README, after the package's first release.
- A row for the fiber switch in `docs/costs.md`, with its probe in `bench/costs/`, if a record of
  rotor needs the number.
- A note in decision 33 on where the public module exports the reactor's limits.

For the package:

- The repository and its name (open question 1). The session makes no repository before Camilo
  names it.
- The shape: who ticks (open question 2).
- pepegrillo as its lint tools, and CI on GitHub's runners.

## Sources

- The session's question to Camilo on 2026-11-09, with its four choices and his answer, for
  "Ruling, 2026-11-09". The session's transcript holds them.
- `std/Io.zig` of Zig 0.16.0 on the development machine, read on 2026-11-10. The lines:
  - `VTable` at 51, with 109 fields, and the six marks "Thread-safe" at 60 to 129;
  - `Future` at 1176, `Group` at 1218, and the rule of `Group.await` at 1272 to 1275;
  - the futex calls at 1540 to 1580;
  - `Mutex` at 1587 to 1651, `Condition` at 1653 to 1763, and `Event` at 1766 to 1870;
  - the queue's `close`, `put`, `putLocked` and `get` at 1918 to 2048, and `Queue` at 2181;
  - `async` at 2326, `concurrent` at 2365, `random` at 2465 and `randomSecure` at 2482;
  - `failing` at 2512 to 2638, and the function of each of its calls, up to line 3436.
- `std/Io/net/HostName.zig` of the same Zig: `lookup` at 150 to 165, and `connectMany` at 331 to
  362. `std/Io/Threaded.zig`: `futexWake` at 2536, and `netLookup` at 13465 to 13520.
- Decision 22, whole, and the removed code: `dfbb644`, `8f76dd7`, `89b0a8a`, the tree before
  `46235cb`, and that commit's summary of lines.
- The fiber switch probe and row C26: `b2bcf60` and `85d5e67`.
- `bench/results/adapter-echo-github-2026-11-05.md`.
- `src/rotor/rotor.zig`, `src/rotor/rotor_loop.zig`, `src/core/shared_loop.zig`,
  `src/core/surface.zig`, `src/core/operation.zig`, `src/core/event.zig`, `src/core/tasks.zig`,
  `src/core/dispatch/dispatch.zig` and `src/core/dispatch/dispatch_callbacks.zig` at `2b165b8`.
- `docs/using.md` at `2b165b8`: "Submit and tick", "Cross-core calls", "A library that shares a
  loop", "A host that owns the wait" and "Not in version one".
- `README.md` at `2b165b8`, "Limits", and decisions 1 and 2 as they are at that commit, for "What
  changes in rotor".
- `bench/baseline/work.txt`, `bench/work/work.zig` and `docs/costs.md` at `2b165b8`.
- `bench/alternatives/std_io_timers.zig` and `bench/timers/timers_runner.zig` at `2b165b8`.
- `build.zig.zon` at `2b165b8`, for the paths of rotor's package.
- Decisions 1, 2, 4, 5, 7, 10, 18, 23, 26, 27, 28, 29, 30, 32 and 33.
