# 33. A core for the loop, and an optional layer for tasks and callbacks

Status: **proposed** on 2026-11-08, and revised the same day after three reviews. Nothing is
built, and nothing is built before Camilo accepts this record. Every number here is a row of
`docs/costs.md`, a row of `bench/baseline/work.txt`, a count that an earlier record measured, or a
prior: an instruction count from arithmetic over the code at `e05a549`. Nothing was measured for
this record. Each table says where its numbers come from.

If it is accepted, it amends decisions 1, 2, 7, 10, 23, 26, 27, 28, 29, 30 and 32, and the Layout
section of CLAUDE.md. "Ask before" lists the items that need Camilo's word first. Decision 31 is
accepted and not built, and open question 9 asks where it goes.

## Ruling, 2026-11-08

The colibri session relayed this ruling, and Camilo confirmed it to this session the same day:

1. **rotor's core stays a library for the loop and its I/O operations.**
2. **The Seastar-style pieces go in an optional layer**: tasks, pollers, scheduling groups, and
   completion records with callbacks. A user of a plain loop never takes the layer on.
3. **The split falls to a release after v0.10.0.** v0.10.0 was tagged on 2026-11-08 at `9339858`.
4. **colibri takes a small interface in its own terms.** A shared `colibri.Client` or `Server`
   takes its operations, the completions in, and its next deadline. rotor's `SharedLoop` is one
   adapter over that interface. colibri's public API names no `*rotor.SharedLoop`,
   `rotor.BufferGroup` or `rotor.Task`.

Camilo asked for this record as a proposal.

## Context

### What the code does today

These facts were read from the tree at `e05a549`, which is `9339858` and one commit of the test
gates.

- **`core` holds the layer.** `src/core/` holds 17,411 lines of Zig. 5,886 of them, 34 percent,
  are in `dispatch/`, `scheduling/`, `call/`, `tasks.zig`, `tasks_test.zig` and
  `shared_loop.zig`. The core keeps part of `call/`: `call_take.zig`, 162 lines, holds the drain's
  slow path. So the move takes at most 5,724 lines, 33 percent. The port and `wait_until` then add
  lines to the core.
- **Every backend embeds the layer's state.** `core.Tables` holds `dispatch: Dispatch`, 104 B
  (`dispatch.zig`, comptime assert), and `groups: *Groups`. Each backend's `init` carves one
  `Groups` of 536 B from the caller's memory (`kqueue.zig:175`, `uring.zig:192`, `epoll.zig:189`).
  The public module passes `.named_groups = scheduling.root_groups.table` into each backend's
  options (`rotor_loop.zig`, `sizing`).
- **Every tick reads the layer's state.** Each backend's `tick` starts with `dispatch.idle()`
  (`kqueue.zig:350`), which reads the poller count and `callbacks_outstanding`. A kept tick error
  adds 1 to the same count (`tick_error.zig`), so it takes the next tick off the fast path.
- **Every submit counts records.** `Tables.submit` adds the `dispatched` bit of each operation
  and calls `Dispatch.note_submitted` (decision 26).
- **A tick that would block reads the task queues.** `Tables.wait_bound` reads `tasks.count` and
  `groups_ready` (`tables_deadline.zig:55`), because the drain can queue the task of a call
  (decision 32, item 2).
- **One stored limit has one writer.** `Dispatch.until_ns` bounds the wait. Only the layer writes
  it: `begin` with the pollers' least limit, `remove_poller` with `.none`, and `note_wake` and
  `end` with `.now`. `note_wake` and `end` store `.now` only while a poller is added, because only
  then does the next tick run `begin`, which writes the limit again (`dispatch.zig:121`, `:285`).
- **The drain waits for tasks and calls.** `core/shutdown.zig` ticks until `in_flight` and
  `callbacks_outstanding` are 0, and returns `TasksStillQueued` when only tasks are left.
  `shutdown.zig`, `tick_error.zig`, `surface.zig`, `constants.zig` and `tables.zig` name
  `tasks_queued`, `TasksStillQueued` or `callbacks_outstanding`.
- **The mailbox carries the calls of decision 32.** A call and its return use two reserved tags
  above `message_tag_wake`. `Mailbox.calls_out` counts the calls out on each pair. Each ring keeps
  32 of its 256 slots for returns, so a post sees `mailbox_posts_max`, 224.
- **A call to a loop that never served halts that loop.** `call` (`call/call.zig:208`) refuses
  an id that runs no loop with `LoopNotFound`. It does not know whether the target serves the
  call's service. The target halts at `call_take.zig`, `assert(station.state != .unused)`.
- **The surface has 43 names** (`core/surface.zig`). 16 of them belong to the layer: `add_poller`,
  `remove_poller`, `schedule`, `is_scheduled`, `tasks_queued`, `task_budget_left`,
  `discard_tasks`, `schedule_in`, `charge_task`, `reserve_scheduling_group`,
  `set_scheduling_group_shares`, `shared`, `call`, `answer`, `serve` and `stop_serving`. 4 of the
  10 error sets of `rotor.Loop` belong to it too: `AddPollerError`, `ScheduleError`,
  `ReserveSchedulingGroupError` and `CallError`. `DrainError` carries `TasksStillQueued`.
- **A twin carries the layer.** Decision 10 lets a consumer bring a twin of the surface for
  replay. Since decision 28, that twin must carry `shared`, `SharedLoop` and `heartbeat`, and each
  name of the layer above.
- **No consumer uses the layer on its main branch.** colibri pins `4f818b7`, a 0.7.0 tree. cocuyo
  pins v0.4.0 (`8cde9a6`), and stompy pins v0.7.0 (`1d0d0ce`). A search of their sources for
  `SharedLoop`, `Task`, `Poller`, `Completion.init`, `schedule_in`, `add_poller`, `WaitLimit` and
  `Service` found none, on 2026-11-08. colibri's draft for its decision 156, in its
  `docs/design.md`, plans one poller, one task and a record for each operation on a
  `*rotor.SharedLoop`. Ruling item 4 takes those names out of colibri's public API. colibri waits
  on v0.10.0, so it can take `SharedLoop` before the release of this record.

### What a plain loop pays for the layer today

A plain loop is a loop whose program names no record, adds no poller, schedules no task and makes
no call. The table says what such a loop pays, and where the number comes from.

| what | where | size | source |
|---|---|---|---|
| `Dispatch` in `Tables` | each loop | 104 B | comptime assert in `dispatch.zig` |
| `Tables.groups` | each loop | 8 B; it moved io_uring's `wakes` and cost 1 instruction in each tick | decision 30, "What the path with one group costs against main" |
| `Groups` | each loop's memory | 536 B | comptime assert in `scheduling_groups.zig` |
| `idle()` and the branch to the dispatched tick | each tick | about 6 instructions | decision 26, "What it measured", by cachegrind. Decision 27, "What was built", item 1, keeps the same two loads and two compares |
| the count of records | each operation at submit | about 8 instructions, the bit into the slot included | decision 26, "What it measured" |
| the `dispatched` bit | each event | about 2 instructions | decision 26, "What it measured" |
| `tasks.count` and `groups_ready` | each tick that would block | two loads, an OR and a branch, about 4 instructions | `tables_deadline.zig:55`, arithmetic, not measured |
| the slots kept for returns | each ring | a post sees 224 slots, not 256 | decision 32, rule 5 |
| `TasksStillQueued` | `drain`'s error set | one error that a plain loop never returns | `rotor_loop.zig` |
| 16 names and 4 error sets | the surface | a plain user reads them, and a twin carries them | `core/surface.zig` |

The stamp of decision 28 is not in this table. It is the core's, as "The line" says. Decision 28
counted 7 instructions of it in each tick on arm64, from the disassembly.

So a plain loop pays about 650 B of memory that no tick of it reads. It pays about 6
instructions in each tick and about 10 for each operation. Decisions 26 and 30 measured the rows
that cite them. The read of the task queues is arithmetic. Decision 26 measured +2.1 and +2.3
percent on two kqueue rows, past the tolerance of the work gate, and Camilo raised those lines.
Its other rows sat inside the tolerance. The speed gain of the split for a plain user is
therefore small. The gain is a smaller surface, less memory, and a core with up to 33 percent
fewer lines for a reader to read and a twin to carry.

## The decision, as proposed

1. **The core keeps the loop and its I/O.** It keeps every piece that a program with one owner of
   the loop, and no callback, needs.
2. **The layer is a new module, `reactor`.** It holds the records, the pollers, the tasks, the
   scheduling groups, the calls and `SharedLoop`. It imports `core` and nothing else.
3. **The layer wraps a loop.** `reactor.Reactor(Loop)` holds one `Loop` by value and its own
   state. `Loop` is any type that carries the core's surface and the port below.
4. **The core gains a port of eight names.** Each backend's `Loop` declares them. The public
   `rotor.Loop` does not. They are the calls that the layer needs and a plain caller must not make.
5. **The core gains one public call, `wait_until`.** It bounds the wait of each tick at a
   deadline. The stored limit has one writer on each kind of loop. On a plain loop, the program
   writes it. On a reactor, only the layer writes it, for its pollers. A program on a reactor
   bounds its wait with a poller, as a library does (decision 29).
6. **The public module exports `rotor.Reactor`.** A program that wants the layer makes a
   `rotor.Reactor` in place of a `rotor.Loop`. `Reactor.shared()` returns the same
   `*rotor.SharedLoop` as today, so a library changes nothing.
7. **A tick that runs a callback is not slower than at v0.10.0.** The layer's rows of the work
   gate count at or below their counts at `9339858`, by the method of "How a layer row is
   compared".

### The line

The rule: **a piece goes in the layer when it calls the user's code on the loop's thread from
inside a tick, or exists only to order or name such calls.** Every other piece stays in the core.

| piece | side | why |
|---|---|---|
| `Loop`: `init`, `deinit`, `submit`, `cancel`, `cancel_all`, `tick`, `drain`, `assert_empty`, `in_flight` | core | the loop and its operations |
| `Operation`, `Event`, `Handle`, `Slot` and the slot table | core | the operations and their completions |
| the `dispatched` bit of a slot and of an event | core | the slot keeps it from submit to the event. The core copies it and never reads it |
| `Completion`, `Completion.Call` and `Operation.completion` | core | data that an operation carries. See open question 5 |
| timers, repeating timers, and the deadline of an operation | core | decisions 5 and 14 |
| `WaitLimit` and the new `wait_until` | core | a deadline that bounds a wait. Decision 29 put `WaitLimit` in the core already |
| `post`, `Registry`, `Remote`, the mailbox rings | core | decision 4 |
| `Message.wake`, the reserved tags, the drain's slow path, `calls_out` and the 32 slots kept for returns | core | the transport. The layer sends and takes calls through the port |
| registered buffers, provided buffers, `BufferGroup`, `reserve_buffer_group` | core | kernel state. Two parts of one program can clash on an id without a library |
| datagrams, files, the offload, the spin budget, the fair tick order of W3 | core | I/O |
| `Statistics`, the stall count, the stamp, the heartbeat line, `Heartbeat.watch` | core | a turn exists on a plain loop: the program's code between ticks. Decision 9, rule 7 counts it |
| `wait_descriptor`, `wait_limit` | core, and the layer has its own `wait_limit` | decision 23. The layer adds its tasks and its pollers |
| the kept tick error | core | decision 5, amendment of 2026-11-06 |
| the drain of operations, `StillInFlight` | core | `core/shutdown.zig` keeps it, over `in_flight` alone |
| the call of each record, `Dispatch.call_records` | layer | it calls the user's code |
| `Poller`, `add_poller`, `remove_poller`, the pollers' limit | layer | it calls the user's code |
| `Task`, `Tasks`, `schedule`, `discard_tasks`, `TasksStillQueued`, the drain's wait for tasks and calls | layer | it calls the user's code. The layer's drain moves to `src/reactor/reactor_shutdown.zig` |
| `SchedulingGroup`, `NamedSchedulingGroup`, `Groups`, DRR, `charge_task`, the root's `rotor_scheduling_groups` | layer | it orders the tasks |
| `Service`, `CallRecord`, `CallLink`, `CallStation`, `call`, `answer`, `serve`, `stop_serving` | layer | a handler and a `finish` run as tasks |
| `SharedLoop` | layer | it exists so that several libraries share one loop, which needs records |
| the name of each callback in the heartbeat, `Turn`, `turn_name`, `turn_group` | the layer writes them, and the line stays the core's | only the layer calls a callback |
| the check that no tick runs inside a tick | layer | only a callback can tick inside a tick |

Two pieces sit close to the line:

- **The stall watch.** The stamp, the turn check and `Heartbeat.watch` stay in the core. A plain
  loop has turns too, and stompy's journal is a plain loop that a stall would hurt. The layer
  writes the name of each callback on the same line, through the port. On a plain loop that
  name stays null, and a watch reports a stuck turn with no name, which is the program's own code.
- **Calls.** A call needs a task and a group, so the call is the layer's. Its transport is the
  ring, which is the core's. So the core keeps the tags, the slow path of the drain and the kept
  slots, and hands each call and return to the layer.

### The core's surface after the split

`core/surface.zig` loses the 16 names of the layer and gains `wait_until`: 28 names. The public
`rotor.Loop` carries those 28 and 6 error sets. `DrainError` loses `TasksStillQueued`.

```zig
// rotor.Loop, and each backend's Loop. Program only (class B owner check).
/// Bounds the wait of each tick that follows at `limit`, until the next call. `.none`, the value
/// at init, bounds nothing. `.now` makes each tick wait 0 ns. The tick compares the limit with its
/// own stamp after R1, as it compares the nearest timer (decision 29, item 2).
pub fn wait_until(loop: *Loop, limit: WaitLimit) void;
```

It is one store. `Tables.wait_bound` reads the stored limit already, as `Dispatch.until_ns`
today. So it adds no instruction to a tick. It moves from `Dispatch` to `Tables`, 8 B. The core
never writes it, so a plain program's limit stays until the program writes it again.

`wait_limit` on a plain loop answers `.now` for the core's reasons: operations that wait to be
submitted, results that wait to be handed over, messages in a ring, an offload result, and a kept
error. Otherwise it answers the least of the nearest timer and the stored limit, as today.

### The port

The layer needs eight things from a backend's `Loop` that a plain caller must not reach. Each
backend declares them, and `core/surface.zig` lists them as `port_declarations`, checked at
comptime as the surface is. The public `rotor.Loop` does not declare them. Decision 1's amendment
of 2026-11-07, item 6, keeps the heartbeat's writer out of the public API, and the port holds it.

| name | what | today |
|---|---|---|
| `tick_backend(events, wait_ns)` | the backend's tick, with no check of a kept error | the private function of each backend with this name |
| `take_kept_error()` | returns the kept error once, and lowers `outstanding` | `kept_error.take` |
| `outstanding()` | a pointer to the word that takes a tick off the fast path | `Dispatch.callbacks_outstanding` |
| `heartbeat_line()` | the heartbeat's writer, so the layer names each callback | `tables.heartbeat` |
| `attach_reserved(hook)` | the function and the context that the drain hands each wake, call and return. It also marks the loop in its registry as one that takes calls | `call_take.take_reserved` and `Dispatch.note_wake`, called directly |
| `push_reserved(target, message, calls_out)` | a call or a return into a ring's kept slots | inside `core.call.loop.Calls` |
| `wake_target(target, descriptor)` | the wake after a call or an answer | the non-surface function of each backend with this name |
| `assert_owner()` | the owner check (class B) | `tables.assert_owner` |

A Zig field is always reachable. A program can reach a backend through `rotor.Loop`'s `inner`
field and call a port name there, as it can reach every private field of a backend today.
Decision 1, "The public module", makes only the declarations of `rotor.Loop` API. So the port is
not API for a program. It is API for the author of a twin, by open question 6.

`outstanding` stays one `u32` word in `Tables`. The core raises it for a kept error, and the layer
raises it for each record in flight, each queued task and each call. The reactor holds its loop by
value, so `outstanding()` inlines to a fixed offset from the reactor's address. A raise or a lower
is then the same add as today. A plain tick reads one word, where it reads two today:

```zig
pub fn tick(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
    if (loop.tables.outstanding != 0) try loop.take_kept_error();
    return loop.tick_backend(events, wait_ns);
}
```

The layer's tick keeps today's shape, on the layer's state and the port:

```zig
pub fn tick(reactor: *Reactor, events: []Event, wait_ns: u64) TickError!u32 {
    if (reactor.dispatch.poller_count == 0 and reactor.loop.outstanding().* == 0)
        return reactor.loop.tick_backend(events, wait_ns);
    return reactor.tick_dispatched(events, wait_ns);
}
```

`tick_dispatched` is today's function: `take_kept_error`, `begin`, `tick_backend`, `end`. The
layer writes the stored limit through the loop's `wait_until` at each place where it writes
`Dispatch.until_ns` today, and at no other place. The rules of today hold:

- `begin` stores the pollers' least limit.
- `remove_poller` stores `.none` when it removes the last poller.
- `end` and the hook for a wake store `.now` only while a poller is added. The next tick then runs
  `begin`, which writes the limit again.

So no tick on the fast path keeps a `.now` that nothing clears. A reactor with no poller holds
`.none`.

**The reserved hook.** The drain's slow path, `take_reserved` (ledger rows H6 to H8), calls the
hook for each reserved message, in the order of its ring. It is an indirect call (C5, 1.34 to 1.53
ns on the three machines), only on the cold path. The layer's hook queues the task of a call or a
return, and raises `outstanding`. The hook writes no stored limit for a call. The slow path tells
the tick that it handed a call or a return to the hook, and the tick does not block, as when the
drain writes an event. This tells only the tick that took the message, so nothing has to clear
it. It replaces the read of the task queues in `Tables.wait_bound`. A tick on the fast path that
took a call does not block, and the next tick takes the dispatched path, because `outstanding` is
not 0. Its `end` runs the task.

A loop with no hook drops a wake, as a plain loop does today. It halts on a call or a return
(class B). `call` refuses a target that attached no hook, by item 12 below, so a call from a
reactor to a plain loop returns an error on the caller's thread. Only a forged message then
reaches the halt.

### The public module

| name | today | after |
|---|---|---|
| `rotor.Loop` | 43 surface names, 10 error sets | 28 surface names, 6 error sets |
| `rotor.Reactor` | none | the host's reactor: a tagged union of `reactor.Reactor(uring.Loop)` and `reactor.Reactor(epoll.Loop)` on Linux, and `reactor.Reactor(kqueue.Loop)` on Darwin, as `rotor.Loop` wraps the backends |
| `rotor.SharedLoop` | the view of `rotor.Loop` | the view of `rotor.Reactor`, with the same 21 library calls, and 9 refused calls: today's 8 and `wait_until` |
| `rotor.Task`, `rotor.Poller`, `rotor.SchedulingGroup`, `rotor.NamedSchedulingGroup`, `rotor.SchedulingGroupName`, `rotor.named_scheduling_group`, `rotor.Service`, `rotor.CallRecord`, `rotor.Answer`, `rotor.CallResult`, `rotor.CallOptions`, `rotor.CallError`, `rotor.CallLink`, `rotor.CallStation` | from `core` | the same names, from `reactor` |
| `rotor.Completion`, `rotor.WaitLimit`, `rotor.BufferGroup`, `rotor.Heartbeat` | from `core` | no change |
| `rotor.reactor` | none | the generic `Reactor(Loop)` and `port_declarations`, for a twin (open question 6) |

`rotor.Reactor` declares the 43 names of today's `rotor.Loop`. Each name does what it does today.
It also declares `wait_until` as a compile error that states the rule: a reactor bounds its wait
with a poller. The calls of the reactor fall in three kinds:

- **The layer's 16 names** are the layer's own.
- **Seven calls wrap the loop's call.** `init`, `deinit`, `memory_bytes`, `tick`, `drain`,
  `assert_empty` and `wait_limit` each do the layer's part, and call the loop's call for the
  core's part.
- **Each other call forwards** to the loop inside, inline.

The seven calls that wrap:

- `Reactor.Options` holds the loop's `Options` as a field, and `named_groups`, whose default is
  the root's `rotor_scheduling_groups`, as today. Each field has a default, and the reactor copies
  what it keeps. The backends' options lose `named_groups`.
- `Reactor.memory_bytes(options: *const Options)` is the loop's bytes, then the bytes of `Groups`
  at their alignment: 536 B more, as today.
- `Reactor.init(reactor: *Reactor, memory, options: *const Options)` starts the reactor in place.
  It carves `Groups` from the end of `memory`, starts the loop in place on the rest, and attaches
  the hook with the reactor's address as its context. A reactor then stays at that address, as a
  loop stays at its address today. The hook asserts that its context is a reactor that `init`
  started (class C, on the cold path).
- `Reactor.deinit` asserts that no poller is added and no task is queued, as
  `Dispatch.assert_empty` does today, then ends the loop. `Reactor.assert_empty` checks the same,
  and the loop's own.
- `Reactor.tick` is the code above. `Reactor.wait_limit` answers `.now` while a task is queued,
  and otherwise the loop's `wait_limit`, as `limit_between_ticks` does today.
- `Reactor.drain` is today's drain over the reactor. It ticks the reactor, so each record and
  task runs. It waits on `in_flight` and `outstanding`, and returns `StillInFlight` or
  `TasksStillQueued` as today. The loop's own `drain` waits on `in_flight` alone.

The program writes `var reactor: rotor.Reactor` where it wrote `var loop: rotor.Loop`, and
passes `rotor.Reactor.Options`, which holds its old options as one field.

A program that wants neither callbacks nor libraries on its loop writes `rotor.Loop`, and its
binary holds no code of the layer. Zig compiles only what a program names.

### The module graph

This is an ask-before item: two new edges.

| module | imports today | imports after |
|---|---|---|
| `core` | `assertion_options` | no change |
| `linux_shared` | `core` | no change |
| `uring`, `epoll` | `core`, `linux_shared` | no change |
| `kqueue` | `core` | no change |
| `reactor` | none: it does not exist | `core` |
| `rotor` | `core`, `uring`, `epoll`, `kqueue` | the same, and `reactor` |
| `conformance` | `core`, `backend` | the same, and `reactor` |

No backend imports `reactor`, and `core` imports nothing new. So the build refuses a backend
that reaches into the layer, and refuses a core that names it. `bench/` stays outside the graph,
and `build/bench.zig` gives `bench/work/work.zig` the `reactor` import for the layer's rows.

`src/reactor/` owns its `constants.zig`: `pollers_max`, `tasks_queued_max`, `tasks_per_tick_max`,
`scheduling_groups_max`, `scheduling_shares_max`, `scheduling_shares_default`,
`scheduling_unit_credit`, `task_charge_max`, `visits_per_run_max`, `services_max`, `call_tasks_max`
and `task_queue_length_max` move there with their asserts. `calls_per_pair_max`,
`mailbox_posts_max`, `message_tag_call` and `message_tag_return` stay in the core, because the
ring uses them. No value changes.

### `SharedLoop` and the conformance suite

`SharedLoop` moves to `src/reactor/shared_loop.zig`. It is generic over the type it views, so the
public module makes it over `rotor.Reactor`. Its list of library calls does not change. Its list
of refused calls gains `wait_until`, with a compile error that states the rule: a library bounds
the wait with a poller. `zig build test-compile-fail` keeps each case, and gains that one.

The conformance suite keeps one harness for each backend, as decision 10 asks. Its scenarios fall
in two sets:

- **The core's scenarios** run on `backend.Loop`, as today. About 30 files name no part of the
  layer: TCP, UDP, timers, posts, files, the offload, the registry, the fair tick order and others.
- **The layer's scenarios** run on `reactor.Reactor(backend.Loop)`: `conformance_dispatch`,
  `conformance_dispatch_local`, `conformance_tasks`, `conformance_scheduling`,
  `conformance_call`, `conformance_call_threads`, `conformance_storm`, the three program files, and
  the parts of `conformance_limits`, `conformance_shutdown`, `conformance_cost`,
  `conformance_wait_limit`, `conformance_stall` and `conformance_buffer_release` that name the
  layer. The harness's check of each callback's time stays.

Each set runs on each backend, with the spin budget, and shuffled, as `zig build test` runs the
suite today. The race gate runs the storm and the calls on a reactor, as today on a loop.

## What it costs

### A plain loop, after

| what | today | after | source |
|---|---|---|---|
| memory of each loop | `Dispatch` 104 B, `Tables.groups` 8 B, `Groups` 536 B | `outstanding` 4 B, the stored limit 8 B, the hook 16 B | the sizes above. Net about 620 B less |
| each tick | about 6 instructions for `idle()` and its branch | one load, one compare and a branch for the kept error. The fall is 2 to 5 instructions | decision 26 for today. A prior for the fall: the part of the 6 that stays is not measured |
| each tick on io_uring | 1 instruction for the move of `wakes` | not known: `Tables` loses 112 B and gains 28 B, so `wakes` does not return to its place before decision 30 | decision 30 |
| each tick that would block | about 4 instructions for the task queues | 0 | arithmetic, a prior |
| each operation at submit | about 8 instructions | the bit into the slot only. The fall is 0 to 8: decision 26 did not split its 8, and the bit's store stays | decision 26 |
| each event | about 2 instructions | about 2 | the bit stays. Open question 5 |
| a post | 224 slots of a ring | 224 slots | open question 4 |

The work gate's plain rows, as priors from the table above. A minus is fewer instructions. Each
row's arithmetic is ticks times 2 to 5, plus operations times 0 to 8, plus 4 for a tick that
would block. The percent is of the line of `macos-aarch64-kqueue`, except where the row says.

| row | what one iteration holds | arithmetic | prior change | percent of the line |
|---|---|---|---|---|
| `post` | 2 ticks | 2 × (2 to 5) | -4 to -10 | 0.3 to 0.8 of 1217 |
| `post-operation` | 4 ticks, 2 operations, 4 events | 4 × (2 to 5) + 2 × (0 to 8) | -8 to -36 | 0.3 to 1.2 of 3114 |
| `timer` | 1 tick, 1 operation | (2 to 5) + (0 to 8) | -2 to -13 | 0.2 to 1.1 of 1151 |
| `batch` | 1 tick, 32 operations | (2 to 5) + 32 × (0 to 8) | -2 to -261 | 0.0 to 1.1 of 24624 |
| `wait` | 1 tick that blocks | (2 to 5) + 4 | -6 to -9 | 0.1 to 0.2 of 5296; 0.9 to 1.4 of 632, `linux-aarch64-epoll` |

The upper ends of these priors sit near 1 percent. Decision 26 measured +2.1 and +2.3 percent on
kqueue for the same code, more than its own arithmetic gives. So a fall past the 2 percent
tolerance is possible. A step that counts such a fall lowers that line, as the gate asks. This
record claims no speed gain for a plain loop.

### A loop with the layer, after

Rule 7 holds the layer to v0.10.0. These are the changes against it, as priors:

| path | change | source |
|---|---|---|
| each tick | the same two compares, on the layer's `poller_count` and the core's `outstanding` | the code above |
| each dispatched tick | the same calls. The layer writes the stored limit at the same places as today, one store each | the code above |
| each raise and lower of `outstanding` | the same add. `outstanding()` inlines to a fixed offset from the reactor | the port above |
| each tick on io_uring | not known. `Tables` changes again, so the place of `wakes` is not known | decision 30 |
| each operation with a record at submit | the layer counts the records of the taken operations after `submit`: about 2 to 3 instructions more for each operation | arithmetic, a prior |
| each call or return in the drain | one indirect call through the hook and its two arguments, about 3 instructions and C5. The signal to the tick: one OR on the slow path | `docs/costs.md` C5, and arithmetic |
| each `call` | a load and a branch on the registry's mark of the target, about 2 instructions (item 12) | arithmetic, a prior |
| each tick that would block | the read of the task queues goes: about -4 | arithmetic, a prior |
| each callback | the same store of its name | decision 28 |
| memory | the same bytes, in the reactor and not in `Tables` | the sizes above |

Two rows can rise:

- `record` can rise by about 3 of 1283 on `mac`, 0.2 percent, at its submit.
- `call` holds one `call` and two reserved messages in each round trip, so it can rise by about
  2 + 2 × 4 = 10 of 2529, 0.4 percent. Its target sleeps between calls, so the -4 of a tick that
  would block can take some of it back. How much is not known.

Rule 7 forbids both rises. The build must cut each rise before it lands, or Camilo rules on open
questions 8, 11 and 12. The other layer rows, `task`, `tasks-64`, `poller`, `tasks-groups-4` and
`tasks-groups-16`, keep the same work in each tick, and are expected at or below v0.10.0.

### How a layer row is compared

The macOS counts hold the kernel's instructions too, and they move from run to run.
`bench/baseline/work.txt` records the spread on `mac`: `record` and `poller` agreed within 3
instructions, `poller` counted 562, 562 and 559, and `tasks-groups-4` counted 12943, 12942 and
12978. A rise of 3 to 10 is inside that spread. So rule 7 uses two methods:

1. **On arm64 Linux, cachegrind decides.** It counts user instructions, the same on every run. A
   layer row counts at or below its count at `9339858`, with no tolerance. This is the method
   that passes or fails a step.
2. **On `mac`, a row is a check against a large rise.** Each step and `9339858` are counted five
   times each, in turns, on the same day. A step fails when its median is above the highest of
   the five counts at `9339858`.

The x86-64 rows come from CI after the push, and rule 7 does not use them, because CI counts the
two trees in different runs.

## Where it meets the records

- **Decision 1.** The graph gains `reactor` and two edges. The public module gains `Reactor`. The
  batch stays the core's shape. An operation still names a record only when its caller asks,
  and only the layer calls the record.
- **Decision 2.** The rows "tasks", "cross-core calls", "scheduling groups" and "shared loop" stay
  in version one, and each row names the layer. The row "stalls" stays the core's.
- **Decision 7.** `tick_dispatched` moves from the three backend files to `src/reactor/reactor.zig`,
  with its cold hint. The list gains that file, and ledger rows H1 to H3 are replaced by one row.
  This is an ask-before item. H4 to H8 stay where they are.
- **Decision 10.** A twin carries the 28 names and the port, and gets the layer from
  `rotor.reactor.Reactor(Twin)`. Decision 24, proposed, gains the same.
- **Decision 23.** A host that sleeps reads `wait_limit` on the type it ticks: the loop or the
  reactor.
- **Decisions 26 to 30, and 32.** The code moves, and the behaviour does not. Each record gains
  an amendment that names the new files. Decision 32 also gains the refusal of item 12.
- **Decision 29, item 2,** rejected `bound_wait(at_ns)` beside the poller's `bool`, because a
  poller would have two ways to say "do not block". This record keeps one way on each kind of
  loop. A plain loop has `wait_until` and no poller. A reactor has the poller's `WaitLimit`, and
  `wait_until` does not compile on a reactor or on `SharedLoop`. The layer calls the loop's
  `wait_until` inside the reactor, as it writes `Dispatch.until_ns` today. So this record does
  not reverse decision 29.
- **Decision 17,** proposed, names a layer that owns the loop and holds TLS and DNS. The `reactor`
  layer is a different thing: it holds no protocol.
- **Non-negotiable 2.** The layer reads no clock and decides nothing from a pointer value, as
  today. The hook is a function that the layer stores once at init.

## Alternatives it beat

1. **Leave it as it is.** A plain loop still pays the costs above, and the ruling is not met.
   The core keeps up to 33 percent of its lines for the layer, and a twin keeps the 16 names.
2. **A comptime switch in `Loop`.** Each backend's `Loop` takes `comptime layer: bool`, and each
   path tests it. Neither kind pays a run-time cost, and no port is needed. But the layer's code
   stays in `core` and in each backend, so the module graph does not show the line. Each backend
   file holds two shapes. The conformance suite runs twice on each backend, beside the spin and
   shuffle runs it has. A twin must carry both shapes. The type of `*SharedLoop` depends on the
   switch.
3. **A separate loop type in each backend.** Each backend exports `Loop` and `ReactorLoop`. The
   dispatched tick is then in six types of three modules, where it is in three today. The layer
   stays in the backends and in `core`.
4. **A wrapper over the public surface alone, with no port.** The layer would wrap `rotor.Loop`
   through its public calls. It cannot write a callback's name in the heartbeat, so decision 28's
   ruling 2 breaks. It cannot take a call from the drain, so decision 32 breaks. A poller's
   deadline becomes a relative wait from the last tick's stamp, so it is late by one turn, and
   decision 29, item 2, step 2 breaks. A kept error would come after the pollers.
5. **The layer as a package of its own.** In both forms, the author of a twin needs the port.
   In one package, the port and the layer change in the same release, and each release tests them
   together. In two packages, a consumer pins two versions that must agree, and the port must keep
   its form across releases of rotor for each version of the layer.
6. **The proposal: a wrapper with a port.** One copy of the layer's code serves each backend and
   a twin. The graph shows the line. A plain loop holds no state of the layer, and the layer does
   today's work in each tick. Its costs are the port's eight names, an indirect call on each
   reserved message, a count at submit, and a check of the target at each `call`.

## colibri, cocuyo and stompy

### colibri's interface, and `SharedLoop` as one adapter

Ruling item 4 gives colibri an interface in its own terms. colibri owns its names, so this record
does not name them. It states what rotor gives each adapter, so both adapters need only names
that exist after this record. colibri's library owns no I/O, so in both adapters the program owns
the loop or the reactor, and the adapter feeds colibri.

| colibri's part | the adapter over a plain `rotor.Loop`, which the program owns and ticks | the adapter over `*rotor.SharedLoop`, which the program's `rotor.Reactor` gives |
|---|---|---|
| its operations, out | the adapter calls `submit` and `cancel` on the program's loop | `submit` and `cancel`, each operation with a `Completion` in the adapter's struct |
| the completions, in | the program hands colibri each event of colibri's operations that its `tick` returns | each record's callback hands the event to colibri |
| its next deadline | the program stores the least of colibri's deadline and its own with `wait_until`, before each `tick` | one `Poller` that returns `.at(deadline)` |
| the handler's work | the program calls it after its tick | one `Task` that the poller schedules in colibri's group |
| its buffer group | `reserve_buffer_group` on the program's loop | `reserve_buffer_group` on the view |

A plain loop has one stored limit, and only the program writes it. So the program takes the least
of each deadline it holds, and writes that. The adapter over a plain loop needs the core alone.
`wait_until` replaces the cancel and the second arm of a timer each time a QUIC deadline moves,
which decision 29 recorded as colibri's cost. Each adapter keeps `BufferGroup`, `Task` and
`Poller` inside colibri's adapter, so colibri's public API names none of them.

### What breaks, and the migration

| consumer | pins | uses the layer | what breaks at the release of this record |
|---|---|---|---|
| colibri | `4f818b7` | no. Its decision 156 draft plans to, and colibri can take v0.10.0's `SharedLoop` first | the program's `loop.shared()` becomes `reactor.shared()`, and its `rotor.Loop` becomes `rotor.Reactor`. Ruling item 4 keeps `SharedLoop` out of colibri's public API, so only its adapter and its tests change |
| cocuyo | v0.4.0 | no | nothing of this record. Its move from v0.4.0 holds each change of v0.5.0 to v0.10.0, which decisions 23 to 32 list. One of them: v0.10.0 changed `provide_buffers` to take a `BufferGroup` (decision 29), and cocuyo writes an integer id (`io_tcp_group.zig:37`) |
| stompy | v0.7.0 | no | nothing. A stompy that wants calls between its loops makes one `rotor.Reactor` for each core |

The migration for a program on v0.10.0 that uses the layer:

1. Replace `rotor.Loop` with `rotor.Reactor` for each loop that runs records, pollers, tasks or
   calls.
2. Put the loop's old options in the `loop` field of `rotor.Reactor.Options`.
3. Keep each library as it is. It holds the same `*rotor.SharedLoop`, with the same calls.
4. Replace `rotor.Loop.AddPollerError`, `ScheduleError`, `ReserveSchedulingGroupError` and
   `CallError` with the `rotor.Reactor` names of the same sets.

A program that names a layer call on a `rotor.Loop` fails to compile, and the compiler names the
call. The release is v0.11.0. rotor keeps no forwarder on `rotor.Loop`, because a forwarder keeps
the layer's state in the plain loop (open question 2).

## Build order

Each step keeps `zig build test` green, and passes the Linux gate and the race gate before it
lands. Each step that changes a tick also passes the stress gate. Each step counts every row of
the work gate by the methods of "How a layer row is compared", at the step and at `9339858`, on
the same day.

1. **The port and `wait_until`, with no move.** Each backend declares the eight port names over
   today's state, and `core/surface.zig` checks them. `wait_until` writes `Dispatch.until_ns`. A
   conformance scenario holds `wait_until` on each backend. Gate: every row within 2 percent of
   its line, and the layer's rows at or below `9339858`.
2. **The module `reactor`, as a forwarder.** `reactor.Reactor(Loop)` wraps a backend loop and
   forwards each layer call to today's backend call, inline. The public module exports
   `rotor.Reactor`, and `rotor.Loop` keeps its names. The layer's conformance scenarios, the
   layer's rows of `bench/work/work.zig` and `examples/stall_watch.zig` move to the reactor. Gate:
   the layer's rows at or below `9339858`. A forwarder adds no instruction, so a rise here is a
   fault of the step.
3. **The move.** `dispatch/`, `tasks.zig`, `scheduling/`, `call/` (except the ring's part and
   `call_take.zig`'s slow path) and `shared_loop.zig` move from `src/core/` to `src/reactor/`, with
   their tests. The drain's wait for tasks and calls moves from `core/shutdown.zig` to
   `src/reactor/reactor_shutdown.zig`. `Tables` loses `Dispatch` and `groups`, and gains
   `outstanding`, the stored limit and the hook. The backends lose `tick_dispatched`, the layer's
   calls and `named_groups`. The hook replaces the direct calls in the drain. `call` gains the
   check of item 12. `rotor.Loop` loses the 16 names. The halt scenarios of the layer move to
   `tools/halt/reactor_*` and name the reactor. The programs of `tools/compile_fail/` stay there.
   Each one that makes a loop makes a `rotor.Reactor` instead, and `poller.zig` reaches the view
   through `reactor.shared()`. One step, because `callbacks_outstanding` joins the records, the
   tasks and the calls (decision 27, item 1), so none of them moves alone. Gate: the plain rows at
   or below their lines, and a lower line where the gate asks; the layer's rows at or below
   `9339858`; the cost gates on each backend; `zig build tla`, whose heartbeat and call models
   keep their order of stores; `zig build proofs`, with the new path of `scheduling_run.zig` in
   `proofs/README.md`.
4. **The records and the documents.** Decision 7 and the ledger, the amendments of each record
   in "Where it meets the records", `docs/using.md` in two parts, "A loop" and "A reactor",
   CLAUDE.md's Layout, and the README. Gate: `zig build test`, whose README check holds each Zig
   block to a file that runs.
5. **An example of colibri's shape.** `examples/two_adapters.zig`: one library written against
   three functions of its own, run once on a plain loop that the program owns and ticks, and once
   on a reactor through `SharedLoop`, with a checker. The plain run writes the least of the
   library's deadline and the program's own with `wait_until`. Gate: `zig build test` runs it on
   each backend, and the Linux gate on io_uring and epoll.
6. **The release.** `build.zig.zon` takes 0.11.0, and the tag follows.

The mutations of step 3, each against the narrowest target:

- the plain tick that skips `take_kept_error`: `zig build test-core`, a test of `tick_error.zig`
  over `outstanding`;
- the layer's submit that counts no record: `zig build test-reactor`, the property test of
  `Dispatch`;
- the hook not attached: the call scenarios of the conformance suite;
- `wait_until` that stores nothing: its conformance scenario;
- the slow path's signal to the tick removed: the call scenarios, where the target sleeps
  through its own task;
- `end` that stores `.now` with no poller added: the scenario of a reactor with no poller that
  takes a call, then blocks;
- the layer's drain that does not wait for tasks: `zig build test-reactor`, the tests of
  `reactor_shutdown.zig`;
- the check of item 12 removed: the call scenario to a plain loop;
- the halt on a call with no hook removed: its halt scenario.

## How it would be checked

- `core/surface.zig` lists 28 names, and `port_declarations` lists eight. Each backend checks both
  at comptime, on every host.
- The test of the public module holds `rotor.Loop` to the 28 names and 6 error sets, and
  `rotor.Reactor` to its own list.
- A comptime assert holds the new size of `Tables`, and another holds `Reactor`'s.
- Compile-fail cases: a program that calls `schedule_in` on a `rotor.Loop`, one that calls
  `wait_until` on a `rotor.Reactor`, and one that calls it on a `*rotor.SharedLoop`. Each states
  the rule.
- A conformance scenario on each backend: `wait_until(.at(t))` bounds a tick that would block at
  `t`, `.now` gives no wait, and `.none` gives the caller's wait. A timer before `t` still ends
  the wait first. The limit stays across ticks until the program writes it again.
- A conformance scenario on each backend: a reactor with no poller takes a call, runs its task,
  and then a tick with a wait blocks for that wait.
- A conformance scenario on each backend: a reactor calls a plain loop of the same registry, and
  `call` returns `LoopNotFound`. The plain loop does not halt.
- A halt scenario: a forged call message that reaches a loop with no hook.
- Every scenario of the layer passes on `reactor.Reactor(backend.Loop)`, unchanged.
- The work gate, as "How a layer row is compared" and "Build order" say.

## Open questions

1. **Are `reactor` and `rotor.Reactor` the names?** Proposed: yes. Decision 26 modelled the layer
   on Seastar's reactor. `Runtime` suggests threads, which the layer does not start, and
   `Scheduler` names one of its parts.
2. **Does `rotor.Loop` keep forwarders for the layer's names for one release?** Proposed: no.
   colibri may take v0.10.0's `SharedLoop` before this release. Ruling item 4 keeps that name out
   of colibri's public API, so its move is one type and one call in its adapter and its tests. A
   forwarder would spare that, and keep the layer's state in every plain loop.
3. **Does the stall count stay in the core?** Proposed: yes, with the stamp, the turn check and the
   watch. The two counts of the turn, which the stamp zeroes, are the layer's data on the core's
   line. A later change can move that store into the layer's tick, if a count shows a gain.
4. **Does a plain loop keep the 32 slots of each ring for returns?** Proposed: yes, for now. A
   registry option for the reserve adds a load to each post, and a ring shared by a reactor and a
   plain loop needs one answer. The cost is a post that sees 224 slots, where it saw 256 before
   decision 32.
5. **Do `Completion` and `Operation.completion` stay in the core?** Proposed: yes. The bit is the
   core's, and the type is 8 B of data. On a plain loop the event of such an operation reaches
   the caller of `tick`, with `dispatched` set. A builder in the layer makes that misuse fail to
   compile, and breaks a name that colibri's draft uses. This record keeps the name.
6. **Does the public module export the generic `Reactor(Loop)` for a twin?** Proposed: yes, as
   `rotor.reactor.Reactor` beside `port_declarations`. A twin of decision 10 then gets the layer
   without a copy, and decision 24's search can drive a reactor. The port then becomes API for a
   twin's author, with the same rules as the surface: a change to it is a breaking change, named
   in the release. A program does not reach it through `rotor.Loop`'s declarations.
7. **Does decision 7's list gain `src/reactor/reactor.zig`?** Proposed: yes, for the cold hint of
   `tick_dispatched` alone, with one ledger row. H1 to H3 retire, because their files lose that
   function.
8. **What if the hook makes `call` count more than at v0.10.0?** Proposed: the step then gives
   each backend's `Loop` a comptime parameter, the type of its hook, `void` for a plain loop. The
   call is then direct, at the cost of a second instance of each backend in a program that runs a
   plain loop beside a reactor. Camilo rules with the counts of both forms.
9. **Where does decision 31's disk scheduler go?** Proposed: in the layer, as a holder in front of
   the core's `submit`, so a plain loop pays nothing for it. Decision 31 put it in each backend's
   flush. Its capacity and share rules do not change. Camilo rules when decision 31 is built.
10. **Does v0.11.0 carry this record alone?** Proposed: yes. Each consumer then moves once for
    the split, and a later release carries new behaviour.
11. **What if the layer's count at submit makes `record` count more than at v0.10.0?** Proposed:
    the core's `submit` then adds the `dispatched` bits to `outstanding`, as `Tables.submit`
    counts them today. A plain loop then keeps that part of decision 26's 8 instructions for each
    operation. Camilo rules with the counts of both forms.
12. **How does `call` refuse a target that takes no calls?** Proposed: `attach_reserved` marks the
    loop in its registry before the loop runs, and `call` returns `LoopNotFound` for a target with
    no mark. That error already covers a loop that is not running and a remote, so `CallError`
    does not change. The cost is a load and a branch at each `call`. The other answer is today's
    halt on the target's thread, which a caller's mistake on another thread reaches. A refused
    operation returns an error value, by CLAUDE.md's conventions, so this record does not propose
    it. A target that served and stopped answers `target_stopped`, as today.

## Ask before

- Two new edges of the module graph: `rotor` to `reactor`, and `conformance` to `reactor`.
- The layout of a hot structure: `Tables` loses `Dispatch` and `groups`, and gains `outstanding`,
  the stored limit and the hook. A loop's memory loses `Groups`.
- A file on decision 7's list: `src/reactor/reactor.zig` (open question 7).
- The named limits of the layer move to `src/reactor/constants.zig`. No value changes.
- The surface of decision 1: 16 names leave `rotor.Loop`, and `wait_until` joins it.
- `SharedLoop`'s refused calls gain `wait_until`, which changes the list of decision 28.
- The registry gains a mark for each loop that takes calls (open question 12).

## Sources

- Seastar's reactor, as decision 26 describes it from Seastar's published design.
- The work gate's lines, their history and their spread: `bench/baseline/work.txt` at `e05a549`.
- The measured counts of decisions 26, 27, 28, 30 and 32, each cited where it is used.
- colibri's draft of its decision 156, in its `docs/design.md`, read on 2026-11-08.
- The `build.zig.zon` of colibri, cocuyo and stompy, read on 2026-11-08.
