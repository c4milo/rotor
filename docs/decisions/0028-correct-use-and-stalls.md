# 28. A shared loop that refuses wrong use, and stalls a program can see

Status: proposed on 2026-11-06. Nothing is built. Every cost here is a prior: a row of
`docs/costs.md` at the `mac` median, or an instruction count from arithmetic. Nothing was measured
for this record.

It amends these records:

- decision 26, at the function pointer that `Completion` and `Poller` hold, and at the check of
  `deinit`;
- decision 27, at the function pointer that `Task` holds;
- decision 9, with a new rule 7;
- decision 10, because a twin's surface gains `shared`, `SharedLoop` and `heartbeat`;
- decision 23, because a host that sleeps in its own wait turns the stall count off;
- decision 2, with new rows in "In version one".

## Context

Camilo stated two requirements on 2026-11-06:

1. **The shared-loop API is simple to use correctly.** Wrong use fails to compile. Where the
   compiler cannot see it, wrong use halts at once.
2. **rotor gives tools to prevent a stall, and tools to monitor one.**

The same day he ruled that the first draft of this record goes in two records. This record holds
the view of the loop, the callback names, the stall count, the heartbeat and the prevention.
Decision 29 holds the other items: `Message.wake`, `WaitLimit`, `BufferGroup`, `reserve_group`
and `wait_limit`.

Two commits since the draft bear on this record:

- 206127e (decision 26, "Correction of 2026-11-06") moved the subtraction in `call_records` after
  the record's call, so a `tick` inside the last record's callback halts. It is not proposed here.
- 7303116 made the conformance harness time each callback. Section 3 relates the stall count to it.

### Terms

- **Stamp.** A clock value that a backend tick reads today. R1 is at the start of the backend tick
  (`kqueue_tick.zig:34`). R2 is after a wait that blocked (`kqueue_tick.zig:77`, decision 9,
  rule 4). This record adds no clock read.
- **Turn.** The span from one stamp to the next R1. It holds the callbacks of the last tick, the
  program's code between ticks, and the pollers of the next tick. A kernel wait is never in a turn,
  because R2 starts a new turn after it.
- **Stall.** A turn at or above `Options.stall_turn_ns`.

### What the code does today

These facts were read from the tree at `6db6127`:

- **A library holds a `*rotor.Loop`.** So it can call `tick`, `drain`, `deinit`, `cancel_all` and
  `discard_tasks`. Decision 27, ruling 1 says that only the program ticks a shared loop. Only the
  class A check in `Dispatch.begin` enforces it, and only inside a callback.
- **`deinit` inside a callback does not halt.** `Dispatch.assert_empty` checks the pollers and the
  tasks, and not `ticking`.
- **A record, a poller and a task hold only a function pointer.** A report cannot name the callback
  that held the loop.
- **Nothing in `core` measures a stall.** `Statistics` holds sampled operation latencies (decision
  9), and nothing about the loop's turns.
- **The conformance harness checks the time of each callback.** `conformance_stall.zig` reads the
  clock around each handler. A run over `callback_stall_ns_max` (50 ms) makes the next
  `Harness.tick` or `Harness.drain` fail with `error.CallbackStalled`. Only rotor's suite has it.

## The decision, as proposed

1. **One view.** The program hands each library a `*rotor.SharedLoop`, an opaque type. It declares
   the calls a library may make. `tick`, `drain`, `deinit`, `cancel_all` and `discard_tasks` fail
   to compile on it, with a message that states the rule.
2. **Names.** Each `Completion`, `Poller` and `Task` points to a static `Call`, which holds the
   callback's name. The name is `@typeName(Parent) ++ "." ++ field`, with no new parameter.
3. **A stall count.** Each tick compares the turn with a threshold at R1. A stall adds to three
   fields of `Statistics`, which the program reads. There is no hook.
4. **A callback that never returns.** The loop writes a heartbeat on a cache line of its own. A
   thread that the program starts reads it, and gets the name of the callback that holds the loop.
5. **Prevention.** A test checks the stall count. `examples/offload.zig` shows decision 18's
   offload. A lint rule for calls that block is proposed to pepegrillo.

### 1. One view: `SharedLoop`

```zig
// src/rotor/rotor_shared.zig (new)
/// The loop as the program hands it to a library (decision 28). Its address is the address of
/// the `rotor.Loop`, and each call is the `Loop` call of the same name. Only the loop's own thread
/// calls it (class B, as today).
pub const SharedLoop = opaque {
    pub fn submit(shared: *SharedLoop, operations: []const Operation, handles: []Handle) u32;
    pub fn cancel(shared: *SharedLoop, handle: Handle) void;
    pub fn post(shared: *SharedLoop, target: LoopId, message: Message) PostError!void;
    pub fn now_ns(shared: *const SharedLoop) u64;
    pub fn schedule(shared: *SharedLoop, task: *Task) ScheduleError!void;
    pub fn is_scheduled(shared: *const SharedLoop, task: *const Task) bool;
    pub fn task_budget_left(shared: *const SharedLoop) u32;
    pub fn add_poller(shared: *SharedLoop, poller: *Poller) AddPollerError!void;
    pub fn remove_poller(shared: *SharedLoop, poller: *Poller) void;
    // provide_buffers, provide_datagram_buffers, datagram, provided_buffer, give_back_buffer
    // and release_buffers: as in `Loop`. Decision 29 adds reserve_group.

    /// The calls that only the program makes. The test that names every public function skips
    /// these names, and `zig build test-compile-fail` proves that each one refuses.
    pub const refused = .{ "tick", "drain", "deinit", "cancel_all", "discard_tasks" };
    pub const tick = @compileError("a library never ticks a shared loop: finish the work " ++
        "in a record, a poller or a task (decision 27, ruling 1)");
    pub const drain = @compileError("only the program drains a shared loop");
    pub const deinit = @compileError("only the program ends a shared loop");
    pub const cancel_all = @compileError("cancel_all cancels every library's operations");
    pub const discard_tasks = @compileError("only the program discards the task queue");
};

// rotor.Loop gains one call, and keeps every call it has.
/// The view that the program hands to each library at init. Program only (class B).
pub fn shared(loop: *Loop) *SharedLoop;
```

A library takes `*rotor.SharedLoop` at init and keeps it. The handlers do not change: a record, a
poller and a task keep the parameters of decisions 26 and 27. A handler finds the view in its
parent, as it finds any other state.

Each method casts the address back and calls the `Loop` call, so it costs what that call costs.
The methods are plain functions, not `inline`, because decision 7 does not list `src/rotor/`. That
ReleaseSafe inlines so small a function is a prior, and the work gate shows it. A twin brings its
own `SharedLoop` with the same declarations (decision 10).

One fix needs no new API. `Dispatch.assert_empty` gains `assert(!dispatch.ticking)`, class C. So
the program's own record that calls `deinit` on its `*Loop` halts at once.

What still compiles, and halts:

| misuse | check | class |
|---|---|---|
| a library casts the view to `*rotor.Loop` and ticks inside a callback | `ticking` in `begin` | A |
| the program's own record ticks the `*Loop` that the program holds | `ticking` in `begin`, reached since 206127e | A |
| the program's own record calls `deinit` | `!ticking` in `assert_empty` (new) | C |
| a poller adds or removes a poller | `polling`, decision 26 | as today |
| a thread other than the loop's uses the view | `assert_owner` | B |

A cast from `*SharedLoop` to `*Loop` is a deliberate `@ptrCast`. The loop cannot see a library
that casts and ticks outside a callback. The first draft read that stompy's journal ticks from
`Batch.wait`. That code then needs such a cast. The view costs 0 at run time.

### 2. A name for each callback

```zig
// src/core/dispatch.zig
pub const Completion = struct {
    call: *const Call,

    /// A static entry. `init` makes one, named `@typeName(Parent) ++ "." ++ field`.
    pub const Call = struct {
        /// Static data, so another thread may read it after a library frees its record.
        name: [:0]const u8,
        function: *const fn (completion: *Completion, event: Event) void,
    };
};
// Poller and Task take the same shape. Each `init` keeps its three parameters.
```

- **No call site changes.** The name comes from the parent type and the field, for example
  `colibri.client.Client.receive`.
- **The records do not grow.** `Completion` stays 8 B, `Poller` 8 B and `Task` 16 B. Comptime
  asserts hold them.
- **A `Call` written by hand is a container-level `const` with a literal name.** Zig cannot
  refuse a `Call` on the stack, so its doc comment and the guide state the rule.

Cost: a callback loads `record.call`, then `call.function`. That is one more dependent load for
each callback. The `Call` entries are few and read-only, so in steady state the load is C1, 0.93 ns
on `mac`.

### 3. The stall count

At R1 each backend calls `Tables.note_clock(now_ns)` with the stamp it reads today. Core then:

1. computes `span = now_ns -| beat_ns`, where `beat_ns` is the start of the open turn;
2. calls the cold function `note_stall` when `span >= turn_ns`;
3. stores `now_ns` in `beat_ns`, and 0 in the count of callbacks in the turn.

Before a kernel wait that blocks, the backend calls `note_asleep()`, which stores `asleep`
(`maxInt(u64)`) in `beat_ns`. The subtraction saturates, so a wait gives a span of 0 with no extra
branch. At R2 the backend calls `note_woken(now_ns)`, which starts a turn and checks none. `begin`
and `end` add the callbacks they called to the count of the turn.

```zig
// src/core/statistics.zig. `Statistics` gains three fields. `Loop.statistics()` returns them.
/// Stalls, exact (decision 9, rule 7).
stalls: u64,
stall_ns_max: u64,
/// The last stall. All zero while `stalls` is 0.
last_stall: Stall,

/// One stall. Size 32 B, alignment 8 (comptime assert).
pub const Stall = struct {
    end_ns: u64, // the stamp that ended the turn
    span_ns: u64,
    callbacks: u32, // the callbacks that the loop called in the turn
    /// The callback's name when `callbacks == 1`, else null.
    name: ?[*:0]const u8,
};

// rotor.Loop.Options gains one field.
/// A turn at or above this is a stall. Null counts no stall.
stall_turn_ns: ?u64 = constants.stall_turn_ns_default,
```

| shape | what it means |
|---|---|
| `callbacks == 1`, `name` set | that callback held the loop |
| `callbacks > 1`, `name` null | several callbacks shared the turn. A watch of section 4 names the one that runs while the turn is open |
| `callbacks == 0` | the program's own code between ticks, or rotor's work before R1, such as a file call under `file_policy = .blocking` |

A program reads `statistics()` between ticks and exports it. rotor never logs (decision 9, rule 6).

**Decision 9, rule 7 (new).** "A stall is a count of turns at or above a threshold. It is exact,
because its cost is one compare in each tick and a write only when a stall occurs. It is a
statistic: no control flow reads it (rule 1), and no trace holds it." CLAUDE.md says that
statistics are sampled. A sampled count misses the rare stall that an operator needs. So this
record asks for the rule (open question 1).

**The harness check of 7303116 stays.** It times one handler, in rotor's conformance suite only.
The stall count times a turn, in each loop. A scenario's own code between ticks, such as a thread
start or a sleep, is in a turn and not in a handler. So a stall count in each scenario would fail
correct scenarios. Only the new scenarios of this record read the stall count. A consumer has no
harness of rotor's, so the stall count is its check.

Two spans are not seen:

- **The backend's work between R1 and a wait that blocks is in no turn.** So a file call under
  `file_policy = .blocking` in that flush is not a stall. A watch sees it while it runs, with a
  null name.
- **A host that sleeps in its own wait (decision 23) reads as one long turn.** Such a host sets
  `stall_turn_ns = null` and watches no heartbeat. No record gives it a call that marks its sleep.

### 4. The heartbeat

A callback that never returns never ends its turn, so section 3 never counts it. Another thread
must see it. rotor starts no thread (non-negotiable 4). The program starts one, and reads the
loop's heartbeat from it.

```zig
// src/core/stall.zig (new). Carved from the loop's memory, on a line of its own.
/// What the loop's thread writes so that another thread can see that it is stuck (decision 28).
pub const Heartbeat = struct {
    /// The stamp that started the open turn, or `asleep` while the loop is in a kernel wait.
    beat_ns: std.atomic.Value(u64) align(constants.heartbeat_alignment),
    /// The name of the callback that runs now, or null.
    running: std.atomic.Value(?[*:0]const u8),
    /// The watches that read this line. The loop's `deinit` halts while it is above 0.
    watchers: std.atomic.Value(u32),
    // The loop's own fields follow: the threshold, the count and the last name of the turn.

    /// Adds 1 to `watchers`. Any thread may call it.
    pub fn watch(heartbeat: *Heartbeat) Watch;
    pub const Watch = struct {
        heartbeat: *Heartbeat,
        beat_ns: u64, // the stamp that the last check saw
        checks: u32, // the checks in a row that saw that stamp
        /// Reads the heartbeat once. Returns the open turn when the last check saw it open too.
        pub fn check(watcher: *Watch) ?Stuck;
        /// Subtracts 1 from `watchers`. Call it before the loop's `deinit`.
        pub fn end(watcher: *Watch) void;
    };

    pub const Stuck = struct {
        name: ?[*:0]const u8, // the callback that runs now; null for code outside a callback
        since_ns: u64, // the stamp that started the open turn
        checks: u32,
    };
};

// rotor.Loop, program only (class B).
/// The loop's heartbeat, for a thread that the program starts. Valid until `deinit`.
pub fn heartbeat(loop: *Loop) *Heartbeat;
```

**The order of the stores.** The loop stores `beat_ns` with release order at R1, before a kernel
wait, and at R2. Before each callback it stores the callback's name in `running`, with release
order. After the callbacks of `begin` and of `end`, it stores null there. A release store is a
plain store on x86-64, and `stlr` on arm64.

**The order of the loads.** `check` loads `beat_ns` with acquire order (load 1), then `running`
with acquire order (load 2), then `beat_ns` again (load 3). The acquire load of `running` keeps
load 3 after it, as a seqlock reader does. The release store of `running` makes the `beat_ns` of
its turn visible before the name. So when loads 1 and 3 are equal, the name belongs to that turn.
Without both orders, arm64 may do load 3 before load 2. A turn that ends while `check` runs then
gives two equal old stamps and the next turn's name.

Then `check` returns null when loads 1 and 3 differ, or when `beat_ns` is `asleep`. On a stamp
that differs from `Watch.beat_ns`, it keeps the stamp, sets `checks` to 0, and returns null.
Otherwise the turn stayed open for at least one period. It adds 1 to `checks` and returns a `Stuck`.

`check` reads no clock. The program chooses the period. A turn of `n` periods or more is reported
with `checks` of `n - 1` or more. So the program's limit is a count of checks, and the report is
the same function of the heartbeat on every run. A name is static data, so the program may read it
after a library frees the record.

The loop's `deinit` halts while `watchers > 0` (class C). So a watch that would read freed memory
halts the program at once, on the loop's thread.

`examples/stall_watch.zig`, which the examples gate runs, shows the program's thread. It sleeps
one period, calls `check`, and prints, exports, or aborts for a core file.

**A long callback and a run of short calls of one name look the same.** An example is 64 records
of one type at 1 ms each. They read as one name that held the loop for 64 ms. The report is
correct, because together they held the loop for 64 ms.

### 5. Prevention

**A test that fails on a stall.** A consumer's test sets `stall_turn_ns` and checks the count at
its end:

```zig
try std.testing.expectEqual(@as(u64, 0), loop.statistics().stalls);
```

On a failure, `last_stall` gives the name. The check compares times, so a busy machine can fail
it. A threshold that proves flaky is raised deliberately, with the number beside it, as for the
cost gates. colibri, cocuyo and stompy add the check to each test that runs a shared loop.

**Work split into slices.** Decision 27 gives what a long task needs. A task reads
`task_budget_left`, does that many slices, and schedules itself again. CPU work that cannot split
goes to another loop through `post` (decision 4). The guide shows both.

**The offload.** A file call that blocks on kqueue or epoll stalls the loop for its whole length.
Decision 18's offload moves such a call to threads that the program writes. The only pool today is
in `bench/`. So this record adds `examples/offload.zig`, a bounded pool with decision 18's shutdown
order, which the examples gate runs. It adds no API.

**A lint rule, proposed to pepegrillo.** The rule walks the handler of each `init` to a named
depth in its file. It reports a call on a deny list, such as `std.Thread.sleep`, `std.posix.fsync`,
the `std.fs` calls and `std.Thread.Mutex.lock`. It reads syntax only, so it misses a method through
its type, a call through a pointer, and a call into another file. This record does not build it.

## New limits

Each one goes in `src/core/constants.zig` with a doc comment and its comptime asserts. Every value
is a prior.

| constant | value | what it bounds |
|---|---|---|
| `stall_turn_ns_default` | 10 ms | the default stall. It is over 15 times one full run of 64 tasks of 10 µs (decision 27). A program may set another value, or null. stompy, with turn work of its own, may raise it |
| `heartbeat_alignment` | 128 | the heartbeat's line. Apple silicon reports 128-byte lines, as `mailbox_index_alignment` says |

## Determinism

Core reads no clock: `note_clock` and `note_woken` take the backend's stamps as parameters. What
runs, and in what order, depends on none of the stall data. The loop writes the count and the
heartbeat, and never reads them for a choice. A watch reads no clock.

## Where it meets the records

- **Decision 2.** "In version one" gains `SharedLoop`, the stall count, and the heartbeat. "Not in
  version one" gains a stall hook, and a watch thread that rotor starts.
- **Decisions 7 and 8.** No file joins decision 7's list, and no assertion moves class.
- **Decision 9.** Rule 7 is added. Rule 4's stamps serve the turn check.
- **Decision 10.** A twin's surface gains `shared`, `SharedLoop` and `heartbeat`.
- **Decision 23.** A host that sleeps in its own wait sets `stall_turn_ns = null` and watches no
  heartbeat.
- **Decisions 26 and 27.** `Completion`, `Poller` and `Task` hold `call: *const Call`. `deinit`
  inside a callback halts.
- **Decision 29.** Its draft follows this record's one view, and drops `Lent` and `InPoll`. A
  poller's handler keeps decision 26's parameters and returns `WaitLimit`. `reserve_group` joins
  `SharedLoop`. Its open question 3 gets a new reason: this record changes what a library holds,
  and decision 29 changes what a poller returns. It removes its sentence on a call before a host
  sleeps.

## What it costs

Every number here is a prior. The baselines are the `macos-aarch64-kqueue` section of
`bench/baseline/work.txt` at `6db6127`.

| item | added |
|---|---|
| each tick | at R1: the load of the heartbeat pointer and of `beat_ns` and the threshold, a subtraction that saturates, a compare, a branch, and two stores. About 7 instructions |
| a tick that blocks | two more stores, around a kernel call of at least C10 (294 ns) |
| a stall | a cold function: two counters and `last_stall`. About 20 instructions, only when a stall occurs |
| each callback | the dependent load of `Call` (1) and the release store of `running` (1) |
| each dispatched tick | the callback count of the turn (about 3), the last name and the null store of `running` (about 2) |
| a `check` | the heartbeat line moves to the watch thread's core, and back at the loop's next store. No row of `docs/costs.md` holds one line transfer. C19, 97.0 ns on `mac`, moves about two lines and is an upper bound. At a period of 10 ms: 100 × 97.0 ns, under 10 µs each second |
| memory | the heartbeat line (128 B), the stall fields of `Statistics` (48 B), and 8 B in `Tables` for each loop |

| row | baseline | added | prior |
|---|---:|---|---:|
| `post` | 1218 | turn check (7) | about 1225, +0.6 percent |
| `post-operation` | 3051 | turn check over two ticks (14) | about 3065, +0.5 percent |
| `timer` | 1111 | turn check (7) | about 1118, +0.6 percent |
| `batch` | 24624 | turn check (7) | under +0.1 percent |
| `wait` | 5408 | turn check (7), two stores | about +0.2 percent |
| `task` | 610 | 7 for the tick, 5 for the dispatch, 2 for the task | about 624, +2.3 percent |
| `tasks-64` | 4407 | 7 for the tick, 5 for the dispatch, 2 for each of 64 tasks | about 4547, +3.2 percent |

**The `task` and `tasks-64` rows are over the 2 percent tolerance.** Camilo rules on new baselines
with the measured counts (open question 2). If one of the older rows moves past the tolerance,
the turn check moves into a function of its own. The backend then calls it only when the threshold
is not null.

That the `stlr` of `running` costs about what a plain store costs is a prior. A build reports
where the compiler places the new fields of `Tables` before the layout is fixed, as decision 27
did. The cross-core and timer rows run on a quiet `mac` before and after, because the work gate
cannot see the cost of a cache line that moves.

## Alternatives it beat

- **The status quo: a library that holds `*Loop`.** A library that ticks compiles, so it does not
  meet Camilo's first requirement.
- **A view for each callback kind** (`Lent`, `InPoll` and `InTask` in the first draft). A parent
  keeps its `*SharedLoop`, so a poller's view gives a second path to the loop and no guarantee. It
  also changes each handler's parameters, and costs about 1 instruction for each poller call.
- **A struct `SharedLoop` with a field `loop: *Loop`.** Zig has no private fields, so
  `shared.loop.tick()` compiles with no cast. An opaque view needs a deliberate `@ptrCast`.
- **No declarations for the refused calls.** Zig then says "no member named tick", which does not
  state the rule.
- **From the first draft: `Site`, `Task.Next`, and a time for each callback.** A comptime name is
  static data already, so it needs no type. A task that splits its work schedules itself again. A
  time for each callback needs two clock reads for each one, and a watch names a long callback.
- **Names grown into the records** (`Completion` 16 B, `Task` 24 B). Decision 27 rejected a 24 B
  `Task`. Another thread could also read a name in a record after the handler frees the record.
- **A histogram of stall spans, a ring of recent stalls, and a floor under `stall_turn_ns`.** They
  cost about 640 B for each loop and two more limits. The count, the worst span and the last stall
  serve a test. A low threshold only counts more stalls, so a floor prevents no fault.
- **A stall hook that the loop calls.** It runs program code on the loop's thread because of a
  clock value, which breaks non-negotiable 2. It is one more callback that can stall. A stalled loop
  cannot call it either.
- **The heartbeat in `Dispatch`.** `poller_count` and `callbacks_outstanding`, which every tick
  reads, share that line. Each `check` would move it.
- **A `Watchdog` that holds a slice of loops, a time and a limit.** A time needs a clock that the
  program and the loop share, which is one more public call. A slice needs one more limit and a
  halt. One `Watch` for each loop, with a count of checks, gives the same limit.
- **A watch thread that rotor starts, or a signal to the loop's thread.** Both break
  non-negotiable 4, and a signal handler cannot safely read the loop. Seastar's stall detector uses
  a timer signal. That is recalled from its documents, and was not read for this record.

## How it would be checked

**Compile-fail tests.** A new step of `zig build test`, `zig build test-compile-fail`, builds one
file of `tools/compile_fail/` for each refused call of `SharedLoop`. The compiler must refuse each
with the expected text. The test that names every public function skips the names in `refused`.

**Unit tests in core, with no `Loop`:**

1. `note_clock` counts a turn at the threshold, and none below it. `asleep` hides a wait.
2. `Stall.callbacks` and `Stall.name` for one callback, for several, and for none.
3. `Watch.check` with heartbeats written by hand. The cases are a loop that moved, a stuck
   callback, a loop asleep, and program code. `checks` counts up while one turn stays open.

**Conformance scenarios,** added to the `conformance_stall.zig` of 7303116. They run on every
backend, and again with the spin budget. Each sleep stays under `callback_stall_ns_max`, so the
harness check does not fail the scenario:

- A record that sleeps 20 ms with a threshold of 5 ms gives a stall with `callbacks == 1` that
  names it.
- Program code that sleeps 20 ms between ticks gives a stall with `callbacks == 0`.
- A tick that blocks 50 ms with no work gives no stall.
- Each check asks for "at least the stall it made", because a busy machine adds stalls.

**Race gate.** A thread checks a watch at a period of 10 ms. Beside it, a loop's callback spins
until a flag is set. `check` names the callback, and the test thread then sets the flag.

**A model.** `spec/tla/heartbeat/` holds the order of section 4. In it, the stores of the loop and
the loads of `check` take effect in any order that their memory orders allow. Its configuration
must hold: a `Stuck` names a callback of the turn that it reports. One mutant drops the release
order of the store of `running`, and one drops the acquire order of its load. Each must fail. No
test on a real core makes that reorder on demand, so these mutations are measured against
`zig build tla`.

**Halt scenarios** in `tools/halt/`. Each one must die by a signal, and must return once its
assertion is deleted:

| scenario | check | class |
|---|---|---|
| a record calls `deinit` on the program's `*Loop` | `!ticking` in `assert_empty` | C |
| `deinit` while a watch reads the heartbeat | `watchers == 0` | C |
| `Loop.shared` or `Loop.heartbeat` from another thread | `assert_owner` | B |

**Mutations,** each against the narrowest target:

- the turn check deleted, or `asleep` not stored: `test-core` test 1, and `conformance_stall`;
- the name kept for a turn of several callbacks: `test-core` test 2;
- `running` not cleared after the callbacks, or load 3 deleted: `test-core` test 3;
- the release order of `running`, or the acquire order of its load, removed: `zig build tla`;
- each halt deleted: `halt-check`; each `@compileError` deleted: `test-compile-fail`.

**Gates.** The older rows of the work gate stay within 2 percent, and `task` and `tasks-64`
wait on open question 2. The call gate counts no new call: the turn check makes none.

## Open questions

These are in the order that Camilo should rule on them. Each has a proposed answer.

1. **Decision 9, rule 7.** (a) The stall count is exact: one compare in each tick. (b) Turns are
   sampled as operations are. *Proposed: (a). A sampled count misses the rare stall that matters,
   and the compare costs what a sample test costs.*
2. **The `task` and `tasks-64` rows.** (a) Raise both baselines to the measured counts, priors of
   +2.3 and +3.2 percent. (b) No store of `running` for each callback. A stall then names a
   callback only when its turn had one, and a watch names none. *Proposed: (a). A watch that names
   the stuck callback is the reason for the store.*

## Ask before

These items of CLAUDE.md's "Ask before" apply:

- **Changing the size or layout of a hot structure.** `Tables` gains `heartbeat: *Heartbeat`
  (8 B). The function pointer of `Completion`, `Poller` and `Task` becomes a pointer to a static
  `Call`. Their sizes stay.
- **Building anything decision 2 leaves out of version one.** `SharedLoop`, the stall count and the
  heartbeat are new rows.
- **An amendment of decision 9.** Rule 7, open question 1.
- **New named limits.** The two constants of "New limits".
- **New baselines** for `task` and `tasks-64` (open question 2).

The record adds no dependency, no edge to the module graph, and no file to decision 7's list. It
weakens no assertion. It changes the API of decisions 26 and 27, which no tag holds yet, because
`v0.9.0` is older than decision 26. So it lands with decision 29, before the next tag.

## Sources

- The first draft of this record, of 2026-11-06, and what Camilo ruled the same day.
- The draft of decision 29 of 2026-11-06.
- `src/core/dispatch.zig`, `src/core/tasks.zig`, `src/core/statistics.zig`,
  `src/kqueue/kqueue_tick.zig`, `src/rotor/rotor_loop.zig`, `src/conformance/conformance_stall.zig`
  and `src/conformance/constants.zig` at `6db6127`.
- `bench/baseline/work.txt` and `docs/costs.md` at `6db6127`.
- Seastar's stall detector (`--blocked-reactor-notify-ms`): recalled from its published documents,
  not read for this record.
