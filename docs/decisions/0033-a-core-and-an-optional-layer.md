# 33. A core for the loop, and an optional layer for tasks and callbacks

Status: **accepted** on 2026-11-10 by Camilo ("Rulings, 2026-11-10"). It was proposed on 2026-11-08,
and revised the same day after five reviews. Camilo ruled open questions 1, 5, 6, 9, 13 and 16 that
day. On 2026-11-09 he chose the name `reactor` for the internal module ("Ruling on the module's
name"). On 2026-11-10 he confirmed his chat rulings of 2026-11-08 on the other ten questions, and
approved each item of "Ask before". The rulings on questions 8, 11, 13 and 16 leave one choice each
to the counts of step 2. The build starts at step 1. The same day Camilo amended the port at each
step ("Amendment, 2026-11-10: the port at each step").

Every number here is a row of `docs/costs.md`, a row of `bench/baseline/work.txt`, a count that an
earlier record measured, or a prior. A prior is an instruction count from arithmetic over the code
at `e05a549`. Nothing was measured for this record. Each table says where its numbers come from.

If it is accepted, it amends decisions 1, 2, 7, 10, 23, 26, 27, 28, 29, 30, 31 and 32. It also
amends the Layout section of CLAUDE.md, and the list of scopes in its Commits section. "Ask before"
lists the items that need Camilo's word first. Decision 31 is accepted and not built. This record
moves its scheduler from each backend's flush into the reactor, the optional module that this record
adds. Camilo ruled on that move on 2026-11-08 (open question 9).

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

## Ruling on the names, 2026-11-08

Camilo saw `rotor.reactor.Reactor` and `reactor.Reactor(Loop)` in the draft, and ruled that the
names must not repeat:

1. **The public module exports one name for the reactor, the generic `rotor.Reactor(Loop)`.** A
   program writes `rotor.Reactor(rotor.Loop)`. A twin writes `rotor.Reactor(Twin)`, as
   `std.ArrayList(T)` takes its element type.
2. **There is no `rotor.reactor` namespace.**
3. **The internal module is `layer`.** The tree reads `layer.Reactor(uring.Loop)`, and its files are
   under `src/layer/`. The ruling of 2026-11-09, below, replaces this item.

Zig's style guide says the same: a name does not repeat its namespace (`json.Value`, not
`json.JsonValue`). This record applies that rule to each name it proposes. "The names, checked"
lists them. The rule also covers the name that the compiler prints for a type, because a user reads
it in each compile error. The ruling of 2026-11-09 accepts one printed repeat, `reactor.Reactor`.
"Where each type is declared" gives those names.

## Ruling on the module's name, 2026-11-09

Camilo asked this session about the name of the internal module: "layer? isn't that a weird name?"
The session then put three choices to him:

- `dispatch`, which the session recommended. The tree calls this code `dispatch` today:
  `src/core/dispatch/`, `Dispatch` and `tick_dispatched`. The compiler would print
  `dispatch.Reactor(kqueue.Loop)`.
- `reactor`. The text of this choice said that no program types `reactor.Reactor`, and that a
  compile error and `@typeName` print it. It called that name the repeat that Camilo struck on
  2026-11-08.
- No change to the record.

Camilo chose `reactor`. He gave no reason with the choice. So the ruling is:

1. **The internal module is `reactor`, under `src/reactor/`.** Its root file is
   `src/reactor/reactor.zig`, which declares `Reactor`.
2. **The ruling accepts one printed repeat, `reactor.Reactor(kqueue.Loop)`.** A compile error and
   `@typeName` print it. The text of the choice that Camilo took named that repeat.
3. **Items 1 and 2 of the ruling on the names stand.** The question kept them. The public module
   exports one name, the generic `rotor.Reactor(Loop)`. There is no public `rotor.reactor`
   namespace, so a program never types `reactor.Reactor`.

The ruling reverses one part of the ruling on the names. On 2026-11-08 Camilo struck
`reactor.Reactor(Loop)`, and item 3 gave the module another name to keep that repeat out of the
tree. Now the tree reads `reactor.Reactor(Loop)` again, and the compiler prints it.

Camilo's question is his only word on the old name. This record gives two reasons against it:

- The word says where the code sits. It does not say what the code does.
- This repository uses the word for two other things. CLAUDE.md and the README call rotor "an event
  loop and I/O layer". Decision 17 has the title "The layer that owns the loop".

The word "reactor" has earlier uses in the records too:

- Decisions 26 and 27 use it for Seastar's reactor, the model of these pieces. That use agrees with
  the module's name.
- Decisions 31 and 32 state a requirement of Camilo as "robust under one reactor per core". Each
  explains it as one loop for each CPU core. There the word names each loop of a core. In this
  record a plain `rotor.Loop` is not a reactor. So each of the two records gains a note on the word
  ("Where it meets the records").

The rule on printed names stands for each other type. No program types `wait_limit.WaitLimit`
either, so that fact does not separate the exception from the rest. The cost of the rule separates
them:

- A repeat such as `wait_limit.WaitLimit` or `call.call.Answer` comes from the file that declares
  the type. It goes when the declaration moves to the module's root file. No name changes, and the
  compiler then prints the module's name.
- The repeat `reactor.Reactor` is the name of a type in the root file already. It goes only at the
  cost of a name, in one of two ways:
  - The module or the type takes another word. The two rulings chose `Reactor` and `reactor`.
  - The generic moves out of the root file, against the rule of "Where each type is declared". The
    compiler then prints the name of that file, and not the module's: `generic.Reactor(kqueue.Loop)`
    for a file `generic.zig`. A test on Zig 0.16.0 showed this on 2026-11-09 ("Sources").

This record takes neither way.

The ruling changes these parts of this record:

- It replaces item 3 of the ruling on the names.
- Each name that followed from the module's old name now follows `reactor`:
  - the files of `src/reactor/`, each named after `reactor.zig`;
  - the test step, `zig build test-reactor`;
  - the halt scenarios, `tools/halt/reactor_scenarios*.zig`;
  - the commit scope, `reactor`;
  - the three new edges of the module graph;
  - the new row of the ledger, and the file that joins decision 7's list.
- The rule on printed names gains one exception, item 2. The repeat is in the printed name of the
  generic and of each type declared inside it ("Where each type is declared").
- The note on decision 17 that this record proposed goes. No module of rotor now shares a name with
  that record's component.
- Decisions 31 and 32 gain the note on the word "reactor".
- The first ruling of 2026-11-08 names "an optional layer". This record calls that part "the
  reactor", and one value of the type "a reactor".

The name has one cost inside the tree. Zig refuses a parameter or a variable that has the name of a
declaration of its file. So a file that declares an import as `reactor` cannot name a receiver
`reactor`. The receiver of this record's sketches has that name, as a loop's receiver is `loop`. The
cost reaches three kinds of file:

- **The split files of `src/reactor/`.** A split file imports its root file, and the tree names that
  import after the module: `kqueue_tick.zig` declares `const kqueue = @import("kqueue.zig");`. By
  that convention `reactor_tick.zig` declares `reactor`, and `tick(reactor: *Reactor, ...)` does not
  compile there.
- **The files of the public module that import the module**, `rotor.zig` and `rotor_reactor.zig`.
- **Each other file that imports the module**: the conformance suite, `bench/work/work.zig` and the
  halt scenarios.

The rule of this record: **the receiver keeps the name `reactor`, and a file that needs that name
declares its import as `reactor_module`.** Two split files of the tree name their root file that way
today: `call_take.zig` declares `call_module`, and `dispatch_calls.zig` declares `dispatch_module`.
A file with no parameter or variable of that name declares the import as `reactor`, as the sketch of
`rotor.zig` does. The name of an import does not change the name that the compiler prints. Two tests
on Zig 0.16.0 showed these facts on 2026-11-09 ("Sources").

## Rulings, 2026-11-10

On 2026-11-08 Camilo ruled ten more open questions in chat, and chose to accept this record and
start step 1. In the same hour he asked the session to teach him how rotor works as a plain loop and
as a reactor. So the session held the acceptance and wrote none of those rulings here.

On 2026-11-10 the session put each of them to him again, as a question with its choices. The first
choice of each row was the ruling of 2026-11-08. He gave no reason with a choice.

| question | the choices | Camilo chose |
|---|---|---|
| Decision 33 leaves 28 names on a plain `rotor.Loop`, against libxev's 12 | keep the 28; a draft of a smaller buffer API; the 9 buffer calls as free functions; no `assert_empty` | **keep the 28** |
| 2. Forwarders on `rotor.Loop` for one release | none; forwarders for v0.11.0 | **none** |
| 3. The stall count | stays in the core; moves to the reactor | **stays in the core** |
| 4. The 32 slots of each ring for returns | a plain loop keeps them for now; an option for the reserve | **a plain loop keeps them for now** |
| 10. What v0.11.0 carries | this record alone; other work too | **this record alone** |
| 7. Decision 7's list | `reactor_tick.zig` joins it for one cold hint, which the counts must justify; no new file | **as proposed** |
| 8 and 11. The forms of `call` and `record` | step 2 builds both forms, and Camilo chooses with the counts; the plain form, with a stop at a loss over 2 percent | **both forms, and the counts decide** |
| 12. A call to a target that takes no calls | `LoopNotFound`; the halt on the target | **`LoopNotFound`** |
| 14 and 15. The rename to `group()`, and the core's types in `core.zig` | both; only the rename; neither | **both** |
| The three new edges of the module graph | confirm; not yet | **confirm** |
| The layout of `Tables`, of a loop's memory and of the heartbeat line, and the move of the reactor's limits | approve; not yet | **approve** |
| Acceptance | accept, and start step 1; accept, and build later; not yet | **accept, and start step 1** |

What the choices said, where a ruling depends on it:

- **The 28 names.** Camilo asked whether rotor is as light as libxev and libuv in its API. The
  session counted 12 calls on libxev's loop at the pinned commit `9ce8e8e`. It counted 318
  functions in libuv's `uv.h` at v1.52.1. The question said that the gap to libxev is in three
  groups that libxev does not have: buffers, posts between loops, and the reports and the host's
  wait.
- **Question 12.** The choice said that the check costs one load and one branch in each `call`.
- **The layout.** The question named the changes of "Ask before": `Tables` loses `Dispatch` and
  `groups`, a plain loop's memory loses `Groups`, the heartbeat line gains `poller_name` in its
  padding and stays 128 B, and the limits move with no value changed.

So each open question of this record has a ruling. Each item of "Ask before" is approved.

## Amendment, 2026-11-10: the port at each step

The agent that started step 1 stopped before it changed a file. It found three gaps between the
port and today's code:

- `attach_reserved` stores a hook and marks the loop in its registry. Today no field holds either.
  The hook's 16 B in `Tables` and the mark come at step 3, and Camilo approved that layout for
  step 3.
- The line's `name_poller` needs the field `poller_name`, which also comes at step 3. Step 2's
  check of the line would report it missing on each backend.
- `push_reserved` returns only the pair's count of calls out. `wake_target` needs the target's
  descriptor, and no name of the port gives it to the reactor.

The session put two questions to Camilo, each with its choices. The first choice of each was the
session's recommendation. He gave no reason with a choice.

| question | the choices | Camilo chose |
|---|---|---|
| How the build order handles a name of the port whose state comes at step 3 | each name joins the check with its state; a stub whose body is a compile error; the state moves to step 1 | **each name joins the check with its state** |
| How the reactor wakes the target of a call or a return | `push_reserved` wakes it; `push_reserved` also returns the descriptor | **`push_reserved` wakes it** |

So this record changes in two ways:

1. **A name of the port, or a call of the line, joins the comptime check at the step that builds
   its state.** Step 1 checks seven names: `tick_backend`, `take_kept_error`, `outstanding`,
   `stored_limit`, `heartbeat_line`, `push_reserved` and `assert_owner`. The line has five calls
   then: `enter`, `leave`, `leave_polling`, `leave_tasks` and `leave_group_tasks`. At step 3,
   `attach_reserved` joins the port with the hook and the registry's mark, and `name_poller` joins
   the line with `poller_name`. No step declares a stub, and no layout change comes before step 3.
2. **`push_reserved` pushes the message and then wakes the target**, as `Calls.call` and the
   answer do today in one place. So `wake_target` leaves the port, and a twin carries one name
   fewer. The port has eight names after step 3. The reactor still raises the pair's count of calls
   out after a push of a call, as `call` does today. For a return, the count does not change, as
   today.

"The port", "Build order" and "How it would be checked" read with this amendment. Where they say
nine names, the port has eight after step 3.

## Context

### What the code does today

These facts were read from the tree at `e05a549`, which is `9339858` and one commit of the test
gates.

- **`core` holds the reactor's code.** `src/core/` holds 17,411 lines of Zig. 5,886 of them, 34
  percent, are in `dispatch/`, `scheduling/`, `call/`, `tasks.zig`, `tasks_test.zig` and
  `shared_loop.zig`. The core keeps about 30 of those lines: `WaitLimit`, the id `SchedulingGroup`,
  and the switch of `take_reserved` on the tag ("What the core keeps from the files that move"). So
  the move takes about 5,850 lines, 34 percent, by arithmetic over the line counts. The port and
  `wait_until` then add lines to the core.
- **Every backend embeds the reactor's state.** `core.Tables` holds `dispatch: Dispatch`, 104 B
  (`dispatch.zig`, comptime assert), and `groups: *Groups`. Each backend's `init` carves one
  `Groups` of 536 B from the caller's memory (`kqueue.zig:175`, `uring.zig:192`, `epoll.zig:189`).
  The public module passes `.named_groups = scheduling.root_groups.table` into each backend's
  options (`rotor_loop.zig`, `sizing`).
- **Every tick reads the reactor's state.** Each backend's `tick` starts with `dispatch.idle()`
  (`kqueue.zig:350`), which reads the poller count and `callbacks_outstanding`. A kept tick error
  adds 1 to the same count (`tick_error.zig`), so it takes the next tick off the fast path.
- **Every submit counts records.** `Tables.submit` adds the `dispatched` bit of each operation
  and calls `Dispatch.note_submitted` (decision 26).
- **A tick that would block reads the task queues.** `Tables.wait_bound` reads `tasks.count` and
  `groups_ready` (`tables_deadline.zig:55`), because the drain can queue the task of a call
  (decision 32, item 2).
- **One stored limit has one writer.** `Dispatch.until_ns` bounds the wait. Only the reactor's code
  writes it: `begin` with the pollers' least limit, `remove_poller` with `.none`, and `note_wake`
  and `end` with `.now`. `note_wake` and `end` store `.now` only while a poller is added, because
  only then does the next tick run `begin`, which writes the limit again (`dispatch.zig:121`,
  `:285`).
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
- **The surface has 43 names** (`core/surface.zig`). 16 of them belong to the reactor: `add_poller`,
  `remove_poller`, `schedule`, `is_scheduled`, `tasks_queued`, `task_budget_left`, `discard_tasks`,
  `schedule_in`, `charge_task`, `reserve_scheduling_group`, `set_scheduling_group_shares`, `shared`,
  `call`, `answer`, `serve` and `stop_serving`. 4 of the 10 error sets of `rotor.Loop` belong to it
  too: `AddPollerError`, `ScheduleError`, `ReserveSchedulingGroupError` and `CallError`.
  `DrainError` carries `TasksStillQueued`.
- **A twin carries the reactor's names.** Decision 10 lets a consumer bring a twin of the surface
  for replay. Since decision 28, that twin must carry `shared`, `SharedLoop` and `heartbeat`, and
  each name of the reactor above.
- **No consumer uses the reactor on its main branch.** colibri pins `4f818b7`, a 0.7.0 tree. cocuyo
  pins v0.4.0 (`8cde9a6`), and stompy pins v0.7.0 (`1d0d0ce`). A search of their sources for
  `SharedLoop`, `Task`, `Poller`, `Completion.init`, `schedule_in`, `add_poller`, `WaitLimit` and
  `Service` found none, on 2026-11-08. colibri's draft for its decision 156, in its
  `docs/design.md`, plans one poller, one task and a record for each operation on a
  `*rotor.SharedLoop`. Ruling item 4 takes those names out of colibri's public API. colibri waits on
  v0.10.0, so it can take `SharedLoop` before the release of this record.

### What a plain loop pays for the reactor today

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
therefore small. The gain is a smaller surface, less memory, and a core with about 34 percent
fewer lines for a reader to read and a twin to carry.

## The decision, as proposed

1. **The core keeps the loop and its I/O.** It keeps every piece that a program with one owner of
   the loop, and no callback, needs.
2. **The reactor is a new module, `reactor`, under `src/reactor/`.** It holds the records with their
   callbacks, the pollers, the tasks, the scheduling groups, the calls and `SharedLoop`. It imports
   `core` and nothing else. Its root file, `src/reactor/reactor.zig`, declares each type that a
   program can see. So the compiler prints `reactor.Reactor(kqueue.Loop)`. That printed name
   repeats, and the ruling of 2026-11-09 accepts it.
3. **The reactor wraps a loop.** `reactor.Reactor(Loop)` holds one `Loop` by value and its own
   state. `Loop` is any type that carries the core's surface and the port below.
4. **The core gains a port of nine names.** Each backend's `Loop` declares them. The public
   `rotor.Loop` does not. They are the calls that the reactor needs and a plain caller must not
   make. "How the host's reactor reaches the port" says how the public module reaches them.
5. **The core gains one public call, `wait_until`.** It bounds the wait of each tick at a deadline.
   The stored limit has one writer on each kind of loop. On a plain loop, the program writes it with
   `wait_until`. On a reactor, only the reactor's own code writes it, through the port, for its
   pollers. A program on a reactor bounds its wait with a poller, as a library does (decision 29).
6. **The public module exports the generic `rotor.Reactor(Loop)`, and no other name for the
   reactor.** A program that wants the reactor makes a `rotor.Reactor(rotor.Loop)` in place of a
   `rotor.Loop`. A twin writes `rotor.Reactor(Twin)`. `shared()` on the program's reactor returns
   the same `*rotor.SharedLoop` as today, so a library changes nothing.
7. **A tick that runs a callback is not slower than at v0.10.0.** The reactor's rows of the work
   gate count at or below their counts at `9339858`, by the method of "How a reactor row is
   compared".

### The line

The rule: **a piece goes in the reactor when it calls the user's code on the loop's thread from
inside a tick, or exists only to order or name such calls.** Every other piece stays in the core.

| piece | side | why |
|---|---|---|
| `Loop`: `init`, `deinit`, `submit`, `cancel`, `cancel_all`, `tick`, `drain`, `assert_empty`, `in_flight` | core | the loop and its operations |
| `Operation`, `Event`, `Handle`, `Slot` and the slot table | core | the operations and their completions |
| the `dispatched` bit of an operation, a slot and an event | core | one bit that the slot keeps from submit to the event. The core copies it and never reads it. It holds no callback and no address. See open question 5 |
| `Completion`, `Completion.Call`, and the call that names a record in an operation, today `Operation.completion` | reactor | a completion record with a callback, which the ruling names. The reactor's `Completion.mark(record, operation)` writes the record's address in `user_data` and sets the bit. See open question 5 |
| timers, repeating timers, and the deadline of an operation | core | decisions 5 and 14 |
| `WaitLimit` and the new `wait_until` | core | a deadline that bounds a wait. Decision 29 put `WaitLimit` in the core already. Its declaration moves from `dispatch_callbacks.zig` to `core.zig`, the module's root |
| the id `SchedulingGroup`, an `enum(u8)` with no behaviour | core | the stall line names the group of a stuck task with it (`Statistics.Stall.group`). `Groups`, the shares and DRR are the reactor's |
| `post`, `Registry`, `Remote`, the mailbox rings | core | decision 4 |
| `Message.wake`, the reserved tags, the drain's slow path, `calls_out` and the 32 slots kept for returns | core | the transport. The reactor sends and takes calls through the port |
| registered buffers, provided buffers, `BufferGroup`, `reserve_buffer_group` | core | kernel state. Two parts of one program can clash on an id without a library |
| datagrams, files, the offload, the spin budget, the fair tick order of W3 | core | I/O |
| `Statistics`, the stall count, the stamp, the heartbeat line, `Heartbeat.watch` | core | a turn exists on a plain loop: the program's code between ticks. Decision 9, rule 7 counts it |
| `wait_descriptor`, `wait_limit` | core, and the reactor has its own `wait_limit` | decision 23. The reactor adds its tasks and its pollers |
| the kept tick error | core | decision 5, amendment of 2026-11-06 |
| the drain of operations, `StillInFlight` | core | `core/shutdown.zig` keeps it, over `in_flight` alone |
| the call of each record, `Dispatch.call_records` | reactor | it calls the user's code |
| `Poller`, `add_poller`, `remove_poller`, the pollers' limit, `pollers_max` | reactor | it calls the user's code |
| `Task`, `Tasks`, `schedule`, `discard_tasks`, `TasksStillQueued`, the drain's wait for tasks and calls | reactor | it calls the user's code. The reactor's drain moves to `src/reactor/reactor_shutdown.zig` |
| `NamedSchedulingGroup`, `Groups`, the shares, DRR, `charge_task`, the root's `rotor_scheduling_groups` | reactor | it orders the tasks |
| `Service`, `CallRecord`, `CallLink`, `CallStation`, `call`, `answer`, `serve`, `stop_serving` | reactor | a handler and a `finish` run as tasks |
| `SharedLoop` | reactor | it exists so that several libraries share one loop, which needs records |
| the name of each callback in the heartbeat, `Turn`, `turn_name`, `turn_group`, and a new `poller_name` | the reactor writes them, and the line stays the core's | only the reactor calls a callback |
| the check that no tick runs inside a tick | reactor | only a callback can tick inside a tick |

Two pieces sit close to the line:

- **The stall watch.** The stamp, the turn check and `Heartbeat.watch` stay in the core. A plain
  loop has turns too, and stompy's journal is a plain loop that a stall would hurt. The reactor
  writes the name of each callback on the same line, through the port. On a plain loop that name
  stays null, and a watch reports a stuck turn with no name, which is the program's own code.
- **Calls.** A call needs a task and a group, so the call is the reactor's. Its transport is the
  ring, which is the core's. So the core keeps the tags, the slow path of the drain and the kept
  slots, and hands each call and return to the reactor.

### What the core keeps from the files that move

Step 3 moves `dispatch/`, `scheduling/`, most of `call/`, `tasks.zig` and `shared_loop.zig`. Some
core files name types of those files today. The core imports nothing new, so each such name
leaves the core file, or its type stays in the core. This list was read from the imports at
`e05a549`:

| core file today | what it names | after the split |
|---|---|---|
| `operation.zig` | `Completion`, for `Operation.completion` | nothing. The builder moves to the reactor as `Completion.mark`, and `Operation` keeps the bit |
| `tables/tables.zig` | `Dispatch`, `Groups`, `NamedTable` | nothing. `Tables` keeps `outstanding`, the stored limit and the hook |
| `tables/tables_deadline.zig` | `WaitLimit`; `Completion` in its tests | `WaitLimit` from `core.zig`, which declares it. The tests set the bit and `user_data` by hand |
| `tick_error.zig` | `Dispatch`, for `callbacks_outstanding` | a `*u32`, the `outstanding` word |
| `inbox.zig` | `call_take`, `Dispatch`, `Groups` | the hook. `take_reserved` keeps its switch on the tag in the core: a wake sets the drain's bit, and a call or a return goes to the hook. `take_call`, `take_return`, `answer`, `schedule_link` and `verdict` move to the reactor, which runs them inside its hook |
| `stall.zig` | `Poller`, `SchedulingGroup`, `pollers_max`; a poller and `WaitLimit` in its tests | `name_of_one` reads the heartbeat's new `poller_name`, and not the pollers' table. The reactor writes that field at each `add_poller` and `remove_poller`, through the line's `name_poller`: the name of its first poller, or null. The field sits in the padding of the 128 B line, so the size does not change. `SchedulingGroup` comes from `core.zig`, which declares it |
| `statistics.zig` | `SchedulingGroup` | the same id, from `core.zig` |
| `stall_watch.zig` | `Poller`, in its tests | the tests that need a poller move to the reactor |
| `offload.zig`, `offload_in_flight.zig`, `offload_in_flight_close.zig`, `tick_share.zig`, `tables/tables_finish.zig` | `Groups` or `Completion`, in their test fixtures | the fixtures lose the field, or set the bit by hand |
| `core.zig` | `call`, `dispatch`, `scheduling`, `shared_loop`, `tasks`, and their tests | none of them. It declares `WaitLimit` and `SchedulingGroup` itself, so the compiler prints `core.WaitLimit` and `core.SchedulingGroup` |

`scheduling_groups_max` stays in the core's `constants.zig`, because `stall.zig` asserts a group id
against it. The reactor reads it from the core.

### The core's surface after the split

`core/surface.zig` loses the 16 names of the reactor and gains `wait_until`: 28 names. The public
`rotor.Loop` carries those 28 and 6 error sets. `DrainError` loses `TasksStillQueued`.

```zig
// rotor.Loop, and each backend's Loop. The program only (class B owner check). A reactor and
// SharedLoop refuse it at compile time.
/// Bounds the wait of each tick that follows at `limit`, until the next call. `.none`, the value
/// at init, bounds nothing. `.now` makes each tick wait 0 ns. The tick compares the limit with its
/// own stamp after R1, as it compares the nearest timer (decision 29, item 2).
pub fn wait_until(loop: *Loop, limit: WaitLimit) void;
```

It is one store. `Tables.wait_bound` reads the stored limit already, as `Dispatch.until_ns`
today. So it adds no instruction to a tick. It moves from `Dispatch` to `Tables`, 8 B. The core
writes it only at init, with `.none`, so a plain program's limit stays until the program writes
it again.

Each kind of loop has one writer of the stored limit:

| kind of loop | writer | how |
|---|---|---|
| plain `rotor.Loop` | the program | `wait_until`, with the owner check |
| `rotor.Reactor(rotor.Loop)`, or `rotor.Reactor(Twin)` | the reactor, for its pollers | the port's `stored_limit()`, a pointer, at the places where it writes `Dispatch.until_ns` today. The program cannot call `wait_until`, because a reactor and `SharedLoop` refuse it at compile time |

The reactor does not call `wait_until`, so a dispatched tick makes no owner check that it does not
make today. A program can reach the backend's loop inside a reactor through a field, as "The port"
says of the port's names. That is not API.

`wait_limit` on a plain loop answers `.now` for the core's reasons: operations that wait to be
submitted, results that wait to be handed over, messages in a ring, an offload result, and a kept
error. Otherwise it answers the least of the nearest timer and the stored limit, as today.

### The port

The reactor needs nine things from a backend's `Loop` that a plain caller must not reach. Each
backend declares them, and `core/surface.zig` lists them as `port_declarations`, beside today's
`loop_declarations` and `remote_declarations`. The list is the tree's: the public module does not
export it. `reactor.Reactor(Loop)` checks it at comptime, as "How a twin's author learns the port"
says. The public `rotor.Loop` does not declare the port's names.

A twin in a dependent package can name only the module `rotor` (decision 1). So each type in the
port is one of three kinds: a Zig type, a type that the public module exports today, or a type of
the twin's own. The port adds no export. In particular, the heartbeat's writer, `core.Heartbeat`,
stays out of the public API, as decision 1's amendment of 2026-11-07, item 6, rules. A backend
returns that writer from `heartbeat_line`, and a twin returns a line type of its own.

Each signature below follows the receiver, `loop: *Loop`. `E` is the loop's own error set for a
tick, which the reactor reads from the function's type. Step 1 fixes each signature over today's
code, and `docs/using.md` lists them (step 4).

| name | signature | what | today |
|---|---|---|---|
| `tick_backend` | `(events: []rotor.Event, wait_ns: u64) E!u32` | the backend's tick, with no check of a kept error | the private function of each backend with this name |
| `take_kept_error` | `() E!void` | returns the kept error once, and lowers `outstanding` | `kept_error.take` |
| `outstanding` | `() *u32` | a pointer to the word that takes a tick off the fast path | `Dispatch.callbacks_outstanding` |
| `stored_limit` | `() *rotor.WaitLimit` | a pointer to the stored limit. On a reactor, only the reactor's own code writes it | `Dispatch.until_ns` |
| `heartbeat_line` | `() *Line`, where `Line` is any type that declares the six calls of the next table | the line on which the reactor names each callback | `tables.heartbeat` |
| `attach_reserved` | `(context: *anyopaque, take: *const fn (context: *anyopaque, sender: rotor.LoopId, message: rotor.Message) void) void` | the function and the context that the drain hands each wake, call and return. It also marks the loop in its registry as one that takes calls | `call_take.take_reserved` and `Dispatch.note_wake`, called directly |
| `push_reserved` | `(target: rotor.LoopId, message: rotor.Message) error{ LoopNotFound, CallsFull, MailboxFull }!*u32` | a call or a return into a ring's kept slots. It returns the pair's count of calls out, which the reactor keeps in the call's link | inside `core.call.loop.Calls` |
| `wake_target` | `(target: rotor.LoopId, descriptor: rotor.Descriptor) void` | the wake after a call or an answer | the non-surface function of each backend with this name |
| `assert_owner` | `() void` | the owner check (class B) | `tables.assert_owner` |

The calls that the reactor makes on the line take only Zig types. The first five are the calls of
today's writer. The sixth is new.

| call on `Line` | signature, after `line: *Line` | when the reactor makes it |
|---|---|---|
| `enter` | `(name: *const [:0]const u8) void` | before each callback |
| `leave` | `(called: u64) void` | after the records of a tick's `end` |
| `leave_polling` | `(polled: u32) void` | after the pollers of a tick's `begin` |
| `leave_tasks` | `(ran: u64) void` | after the run of tasks of decision 27 |
| `leave_group_tasks` | `(ran: u64, group: u8) void` | after the run of the groups of decision 30 |
| `name_poller` | `(name: ?*const [:0]const u8) void` | at each `add_poller` and `remove_poller` |

A twin's line can store nothing. Its watch then names no callback, which a twin for replay does
not need.

A Zig field is always reachable. A program can reach a backend through `rotor.Loop`'s `inner`
field and call a port name there, as it can reach every private field of a backend today.
Decision 1, "The public module", makes only the declarations of `rotor.Loop` API. So the port is
not API for a program. It is API for the author of a twin, who passes a type to
`rotor.Reactor(Twin)` (open question 6).

`outstanding` stays one `u32` word in `Tables`. The core raises it for a kept error, and the reactor
raises it for each record in flight, each queued task and each call. The reactor holds its loop by
value, so `outstanding()` inlines to a fixed offset from the reactor's address. A raise or a lower
is then the same add as today. A plain tick reads one word, where it reads two today:

```zig
pub fn tick(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
    if (loop.tables.outstanding != 0) try loop.take_kept_error();
    return loop.tick_backend(events, wait_ns);
}

/// Returns the kept error once, and lowers `outstanding`. It is marked cold so that the compiler
/// keeps it out of `tick`, as `tick_dispatched` is marked today (decision 7, rows H1 to H3).
fn take_kept_error(loop: *Loop) TickError!void {
    @branchHint(.cold);
    try loop.kept_error.take(&loop.tables.outstanding);
}
```

The hint is the same use of the same technique, in the same three files, on a different
function. Step 3 measures it again before H1 to H3 change (decision 7 below).

The reactor's tick keeps today's shape, on the reactor's state and the port:

```zig
pub fn tick(reactor: *Reactor, events: []Event, wait_ns: u64) TickError!u32 {
    if (reactor.dispatch.poller_count == 0 and reactor.loop.outstanding().* == 0)
        return reactor.loop.tick_backend(events, wait_ns);
    return reactor.tick_dispatched(events, wait_ns);
}
```

`tick_dispatched` is today's function: `take_kept_error`, `begin`, `tick_backend`, `end`. The
reactor writes the stored limit through `stored_limit()` at each place where it writes
`Dispatch.until_ns` today, and at no other place. The rules of today hold:

- `begin` stores the pollers' least limit.
- `remove_poller` stores `.none` when it removes the last poller.
- `end` and the hook for a wake store `.now` only while a poller is added. The next tick then runs
  `begin`, which writes the limit again.

So no tick on the fast path keeps a `.now` that nothing clears. A reactor with no poller holds
`.none`.

**The reserved hook.** The drain's slow path, `take_reserved` (ledger rows H6 to H8), calls the hook
for each reserved message, in the order of its ring. It is an indirect call (C5, 1.34 to 1.53 ns on
the three machines), only on the cold path. The reactor's hook queues the task of a call or a
return, and raises `outstanding`. The hook writes no stored limit for a call. The slow path tells
the tick that it handed a call or a return to the hook, and the tick does not block, as when the
drain writes an event. This tells only the tick that took the message, so nothing has to clear it.
It replaces the read of the task queues in `Tables.wait_bound`. A tick on the fast path that took a
call does not block, and the next tick takes the dispatched path, because `outstanding` is not 0.
Its `end` runs the task.

A loop with no hook drops a wake, as a plain loop does today. It halts on a call or a return
(class B). Three cases reach a reserved message:

| case | at v0.10.0 | after |
|---|---|---|
| a reactor calls the id of a plain loop | no plain loop exists: every loop takes calls, and a loop that never served the service halts | `call` returns `LoopNotFound` on the caller's thread, by open question 12. The plain loop gets no message and does not halt |
| a reactor calls a reactor that never served the service | the target halts at `assert(station.state != .unused)` (class B) | no change. The same check runs in the reactor's hook, on the target's thread. Decision 32 chose this halt, and this record keeps it |
| a message that no `call` sent, or a call that passed the check while its target ended and a plain loop took its id | the target halts on the link's checks | a plain loop halts on the missing hook. The second half is the window of decision 32's W4, which that record leaves open |

So the split adds no halt that a correct program reaches. The halt on a missing hook catches only
a forged message, or the W4 window.

### The public module

| name | today | after |
|---|---|---|
| `rotor.Loop` | 43 surface names, 10 error sets | 28 surface names, 6 error sets |
| `rotor.Reactor(Loop)` | none | a function that returns a type. `rotor.Reactor(rotor.Loop)` is the host's reactor, which "How the host's reactor reaches the port" describes. `rotor.Reactor(Twin)` is `reactor.Reactor(Twin)`, for a twin of decision 10 |
| `rotor.SharedLoop` | the view of `rotor.Loop` | the view of `rotor.Reactor(rotor.Loop)`, with the same 21 library calls, and 9 refused calls: today's 8 and `wait_until`. Each reactor type declares its own view as `SharedLoop`, and `rotor.SharedLoop` is `rotor.Reactor(rotor.Loop).SharedLoop` |
| `rotor.Completion`, `rotor.Task`, `rotor.Poller`, `rotor.NamedSchedulingGroup`, `rotor.Answer`, `rotor.CallResult`, `rotor.CallOptions`, `rotor.CallError`, `rotor.CallLink`, `rotor.CallStation` | from `core` | the same names, from `reactor`, whose root declares each. `Completion` gains `mark` in place of `Operation.completion`. None of these types names a view, so a twin's program writes them as a host's program does |
| `rotor.Service`, `rotor.CallRecord` | from `src/rotor/rotor_service.zig`, which binds each to the host's `SharedLoop` | `rotor.Reactor(rotor.Loop).Service` and `rotor.Reactor(rotor.Loop).CallRecord`. Each reactor type declares `Service` and `CallRecord` over its own view, as it declares `SharedLoop`. A twin's program writes `rotor.Reactor(Twin).Service` and `rotor.Reactor(Twin).CallRecord`. `rotor_service.zig` goes |
| `rotor.SchedulingGroupName`, `rotor.named_scheduling_group` | from the root's groups, through `root_groups` of `src/rotor/rotor_loop.zig` | no change in name. They name the groups of the root's `rotor_scheduling_groups`, which each reactor type takes by default, the host's and a twin's alike. `root_groups` moves to `reactor` |
| `rotor.WaitLimit`, `rotor.SchedulingGroup` | from `core` | no change in name. `core.zig` declares each |
| `rotor.BufferGroup`, `rotor.Heartbeat` | from `core` | no change |

There is no `rotor.reactor` namespace, and the public module exports no list of the port's names
(open question 6).

`rotor.Reactor(rotor.Loop)` declares the 43 names of today's `rotor.Loop`. Each name does what it
does today. It also declares `wait_until` as a compile error that states the rule: a reactor
bounds its wait with a poller. The calls of the reactor fall in three kinds:

- **16 calls are the names that leave `rotor.Loop`** ("What the code does today"). The loop declares
  no call of the same name, and the module `reactor` holds their code.
- **Seven calls wrap the loop's call.** `init`, `deinit`, `memory_bytes`, `tick`, `drain`,
  `assert_empty` and `wait_limit` each do the reactor's part, and call the loop's call for the
  core's part.
- **Each other call forwards** to the loop inside, inline.

The seven calls that wrap, on `reactor.Reactor(Loop)`, and so on each member of the host's reactor:

- `Options` holds the loop's `Options` as the field `loop`, and `named_groups`, whose default is
  the root's `rotor_scheduling_groups`, as today. Each field has a default, and the reactor copies
  what it keeps. The backends' options lose `named_groups`. The host's reactor takes
  `rotor.Loop.Options` in `loop`, and lowers it to the backend's options, as `rotor.Loop.init`
  does today.
- `memory_bytes(options: *const Options)` is the loop's bytes, then the bytes of `Groups` at
  their alignment: 536 B more, as today.
- `init(reactor: *Reactor, memory, options: *const Options)` starts the reactor in place. It
  carves `Groups` from the end of `memory`, starts the loop in place on the rest, and attaches the
  hook with the reactor's address as its context. A reactor then stays at that address, as a loop
  stays at its address today. The hook asserts that its context is a reactor that `init` started
  (class C, on the cold path).
- `deinit` asserts that no poller is added and no task is queued, as `Dispatch.assert_empty` does
  today, then ends the loop. `assert_empty` checks the same, and the loop's own.
- `tick` is the code above. `wait_limit` answers `.now` while a task is queued, and otherwise the
  loop's `wait_limit`, as `limit_between_ticks` does today.
- `drain` is today's drain over the reactor. It ticks the reactor, so each record and task runs.
  It waits on `in_flight` and `outstanding`, and returns `StillInFlight` or `TasksStillQueued` as
  today. The loop's own `drain` waits on `in_flight` alone.

The program names the type once, and writes `var reactor: Reactor` where it wrote
`var loop: rotor.Loop`:

```zig
const Reactor = rotor.Reactor(rotor.Loop);

fn run(memory: []align(rotor.memory_alignment) u8, loop_options: rotor.Loop.Options) !void {
    var reactor: Reactor = undefined;
    try reactor.init(memory, &.{ .loop = loop_options });
    defer reactor.deinit();
    // ...
}
```

It passes `Reactor.Options`, which holds its old options as one field. Zig makes one type for each
argument, so each `rotor.Reactor(rotor.Loop)` in a program names the same type.

A program that wants neither callbacks nor libraries on its loop writes `rotor.Loop`, and its binary
holds no code of the reactor. Zig compiles only what a program names.

### How the host's reactor reaches the port

`rotor.Loop` holds its backend in a field, `inner`: a tagged union with one member for each
backend of the build (`src/rotor/rotor_loop.zig`). Each of its calls switches on the union, and
calls the backend's own `Loop`. The port's names are declarations of each backend's `Loop`, and a
dependent package cannot name a backend. So the public module can reach the port, and a program
cannot reach it through a declaration.

`rotor.Reactor` is a function of the public module:

```zig
/// The reactor over a loop (decision 33). `Reactor(Loop)` is the host's reactor. Any other type is
/// a twin of decision 10, which declares the core's surface and the port.
pub fn Reactor(comptime Base: type) type {
    if (Base == Loop) return struct {
        inner: reactor_calls.Inner,

        const calls = reactor_calls.Calls(@This());
        // One alias for each call of the reactor, as `tick` is. The function is in
        // `rotor_reactor.zig`, and takes `*@This()` first.
        pub const tick = calls.tick;
        // ...
        pub const SharedLoop = struct {
            // The view, with one alias for each of its calls, in the same way.
        };
    };
    return reactor.Reactor(Base);
}
```

The parameter is `Base`, because Zig refuses a parameter that has the name of a declaration of its
file, and the file declares `Loop`. The file also declares `reactor`, its import of the module, so
no parameter of the file takes that name.

The struct is declared inside the function, so the compiler prints the host's reactor as
`rotor.Reactor(rotor_loop.Loop)`, and its view as `rotor.Reactor(rotor_loop.Loop).SharedLoop`.
`rotor_loop.Loop` is how the compiler prints `rotor.Loop` today. This record does not propose
that name, and open question 15 asks whether v0.11.0 changes it. The functions of the host's
reactor are in `src/rotor/rotor_reactor.zig`. That file declares no type that a program can see,
so its name is in no message. An alias of a function that takes `*@This()` first is a method:
`reactor.tick(events, 0)` compiles, where `reactor` is a program's variable of that type. A test
of `@typeName` on Zig 0.16 showed both facts on 2026-11-08.

The struct holds a tagged union, `inner`, as `rotor.Loop` does: `reactor.Reactor(uring.Loop)` and
`reactor.Reactor(epoll.Loop)` on Linux, and `reactor.Reactor(kqueue.Loop)` on Darwin. Its `init`
picks the member of the process's backend, as `rotor.Loop.init` does. Each member reaches its
backend's port directly. The port is never a declaration of `rotor.Loop`, so decision 1's rule
holds.

**What the argument means.** A Zig programmer reads `Reactor(T)` as `std.ArrayList(T)`: a container
that holds a `T`. `reactor.Reactor(uring.Loop)` and `rotor.Reactor(Twin)` hold their argument by
value. The host's reactor holds the backend loop that a `rotor.Loop` would hold, in a union of the
same members. It does not hold a value of the type `rotor.Loop`. The consequences:

- No reactor gives out its loop as API: the host's reactor does not, and `reactor.Reactor(Loop)`
  does not. A plain call on the loop inside, such as `tick` or `wait_until`, would skip the
  reactor's records and pollers. It would also write the stored limit that only the reactor's own
  code writes ("The core's surface after the split"). The host's reactor has no `*rotor.Loop` to
  give out in any case.
- So code that takes a `*rotor.Loop` does not run on a reactor. colibri's adapter over a plain
  loop runs on a plain loop, and its adapter over `*rotor.SharedLoop` runs on a reactor ("colibri's
  interface"). A function that serves both takes the loop's type as a comptime parameter.
- `rotor.Reactor(W)`, where `W` wraps `rotor.Loop`, makes a twin's reactor. The build then stops
  with the error of "How a twin's author learns the port", whose last line says to pass
  `rotor.Loop`.

The argument names the loop that the reactor runs, and each call of the reactor does what the same
call of that loop does, plus the reactor's part. The reactor takes no `rotor.Loop` and returns none.
The record judges that a Zig programmer can learn this from the doc comment above. Open question 16
asks Camilo to rule on it, with the other choices.

The costs of this choice:

- Each call of the host's reactor switches on the union once. The member then runs with no other
  switch. That is today's cost of `rotor.Loop`: on Darwin the union has one member, and on Linux
  the switch is a load and a branch. Inside the member, `outstanding()` is a fixed offset, as "The
  port" says.
- The public module holds a second set of forwarders, each a switch over the union: the 28 core
  names, the 16 names of the reactor, and the seven calls that wrap. The forwarders of the 16 names
  move from `rotor_loop_scheduling.zig` and `rotor_loop_calls.zig`, 109 lines today. The 28 core
  names add about as many lines as their forwarders in `rotor_loop.zig`. Those were not counted for
  this record. The forwarders are in `rotor_reactor.zig`. If that file passes 500 lines, it splits
  by the file-length rule, and no type changes its printed name.
- `src/rotor/rotor.zig` holds 500 lines at `e05a549`, the limit of `tools/lint/file_length.zig`.
  The struct holds one alias line for each of 51 calls of the reactor and 30 calls of its view,
  the union and the doc comments. That is about 100 lines by arithmetic, not counted. So step 2
  moves at least that many lines out of `rotor.zig` first.

Two other choices were weighed:

- **The host's reactor holds a `rotor.Loop` by value, and the public module gives the module
  `reactor` a private port**: functions that switch on `loop.inner`. The generic then takes the port
  as a second argument, so the tree does not read `reactor.Reactor(uring.Loop)`. Each port call
  switches on the union. A tick makes at least two, `outstanding()` and `tick_backend`, and each
  raise of `outstanding` at submit makes one more. On Linux each switch is about 2 instructions, by
  arithmetic, on each tick and each operation with a record. Rule 7 forbids that rise.
- **`rotor.Loop` declares the port's names as `pub`.** Decision 1 makes each declaration of
  `rotor.Loop` API, so this makes the port API for a program. Decision 1's amendment of
  2026-11-07, item 6, keeps the heartbeat's writer out of the API.

Open question 13 asks Camilo to rule on the choice.

### How a twin's author learns the port

The public module exports no list of the port's names. So `reactor.Reactor(Loop)` checks `Loop` at
comptime, before it makes anything. The check reads `core/surface.zig`'s `loop_declarations`, which
hold the core's 28 names after step 3, and its `port_declarations`. It collects each name that
`Loop` does not declare, and the six calls of the line that `heartbeat_line` returns. It stops the
build with one compile error that names them all. Today's `surface.check` stops at the first missing
name. The reactor's check names each one, so the author adds them in one pass. The message, as a
sketch:

```text
rotor.Reactor(twin.Loop): the type lacks 3 declarations that the reactor needs:
  tick_backend: the backend's tick, with no check of a kept error
  stored_limit: a pointer to the stored limit, which only the reactor writes
  wake_target: the wake after a call or an answer
A program passes rotor.Loop. A twin of decision 10 declares each name (decision 33, "The port").
```

The costs of this choice:

- It costs compile time only, and no instruction at run time.
- The check sees names, not signatures. A wrong signature fails where the reactor calls it, and the
  error names a line of `src/reactor/`, not a line of the twin. So `docs/using.md` gains a section
  for a twin's author with the nine signatures and the six calls of the line (step 4). Its Zig block
  is an excerpt of `examples/twin.zig`, which `tools/readme_examples.zig` holds to a file that
  compiles. That example imports only the module `rotor`, as a dependent package does. So the build
  shows that a twin outside the tree can write each type of the port.
- The words of the message are part of the port's documentation. A change to the port changes
  them in the same commit, and the release names the change.
- A program that passes its own wrapper of `rotor.Loop` gets this error too. The last line of the
  message tells it to pass `rotor.Loop`.

The other choice is a compile error at the first missing name, as `surface.check` gives today. It
is shorter code, and the author builds once for each missing name.

### The names, checked

Each name that this record proposes, or moves into the reactor, against the two rulings on the names
and the API rules of `~/.claude/CLAUDE.md`:

| name | verdict |
|---|---|
| `rotor.reactor`, `rotor.reactor.Reactor`, `rotor.reactor.port_declarations` | struck by the ruling of 2026-11-08. `rotor.Reactor(Loop)` is the one export. The module `reactor` is not this namespace, because the public module does not export it |
| the module `reactor`, `src/reactor/`, `reactor.Reactor(Loop)` | they stand, by the ruling of 2026-11-09. Item 3 of the ruling on the names struck them on 2026-11-08, and the later ruling replaces that item. The compiler prints the repeat `reactor.Reactor`, and the later ruling accepts it. No program types it |
| `tools/halt/reactor_scenarios*.zig`, `reactor_scenarios`, `zig build test-reactor`, the commit scope `reactor` | named after the module, as `core_scenarios*.zig`, `test-core` and the scope `core` are named |
| `rotor.Reactor(Loop)` | a generic type with the name of the thing, as `std.ArrayList(T)`. Its `init` starts it in place through an out-pointer, takes `*const Options`, and has a `deinit`. The host's reactor holds the backend loop of a `rotor.Loop`, not a value of that type ("How the host's reactor reaches the port", open question 16) |
| `rotor.Reactor(rotor.Loop).Options`, with the fields `loop` and `named_groups` | each field has a default, and the reactor copies what it keeps |
| `rotor.Reactor(rotor.Loop).SharedLoop`, `rotor.SharedLoop` | no repeat: a reactor's view is a shared loop |
| `rotor.Reactor(rotor.Loop).Service`, `rotor.Reactor(rotor.Loop).CallRecord`, and the same names of `rotor.Reactor(Twin)` | no repeat. `rotor.Service` and `rotor.CallRecord` name the host's, as `rotor.SharedLoop` does |
| `rotor.Reactor(rotor.Loop).AddPollerError`, `ScheduleError`, `ReserveSchedulingGroupError`, `CallError` | today's names of `rotor.Loop`, moved. None repeats `Reactor` |
| `src/reactor/reactor.zig`, `reactor_tick.zig`, `reactor_shutdown.zig`, `reactor_shared.zig`, `constants.zig` | the root and the files split from it, named after it by CLAUDE.md's rule. The root declares each type that a program can see. The other files hold functions, so no type's printed name holds their names |
| `src/rotor/rotor_reactor.zig` | the functions of the host's reactor and its view. It declares no type that a program can see. `rotor.zig` declares the struct ("How the host's reactor reaches the port") |
| `wait_until` | snake_case. No repeat |
| `Completion.mark(record, operation)` | a method of the record, with the record first |
| the port: `tick_backend`, `take_kept_error`, `outstanding`, `stored_limit`, `heartbeat_line`, `attach_reserved`, `push_reserved`, `wake_target`, `assert_owner` | snake_case. None repeats `Loop` or a backend's name |
| `name_poller`, a call on the heartbeat's line | snake_case. No repeat |
| `port_declarations` | in `core/surface.zig` beside `loop_declarations` and `remote_declarations`, and not exported |
| `poller_name` in the heartbeat line, `outstanding` in `Tables` | fields. No repeat |
| `WaitLimit`, `SchedulingGroup` in the core | declared in `core.zig`, the root, and printed `core.WaitLimit` and `core.SchedulingGroup`. The draft put each in a file of its own name, which prints `wait_limit.WaitLimit`, a repeat. The move to the root removes that repeat and changes no name. So the rule stands for these types, and `reactor.Reactor` is its one exception ("Ruling on the module's name") |
| `examples/two_adapters.zig`, `examples/twin.zig` | no repeat |
| `NamedSchedulingGroup.scheduling_group()` | a name of decision 30 that this record moves and does not propose. It repeats its type's name. Open question 14 asks whether v0.11.0 renames it |

### Where each type is declared

Zig 0.16 prints a type by the path of the file that declares it, from the module's root, then the
type's name. A type in the root file takes that file's name. In this tree each root file has the
name of its module, so the compiler prints the module's name. Tests of `@typeName` showed this on
2026-11-08 and 2026-11-09 ("Sources"). `build/compile_fail.zig` at `d786659` shows the same:
`scheduling.scheduling.SchedulingGroup`, `call.call.Answer(u64)` and
`*shared_loop.SharedLoop(rotor_loop.Loop)`.

So the file that declares a type decides the name that a user reads in each compile error. A type in
a subdirectory's entry file prints its directory twice, as `call.call.Answer` does. CLAUDE.md's rule
for split files makes such entry files. A type in a file of its own name prints a repeat, as
`wait_limit.WaitLimit` would.

A type that has the name of its module's root file, and is in that file, prints a repeat too:
`Reactor` in `src/reactor/reactor.zig` prints `reactor.Reactor`. That repeat goes only at the cost
of a name ("Ruling on the module's name"). The ruling of 2026-11-09 accepts it.

The rule of this record: **each type that a program can see is declared in its module's root
file, or inside another such type.** Its methods are aliases of functions in the root's split
files, one line each, as "How the host's reactor reaches the port" shows. The code of the moved
directories stays in its files, and only the declarations of the types move.

| type | declared in | the compiler prints |
|---|---|---|
| the reactor's generic | `src/reactor/reactor.zig` | `reactor.Reactor(kqueue.Loop)`, and `reactor.Reactor(twin.Loop)` for a twin in a file `twin.zig` |
| a reactor's view | inside its reactor | `reactor.Reactor(kqueue.Loop).SharedLoop` |
| a reactor's call types | inside its reactor | `reactor.Reactor(kqueue.Loop).Service(...)` and `reactor.Reactor(kqueue.Loop).CallRecord(...)` |
| the host's reactor, its view and its call types | inside `rotor.Reactor`, in `src/rotor/rotor.zig` | `rotor.Reactor(rotor_loop.Loop)`, `rotor.Reactor(rotor_loop.Loop).SharedLoop`, and the same for `Service` and `CallRecord` |
| `Completion`, `Task`, `Poller`, `NamedSchedulingGroup`, `Answer`, `CallResult`, `CallOptions`, `CallLink`, `CallStation` | `src/reactor/reactor.zig` | `reactor.Completion`, `reactor.Answer(u64)`, `reactor.CallResult(u64)`, and so on |
| `WaitLimit`, `SchedulingGroup` | `src/core/core.zig` | `core.WaitLimit`, `core.SchedulingGroup` |

A program writes `rotor.Completion` and reads `reactor.Completion` in an error, as a program writes
`std.ArrayList` and reads `array_list.Aligned`. The module's name differs. One printed name repeats:
`reactor.Reactor`, in the first three rows. The ruling of 2026-11-09 accepts it.

The costs:

- The two root files grow. The root of `reactor` holds about 60 aliases of the reactor and its view,
  and the fields of nine types. The fields of `CallLink` and `CallStation` take about 70 lines
  today. This record did not count the total. If a root passes 500 lines, open question 15 asks
  where the rest goes.
- The tree has two places for a type: its declaration in the root, and its code in a split
  file. A reader of the code goes from the alias to the function.
- The public module's other types keep the names they print today, which this record does not
  propose: `rotor_loop.Loop`, `rotor_loop.Remote`, `statistics.Statistics`,
  `buffer_group.BufferGroup`, `handle.Handle` and `stall_watch.HeartbeatView`. Some repeat their
  file's name. The host's reactor prints `rotor_loop.Loop` as its argument. Open question 15 asks
  whether v0.11.0 moves them too.

### The module graph

This is an ask-before item: three new edges, `reactor` to `core`, `rotor` to `reactor`, and
`conformance` to `reactor`.

| module | imports today | imports after | new edge |
|---|---|---|---|
| `core` | `assertion_options` | no change | none |
| `linux_shared` | `core` | no change | none |
| `uring`, `epoll` | `core`, `linux_shared` | no change | none |
| `kqueue` | `core` | no change | none |
| `reactor` | none: it does not exist | `core` | `reactor` to `core` |
| `rotor` | `core`, `uring`, `epoll`, `kqueue` | the same, and `reactor` | `rotor` to `reactor` |
| `conformance` | `core`, `backend` | the same, and `reactor` | `conformance` to `reactor` |

No backend imports `reactor`, and `core` imports nothing new. So the build refuses a backend that
reaches into the reactor, and refuses a core that names it. `bench/` stays outside the graph, and
`build/bench_work.zig` gives `bench/work/work.zig` the `reactor` import for the reactor's rows.

`src/reactor/` owns its `constants.zig`: `pollers_max`, `tasks_queued_max`, `tasks_per_tick_max`,
`scheduling_shares_max`, `scheduling_shares_default`, `scheduling_unit_credit`, `task_charge_max`,
`visits_per_run_max`, `services_max`, `call_tasks_max` and `task_queue_length_max` move there with
their asserts. `calls_per_pair_max`, `mailbox_posts_max`, `message_tag_call` and
`message_tag_return` stay in the core, because the ring uses them. `scheduling_groups_max` stays in
the core, because the stall line checks a group id against it. No value changes.

### `SharedLoop` and the conformance suite

Each reactor type declares its view as `SharedLoop`, inside its own struct. The view's calls are
functions of `src/reactor/reactor_shared.zig`, generic over the reactor type, and today's
`src/core/shared_loop.zig` moves there. The public module exports the view of
`rotor.Reactor(rotor.Loop)` as `rotor.SharedLoop`. Each reactor type also declares `Service` and
`CallRecord` over its own view, because a handler and a `finish` take the view. The public module
exports the host's as `rotor.Service` and `rotor.CallRecord`. A twin's program names
`rotor.Reactor(Twin).SharedLoop`, `rotor.Reactor(Twin).Service` and
`rotor.Reactor(Twin).CallRecord`. A library that takes `*rotor.SharedLoop` does not take a twin's
view, as today, where a twin carries a `SharedLoop` of its own. Its list of library calls does not
change. Its list of refused calls gains `wait_until`, with a compile error that states the rule: a
library bounds the wait with a poller. `zig build test-compile-fail` keeps each case, and gains that
one.

The conformance suite keeps one harness for each backend, as decision 10 asks. Its scenarios fall
in two sets:

- **The core's scenarios** run on `backend.Loop`, as today. About 30 files name no part of the
  reactor: TCP, UDP, timers, posts, files, the offload, the registry, the fair tick order and
  others.
- **The reactor's scenarios** run on `reactor.Reactor(backend.Loop)`: `conformance_dispatch`,
  `conformance_dispatch_local`, `conformance_tasks`, `conformance_scheduling`, `conformance_call`,
  `conformance_call_threads`, `conformance_storm`, the three program files, and the parts of
  `conformance_limits`, `conformance_shutdown`, `conformance_cost`, `conformance_wait_limit`,
  `conformance_stall` and `conformance_buffer_release` that name the reactor. The harness's check of
  each callback's time stays.

Each set runs on each backend, with the spin budget, and shuffled, as `zig build test` runs the
suite today. The race gate runs the storm and the calls on a reactor, as today on a loop.

The suite makes `reactor.Reactor(backend.Loop)`, and not the host's reactor. The union and the
forwarders of `src/rotor/rotor_reactor.zig` are held by the tests of the public module, which the
Linux gate runs with io_uring and with epoll, as it runs the tests of `rotor.Loop` today.

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

### A reactor, after

Rule 7 holds the reactor to v0.10.0. These are the changes against it, as priors:

| path | change | source |
|---|---|---|
| each tick | the same two compares, on the reactor's `poller_count` and the core's `outstanding` | the code above |
| each dispatched tick | the same calls. The reactor writes the stored limit through `stored_limit()` at the same places as today, one store each, with no owner check | the code above |
| each raise and lower of `outstanding` | the same add. `outstanding()` inlines to a fixed offset from the reactor | the port above |
| each tick on io_uring | not known. `Tables` changes again, so the place of `wakes` is not known | decision 30 |
| each operation with a record at submit | the reactor counts the records of the taken operations after `submit`: about 2 to 3 instructions more for each operation | arithmetic, a prior |
| each call or return in the drain | one indirect call through the hook and its two arguments, about 3 instructions and C5. The signal to the tick: one OR on the slow path | `docs/costs.md` C5, and arithmetic |
| each `call` | a load and a branch on the registry's mark of the target, about 2 instructions (open question 12) | arithmetic, a prior |
| each tick that would block | the read of the task queues goes: about -4 | arithmetic, a prior |
| each callback | the same store of its name | decision 28 |
| each `add_poller` and `remove_poller` | one store of the first poller's name in the heartbeat's `poller_name`. No tick makes it | "What the core keeps from the files that move" |
| memory | the same bytes, in the reactor and not in `Tables` | the sizes above |

Two rows can rise:

- `record` can rise by about 3 of 1283 on `mac`, 0.2 percent, at its submit.
- `call` holds one `call` and two reserved messages in each round trip, so it can rise by about
  2 + 2 × 4 = 10 of 2529, 0.4 percent. Its target sleeps between calls, so the -4 of a tick that
  would block can take some of it back. How much is not known.

Rule 7 forbids both rises. The build must cut each rise before it lands, or Camilo rules on open
questions 8, 11 and 12. The other reactor rows, `task`, `tasks-64`, `poller`, `tasks-groups-4` and
`tasks-groups-16`, keep the same work in each tick, and are expected at or below v0.10.0.

### How a reactor row is compared

The macOS counts hold the kernel's instructions too, and they move from run to run.
`bench/baseline/work.txt` records the spread on `mac`: `record` and `poller` agreed within 3
instructions, `poller` counted 562, 562 and 559, and `tasks-groups-4` counted 12943, 12942 and
12978. A rise of 3 to 10 is inside that spread. So rule 7 uses three methods:

1. **On arm64 Linux, cachegrind decides.** It counts user instructions, the same on every run. A
   reactor row counts at or below its count at `9339858`, with no tolerance. The count runs in an
   arm64 container on `mac`, as the ledger's rows H2 and H3 were counted. This method passes or
   fails a step.
2. **On x86-64 Linux, cachegrind decides too, before the step lands.** No x86-64 machine is named,
   so the count comes from CI. The step goes up as a pull request, and CI's x86-64 job counts the
   work gate on it. A run of CI started by hand on the tag `v0.10.0` gives the counts at `9339858`.
   The programs are built for the baseline processor, and cachegrind counts user instructions, so
   two runs on different runners compare. The two runs must name the same Valgrind version. If they
   do not, both trees run again in one pair of runs on the same day. A reactor row counts at or
   below its count at `9339858`, with no tolerance. The step lands on `main` only after this check
   passes.
3. **On `mac`, a row is a check against a large rise.** Each step and `9339858` are counted five
   times each, in turns, on the same day. A step fails when its median is above the highest of
   the five counts at `9339858`.

## Where it meets the records

- **Decision 1.** The graph gains `reactor` and three edges: `reactor` to `core`, `rotor` to
  `reactor`, and `conformance` to `reactor`. The public module gains the generic `Reactor(Loop)`,
  and "The public module" of decision 1 names it beside `Loop`. The batch stays the core's shape. An
  operation still names a record only when its caller asks, now through the reactor's
  `Completion.mark`, and only the reactor calls the record.
- **Decision 2.** The rows "tasks", "cross-core calls", "scheduling groups" and "shared loop" stay
  in version one, and each row names the reactor. The row "stalls" stays the core's.
- **Decision 7.** `tick_dispatched` moves from the three backend files to
  `src/reactor/reactor_tick.zig`, with its cold hint. The list gains that file, with a new ledger
  row for that hint. The plain tick's branch to `take_kept_error` takes a cold hint in the same
  three backend files, so those files stay on the list. H1 to H3 then name `take_kept_error`, with
  new numbers. Step 3 measures both hints, by the method of H1 to H3: the work gate's rows with the
  hint and without it, on `mac` and in an arm64 container. A hint that shows no gain is not kept,
  and its row is struck. This is an ask-before item. H4 to H8 stay where they are.
- **Decision 10.** A twin carries the 28 names and the port, and gets the reactor from
  `rotor.Reactor(Twin)`. The compile error of "How a twin's author learns the port" names each
  declaration that the twin lacks. Each type of the port is a Zig type, an export of today or the
  twin's own ("The port"), so a twin in a dependent package can write it. A twin no longer carries
  `shared` or `SharedLoop`: the reactor makes them, with `Service` and `CallRecord` over the twin's
  view. Decision 24, proposed, gains the same.
- **Decision 23.** A host that sleeps reads `wait_limit` on the type it ticks: the loop or the
  reactor.
- **Decisions 26 to 30, and 32.** The code moves, and the behaviour does not. Each record gains
  an amendment that names the new files. Decision 26 also gains `Completion.mark` in place of
  `Operation.completion`. Decision 32 also gains the refusal of open question 12.
- **Decision 29, item 2,** rejected `bound_wait(at_ns)` beside the poller's `bool`, because a poller
  would have two ways to say "do not block". This record keeps one way on each kind of loop. A plain
  loop has `wait_until` and no poller. A reactor has the poller's `WaitLimit`, and `wait_until` does
  not compile on a reactor or on `SharedLoop`. The reactor writes the stored limit through the
  port's `stored_limit()`, as it writes `Dispatch.until_ns` today. So this record does not reverse
  decision 29.
- **Decision 31.** Its scheduler moves from each backend's flush to the reactor, as a holder in
  front of the core's `submit` (open question 9). Its capacity and share rules do not change. These
  parts of its text change: the amendments of decisions 11, 12 and 20 at the flush, its options on
  `Loop.Options` of every backend, and its note on the flush files of decision 7. Nothing of it is
  built, so no code moves.
- **Decisions 31 and 32, the word "reactor".** Each states a requirement of Camilo as "robust under
  one reactor per core", and explains it as one loop for each CPU core. After this record, a reactor
  in rotor is a value of `rotor.Reactor(Loop)`, and a plain loop is not one. So each record gains a
  note: the requirement covers each loop of a core, a plain loop or a reactor. Decisions 26 and 27
  use the word for Seastar's reactor, and need no note.
- **Non-negotiable 2.** The reactor reads no clock and decides nothing from a pointer value, as
  today. The hook is a function that the reactor stores once at init.

## Alternatives it beat

1. **Leave it as it is.** A plain loop still pays the costs above, and the ruling is not met. The
   core keeps about 34 percent of its lines for the reactor, and a twin keeps the 16 names.
2. **A comptime switch in `Loop`.** Each backend's `Loop` takes `comptime reactor: bool`, and each
   path tests it. Neither kind pays a run-time cost, and no port is needed. But the reactor's code
   stays in `core` and in each backend, so the module graph does not show the line. Each backend
   file holds two shapes. The conformance suite runs twice on each backend, beside the spin and
   shuffle runs it has. A twin must carry both shapes. The type of `*SharedLoop` depends on the
   switch.
3. **A separate loop type in each backend.** Each backend exports `Loop` and `ReactorLoop`. The
   dispatched tick is then in six types of three modules, where it is in three today. The reactor's
   code stays in the backends and in `core`.
4. **A wrapper over the public surface alone, with no port.** The reactor would wrap `rotor.Loop`
   through its public calls. It cannot write a callback's name in the heartbeat, so decision 28's
   ruling 2 breaks. It cannot take a call from the drain, so decision 32 breaks. A poller's deadline
   becomes a relative wait from the last tick's stamp, so it is late by one turn, and decision 29,
   item 2, step 2 breaks. A kept error would come after the pollers.
5. **The reactor as a package of its own.** In both forms, the author of a twin needs the port. In
   one package, the port and the reactor change in the same release, and each release tests them
   together. In two packages, a consumer pins two versions that must agree, and the port must keep
   its form across releases of rotor for each version of the reactor.
6. **A namespace `rotor.reactor`, with the generic `Reactor(Loop)` and `port_declarations` for a
   twin, beside a concrete `rotor.Reactor`.** This was the draft. A program then read
   `rotor.reactor.Reactor`, a name that repeats its namespace. Camilo struck it on 2026-11-08
   ("Ruling on the names"). The one generic `rotor.Reactor(Loop)` serves the program and the twin,
   and the compile error of "How a twin's author learns the port" replaces the exported list. The
   module `reactor` of the ruling of 2026-11-09 is not this namespace: the public module does not
   export it, so a program cannot name it.
7. **The proposal: a wrapper with a port.** One copy of the reactor's code serves each backend and a
   twin. The graph shows the line. A plain loop holds no state of the reactor, and the reactor does
   today's work in each tick. Its costs are the port's nine names, an indirect call on each reserved
   message, a count at submit, a check of the target at each `call`, and the forwarders of the
   host's reactor in the public module.

## colibri, cocuyo and stompy

### colibri's interface, and `SharedLoop` as one adapter

Ruling item 4 gives colibri an interface in its own terms. colibri owns its names, so this record
does not name them. It states what rotor gives each adapter, so both adapters need only names
that exist after this record. colibri's library owns no I/O, so in both adapters the program owns
the loop or the reactor, and the adapter feeds colibri.

| colibri's part | the adapter over a plain `rotor.Loop`, which the program owns and ticks | the adapter over `*rotor.SharedLoop`, which the program's `rotor.Reactor(rotor.Loop)` gives |
|---|---|---|
| its operations, out | the adapter calls `submit` and `cancel` on the program's loop | `submit` and `cancel`, each operation with a `Completion` in the adapter's struct |
| the completions, in | the program hands colibri each event of colibri's operations that its `tick` returns | each record's callback hands the event to colibri |
| its next deadline | the program stores the least of colibri's deadline and its own with `wait_until`, before each `tick` | one `Poller` that returns `.at(deadline)` |
| the handler's work | the program calls it after its tick | one `Task` that the poller schedules in colibri's group |
| its buffer group | `reserve_buffer_group` on the program's loop | `reserve_buffer_group` on the view |

colibri's decision 159 (ruled 2026-11-08) gives its host interface two calls, `turn(now_ns,
operations)` and `complete(completion, now_ns)`, and colibri calls no host. Its private kind runs
on an adapter that uses the core alone. On 2026-11-08 its session listed what that adapter needs,
and this record keeps each of them in the core:

- `Loop`, `tick` and `Event`.
- `Operation`, with `accept`, `accept_multishot`, `connect`, `receive`, `send`, `close`,
  `receive_from`, and the datagram send with segments and ECN.
- `Operation.shutdown` of the send side. colibri's session added it on 2026-11-10: colibri's
  decision 160 closes an HTTP/1.1 connection in stages (RFC 9112, section 9.6), and its host
  interface carries that as an operation, `shutdown_send`.
- `BufferGroup`, `reserve_buffer_group`, `provide_datagram_buffers`, the datagram view and
  `give_back_buffer`.

A change of this record that moves one of these out of the core is told to colibri first.

A plain loop has one stored limit, and only the program writes it. So the program takes the least
of each deadline it holds, and writes that. The adapter over a plain loop needs the core alone.
`wait_until` replaces the cancel and the second arm of a timer each time a QUIC deadline moves,
which decision 29 recorded as colibri's cost. Each adapter keeps `BufferGroup`, `Task` and
`Poller` inside colibri's adapter, so colibri's public API names none of them.

### What breaks, and the migration

| consumer | pins | uses the reactor | what breaks at the release of this record |
|---|---|---|---|
| colibri | `4f818b7` | no. Its decision 156 draft plans to, and colibri can take v0.10.0's `SharedLoop` first | the program's `loop.shared()` becomes `reactor.shared()`, and its `rotor.Loop` becomes `rotor.Reactor(rotor.Loop)`. Ruling item 4 keeps `SharedLoop` out of colibri's public API, so only its adapter and its tests change |
| cocuyo | v0.4.0 | no | nothing of this record. Its move from v0.4.0 holds each change of v0.5.0 to v0.10.0, which decisions 23 to 32 list. One of them: v0.10.0 changed `provide_buffers` to take a `BufferGroup` (decision 29), and cocuyo writes an integer id (`io_tcp_group.zig:37`) |
| stompy | v0.7.0 | no | nothing. A stompy that wants calls between its loops makes one `rotor.Reactor(rotor.Loop)` for each core |

The migration for a program on v0.10.0 that uses the reactor:

1. Replace `rotor.Loop` with `rotor.Reactor(rotor.Loop)` for each loop that runs records,
   pollers, tasks or calls.
2. Put the loop's old options in the `loop` field of `rotor.Reactor(rotor.Loop).Options`.
3. Keep each library as it is. It holds the same `*rotor.SharedLoop`, with the same calls.
4. Replace `rotor.Loop.AddPollerError`, `ScheduleError`, `ReserveSchedulingGroupError` and
   `CallError` with the `rotor.Reactor(rotor.Loop)` names of the same sets.
5. Replace each `operation.completion(&record)` with `rotor.Completion.mark(&record, operation)`.

A program that names a call of the reactor on a `rotor.Loop` fails to compile, and the compiler
names the call. So does a program that calls `Operation.completion`. A program that sets the
`dispatched` bit by hand and submits the operation to a plain `rotor.Loop` compiles. That loop calls
no record: it hands each such event to the caller of `tick`, with the bit set (open question 5). The
release is v0.11.0. rotor keeps no forwarder on `rotor.Loop`, because a forwarder keeps the
reactor's state in the plain loop (open question 2).

## Build order

Each step keeps `zig build test` green, and passes the Linux gate and the race gate before it lands.
Each step that changes a tick also passes the stress gate. Each step counts every row of the work
gate at the step and at `9339858`, by the three methods of "How a reactor row is compared". Those
methods say when each count is taken. On `mac` both trees are counted on the same day. A step lands
on `main` only after its x86-64 counts pass, from CI on its pull request.

1. **The port and `wait_until`, with no move.** Each backend declares the nine port names over
   today's state, and `core/surface.zig` checks them. Until step 3, the program's limit and the
   pollers' limit share one word, `Dispatch.until_ns`. So step 1 declares `wait_until` on each
   backend's `Loop` only, and not on `rotor.Loop`. Its conformance scenario adds no poller.
   `rotor.Loop` gains `wait_until` at step 3, when the reactor's writes leave the plain loop. Gate:
   every row within 2 percent of its line, and the reactor's rows at or below `9339858`.
2. **The module `reactor`, as a forwarder.** `reactor.Reactor(Loop)` wraps a backend loop and
   forwards each call of the reactor to today's backend call, inline. Its comptime check names each
   declaration that a type lacks. `src/reactor/reactor.zig` declares it. The public module exports
   the generic `rotor.Reactor(Loop)`. `rotor.zig` declares the host's reactor inside it, and
   `src/rotor/rotor_reactor.zig` holds its functions. `rotor.zig` is at its limit of 500 lines, so
   about 100 lines move out of it first. `rotor.Loop` keeps its names. The reactor's conformance
   scenarios, the reactor's rows of `bench/work/work.zig` and `examples/stall_watch.zig` make a
   reactor in place of a loop. `tools/commit_lint.zig` gains the commit scope `reactor`, and so does
   the list of scopes in CLAUDE.md's Commits section. The wiring of the gates changes as the table
   below says. Gate: the reactor's rows at or below `9339858`. A forwarder adds no instruction, so a
   rise here is a fault of the step.
3. **The move.** `dispatch/`, `tasks.zig`, `scheduling/`, `call/` and `shared_loop.zig` move from
   `src/core/` to `src/reactor/`, with their tests. The declaration of each type that a program can
   see moves to `src/reactor/reactor.zig`, and its functions stay in their files ("Where each type
   is declared"). The core keeps what "What the core keeps from the files that move" lists:
   `WaitLimit` and the id `SchedulingGroup`, declared in `core.zig`, the switch of `take_reserved`
   on the tag, and the heartbeat's `poller_name`. The drain's wait for tasks and calls moves from
   `core/shutdown.zig` to `src/reactor/reactor_shutdown.zig`. `Tables` loses `Dispatch` and
   `groups`, and gains `outstanding`, the stored limit and the hook. The backends lose
   `tick_dispatched`, the reactor's calls and `named_groups`, and gain `take_kept_error` with its
   cold hint. The hook replaces the direct calls in the drain. `call` gains the check of open
   question 12. `rotor.Loop` loses the 16 names and gains `wait_until`. The halt scenarios of the
   reactor move to `tools/halt/reactor_scenarios*.zig` and make a reactor:
   `core_scenarios_call_take.zig` becomes `reactor_scenarios_call_take.zig`, and so on for each file
   of the reactor. The programs of `tools/compile_fail/` stay there. Each one that makes a loop
   makes a `rotor.Reactor(rotor.Loop)` instead, and `poller.zig` reaches the view through
   `reactor.shared()`. One step, because `callbacks_outstanding` joins the records, the tasks and
   the calls (decision 27, item 1), so none of them moves alone. Gate: the plain rows at or below
   their lines, and a lower line where the gate asks; the reactor's rows at or below `9339858`; the
   two cold hints measured with and without, for the ledger; the cost gates on each backend;
   `zig build tla`, whose heartbeat and call models keep their order of stores; `zig build proofs`,
   with the new path of `scheduling_run.zig` in `proofs/README.md`.
4. **The records and the documents.** Decision 7 and the ledger, the amendments of each record
   in "Where it meets the records", `docs/using.md` in two parts, "A loop" and "A reactor",
   CLAUDE.md's Layout, the README, and `examples/twin.zig`, the twin that the section for a
   twin's author quotes. Gate: `zig build test`, whose README check holds each Zig
   block to a file that runs.
5. **An example of colibri's shape.** `examples/two_adapters.zig`: one library written against
   three functions of its own, run once on a plain loop that the program owns and ticks, and once
   on a reactor through `SharedLoop`, with a checker. The plain run writes the least of the
   library's deadline and the program's own with `wait_until`. Gate: `zig build test` runs it on
   each backend, and the Linux gate on io_uring and epoll.
6. **The release.** `build.zig.zon` takes 0.11.0, and the tag follows.

The wiring of the gates changes at steps 2 and 3. A gate that a step does not rewire stops at the
step's first build, so each step changes these files in the same commit:

| file | step 2 | step 3 |
|---|---|---|
| `build/modules.zig` | creates `reactor`, which imports `core`, in each graph it builds, the shuffled graph of `build/shuffle.zig` included. `rotor` and the three conformance modules gain the `reactor` import | no change |
| `build.zig` | `unit_test_modules`, which makes each `test-<module>` step, gains `reactor` | no change |
| `build/linux.zig` | its list of test executables for the Linux gate gains `reactor`, so the manifest that `tools/linux_test.sh` reads names it | no change |
| `build/race.zig` | no change. Its comment says that `core` and `reactor` start no thread | the comment is checked again: a test of the reactor that starts a thread adds `reactor` to the race manifest |
| `build/halt.zig` | no change | the list of scenario files gains `reactor_scenarios`, which takes the `reactor` import. The Linux scenarios gain the import where a scenario names the reactor |
| `build/bench_work.zig` | `bench/work/work.zig` takes the `reactor` import for the reactor's rows | no change |
| `build/compile_fail.zig` | one new case: `rotor.Reactor` of a type that lacks names of the port, whose message must name each one | each message that spells a moved type changes to the name of "Where each type is declared": `dispatch.dispatch_callbacks.WaitLimit` becomes `core.WaitLimit` in `poller`; `scheduling.scheduling.SchedulingGroup` becomes `core.SchedulingGroup` in `scheduling_group_literal` and `call_scheduling_group`; `scheduling.scheduling.NamedSchedulingGroup` becomes `reactor.NamedSchedulingGroup` in `call_scheduling_group`; `call.call.Answer(u64)` becomes `reactor.Answer(u64)` in `call_handler_void` and `call_now_no_reply`; `call.call.CallResult` becomes `reactor.CallResult` in `call_finish_type`; and `*shared_loop.SharedLoop(rotor_loop.Loop)` becomes `*rotor.Reactor(rotor_loop.Loop).SharedLoop` in `call_from_remote`. No message holds a repeat. The two cases for `wait_until` are new |

The mutations of step 3, each against the narrowest target:

- the plain tick that skips `take_kept_error`: `zig build test-core`, a test of `tick_error.zig`
  over `outstanding`;
- the reactor's submit that counts no record: `zig build test-reactor`, the property test of
  `Dispatch`;
- the hook not attached: the call scenarios of the conformance suite;
- `wait_until` that stores nothing: its conformance scenario;
- the slow path's signal to the tick removed: the call scenarios, where the target sleeps
  through its own task;
- `end` that stores `.now` with no poller added: the scenario of a reactor with no poller that
  takes a call, then blocks;
- the reactor's drain that does not wait for tasks: `zig build test-reactor`, the tests of
  `reactor_shutdown.zig`;
- the check of open question 12 removed: the call scenario to a plain loop;
- the halt on a call with no hook removed: its halt scenario;
- the reactor's store of `poller_name` removed: the scenario of `conformance_stall` that counts a
  stall of one poller and reads its name;
- a `Reactor.wait_until` that forwards to the loop in place of its compile error: the
  compile-fail case of `rotor.Reactor(rotor.Loop)`, which then compiles and fails the step.

## How it would be checked

- `core/surface.zig` lists 28 names, and `port_declarations` lists nine. Each backend checks both at
  comptime, on every host. `reactor.Reactor(Loop)` checks both too, and names each declaration that
  `Loop` lacks.
- `zig build test` builds `reactor` on every host, and `zig build test-reactor` runs its tests
  alone. `zig build test-linux` builds its test executable, and `tools/linux_test.sh` runs it. The
  compile-fail cases match the new type names of the table in "Build order".
- The test of the public module holds `rotor.Loop` to the 28 names and 6 error sets, and
  `rotor.Reactor(rotor.Loop)` to its own list.
- A comptime assert holds the new size of `Tables`, and another holds the size of each
  `reactor.Reactor(backend.Loop)`.
- Compile-fail cases: a program that calls `schedule_in` on a `rotor.Loop`, one that calls
  `wait_until` on a `rotor.Reactor(rotor.Loop)`, and one that calls it on a `*rotor.SharedLoop`.
  Each states the rule. One more passes `rotor.Reactor` a type that lacks three names of the port,
  and its message must name all three.
- A conformance scenario on each backend: `wait_until(.at(t))` bounds a tick that would block at
  `t`, `.now` gives no wait, and `.none` gives the caller's wait. A timer before `t` still ends
  the wait first. The limit stays across ticks until the program writes it again.
- A conformance scenario on each backend: a reactor with no poller takes a call, runs its task,
  and then a tick with a wait blocks for that wait.
- A conformance scenario on each backend: a reactor calls a plain loop of the same registry, and
  `call` returns `LoopNotFound`. The plain loop does not halt.
- A halt scenario: a forged call message that reaches a loop with no hook.
- A halt scenario, moved from `core_scenarios_call_take.zig` to `reactor_scenarios_call_take.zig`: a
  call that reaches a reactor that never served the service halts in the reactor's hook, as at
  v0.10.0.
- Every scenario of the reactor passes on `reactor.Reactor(backend.Loop)`, unchanged.
- The work gate, as "How a reactor row is compared" and "Build order" say: arm64 and x86-64 Linux by
  cachegrind before a step lands, and `mac` by five counts of each tree.
- The ledger: the cold hint of `take_kept_error` in each backend file, and of `tick_dispatched` in
  `src/reactor/reactor_tick.zig`, each counted with and without.
- A test of the reactor holds the `@typeName` of each type in "Where each type is declared" to the
  name in that table, so a moved declaration that changes a printed name fails `zig build test`.
- `examples/twin.zig` imports only the module `rotor`, declares the core's names, the port and a
  line, and runs one record and one task on `rotor.Reactor(Twin)`. `zig build test` builds and
  runs it.

## Open questions

1. **Are `reactor` and `rotor.Reactor` the names?** Proposed: yes. Decision 26 modelled these pieces
   on Seastar's reactor. `Runtime` suggests threads, which the reactor does not start, and
   `Scheduler` names one of its parts.

   *Ruled on 2026-11-08: the type is `Reactor`, and the names must not repeat. The public module
   exports the generic `rotor.Reactor(Loop)`, and a program writes `rotor.Reactor(rotor.Loop)`.
   There is no `rotor.reactor` namespace. The internal module is `layer`, under `src/layer/`.*

   *Ruled again on 2026-11-09: Camilo chose `reactor` for the internal module, from three choices.
   The module is under `src/reactor/`, so the tree reads `reactor.Reactor(uring.Loop)`. The text of
   his choice named that printed repeat.*

   "Ruling on the names" and "Ruling on the module's name" record the two rulings. "The names,
   checked" applies them to each name of this record.
2. **Does `rotor.Loop` keep forwarders for the reactor's names for one release?** Proposed: no.
   colibri may take v0.10.0's `SharedLoop` before this release. Ruling item 4 keeps that name out of
   colibri's public API, so its move is one type and one call in its adapter and its tests. A
   forwarder would spare that, and keep the reactor's state in every plain loop. *Ruled on
   2026-11-08, and confirmed on 2026-11-10: no forwarders.*
3. **Does the stall count stay in the core?** Proposed: yes, with the stamp, the turn check and the
   watch. The two counts of the turn, which the stamp zeroes, are the reactor's data on the core's
   line. So are `turn_group`, the new `poller_name`, and the id `SchedulingGroup` that a stall
   reports. A later change can move the store of the counts into the reactor's tick, if a count
   shows a gain. *Ruled on 2026-11-08, and confirmed on 2026-11-10: the stall count stays in the
   core, with the stamp, the turn check and the watch.*
4. **Does a plain loop keep the 32 slots of each ring for returns?** Proposed: yes, for now. A
   registry option for the reserve adds a load to each post, and a ring shared by a reactor and a
   plain loop needs one answer. The cost is a post that sees 224 slots, where it saw 256 before
   decision 32. *Ruled on 2026-11-08, and confirmed on 2026-11-10: a plain loop keeps the 32 slots,
   for now.*
5. **Is the `dispatched` bit in the core inside what the ruling allows?** Ruling item 2 puts
   completion records with callbacks in the reactor. So this record moves `Completion`,
   `Completion.Call` and the builder, which becomes `Completion.mark`. The core keeps one bit in
   `Operation`, `Slot` and `Event`, which it copies and never reads. The bit holds no callback and
   no address, but it is the reactor's mark in each operation of a plain loop. It costs the plain
   loop the bit's store at submit and about 2 instructions for each event. Proposed: the bit stays.
   Without it, the reactor must find its records in a table keyed by handle. That is a lookup for
   each event of a reactor. A plain loop that gets an operation with the bit set calls nothing, and
   hands the event to the caller of `tick`. colibri's draft names `Operation.completion`, and its
   adapter changes that one call. *Ruled on 2026-11-08: the bit stays in the core. It is inside the
   ruling, because it holds no callback and no address.*
6. **Does the public module export the generic `Reactor(Loop)` for a twin?** Proposed: yes, as
   `rotor.reactor.Reactor` beside `port_declarations`. A twin of decision 10 then gets the reactor
   without a copy, and decision 24's search can drive a reactor. The port then becomes API for a
   twin's author, with the same rules as the surface: a change to it is a breaking change, named in
   the release. A program does not reach it through `rotor.Loop`'s declarations. *Ruled on
   2026-11-08: the generic is the one export for the reactor, `rotor.Reactor(Loop)`. A twin writes
   `rotor.Reactor(Twin)`, as `std.ArrayList(T)` takes its element type. There is no `rotor.reactor`
   namespace, and the public module exports no `port_declarations`.* A twin's author learns the
   port's names from the compile error of "How a twin's author learns the port", and its signatures
   from `docs/using.md`. The rest stands as proposed: the port is API for a twin's author, and a
   change to it is a breaking change, named in the release. That API is the nine names, their
   signatures, and the six calls of the line, all in "The port". Each of their types is a Zig type,
   an export of today, or the twin's own, so the port adds no export and keeps the heartbeat's
   writer out of the API. The names that a twin's program writes are `rotor.Reactor(Twin)` and its
   `Options`, `SharedLoop`, `Service`, `CallRecord` and error sets, and the exports that name no
   view, such as `rotor.Completion` and `rotor.Task`.
7. **How do decision 7's list and the ledger change?** Proposed: `src/reactor/reactor_tick.zig`
   joins the list, for the cold hint of `tick_dispatched` alone, with a new row. The three backend
   files stay on the list for a cold hint on the plain tick's branch to `take_kept_error`, and H1 to
   H3 name that function. No row changes on arithmetic alone: step 3 counts each hint with and
   without it, as d1657ce counted H1 to H3. A hint that shows no gain is removed, and its row is
   struck. *Ruled on 2026-11-08, and confirmed on 2026-11-10: as proposed.*
8. **What if the hook makes `call` count more than at v0.10.0?** Proposed: the step then gives
   each backend's `Loop` a comptime parameter, the type of its hook, `void` for a plain loop. The
   call is then direct, at the cost of a second instance of each backend in a program that runs a
   plain loop beside a reactor. Camilo rules with the counts of both forms. *Ruled on 2026-11-08,
   and confirmed on 2026-11-10: step 2 builds both forms, and Camilo chooses with the counts.*
9. **Does decision 31's disk scheduler move into the reactor?** Proposed: yes, as a holder in front
   of the core's `submit`, so a plain loop pays nothing for it. Decision 31 is accepted, and put it
   in each backend's flush, so this record amends it. Its capacity and share rules do not change.
   The scheduler calls no user code, so the rule of "The line" alone would keep it in the core. The
   reason to move it is the cost to a plain loop, about 2 instructions in each tick by decision 31's
   own arithmetic. *Ruled on 2026-11-08: the scheduler goes in the reactor, and this record amends
   decision 31.*
10. **Does v0.11.0 carry this record alone?** Proposed: yes. Each consumer then moves once for
    the split, and a later release carries new behaviour. *Ruled on 2026-11-08, and confirmed on
    2026-11-10: v0.11.0 carries this record alone.*
11. **What if the reactor's count at submit makes `record` count more than at v0.10.0?** Proposed:
    the core's `submit` then adds the `dispatched` bits to `outstanding`, as `Tables.submit` counts
    them today. A plain loop then keeps that part of decision 26's 8 instructions for each
    operation. Camilo rules with the counts of both forms. *Ruled on 2026-11-08, and confirmed on
    2026-11-10: step 2 builds both forms, and Camilo chooses with the counts.*
12. **How does `call` refuse a target that takes no calls?** Proposed: `attach_reserved` marks the
    loop in its registry before the loop runs, and `call` returns `LoopNotFound` for a target with
    no mark. That error already covers a loop that is not running and a remote, so `CallError`
    does not change. The cost is a load and a branch at each `call`. The other answer is today's
    halt on the target's thread, which a caller's mistake on another thread reaches. A refused
    operation returns an error value, by CLAUDE.md's conventions, so this record does not propose
    it. A target that served and stopped answers `target_stopped`, as today. The mark covers only
    the kind of loop. A call to a reactor that never served the service still halts on the
    target, as decision 32 chose. A call in decision 32's W4 window, where the target ends and a
    plain loop takes its id, halts the plain loop; W4 decides that window. *Ruled on 2026-11-08,
    and confirmed on 2026-11-10: `call` returns `LoopNotFound` for a target with no mark.*
13. **How does `rotor.Reactor(rotor.Loop)` reach the backend's port?** Proposed: it is a private
    type of the public module, a tagged union of `reactor.Reactor(uring.Loop)` and
    `reactor.Reactor(epoll.Loop)` on Linux, and `reactor.Reactor(kqueue.Loop)` on Darwin. Each
    member reaches its backend's port directly, and `rotor.Loop` declares no name of the port. The
    cost is one switch on the union for each call, as `rotor.Loop` has today, and a second set of
    forwarders in `src/rotor/`. The other answers are a reactor that holds a `rotor.Loop` and
    switches on its union at each port call, which costs about 2 instructions for each switch on
    each tick, and a port declared `pub` on `rotor.Loop`, which makes it API for a program. "How the
    host's reactor reaches the port" gives the costs of each. *Ruled on 2026-11-08 with open
    question 16: step 2 builds both forms, and Camilo chooses with the counts.*
14. **Does v0.11.0 rename `NamedSchedulingGroup.scheduling_group()`?** It is a name of decision
    30, and it repeats its type's name, as `json.JsonValue` does. Proposed: yes, to
    `NamedSchedulingGroup.group()`, in the same release, so each consumer moves once (open
    question 10). The call returns the loop's `SchedulingGroup` for the named group, and `group`
    says that. The cost is one more line of the migration. The name came with decision 30 in
    v0.10.0, and each consumer pins an older tree ("What the code does today"), so none calls it.
    *Ruled on 2026-11-08, and confirmed on 2026-11-10: the rename lands in v0.11.0.*
15. **Where are the types declared that print a repeat today?** "Where each type is declared"
    puts each type of this record in a root file. The public module's other types print the file
    that declares them: `rotor_loop.Loop`, `rotor_loop.Remote`, `statistics.Statistics`,
    `buffer_group.BufferGroup`, `handle.Handle` and `stall_watch.HeartbeatView`. So the host's
    reactor prints as `rotor.Reactor(rotor_loop.Loop)`. Proposed: v0.11.0 moves the declarations
    of the core's types to `core.zig`, by the same rule, so the compiler prints `core.Statistics`.
    `rotor.Loop`, `rotor.Remote` and the other types of the public module keep their places,
    because `rotor.zig` is at its 500 lines and this record already moves about 100 out. A later
    release can declare them in `rotor.zig` too. The same question holds for a root that passes
    500 lines: proposed, a type then goes in a file whose name, followed by the type's name,
    repeats nothing, as `view.zig` with `SharedLoop` would. The cost of the move is lines in each
    root, and one more change to the messages of `build/compile_fail.zig`. *Ruled on 2026-11-08,
    and confirmed on 2026-11-10: as proposed.*
16. **Is `rotor.Reactor(rotor.Loop)` strange to a Zig programmer, when it holds no
    `rotor.Loop`?** "What the argument means" gives the consequences. Proposed: keep it, as the
    ruling on the names wrote it. The argument names the loop that the reactor runs, and no call of
    the reactor takes or returns a `rotor.Loop`. The other choices:
    - The host's reactor holds a `rotor.Loop` by value, and the reactor's state beside it. Each call
      switches once on `loop.inner`, as in the proposal, so the cost is the same. It needs the
      reactor's state apart from the backend's type, which this record has not checked. It still
      gives out no `*rotor.Loop`, for the reasons of "What the argument means".
    - A host's reactor with no argument, beside the generic. Zig refuses two declarations with one
      name, so it needs a second name, such as the `rotor.reactor.Reactor` that the ruling struck
      ("Alternatives it beat", item 6).

    *Ruled on 2026-11-08: the host's reactor holds a `rotor.Loop`, so that `Reactor(T)` holds a `T`,
    as a Zig programmer reads it. The earlier prior of about 2 instructions for each switch was
    never measured. Step 2 builds the private union too, counts both forms on the work gate's
    reactor rows, and Camilo rules with the counts. The reactor's state apart from the backend's
    type is checked at the same step.*

## Ask before

Camilo approved each item of this list on 2026-11-10 ("Rulings, 2026-11-10"). The session put the
first two to him as questions of their own. He approved the others when he accepted the record.

- Three new edges of the module graph: `reactor` to `core`, `rotor` to `reactor`, and `conformance`
  to `reactor`.
- The layout of two hot structures: `Tables` loses `Dispatch` and `groups`, and gains
  `outstanding`, the stored limit and the hook. A loop's memory loses `Groups`. The heartbeat line
  gains `poller_name` in its padding, and stays 128 B.
- A file on decision 7's list: `src/reactor/reactor_tick.zig`. The three backend files keep their
  place for a different function, `take_kept_error` (open question 7).
- An accepted record changes: decision 31's scheduler moves into the reactor (open question 9).
- The ruling's words: the `dispatched` bit of the reactor stays in the core (open question 5).
- The named limits of the reactor move to `src/reactor/constants.zig`. No value changes.
- The surface of decision 1: 16 names leave `rotor.Loop`, and `wait_until` joins it. The public
  module gains the generic `rotor.Reactor(Loop)` (open questions 1, 6, 13 and 16).
  `rotor.Service` and `rotor.CallRecord` become the host's reactor's, and each reactor type
  declares its own.
- The declarations of the reactor's types and the core's `WaitLimit` and `SchedulingGroup` move to
  their modules' root files. The compiler then prints one repeat among them, `reactor.Reactor`,
  which the ruling of 2026-11-09 accepts (open question 15).
- `SharedLoop`'s refused calls gain `wait_until`, which changes the list of decision 28.
- The registry gains a mark for each loop that takes calls (open question 12).

## Sources

- Seastar's reactor, as decision 26 describes it from Seastar's published design.
- The style guide of Zig's language reference, on names that repeat their namespace.
- The session's question to Camilo on 2026-11-09, with its three choices and his answer, for "Ruling
  on the module's name". The session's transcript holds them.
- A test of `@typeName` on Zig 0.16.0, on 2026-11-08. The messages of `build/compile_fail.zig` at
  `d786659` agree with it. It showed four facts:
  - A type in a module's root file prints the root file's name, then its own name.
  - A type declared inside a generic prints the generic's name first.
  - A type in `call/call.zig` prints as `call.call.Answer(u64)`.
  - An alias of a function is a method.
- A second test on Zig 0.16.0, on 2026-11-09. Its module `reactor` has the root file
  `reactor/reactor.zig`. It showed three facts:
  - The generic prints as `reactor.Reactor(core.Loop)`, and its view as
    `reactor.Reactor(core.Loop).SharedLoop`.
  - A type of the root prints as `reactor.Completion`.
  - A file that imports the module as `reactor` and names a parameter `reactor` does not compile.
- A third test on Zig 0.16.0, on 2026-11-09, of a split file `reactor_tick.zig` that imports its
  root file and names its receiver `reactor`. It showed two facts:
  - With the import declared as `reactor`, the file does not compile. The error is "function
    parameter shadows declaration of 'reactor'".
  - With the import declared as `reactor_module`, the file compiles. The compiler still prints
    `reactor.Reactor(core.Loop)` and `reactor.Completion`.
- A fourth test on Zig 0.16.0, on 2026-11-09. Its module `reactor` has the root file `root.zig`, and
  a second file `generic.zig`. It showed two facts:
  - A type in the root file prints as `root.Completion`: the file's name, and not the module's.
  - A generic declared in the second file prints as `generic.Reactor(core.Loop)`.
- `src/kqueue/kqueue_tick.zig`, `src/core/call/call_take.zig` and
  `src/core/dispatch/dispatch_calls.zig` at `fc29015`, for the name that a split file gives the
  import of its root file.
- `src/rotor/rotor.zig`, `src/rotor/rotor_service.zig` and `src/core/stall.zig` at `d786659`, for
  the public module's exports, the binding of `Service` to the host's view, and the calls of the
  heartbeat's writer.
- `src/rotor/rotor.zig` and `src/rotor/rotor_loop.zig` at `adc1adb`, for how `rotor.Loop` holds
  its backend. Neither file changed since `e05a549`.
- The work gate's lines, their history and their spread: `bench/baseline/work.txt` at `e05a549`.
- The measured counts of decisions 26, 27, 28, 30 and 32, each cited where it is used.
- colibri's draft of its decision 156, in its `docs/design.md`, read on 2026-11-08.
- The `build.zig.zon` of colibri, cocuyo and stompy, read on 2026-11-08.
