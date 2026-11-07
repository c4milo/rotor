# 28. A shared loop that refuses wrong use, and stalls a program can see

Status: accepted on 2026-11-06 (see "Ruling, 2026-11-06"), then built and made cheaper the same
day. Camilo ruled on the open items of the build that day too (see "Ruling on the build").
"What was built" at the end says where the code differs from the proposal, and what it measured.
Every other cost here is a prior: a row of `docs/costs.md` at the `mac` median, or an instruction
count from arithmetic. Nothing was measured for this record before the ruling.

## Ruling, 2026-11-06

Camilo accepted this record with the proposed answer to each open question, and the "Ask before"
items it lists:

1. **The stall count is exact** (open question 1): one compare in each tick. Decision 9 gains
   rule 7.
2. **The `task` and `tasks-64` baselines rise to the measured counts** (open question 2), so the
   store of `running` for each callback stays, and a watch can name the stuck callback.
3. **It lands with decision 29, before the next tag**, so each consumer moves once.

It amends these records:

- decision 26, at the function pointer that `Completion` and `Poller` hold, and at the check of
  `deinit`;
- decision 27, at the function pointer that `Task` holds;
- decision 9, with a new rule 7;
- decision 10, because a twin's surface gains `shared`, `SharedLoop` and `heartbeat`;
- decision 23, because a host that sleeps in its own wait turns the stall count off;
- decision 2, with new rows in "In version one".

## Ruling on the build

Camilo ruled on 2026-11-06 on the four items that the build left open:

1. **`src/core/stall.zig` joins decision 7's list of hot files, for one use**: `noinline` on
   `Heartbeat.check_turn`. Decision 7 records the amendment, and ledger row H5 holds the counts
   before and after.
2. **Each row of the work gate that still fails rises to its measured count**, on
   `macos-aarch64-kqueue`, `linux-aarch64-uring` and `linux-aarch64-epoll`, with the `noinline`
   turn check. The header of `bench/baseline/work.txt` and "What it measured" name each raised
   row and its cause. On `linux-x86_64`, each row that moved past 2 percent on arm64 io_uring or
   epoll is deleted, with `task` and `tasks-64`, so CI prints it. The other x86-64 rows stay.
3. **A null threshold pays the one wrapping compare in each tick, and counts no stall.** The
   paragraph on ruling B in "What was built" says so.
4. **The heartbeat model is the only proof of load 3 of `Watch.check`.** No test of the code
   catches the deletion of load 3. The third mutant of `spec/tla/heartbeat/` does.

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
| `callbacks == 0` | the program's own code between ticks, or the loop's own work after R1 in a tick that did not block, such as a file call under `file_policy = .blocking` |

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

## The lint rule, proposed to pepegrillo

This record does not build the rule, and pepegrillo does not hold it yet. What it would do:

- It reads each `Completion.init`, `Poller.init` and `Task.init` of a file, and the handler each
  one names.
- It walks the calls of the handler to a named depth, in that file only.
- It reports a call on a deny list: `std.Thread.sleep`, `std.posix.fsync`, the `std.fs` and
  `std.Io.Dir` calls, `std.Thread.Mutex.lock`, and a `tick` or a `drain`.

It reads syntax only. So it misses a method that it reaches through its type, a call through a
pointer, and a call into another file. rotor's configuration of it, in `tools/lint/`, would name
the deny list and the depth, as each rule there names its own limits.

## What was built

Built on 2026-11-06, by the ruling above, and changed the same day by Camilo's two rulings on a
review of the build (below). The code:

- `src/core/shared_loop.zig`: `SharedLoop(Loop)`, the view, and `check`, which holds a view to its
  declarations. `rotor.SharedLoop` is the view of the public `Loop`, and `Loop.shared` returns it.
- `src/core/stall.zig`: `Heartbeat`, `Watch`, `Stuck`, the turn check, and `name_of`.
- `src/core/statistics.zig`: `Stall`, and the fields `stalls`, `stall_ns_max` and `last_stall`.
- `src/core/layout.zig`: `Layout.add` and `Layout.take` carve a line aligned to 128 bytes from the
  caller's memory, which is aligned to 64. Each backend's `memory_bytes` adds the heartbeat's line,
  and its `init` takes it. `Tables` holds `heartbeat: *Heartbeat`, a pointer of 8 bytes.
- `src/core/dispatch/`: `Completion.Call` and `Poller.Call`, the name that the loop stores before
  each callback, and the check of `ticking` in `assert_empty`. `src/core/tasks.zig`: `Task.Call`.
- The tick of each backend: `Tables.note_clock` at R1, `note_asleep` before a wait that blocks, and
  `note_woken` at R2, which a wait that failed reaches too. The `deinit` of each backend calls
  `Tables.assert_ended`, which is `assert_empty` and the check of the watchers.
- `examples/offload.zig`, a bounded pool with decision 18's shutdown order, and
  `examples/stall_watch.zig`, a watch thread. The examples gate runs both.
- `spec/tla/heartbeat/`: the model of section 4, and its mutants.
- `build/compile_fail.zig` and `tools/compile_fail/`: `zig build test-compile-fail`, which
  `zig build test` runs.

### The rulings of 2026-11-06 on the build

A review found two places where the first build differed from this record. Camilo ruled on both
the same day:

- **Ruling A: build the heartbeat as the record says.** The first build put the heartbeat in
  `Dispatch`, as a field aligned to 128 bytes. So `Dispatch`, `Tables` and each `Loop` took an
  alignment of 128 bytes. Now `Layout` carves the heartbeat's line from the caller's memory, and
  `Tables` holds a pointer to it. `Dispatch` is 96 bytes again, and `Dispatch`, `Tables` and each
  `Loop` have an alignment of 8 again. Comptime asserts hold the size of `Dispatch`, the
  alignment of `Dispatch` and `Tables`, and the size and the alignment of `Heartbeat`.
- **Ruling B: follow the record on the gate rows.** Older rows of the work gate moved past 2
  percent, so the turn check is now a function of its own, `Heartbeat.check_turn`. The first
  build called it only when a threshold was set. Item 10 of "Where the code differs from the
  proposal" changed that: each tick pays one wrapping compare, also under a null threshold. A
  null threshold reaches `check_turn` only for a span of `maxInt(u64)`, and `check_turn` returns
  at once. So a null threshold counts no stall. Camilo accepted this cost on 2026-11-06 (ruling 3
  of that day). `note_clock` stores the stamp in each case, because a watch reads the stamp with
  or without a threshold.

### Where the code differs from the proposal

1. **The heartbeat holds the address of the name in the static `Call`.** The record stored the
   name's pointer, which the loop must load from the `Call`. The address of the name is an address
   that the loop holds already, to load the function. So each callback costs one store and no load.
   A stall and a watch read the name through that address, which is static data.
2. **The view is generic, in `core`.** `core.shared_loop.SharedLoop(Loop)` serves each backend and
   the public module, so `src/rotor/rotor_shared.zig` was not needed. Each backend's `Loop` has
   `shared` and `heartbeat`, and `core/surface.zig` lists both. A cast from the view back to the
   loop has an alignment check, because an opaque type has no alignment.
3. **`deinit` checks the watchers through `Tables.assert_ended`.** `Loop.assert_empty` does not
   check them, because a program may call it while its watch thread runs.
4. **A threshold of 0 halts.** A wait spans 0 ns, so a threshold of 0 would count every wait as a
   stall. `Heartbeat.init` asserts at least 1 ns.
5. **Three more checks halt.** A clock stamp after a wait that equals `asleep`, one watch more
   than the count holds, and a watch that ends twice. Each has a halt scenario.
6. **Files moved for the 500-line limit.** `dispatch.zig` and its tests are in
   `src/core/dispatch/`, with `Calls` in `dispatch_calls.zig`. `Tables.next_expired`,
   `Tables.expire` and the rearm of a repeating timer are in `tables_deadline.zig`. io_uring's
   `provide_datagram_buffers`, `datagram` and `provided_buffer` are in `uring_buffers.zig`.
7. **A third mutant of the model.** A `check` without load 3 names a callback of the next turn,
   whatever the orders. A test on one thread cannot see that, so the model holds it.
8. **The heartbeat's line costs 192 bytes of each loop's memory.** The caller's memory is aligned
   to 64 bytes, so `Layout` reserves 64 bytes more than the line, to move the line to the next
   boundary of 128 bytes. The record counted 128.
9. **A wait that failed starts a turn.** Each tick reads the clock after a wait that blocked
   before it returns a failure of the wait. Without that, `beat_ns` held `asleep` after the
   failure, and the time until the next tick was in no turn and hidden from a watch.
10. **The turn check is one compare, and a null threshold is checked after it.** Each tick
    compares `now_ns -% beat_ns` with `turn_ns`. The subtraction wraps, so the stamp `asleep` and a
    null threshold need no branch in each tick. Only a span at or above `turn_ns` calls
    `check_turn`, which returns at a null threshold, and saturates the span. So a null threshold
    still counts no stall, as ruling B asks. A program with a null threshold now pays the compare
    too, where the first build paid a compare with `never`.
11. **The counts of a turn are two words, and the first stamp of a tick zeroes both with one
    store.** `Heartbeat.Turn` holds `ended`, the records and the tasks of an `end`, and `polled`,
    the pollers of a `begin`. Each has one writer in a turn, so a writer stores its count and adds
    nothing. Only the tasks add to `ended`, after the records of the same `end`. The stamp after a
    wait zeroes nothing, because no callback runs between the two stamps of one tick.
12. **A run of callbacks that called none writes nothing.** `call_records`, `Tasks.run` and
    `begin` each update the heartbeat after their own loop, and only when the loop called a
    callback. `running` is null already in the other case. The model holds this:
    `spec/tla/heartbeat/` stores null only after a call.
13. **A stall of one poller takes the poller's name from the table of pollers.** So `begin` stores
    the count of its pollers and null, and no name. The name is the first poller of the table,
    because no poller is added or removed between `begin` and the stamp that ends the turn.
14. **The loop reads its own stamp with a plain load.** Only the loop's thread writes `beat_ns`,
    so its own read needs no atomic load. `turn_ns` follows `beat_ns`, and arm64 loads both with
    one `ldp`. A comptime assert holds the order of the two fields.

### What it measured

#### After the rulings of 2026-11-06

The final tree is the optimised tree below, with the `noinline` turn check of ledger row H5. On
`mac`, `/usr/bin/time -l` counted three runs of each tree, and the table gives the median. The
runs of one tree agreed within 10 instructions, except `tasks-64` at `c05913b`, within 41. On arm64
Linux, cachegrind counted one run in an arm64 container on `mac`. `c05913b` was counted again
the same way. "Line before" is the row of `bench/baseline/work.txt` before ruling 2 of
2026-11-06: for `task` and `tasks-64`, the counts that ruling 2 of 2026-11-06 set.

| row | backend | line before | `c05913b` | final | change | final against the line | raised to |
|---|---|---:|---:|---:|---:|---:|---:|
| `post` | kqueue | 1218 | 1231 | 1247 | +1.3% | +2.4% | 1247 |
| `post` | io_uring | 1029 | 1043 | 1061 | +1.7% | +3.1% | 1061 |
| `post` | epoll | 1212 | 1212 | 1228 | +1.3% | +1.3% | none |
| `post-operation` | kqueue | 3051 | 3030 | 3062 | +1.1% | +0.4% | none |
| `post-operation` | io_uring | 2794 | 2787 | 2823 | +1.3% | +1.0% | none |
| `post-operation` | epoll | 3019 | 3059 | 3091 | +1.0% | +2.4% | 3091 |
| `timer` | kqueue | 1111 | 1100 | 1108 | +0.7% | -0.3% | none |
| `timer` | io_uring | 1025 | 1027 | 1036 | +0.9% | +1.1% | none |
| `timer` | epoll | 1092 | 1083 | 1091 | +0.7% | -0.1% | none |
| `batch` | kqueue | 24624 | 24611 | 24616 | +0.0% | -0.0% | none |
| `batch` | io_uring | 23757 | 23751 | 23760 | +0.0% | +0.0% | none |
| `batch` | epoll | 23845 | 23836 | 23844 | +0.0% | -0.0% | none |
| `wait` | kqueue | 5408 | 5313 | 5328 | +0.3% | -1.5% | none |
| `wait` | epoll | 655 | 655 | 667 | +1.8% | +1.8% | none |
| `task` | kqueue | 630 | 611 | 630 | +3.1% | +0.0% | none |
| `task` | io_uring | 559 | 535 | 556 | +3.9% | -0.5% | none |
| `task` | epoll | 634 | 611 | 631 | +3.3% | -0.5% | none |
| `tasks-64` | kqueue | 4558 | 4411 | 4561 | +3.4% | +0.1% | none |
| `tasks-64` | io_uring | 3910 | 3697 | 3907 | +5.7% | -0.1% | none |
| `tasks-64` | epoll | 3985 | 3773 | 3982 | +5.5% | -0.1% | none |
| `record` | kqueue | 1222 | 1223 | 1240 | +1.4% | +1.5% | none |
| `record` | io_uring | 1128 | 1134 | 1153 | +1.7% | +2.2% | 1153 |
| `record` | epoll | 1191 | 1196 | 1215 | +1.6% | +2.0% | 1215 |
| `poller` | kqueue | 570 | 573 | 588 | +2.6% | +3.2% | 588 |
| `poller` | io_uring | 497 | 501 | 516 | +3.0% | +3.8% | 516 |
| `poller` | epoll | 574 | 580 | 595 | +2.6% | +3.7% | 595 |

The gate compares each count with its line, and not with the count at `c05913b`. So a row fails
when the change and the distance of `c05913b` from the line pass 2 percent together. Eight rows
failed, and ruling 2 of 2026-11-06 raised each to its final count:

- `poller` on each backend moved past the tolerance by itself. It is one tick with one poller,
  so it pays the 13 or more instructions that "What each instruction that is left buys" counts.
- `post` on kqueue and io_uring, `record` on io_uring and epoll, and `post-operation` on epoll
  sat 0.4 to 1.4 percent over their lines at `c05913b`. The stamp and the turn check of each
  tick, and the name that each callback stores, added 1.0 to 1.7 percent, and took them past.
  `mac`'s `post` is one of them: `c05913b` counted 1231, 1.1 percent over its line of 1218 and
  inside the tolerance, and this record took it to 1247, 2.4 percent over.

`task` and `tasks-64` keep the counts of the tree without H5, which counts 3 fewer on arm64 Linux,
inside the tolerance. `wait` on epoll is 1.8 percent over its line: a count of 669 fails it.

On `linux-x86_64` the `poller` rows are deleted, with `task` and `tasks-64`, so CI prints them:
`poller` moved 3.0 percent on arm64 io_uring and 2.6 on epoll from `c05913b`. No row but these
three moved past 2 percent on arm64, so the other x86-64 rows keep their values. On arm64, `post`
and `record` fail only by their distance from the line at `c05913b`. If x86-64 sat as close to
its lines, CI's x86-64 runner fails those rows too.

#### After the optimisation of 2026-11-06

Camilo ruled on 2026-11-06 to make the build cheaper first. The target was each row of the work
gate except `task` and `tasks-64` within 2 percent of `c05913b`, the tree before this record, with
no change to a behaviour that this record decides. The counts below are the instruction gate with
the default threshold. On `mac`, `/usr/bin/time -l` counted three runs of the optimised tree, which
agreed within 2 instructions, except `batch`, within 43. The table gives the median. On arm64
Linux, cachegrind counted one run in an arm64 container on `mac`.

| row | backend | `c05913b` | optimised | change |
|---|---|---:|---:|---:|
| `post` | kqueue | 1231 | 1246 | +1.2% |
| `post` | io_uring | 1043 | 1067 | +2.3% |
| `post` | epoll | 1212 | 1234 | +1.8% |
| `post-operation` | kqueue | 3030 | 3063 | +1.1% |
| `post-operation` | io_uring | 2787 | 2835 | +1.7% |
| `post-operation` | epoll | 3059 | 3103 | +1.4% |
| `timer` | kqueue | 1101 | 1108 | +0.6% |
| `timer` | io_uring | 1027 | 1039 | +1.2% |
| `timer` | epoll | 1083 | 1094 | +1.0% |
| `batch` | kqueue | 24631 | 24618 | -0.1% |
| `batch` | io_uring | 23751 | 23763 | +0.1% |
| `batch` | epoll | 23836 | 23847 | +0.0% |
| `wait` | kqueue | 5306 | 5328 | +0.4% |
| `wait` | epoll | 655 | 668 | +2.0% |
| `task` | kqueue | 611 | 630 | +3.1% |
| `task` | io_uring | 535 | 559 | +4.5% |
| `task` | epoll | 611 | 634 | +3.8% |
| `tasks-64` | kqueue | 4415 | 4558 | +3.2% |
| `tasks-64` | io_uring | 3697 | 3910 | +5.8% |
| `tasks-64` | epoll | 3773 | 3985 | +5.6% |
| `record` | kqueue | 1223 | 1240 | +1.4% |
| `record` | io_uring | 1134 | 1156 | +1.9% |
| `record` | epoll | 1196 | 1218 | +1.8% |
| `poller` | kqueue | 573 | 588 | +2.6% |
| `poller` | io_uring | 501 | 519 | +3.6% |
| `poller` | epoll | 580 | 598 | +3.1% |

The `wait` row on epoll is 1.98 percent over, inside the tolerance. Two rows fail the target:
`post` on io_uring, by 4 instructions, and `poller` on each backend.

What each change saved, in the order the changes were made. Each cell is the change in
instructions for each iteration, on kqueue, io_uring and epoll:

| change | `post` | `record` | `poller` | `task` |
|---|---|---|---|---|
| the build before the optimisation, against `c05913b` | +21, +26, +30 | +27, +32, +35 | +31, +37, +39 | +27, +32, +34 |
| one compare in each tick, the null threshold checked after it, two counts with one writer each, no zero at the stamp after a wait, no update after a run that called nothing (items 10 to 12) | -3, -2, -6 | -3, -4, -6 | -8, -12, -13 | -2, -4, -6 |
| the stamp and the threshold in one load (item 14) | -2, -2, -2 | 0, -1, -1 | 0, -1, -1 | -1, -1, -1 |
| counts of a word, and the update after each loop (items 11 and 12) | -1, +2, 0 | -7, -5, -6 | -8, -5, -6 | -5, -3, -5 |
| a poller's name from the table (item 13) | 0, 0, 0 | 0, 0, 0 | 0, -1, -1 | 0, 0, 0 |

Each change keeps every behaviour of this record. The mutations of the optimisation are in "How
it is checked".

#### What each instruction that is left buys

The first stamp of each tick costs 7 instructions on arm64, read from the disassembly:

- the load of the heartbeat's pointer, which ruling A asks for;
- one `ldp` of the stamp and the threshold, a subtraction, a compare and a branch: the exact count
  of decision 9, rule 7, and ruling 1;
- the release store of the stamp, which a watch reads;
- one `stp` that zeroes the two counts of the turn, which `Stall.callbacks` needs.

Each callback costs the load of its `Call` before the load of its function, and the release
store of its name: ruling 2. A `begin` that called a poller stores its count and null. An `end`
that called a record or a task stores its count, loads the last name, stores it for the turn,
and stores null.

Before the `noinline` below, the rest was the compiler's, and cost 4 or 5 instructions in each
tick on Linux. Callgrind counted each instruction of io_uring's `post`. The turn check's cold code
was inline in the tick, so the tick kept `wait_ns` in a saved register: one move, and three loads and stores of values that the
register held before. One more branch comes from item 9, where the stamp after a wait moved before
the check of a failed wait. `post` has two ticks, so io_uring's `post` is over by 4. A `noinline`
turn check removes 3 of them in each tick on arm64 Linux, and none on `mac`. Camilo ruled on
2026-11-06 that the code uses it (ruling 1 of that day): decision 7 lists `src/core/stall.zig`,
and ledger row H5 holds the counts.

`poller` cannot meet the target. It is one tick with one poller, so it pays the 7 instructions of
the stamp, the 2 of the poller's callback, 2 to update the heartbeat after `begin`, 1 to load the
pointer, and the address of `running`: 13 or more, where the target allows 10 on io_uring and 11
on `mac` and epoll. Only a change to a behaviour that this record decides removes more.

#### The first build

The instruction gate, with the default threshold, against `5c4bd25`, the tree before this record,
counted the same way. macOS counts the process's instructions with `/usr/bin/time -l` on `mac`, at
a load average of about 7. Three runs of each tree, in turn, agreed within 2 instructions, except
`batch`, within 39, and HEAD's `tasks-64`, within 19. The table gives the median. Linux counts user
instructions with cachegrind in an arm64 container on `mac`, one run each.

| workload | kqueue | io_uring | epoll |
|---|---:|---:|---:|
| `post` | 1231 → 1253 (+1.8%) | 1093 → 1117 (+2.2%) | 1212 → 1242 (+2.5%) |
| `post-operation` | 3030 → 3075 (+1.5%) | 2887 → 2935 (+1.7%) | 3059 → 3119 (+2.0%) |
| `timer` | 1100 → 1111 (+1.0%) | 1052 → 1064 (+1.1%) | 1083 → 1098 (+1.4%) |
| `batch` | 24574 → 24621 (+0.2%) | 23776 → 23788 (+0.1%) | 23836 → 23851 (+0.1%) |
| `wait` | 5310 → 5331 (+0.4%) | none | 655 → 673 (+2.7%) |
| `task` | 611 → 638 (+4.4%) | 559 → 590 (+5.5%) | 611 → 645 (+5.6%) |
| `tasks-64` | 4415 → 4567 (+3.4%) | 3721 → 3941 (+5.9%) | 3773 → 3996 (+5.9%) |
| `record` | 1223 → 1250 (+2.2%) | 1159 → 1190 (+2.7%) | 1196 → 1231 (+2.9%) |
| `poller` | 573 → 605 (+5.6%) | 525 → 561 (+6.9%) | 580 → 619 (+6.7%) |

The turn check costs 11 instructions on arm64 in each tick that has a threshold, read from the
disassembly of the kqueue tick: the load of the heartbeat's pointer, the load of the threshold, a
compare with `never` and its branch, the load of the stamp, a subtraction that saturates (two), a
compare and a branch, the release store of the stamp, and the store that zeroes the count of the
turn. The record's prior was 7. The first build counted 9: ruling A adds the load of the pointer,
where the first build added an offset to the loop's address, and ruling B adds the compare with
`never` and its branch. `post` is two ticks, so it moved by about twice the check.

Each task costs (the change of `tasks-64` less the change of `task`) / 63 more instructions: on
`mac` (152 − 27) / 63, about 2.0, and on arm64 Linux (220 − 31) / 63 and (223 − 34) / 63, 3.0 on
io_uring and on epoll, against a prior of 2.

The first build stored the name's pointer, which each callback loaded from its `Call`. It counted
`tasks-64` at 4717 on `mac`; the address of the name counted 4561. The cross-core and timer rows of
the comparison were not run on a quiet `mac`, which the record asked for.

`bench/baseline/work.txt` takes the counts of the optimised tree for `task` and `tasks-64`, by
Camilo's ruling 2, and the rows that "After the rulings of 2026-11-06" names. On x86-64 the
`task`, `tasks-64` and `poller` rows are deleted, so CI prints them.

### How it is checked

- `stall.zig`: the turn check, a wait, a null threshold that counts no stall, the shape of a stall
  for one record, one poller, several callbacks and none, a watch with heartbeats written by
  hand, and the count of watchers.
- `layout.zig`: a line aligned to 128 bytes sits on its boundary at a base on that boundary and at
  a base 64 bytes past it, inside the room that `add` reserves.
- `dispatch_test.zig`: the heartbeat names each poller, record and task while it runs, holds null
  between them, and counts the callbacks of a turn.
- `shared_loop.zig`: each call of the view reaches its loop, and `check` holds the declarations.
  `rotor.zig`: the public view's address is the loop's, and its calls reach the loop.
- `conformance_stall.zig`, on every backend and again with the spin budget: a record that holds the
  loop after a wait makes a stall that names it; program code between ticks makes a stall of no
  callback; a tick that blocks is in no turn, and program code after its wait makes a stall that
  starts at the stamp after the wait; a null threshold counts none; a watch reports nothing while
  the loop waits; and a watch on another thread names a record that spins until the watch releases
  it. The race gate runs the last two under ThreadSanitizer.
- The tick tests of each backend: a wait that fails leaves a turn open.
- `zig build test-compile-fail`: each of the five refused calls fails with its message.
- `spec/tla/heartbeat/`: the configuration holds, and three mutants fail.
- `tools/halt/`: fourteen new scenarios, whose mutations are listed in the tables below. One of
  them, in `rotor_scenarios.zig`, runs the public module's `Loop.shared`, which checks the thread
  itself.
- `examples/offload.zig` and `examples/stall_watch.zig`, on kqueue, io_uring and epoll.

Mutations of the first build, 45. Each is measured against the narrowest target that can catch it.

| mutation | target | result |
|---|---|---|
| the turn check deleted | `test-core`, `test-conformance-kqueue` | CAUGHT, CAUGHT |
| `asleep` not stored | `test-core`, `test-conformance-kqueue` | CAUGHT, CAUGHT |
| the stamp after a wait not stored | `test-core`, `test-conformance-kqueue` | CAUGHT, CAUGHT |
| the count of a turn not reset at a stamp | `test-core` | CAUGHT |
| the name kept for a turn of several callbacks | `test-core` | CAUGHT |
| the last name taken when nothing was called | `test-core` | CAUGHT |
| `running` not cleared after the callbacks | `test-core` | CAUGHT |
| a watch that takes a wait for a stuck turn | `test-core` | CAUGHT |
| a watch that reports the first check of a turn | `test-core` | CAUGHT |
| a watch that does not count its checks | `test-core` | CAUGHT |
| a stall not counted in the longest span | `test-core` | CAUGHT |
| a poller, a record or a task not named | `test-core` | CAUGHT, CAUGHT, CAUGHT |
| the pollers, or the tasks, not counted in the turn | `test-core` | CAUGHT, CAUGHT |
| a name built from the type alone | `test-core` | CAUGHT |
| the view's `now_ns` that reads nothing | `test-core` | CAUGHT |
| load 3 deleted | `test-core` | NOT CAUGHT |
| load 3 deleted, in the model | `zig build tla` | CAUGHT |
| the release order of `running` dropped, in the model | `zig build tla` | CAUGHT |
| the acquire order of its load dropped, in the model | `zig build tla` | CAUGHT |
| `deinit` inside a tick not checked | `halt-check` | CAUGHT |
| a watch at `deinit` not checked, in core and in kqueue's `deinit` | `halt-check` | CAUGHT, CAUGHT |
| a watch at `deinit` not checked, in io_uring's `deinit` | the Linux gate | CAUGHT |
| a threshold of 0, a stamp of `asleep`, a full count, a watch ended twice | `halt-check` | CAUGHT each |
| `shared` and `heartbeat` from another thread | `halt-check` | CAUGHT, CAUGHT |
| each `@compileError` of the view deleted, five | `test-compile-fail` | CAUGHT each |
| kqueue: no turn check, no `asleep`, no stamp after a wait | `test-conformance-kqueue` | CAUGHT each |
| io_uring: no turn check | the Linux gate | CAUGHT |
| epoll: no `asleep` before a wait | the Linux gate | CAUGHT |

Four mutations first did not compile, because each left a parameter unused, and were written again.
Four were NOT CAUGHT at first, and each named a test that was not there: `asleep` not stored in the
conformance suite, the last name when nothing was called, the stamp after a wait in core, and
kqueue's `asleep` before a wait. Each test is written, and each mutation is CAUGHT now.

Mutations of the rulings and of the review, each against the narrowest target:

| mutation | target | result |
|---|---|---|
| `Layout.take` skips no bytes to a line's boundary | `test-core` | CAUGHT |
| `Layout.add` reserves no slack for a line | `test-core` | CAUGHT |
| a line's room starts at its own alignment, and not at 64 | `test-core` | CAUGHT |
| `Tables.init` makes the heartbeat with no threshold | `test-conformance-kqueue` | CAUGHT |
| the turn check runs with a null threshold too | `test-core` | CAUGHT |
| the test of the threshold inverted | `test-core` | CAUGHT |
| the turn check never runs | `test-conformance-kqueue` | CAUGHT |
| `note_clock` stores the stamp and checks no turn | `test-conformance-kqueue` | CAUGHT |
| the stamp after a wait stores `asleep` | `test-conformance-kqueue` | CAUGHT |
| kqueue: no `asleep` before a wait, and no stamp after it | `test-conformance-kqueue` | CAUGHT |
| kqueue: no stamp after a wait that failed | `test-kqueue` | CAUGHT |
| kqueue: the stamp after the return of a failed wait | `test-kqueue` | CAUGHT |
| io_uring and epoll: the stamp after the return of a failed wait | the Linux gate, `uring` and `epoll` | CAUGHT, CAUGHT |
| the public `Loop.shared` without its owner check | `halt-check` | CAUGHT |

Mutations of the optimisation of 2026-11-06, each against the narrowest target:

| mutation | target | result |
|---|---|---|
| the compare of a tick never calls `check_turn` | `test-core`, `test-conformance-kqueue` | CAUGHT, CAUGHT |
| `check_turn` counts under a null threshold | `test-core` | CAUGHT |
| `check_turn` counts a span below the threshold | `test-core` | CAUGHT |
| the first stamp of a tick does not zero the counts | `test-core` | CAUGHT |
| the records of an `end` are not counted | `test-core` | CAUGHT |
| the tasks replace the count of the records | `test-core` | CAUGHT |
| the pollers of a `begin` are not counted | `test-core` | CAUGHT |
| `running` is not cleared after the pollers | `test-core` | CAUGHT |
| a stall of one poller takes the name of the last record | `test-core` | CAUGHT |
| a turn of several callbacks is named | `test-core` | CAUGHT |
| `call_records`, `begin` or `Tasks.run` does not update the heartbeat | `test-core` | CAUGHT each |

Two mutations first did not compile, because each left a name unused, and were written again.
The model's change, a `leave` that stores nothing after no call, holds, and its three mutants
still fail `zig build tla`.

The scenario "a tick that blocks with no work" first checked only that no stall spanned the wait.
That passed with the turn check deleted, and with the stamp after the wait deleted. Now program code
holds the loop after the wait, and the scenario requires a stall that starts at the stamp after the
wait. The two mutations of that stamp above fail it.

**Load 3 is NOT CAUGHT by any test of the code, and the model is its only proof.** A test on one
thread cannot run the loop between load 1 and load 3, and no test on two cores makes that order on
demand. `spec/tla/heartbeat/` holds it: its third mutant deletes load 3 and fails `zig build tla`.
CLAUDE.md asks for a test that fails when the code breaks. Camilo accepted on 2026-11-06 that the
model, and not a test of the code, proves load 3 (ruling 4 of that day).

### Open after the build

1. **The linux-x86_64 rows.** No container on `mac` counts them. CI's x86-64 runner may fail
   `post` and `record`, which fail on arm64 only by their distance from the line at `c05913b`.
2. **The cost of a moved cache line.** The cross-core and timer comparison waits for a quiet `mac`.
