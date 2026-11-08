# 27. A task queue on the loop

Status: proposed on 2026-11-06, **accepted** by Camilo the same day, with the proposed answer to each open question, and **built** the same day. "Ruling" below says what he decided, and "What was built" at the end says where the code differs from the proposal. It amends decision 2, because it adds a row to the "In version one" table. It builds on decision 26, which Camilo accepted and built on 2026-11-06. It also amends these records:

- decision 26, at its counter, its `begin`, its `end` and its `deinit` check, and at who may tick;
- decision 5, rule 7, at `drain`;
- decision 23, for a host that sleeps in its own wait;
- decision 13, at the spin window and at its point 2.

Amended on 2026-11-08 by decision 32, for the task of a cross-core call:

- The task of a call is pushed with the limit `task_queue_length_max`, which is
  `tasks_queued_max + call_tasks_max`, 82,368. So a queue that the program filled still takes it.
  `schedule` and `schedule_in` keep the cap `tasks_queued_max`. Each bound of a queue's length
  reads `task_queue_length_max`.
- `discard_tasks` halts on the queued task of a call, which `Task.Call.call_record` marks: its
  caller waits for its `finish`.
- P7 also counts the calls out and the calls held (decision 26, amendment of 2026-11-08).
- Open question 14 stays as ruled for a post: a post carries no task. A call's message carries
  the address of a record that holds a task, and only the loop that owns the record queues it,
  on its own queue.

## Ruling, 2026-11-06

Camilo ruled on these points:

1. **Only the program ticks a shared loop.** A library never calls `tick` on a loop it does not own. It submits, returns, and finishes its work in records, pollers and tasks. Decision 26's text is corrected to say so.
2. **The task queue is in core** (open question 1).
3. **The tasks run in `end`, after the records** (open question 2).
4. **The proposed answer stands for open questions 3 to 14.**

Open questions 8 and 15 were settled before the ruling. CI's counts raised the Linux rows of `bench/baseline/work.txt` for decision 26 (89ab0f9). Decision 7 now allows the cold hint in the three backend files, with ledger rows H1 to H3 (d12d078).

## Context

On 2026-11-06 Camilo said that rotor "might also need a task scheduler". He meant the run queue of Seastar's reactor. That queue has three parts:

- a queue of tasks that the reactor runs after it polls;
- scheduling groups with shares;
- a quota, after which a long run of tasks gives way to I/O.

Decision 26 made a loop that several libraries share. An operation may name a `Completion`, and the tick calls it. A library may add a `Poller`, and the loop calls it once in each tick. A callback may not call `tick`. Decision 26 says: "A callback that wants another pass returns, and the loop's next tick serves it." Nothing in rotor yet holds that "other pass" for a library. Each library holds it itself.

The consumers show the need:

- **colibri.** Issue 14's third ruling says that on a shared loop, `colibri.Client.fetch` submits and returns. colibri then calls the caller's record "on a later tick of the loop". That call is not the final event of one rotor operation. It is a callback that a library must still make. Today colibri needs a poller that scans its finished exchanges in each tick. colibri also has its own `Ready` ring (its decision 119) and a `pending` bit set of entries to step again.
- **cocuyo.** It has an intrusive ready list (its decision 20), a queue of held sends, a TCP send queue and a results queue. Its `drive` runs after every tick.
- **stompy.** It has its own `Completion`, a guard against a tick inside a callback, an overflow queue of completions, and turns in a fixed order after each tick.

These lists share four properties:

- Each one is bounded by a count per turn and never by a time.
- None of them lets the loop sleep while work is left.
- Each one takes its order from the order of calls, so a seed replays it.
- Each one is linked through memory that the caller already owns.

Issue 14's second ruling, from the same day, says that only the program ticks a shared loop. No library calls `tick` on a loop it does not own. The reason is nested ticks. A cocuyo callback calls `fetch`, `fetch` ticks, and that tick calls a second cocuyo callback. The issue cites Seastar: the reactor runs a continuation "on a later pass". So a library continues its work through a deferred callback, and not through a tick of its own. Decision 26's text stated its ruling 2 as "Libraries take the loop at init, and any of them may tick". Camilo confirmed the second ruling for this record, and decision 26 now says that only the program ticks. This record depends on that ruling.

Seastar's design meets rotor's rules at four points:

- **It allocates.** A continuation that waits is a heap object. The run queue is a `circular_buffer` that grows. Each task queue is allocated when its group is created.
- **It reads the clock.** The task quota (0.5 ms by default) is a timerfd. On the aio backend the kernel sets the preemption flag by a write to a completion ring. On the epoll backend a `SCHED_FIFO` thread sets it. Group fairness charges each group by its measured run time, so it reads the clock at each switch of group.
- **It overrides its own quota.** While more than `max_task_backlog` (1000) tasks wait, it keeps the run going. Seastar issue 3768 shows that a task which queues itself again then livelocks the other groups.
- **It preempts only between tasks.** Its preemption is cooperative. It checks the flag only after a task, at a `co_await` and in `maybe_yield`.

Each of these points conflicts with a non-negotiable of rotor: zero allocation, determinism, or shared nothing. This record keeps the parts of Seastar that rotor can keep. It drops or defers each of the others, and it names each one under "Alternatives it beat".

Decision 2 does not exclude a scheduler by name. A scheduler is out of version one only because the table does not list it. CLAUDE.md, "Ask before", lists "Building anything decision 2 leaves out of version one". So this record amends decision 2, and nothing is built before Camilo rules.

Decision 22 is the nearest precedent. Its step 1 built "the scheduler, tasks and waits" for the `std.Io` adapter. Camilo removed it on 2026-11-05 for three reasons: its size, its upkeep, and because it bent rotor's rules. This record must stay small:

- a FIFO of callbacks, with no futures, no fibers, no `await` and no groups;
- no clock, no thread, no allocation;
- no exemption from a lint rule.

## The decision, as proposed

A **task** is a record that a library owns and asks the loop to call once, later. The loop keeps one FIFO of tasks. The tick runs the tasks after the completion records, up to a budget counted in tasks. While a task is queued, the tick does not block. The record adds no scheduling groups, no shares and no time quota. "How groups could come later" says how a later record could add them without a change to `Task` or to `schedule`.

A task is not an operation:

- It takes no slot of `operations_max`.
- It makes no event.
- It never reaches the kernel.

So non-negotiable 5 does not apply to it. `Operation` stays a closed union. The task queue keeps its own rule in place of non-negotiable 5. That rule is **the once rule: the loop calls `run` exactly once for each `schedule`, unless the program calls `discard_tasks` before the call.** "Shutdown" below says how `drain` and `discard_tasks` keep the once rule.

A task belongs to the loop that queued it, until its `run` starts or `discard_tasks` unlinks it. The library must not schedule it on a second loop in that time. The check in `push` reads only the queue of the loop that `schedule` names, so it does not catch a task that is queued on another loop.

### The surface

```zig
// src/core/tasks.zig (new). It is pure: it takes no *Loop and reads no clock, so the
// determinism lint holds it. dispatch.zig, at 246 lines, holds the queue and calls it.

/// Work that a library asks the loop to do once, in a later part of a tick (decision 27). The
/// library owns the record and puts it inside its own struct, as it does with a `Completion`.
/// A task is not an operation: it takes no slot, makes no event, and never reaches the kernel.
/// The loop calls through the task's address and links it, and never decides from its value.
/// Size 16 B, alignment 8 (comptime assert).
pub const Task = struct {
    run: *const fn (task: *Task) void,
    /// The task after this one in the queue. Only the loop writes it.
    next: ?*Task = null,

    /// A task at `field` of `Parent` that calls `handler` with its parent. It costs the same
    /// indirect call (C5) as a task written by hand.
    pub fn init(
        comptime Parent: type,
        comptime field: []const u8,
        comptime handler: fn (parent: *Parent) void,
    ) Task;
};

pub const ScheduleError = error{TasksFull};

/// The run queue: a FIFO through `Task.next`, in memory the libraries own. `Dispatch` holds it.
/// Size 24 B, alignment 8 (comptime assert).
pub const Tasks = struct {
    head: ?*Task,
    tail: ?*Task,
    /// The tasks queued.
    count: u32,
    /// `tasks_per_tick_max` less the tasks the current run started. 0 outside a run.
    left: u32,
    pub const empty: Tasks;

    /// Appends `task`. Halts when the task is queued already in this queue. Returns
    /// error.TasksFull when `queued_max` tasks are queued, and then changes nothing.
    /// `Loop.schedule` passes `constants.tasks_queued_max`. A unit test passes a lower value.
    pub fn push(tasks: *Tasks, task: *Task, queued_max: u32) ScheduleError!void;
    /// True when `task` is in this queue: `task.next != null or tasks.tail == task`. A task
    /// that is queued on another loop and is not its tail also reads true.
    pub fn holds(tasks: *const Tasks, task: *const Task) bool;
    /// Runs at most min(count, tasks_per_tick_max) tasks, only from those queued when it
    /// began. Returns the count it ran.
    pub fn run(tasks: *Tasks) u32;
    /// Unlinks every queued task without a call. Returns the count it unlinked. Cold.
    pub fn discard(tasks: *Tasks) u32;
};

// Each backend's Loop (src/{uring,kqueue,epoll}/*.zig) and rotor.Loop. src/core/surface.zig
// gains the five names. rotor.Task and rotor.ScheduleError are exported beside
// rotor.Completion and rotor.Poller.

/// Asks the loop to call `task.run` once, later (decision 27). The order is the order of the
/// calls. Only the loop's own thread calls it (class B owner check). It may be called from
/// the program, a completion record, a poller or a task. It never runs the task itself.
/// A task queued by the program between ticks, by a poller, or by a record runs in the
/// `end` of the next tick to reach it. A task queued by a task runs one tick later.
/// A task belongs to one loop while it is queued. Do not schedule it on a second loop: the
/// check that halts on a task queued twice reads this loop's queue only.
pub fn schedule(loop: *Loop, task: *core.Task) core.ScheduleError!void;

/// True while `task` is queued on this loop. A library that offers an item once reads it
/// before `schedule`, as colibri's `Ready` and cocuyo's ready list offer each item once.
pub fn is_scheduled(loop: *const Loop, task: *const core.Task) bool;

/// The tasks queued now. A host that sleeps in its own wait reads it before it sleeps
/// (decision 23), and a program reads it before `deinit`.
pub fn tasks_queued(loop: *const Loop) u32;

/// `tasks_per_tick_max` less the tasks the current run started, the task that reads it
/// included. 0 outside a run. It is not capped by the queue length, so a task that is alone
/// in the queue reads `tasks_per_tick_max - 1`. A long task that can split its work does at
/// most `task_budget_left() + 1` slices of its own size in one call, then schedules itself
/// again. It reads a count and never the clock.
pub fn task_budget_left(loop: *const Loop) u32;

/// Unlinks every queued task without a call, and returns the count (decision 27, "Shutdown").
/// Only the program calls it, between ticks, after `drain` returns error.TasksStillQueued.
/// It halts when called inside a tick.
pub fn discard_tasks(loop: *Loop) u32;
```

There is no `unschedule` and no option in `Loop.Options`. Open questions 5 and 9 raise each one.

### Data structures

| structure | fields | size, alignment | where it lives |
|---|---|---|---|
| `Task` | `run` (8 B), `next: ?*Task` (8 B) | 16 B, 8 | the library's struct |
| `Tasks` | `head`, `tail` (8 B each), `count: u32`, `left: u32` | 24 B, 8 | inside `Dispatch`, so inside `Tables` |
| `Dispatch` | it gains `tasks`, and `records_in_flight` becomes `callbacks_outstanding`, with the same `u32` | 72 B today, 96 B with `Tasks` inline | inside `Tables` |

Today `Dispatch` holds `pollers: [8]*Poller` (64 B), a `u32`, a `u8` and two `bool`s. That is 71 B, padded to 72 B at alignment 8. `Tasks` adds 24 B at alignment 8, so `Dispatch` becomes 96 B, with no new padding. The change to `Tables` follows from where the compiler places `Dispatch`, which a build must report before the layout is fixed.

- **The link is a pointer and not a 32-bit index.** The tasks are in memory that the libraries own, and the loop has no table to index into. A `Completion` reaches the loop as an address in `user_data` for the same reason.
- **A task needs no flag byte.** A task is queued on this loop when `next != null` or when `tail == task`. So `Task` stays at 16 B, and the queued state cannot drift from the queue of one loop. It does not detect a task that is queued on another loop (see above).
- **`Tables` changes layout.** `Dispatch` is part of `Tables`, which the tick touches. CLAUDE.md, "Ask before", needs Camilo's approval for that change. `Tables` and `Dispatch` are auto-layout Zig structs, so the record cannot place the new field on a cache line by its position in the source. Two layouts are possible:
  - **The 24 B form, as proposed.** `Dispatch` goes from 72 B to 96 B. The instruction gate and a run on a quiet `mac` decide whether it moves anything.
  - **An 8 B form.** `Dispatch` holds a `?*Tasks` that the program hands to the loop, and goes from 72 B to 80 B. It adds one load on the cold path, and it makes a library depend on a program that attached the queue.

  Open question 4 asks which one.

**The counter that `idle()` reads.** `records_in_flight` becomes `callbacks_outstanding`. It counts two things:

- the operations in flight that named a record;
- the tasks queued.

`schedule` adds 1, and `run` and `discard` subtract 1 for each task they unlink. `idle()` stays `poller_count == 0 and callbacks_outstanding == 0`, which is two compares, as today. A program that never schedules a task stays on the fast path.

The fold weakens one check of decision 26. `call_records` subtracts 1 at each final event, and that subtraction's overflow check "halts on a final event the count never saw" (`dispatch.zig`). While a task is queued, a final event that the count never saw takes the count down without an underflow. The halt then comes later, or not at all. This record restores part of the check with a class B check, once in each dispatched tick, after `call_records`: `tasks.count <= callbacks_outstanding`. A stray event that drops the count below the task count halts there. A stray event that drops it less far is not caught until the queue empties. The other choice keeps `records_in_flight` separate and makes `idle()` read a third word. Open question 3 asks which one, and the instruction gate decides.

**Proposed limits for `src/core/constants.zig`.** Each one gets a doc comment.

| constant | value | what it bounds |
|---|---|---|
| `tasks_per_tick_max: u32` | 64 | The most tasks that one run of one tick starts. A prior and not a measurement. It is of the order of Tokio's `event_interval` of 61, Go's 61 and Tokio's budget of 128. At the prior of about 4.3 ns for each hot task, 64 tasks take about 275 ns. That is less than one `kevent` round trip (C10, 294 ns on `mac`). |
| `tasks_queued_max: u32` | 65,536 | The most tasks queued at one time. The intrusive queue has no storage of its own. So this limit is a bound on a producer that does not stop, as non-negotiable 1 and the unbounded-loop lint ask. `schedule` returns `error.TasksFull` at it. |

Comptime asserts beside them:

- `tasks_per_tick_max >= 1`;
- `tasks_per_tick_max <= tasks_queued_max`;
- `tasks_queued_max + operations_max <= maxInt(u32)`, so `callbacks_outstanding` cannot overflow.

Comptime asserts in `tasks.zig`: `@sizeOf(Task) == 16`, `@sizeOf(Tasks) == 24`, and `@alignOf` of each is 8.

### Tick order

The tick steps are named S0 to S5, so that no step shares a name with the once rule. Steps that this record changes are marked **[27]**. kqueue is shown. io_uring and epoll keep their own backend order. The run queue enters none of their backend ticks.

- **S0. The fast path.** `if (dispatch.idle()) return tick_backend(...)`. **[27]** `callbacks_outstanding` now also counts queued tasks. The two compares are the same.
- **S1. `tick_dispatched` (cold) calls `Dispatch.begin(wait_ns)`.**
  1. It checks `assert_class_a(!ticking)`, then sets `ticking` and `polling`.
  2. It calls each poller once, in the order they were added. A poller may call `schedule`.
  3. It clears `polling`.
  4. **[27]** It returns 0 when a poller returned true **or when `tasks.count > 0`**. Otherwise it returns `wait_ns`. So a task that the last tick queued, that the program queued between ticks, or that a poller queued in this step keeps this tick from blocking. Within one thread, no wake is lost.
- **S2. `tick_backend`.** This step does not change. A wait of 0 also turns the spin off, because `spin.applies` needs a wait above the budget. That is the same as a poller that returns true.
- **S3. The backend tick.** This step does not change. On kqueue it runs these steps:
  - `begin_tick` and the clock read;
  - the flush, the due timers, `offload.drain`, `drain_finished` and `drain_mailboxes`;
  - `settle_to_sleep`, `arm_poll` and `kevent`;
  - a clock read after a wait that blocked;
  - the reap, the second drains and `expire_after_reap`.

  The wake handshake of `spec/tla/wake/` does not change. Corrected on 2026-11-06: the model had no tick with a wait of 0, because its receiver always went through `begin_sleep`. It now has the step `DrainNoWait`. That step drains the rings and returns to the drain without a flag, as a tick does when a poller returns true or a task is queued. The invariants hold with it, and the mutant `no_wait_blocks` shows that TLC checks the step.
- **S4. `Dispatch.end(events)`.**
  1. It checks `assert_class_a(ticking)`.
  2. It calls `call_records`, as decision 26 built it. A callback may call `schedule`.
  3. **[27]** It runs the class B check `tasks.count <= callbacks_outstanding`.
  4. **[27]** It calls `tasks.run()`:
     - It checks the shape of the queue (class B): `count == 0` if and only if `head == null` if and only if `tail == null`, and `count <= tasks_queued_max`.
     - It takes the snapshot `n = min(tasks.count, tasks_per_tick_max)` and sets `left = tasks_per_tick_max`.
     - It runs `for (0..constants.tasks_per_tick_max) |i| { if (i == n) break; ... }`. The body has these steps:
       1. It checks `assert_class_a(head != null)` and `assert_class_a(count >= 1)`, then takes `task = head`.
       2. It sets `head = task.next` and `task.next = null`. When the queue is now empty, it sets `tail = null`.
       3. It subtracts 1 from `count`, `left` and `callbacks_outstanding`.
       4. It calls `task.run(task)`.
     - It sets `left = 0`.
  5. It sets `ticking = false` (defer) and returns the count of events at the front.
- **S5. The return to the caller.** The caller of `tick` gets the events that named no record. When tasks remain, the next tick's S1 returns a wait of 0.

Three rules follow from the pop and the snapshot:

- **The pop clears all of the task's state before the call.** The loop never writes the task after `run` returns. So a handler may free or reuse its parent, for example when a connection closes.
- **A task may schedule itself from its own `run`,** because its `next` is already null.
- **The snapshot decides which tick runs a task.** The snapshot is taken in S4, after the pollers of S1 and after `call_records`. So these tasks run in this tick's `end`, inside the bound of `tasks_per_tick_max`:
  - a task that the program queued between ticks;
  - a task that a poller queued in this tick's `begin`;
  - a task that a record queued in `call_records`.

  Only a task that a task queued runs in the next tick. That is a function of the call sequence, so it replays. The API comment of `schedule` states it, and the guide must state it too.

`ticking` is still true while the tasks run. So a task that calls `tick` halts on decision 26's class A check, with no new code. That check enforces issue 14's second ruling for tasks too.

The run loop names `constants.tasks_per_tick_max` as its range. The unbounded-loop lint reports only two shapes: a `while (true)` with no named limit, and a length read compared against a literal. A `for` over a range that names the constant is neither shape, and the range bounds the loop by its form.

**Why the tasks run in `end` and not in `begin`.** A continuation that a completion caused runs in the same tick, and waits for no extra kernel call. In steady state the loop alternates one run of tasks with one full backend tick. Seastar alternates `run_some_tasks` with `poll_once` in the same way.

### Shutdown

As built, `drain` does not run queued tasks. `src/core/shutdown.zig` loops `while (loop.in_flight() != 0)`. `in_flight` is `Tables.in_flight()`, the count of slots in use, so it counts no task. A loop that holds queued tasks and no operation returns from `drain` at once. `deinit` would then halt on the extended `assert_empty`.

This record amends decision 5, rule 7, and `shutdown.drain`:

- `drain` loops while `loop.in_flight() != 0 or loop.tasks_queued() != 0`, still bounded by `drain_rounds_max`.
- When the bound is reached with operations still in flight, `drain` fails with `error.StillInFlight`, as today.
- When the bound is reached with only tasks left, `drain` fails with a new `error.TasksStillQueued`. The kernel then holds nothing, but a callback is still outstanding.
- A task that schedules itself in every tick reaches that bound. It is the same result as an operation that never ends.

The recovery from `error.TasksStillQueued` is `discard_tasks`. The program calls it between ticks. It unlinks each queued task, clears each `next`, subtracts the count from `callbacks_outstanding`, and calls no task. The program can then call `deinit`. A library whose task the program discarded gets no call, so the program must stop that library first, or accept that the library does not finish its work.

`deinit` halts while a task is queued. That is a class C check in `assert_empty`, beside its check for pollers. So the once rule holds at shutdown: each queued task ran, or the program discarded it by an explicit call. Open question 7 asks whether to keep `discard_tasks`.

### Fairness and preemption

1. **FIFO.** Tasks run in the order of the `schedule` calls. That order comes from the program's calls and the kernel's answers. It keeps the property that colibri's `Ready` and cocuyo's ready list were built for: the order replays from a seed.
2. **A budget counted in tasks.** One tick starts at most `tasks_per_tick_max` tasks, and never more than were queued at the snapshot. A task that schedules itself forever therefore runs once in each tick, and the tick still ends. A storm of tasks that callbacks schedule is bounded by the same rule. Each tick in between still reaps, drains the mailboxes and fires due timers.
3. **No sleep while work is queued.** `begin` returns 0 while `tasks.count > 0`. This is the same rule as a poller that returns true, TigerBeetle's `run_for_ns` and stompy's `busy`.
4. **Cooperative only.** rotor cannot stop a task that is in its call. It has no signal, no thread and no stack of its own. "Give way to I/O" means "start no more tasks, and return to the tick". A long task must split itself:
   - Each slice has a size that the library counts, as colibri's `steps_max` and cocuyo's `verifications_per_message_max` already do.
   - In one call, the task does at most `task_budget_left() + 1` slices.
   - When work is left after that, it schedules itself again and returns.

   A task that is alone in the queue reads `tasks_per_tick_max - 1`, so it may do up to 64 slices in one tick. The last task of a full run reads 0 and does one slice. So the slices of one run stay near `tasks_per_tick_max`. The slices that a task does do not lower the value that the next task reads, so this is guidance, and the loop does not enforce it.
5. **No backlog override.** Nothing keeps a run going because the queue is long. The snapshot and the count bound end each run after at most `n` calls, so the livelock of Seastar issue 3768 cannot occur.

The bound on I/O is in tasks and not in time. A run of 64 tasks of 10 µs each holds the loop for 640 µs, which is near Seastar's quota of 0.5 ms. One task of 20 ms holds it for 20 ms. Seastar's quota does not stop such a task either, because its preemption is also cooperative. A timer can therefore fire late by up to one run of task time. The decision 13 entry under "Where it meets the records" says so.

A queued task keeps the loop awake. A library that queues a task in every tick turns the loop into a spin that uses a whole core. Decision 13's ruling says that a loop spends a core it was not given only when its caller asks. This record treats a call to `schedule` as that request.

A run of tasks is not activity for decision 13's spin window. `spin.Window.note_handed_over` moves `active_ns` only when a tick hands over events, and a tick that only runs tasks hands over 0. So after a long series of ticks that only run tasks, the first tick with a wait above the budget finds the window closed, and it blocks at once. A program whose work arrives only through tasks gets no spin after its tasks end. Open question 10 asks whether `end` should report the tasks it ran, so that the window opens.

### How groups could come later

This record builds no scheduling groups. Three reasons:

- colibri and cocuyo budget by count, and split CPU work by count.
- stompy's design refuses weighted DRR and mClock (`serverless-postgres-design.md`, "Performance fairness"). It moves heavy CPU work to another loop through `post`, which is decision 4's answer.
- Seastar's evidence for groups (its tutorial, the introduction to §26: 1,000 fibers against 1 take about 90 percent of the CPU) applies to a program with many producers. No consumer of rotor has shown that need yet.

A later record could add groups without a change to `Task` or to `schedule`:

```zig
// Later, not in this record.
pub const Group = enum(u8) { loop = 0, _ }; // an index into a fixed table of groups_max entries
pub fn add_group(loop: *Loop, shares: u16) AddGroupError!Group;
pub fn schedule_in(loop: *Loop, group: Group, task: *Task) ScheduleError!void;
// `schedule(task)` stays, and means `schedule_in(.loop, task)`. The queue holds the group, so
// `Task` keeps its layout.
```

That record would have to state these points:

- **The rule.** It would use deficit round robin in task counts, with a cursor and a deficit that persist across ticks. Ties break by group index and never by address. The per-tick budget stays `tasks_per_tick_max` across all groups.
- **Fairness in tasks is not fairness in CPU time.** At equal shares, a group of 10 µs tasks gets 1,000 times the CPU of a group of 10 ns tasks. Seastar's shares weigh measured time, which needs the clock. A caller-stated `cost` in task units would be the deterministic repair: `vruntime` grows by cost × (unit / shares), which is stride scheduling.
- **The models.** A TLA+ model of the run loop and Lean proofs of its bounds would come with groups, and not before.

### Determinism

Nothing in the task queue reads the host clock, `std.Random`, uninitialised memory or a pointer value. Each decision it makes is a function of the program's calls, the kernel's answers and the queue's own counters.

1. **Order.** The order is the order of the `schedule` calls. Records run in event order, which is the kernel's answer that decision 26 already accepts. So two runs that make the same calls and get the same answers run the tasks in the same order.
2. **Budget.** `n = min(tasks.count, tasks_per_tick_max)` is a count of calls made. It is state, not a statistic and not a time. No statistic steers it, which meets decision 9, rule 1. It is not a sample, but it follows the principle of rule 2: it is a function of the operation sequence. It also meets decision 13, point 4.
3. **Wait.** `begin` returns 0 because `tasks.count > 0`, which is a compare of state.
4. **Pointers.** The loop dereferences a task to call `run` and to follow `next`. It never compares, hashes or sorts by address. Two checks compare pointers for equality: `tail == task` in `push` and in `holds`. Each one checks identity and makes no choice. A property test shows that the same tasks at different addresses give the same trace.
5. **No new clock read.** The tick reads the clock where decision 9, rule 4 says. `tasks.zig` takes no `now_ns`.
6. **Lint.** `tools/lint/determinism.zig` holds `src/core/tasks.zig` with no exemption. The run loop's range names `constants.tasks_per_tick_max`, so the unbounded-loop lint has no shape to report.

Decision 4 says that "a loop that moves work is a scheduler, and a scheduler's order is what replay cannot reproduce". This queue moves no work between cores. Its order is a function of the call sequence, so replay reproduces it. The way across threads stays `post`. `schedule` checks the owner, so no thread but the loop's own can queue a task.

## Where it meets the records

- **Decision 2 (scope).**
  - Add a row to "In version one": "tasks: a FIFO of caller-owned records that the tick runs, at most `tasks_per_tick_max` in each tick (`0027-a-task-queue.md`)".
  - Add these to "Not in version one", so that none of them comes in later without a record:
    - scheduling groups and shares;
    - a time quota;
    - preemption of a task in its call;
    - an I/O scheduler such as Seastar's fair queue.
  - `Operation` stays a closed union.
- **Decision 26 (a shared loop).**
  - `records_in_flight` becomes `callbacks_outstanding`.
  - `begin` returns 0 while a task is queued.
  - `end` runs the tasks after the records, inside the `ticking` window.
  - `assert_empty` also halts on a queued task.
  - Its alternative "A router in each library" gains a sentence: a run queue in each library is the same case, and this record answers it.
  - Its ruling 2 should carry issue 14's second ruling. That correction belongs to decision 26.
- **Decision 5, rule 7 (drain).** `drain` also ticks while tasks are queued, and fails with `error.TasksStillQueued` at its bound. `discard_tasks` is the recovery ("Shutdown").
- **Decision 23 (a host that owns the wait).** A queued task never makes `wait_descriptor` readable. So a host that sleeps in its own wait, such as stompy's background worker, follows this rule: before it sleeps on `wait_descriptor()`, it calls `tick` with a wait of 0 while `tasks_queued() != 0`. Decision 23 and decision 26 do not say what a host does after a poller returns true, and the host cannot read that value. Open question 11 asks whether the same rule must cover it.
- **Decision 10 and decision 24 (proposed).** Non-negotiable 3 says that a consumer that needs replay substitutes its own twin of the surface. Decision 24 builds a simulated surface. A twin must now implement `schedule`, `is_scheduled`, `tasks_queued`, `task_budget_left` and `discard_tasks`. It must run the tasks after the records in `end`, with the snapshot rule of "Tick order".
- **Decision 1 (interface).** One more callback shape beside the batch, as decision 26 added. The batch stays the default shape. A task costs one indirect call (C5) and puts no byte in the slot.
- **Decision 4 (threading).** One sentence under "When one core is hot": a run queue in one loop moves no work between cores, and its order replays. Work stealing stays rejected.
- **Decision 9.** No text changes. This record cites rule 1 for the count budget, and "Sample by the clock" for the time quota it rejects.
- **Decision 13.** Three sentences:
  - A queued task, like a poller that returns true, makes the wait 0 and so turns the spin off. A call to `schedule` is a request to spend the core.
  - A run of tasks can make a timer late by up to one run of task time. Point 2 covers the spin only, and a run of tasks is the caller's own work.
  - A run of tasks is not activity for the spin window, so it does not move `active_ns`.
- **Decision 8.** No class changes. The new checks are listed by class below.
- **Decision 7.** This record adds no hot file and no ugly technique. Decision 26 put `@branchHint(.cold)` on `tick_dispatched` in `kqueue.zig`, `uring.zig` and `epoll.zig`. None of these files is on decision 7's list, and the ledger holds no row for them. This record puts more code behind that hint, so the gap matters more. Open question 13 asks Camilo to close it, apart from this record.
- **Decision 17 (proposed).** Its test is "can it be written against rotor's public surface alone?" For one library, the answer is yes: a library can build its queue over a `Poller`. For one order and one budget across all the libraries on a shared loop, the answer is no. Open question 1 puts this choice to Camilo first.
- **Decision 18.** A task must not become a second way to run blocking work on the loop. Blocking work stays with the caller-supplied pool.

## What it costs

Every number here is a prior: arithmetic from `docs/costs.md`, at the `mac` median unless another column is named. Nothing was measured for this record. Under `costs.md` rule 3, no number here may support a claim until the harness measures it.

| case | what it adds | rows | prior |
|---|---|---|---|
| A program with no task, no record and no poller (every workload of the instruction gate) | S0 reads the same two words | none | 0 instructions in each tick, each submit and each event |
| A program with records or pollers, but no task | a compare in `begin`, a compare before `run`, and the class B check in `end` | 3 × C1 | about 2.8 ns in each dispatched tick |
| `schedule`, task line hot | owner check, a load of the task's line for the class A check, the `TasksFull` compare, a load of `tail`, the branch for an empty queue, stores to `tail.next` and `tail`, two increments | C21 + about 5 × C1 | 1.55 + 4.65 = about 6.2 ns |
| `schedule`, task line cold | the same, with the task's line not in cache | C21 + C3 + about 4 × C1 | about 133 ns. The line is often hot, because a library usually writes its parent just before `schedule`. Nothing guarantees it. |
| One task's run, hot | the pop (2 × C1), the indirect call (C5), the decrements (C1) | 3 × C1 + C5 | 2.79 + 1.50 = about 4.3 ns |
| From `schedule` to the end of `run`, hot | the hot rows above | | about 10.5 ns |
| A task record that is cold at the pop | the first touch of the library's line | C3 | +128 ns (`orbstack` 185). This is the library's memory, the same as for a `Completion`. |
| A task with a different function from the one before | one mispredicted call | C4 | +5.77 ns |
| One full run of 64 empty hot tasks | 64 × 4.3 | | about 275 ns, less than one `kevent` (C10, 294 ns) |
| A tick that exists only to run tasks | a full backend tick with a wait of 0: `begin_tick`, the clock read, the flush, the timer check and the drains | C20 + the loop's own work | at least 16.4 ns for the clock, plus the backend's own work, which no row holds. On kqueue a polling tick with nothing to ask the kernel makes no call (decision 12, point 6). On io_uring and epoll the call is not known. The worst case adds C6, 88.9 ns on `orbstack` and 124 ns on `github`. Spread over 64 tasks, the clock alone is 0.26 ns a task. With one task in each tick, the whole tick is the cost. |

For comparison, these are the two ways a library defers a call today:

- **A `nop` that names a `Completion`.**
  - On io_uring it costs C8 + C9 + C5: 51.6 + 11.7 + 1.53 = about 64.8 ns on `orbstack`, or 56.3 + 5.09 + 1.34 = about 62.7 ns on `github`. It also takes one 64 B slot of `operations_max`.
  - On kqueue and epoll, a `nop` finishes inline at the flush, so it costs only the loop's own work. No row holds that work, so this record claims no saving there.
- **A queue in each library, over a `Poller`.** It has the same cost for each task as this record, plus one C5 (1.50 ns) for each poller in each tick. It also takes one of the `pollers_max` (8) poller slots. Three libraries that each budget 64 tasks run up to 192 tasks in one tick, and none of them sees the others' work.

A **time quota**, which this record rejects, would cost this:

- A fresh clock read before each task costs C20 = 16.4 ns. That is 16.4 / 4.3 = about 3.8 times the task's own run.
- One read every 32 tasks costs about 0.5 ns a task.

Either form breaks non-negotiable 2 in core.

**The instruction gate.** The claim that this record makes is only this: case A adds 0 instructions. These runs must prove it:

- `zig build work-gate` on `mac`;
- CI's Linux runners.

The proof is not tight:

- **Layout risk.** `Dispatch` grows by 24 B. The note of 2026-11-05 in `bench/baseline/work.txt` shows that 06549d2 moved the `timer` row of `linux-aarch64-uring` by 19 instructions over the tree before it. Part of that came from a new check, and part from a code layout that no line of the change explains.
- **The epoll `timer` row may be over its tolerance already.** The `linux-aarch64-epoll` section of `bench/baseline/work.txt` holds `timer 1061`. Decision 26 counted that row at 1070 before its change and 1092 after it, with cachegrind in an arm64 container on `mac`. 1092 is 2.9 percent over 1061, past the 2 percent tolerance. Decision 26 did not raise the Linux sections. It is not known whether CI's arm64 runner counts the same as that container. So before this record is built, CI's last count for that row is read. If the row is over its tolerance today, Camilo rules on it apart from this record. If this record then moves a row past 2 percent, the field moves or takes the 8 B form. The baseline is not raised for this record.
- **Cycles the gate cannot see.** The 24 B can move a hot field of `Tables` across a cache line. That costs cycles and not instructions. The cross-core and timer rows are run on a quiet `mac` before and after.

## Alternatives it beat

- **No change: each library keeps its own deferred list, or builds a run queue over a decision 26 `Poller`.** This needs no change to rotor and no amendment of decision 2, and it passes decision 17's test. It is what colibri, cocuyo and stompy do today: three implementations of one queue. It loses on four points:
  - Each library has its own order. Two libraries have no common FIFO.
  - Each library has its own budget, and the budgets add up. No library sees the work of another.
  - Each library takes one of `pollers_max` slots.
  - A task that a callback queues runs one tick later, at the next `begin`, and not in the tick that caused it.

  This is the alternative that the record must beat. Open question 1 puts it to Camilo first.
- **A `nop` with a `Completion` as the task.** It exists today. It costs a slot for each deferred call and, on io_uring, about 63 ns of kernel work (C8 + C9). Its order across a batch is the kernel's, and a task does not need the kernel.
- **Seastar as is.** It has heap continuations, a run queue that grows, a quota from a timerfd, a thread or a kernel ring to set the flag, groups charged by measured time, and a backlog override. Each part breaks a non-negotiable or a bound:
  - the heap breaks non-negotiable 1;
  - the clock breaks non-negotiable 2;
  - the thread breaks non-negotiable 4;
  - the backlog override can livelock (issue 3768).

  This record keeps Seastar's order of "run the tasks after the reactor polls", its rule of "do not sleep with work queued", and its cooperative yield.
- **Tokio's budget.** Each task gets 128 units, and each `.await` on a Tokio resource costs one unit. When the budget is spent, the resources answer "not ready". This is a count and reads no clock, which fits rotor. But rotor's resources are not futures, so no operation can answer "not ready" to a task. The budget that this record keeps is the part that fits: a count of tasks in each tick, of the order of Tokio's `event_interval` of 61. The yield is the task's own check through `task_budget_left()`.
- **A time quota.** Three forms were considered:
  - **The tick's cached `now_ns`.** It does not move inside a run, so a quota from it never stops a run. It could only size the next run from the gap since the last tick. That is an adaptive budget, which decision 13, point 4 forbids without an amendment.
  - **A fresh read every K tasks.** It costs C20 for each read. It also makes the yield point, and so the order of tasks against submissions, a function of the clock. Decision 9 rejected "Sample by the clock" for that reason. If a time quota is ever wanted, it must follow decision 13's spin:
    - the backend reads the clock and core takes it as a parameter;
    - a count bound stays in force;
    - the option is off by default;
    - decisions 9 and 13 are amended first.

    That is a separate record.
  - **A flag that the kernel or a timer sets.** Seastar and Glommio use the completion tail of an aio or io_uring ring. On io_uring with `DEFER_TASKRUN` the kernel posts no completion while user code runs. kqueue has no shared ring, and `mac` is the production bar. A timer thread or a signal breaks non-negotiable 4.
- **Scheduling groups and shares now.** Two designs were considered. One used stride scheduling with a `vruntime` rebase, a clamp at activation, a stated `cost` and 16 groups. The other used deficit round robin with a cursor that persists, a TLA+ model and Lean proofs. No consumer needs shares, and stompy's design refuses them. Each design was three to five times the size of this record. "How groups could come later" keeps the path open.
- **Run the tasks in `begin`, before the pollers.** A task that a callback queued would then run one tick later. In exchange, a poller could see the tasks' work. This record proposes `end` (open question 2).
- **Run the tasks inside each backend's tick.** This needs three copies, adds work to the hot path of every program, and changes `kqueue_tick.zig`, which is at 451 lines.
- **A ring of task pointers with `tasks_max` entries,** as Tokio and Go use with 256. It costs `tasks_max` × 8 B in each loop. It also needs a copy of each pointer, and the intrusive link does not.
- **Run until the queue is empty,** as TigerBeetle's `IO.run()` does. A task that queues itself again never returns from such a run. The snapshot prevents this.
- **An idempotent `schedule` that ignores a second call.** It would remove a halt and hide a class of bugs. `is_scheduled` lets a library offer an item once on purpose.
- **A flag byte or a loop pointer in `Task`, to catch a task queued on two loops.** It makes `Task` 24 B and adds a store to each `schedule`. This record states the rule in the API comment instead, and the class D walk catches a queue that a second loop corrupted.

## How it would be checked

**Unit tests in `src/core/tasks.zig` and `src/core/dispatch.zig`, with no `Loop`:**

1. Tasks run in the order of the `schedule` calls, and each runs exactly once.
2. One `end` runs `tasks_per_tick_max` tasks when 64 + 5 are queued.
3. A task that schedules itself runs once in each `end`. A task that a task schedules does not run in the same `end`.
4. A task that a record schedules inside `call_records` runs in the same `end`, after every record.
5. `begin` returns 0 while a task is queued. It returns `wait_ns` when the queue and the pollers have nothing to do.
6. `idle()` is false while a task is queued, and true after the task runs.
7. `push` with `queued_max` set to 4 returns `error.TasksFull` at the fifth task, and changes nothing.
8. A task that frees its parent in `run` is not written after the call. A Debug build fills the parent with a pattern, and the next run checks that the queue does not read the pattern.
9. `task_budget_left()` reads these values:
   - outside a run, 0;
   - inside a task that is alone in the queue, `tasks_per_tick_max - 1`;
   - inside the first of three queued tasks, `tasks_per_tick_max - 1`, and inside the third, `tasks_per_tick_max - 3`;
   - inside the 64th task of a run of `tasks_per_tick_max`, 0.
10. `shutdown.drain` with no operation in flight and tasks queued runs them. With a task that schedules itself forever, it returns `error.TasksStillQueued` at `drain_rounds_max`. `discard_tasks` then returns 1, `tasks_queued()` is 0, `idle()` is true, and the task's `next` is null. The `Fake` loop of `shutdown.zig` gains `tasks_queued` and `discard_tasks`.
11. Two tasks are queued, and the head schedules itself again from its `run`. The head runs once in this `end`, and once in the next.
12. A task that a poller schedules in `begin` runs in the same tick's `end`.

**A property test, seeded from `core.random`, that prints its seed when it fails (non-negotiable 6).** The generator draws a sequence of steps:

- schedule a new task from the program;
- let a task schedule k more tasks, k in 0 to 3, or schedule itself forever;
- let a poller schedule a task in `begin`;
- deliver a record event that schedules a task;
- run a `begin` and `end` pair;
- discard the queue.

A reference model in the test, a plain list and a loop, computes the task that each step must run, in the style of `timer_heap.zig`'s model. The properties are exact integer checks:

| # | property | check |
|---|---|---|
| P1 | run bound | Each `end` runs at most min(count at the snapshot, `tasks_per_tick_max`) tasks. |
| P2 | snapshot | No task that a task scheduled runs in the same `end`. With a task that schedules itself forever, every `end` returns. |
| P3 | the reference model | Each `end` runs the same sequence of task ids as the model. |
| P4 | progress | A task queued at position k runs within ceil(k / `tasks_per_tick_max`) + 1 ends. |
| P5 | address independence | The same seed, with the tasks in two arrays at different addresses (one reversed), gives the same trace hash. |
| P6 | conservation | scheduled = run + discarded + queued after every step. |
| P7 | the counter | `callbacks_outstanding` = records in flight + `tasks.count` after every step. |
| P8 | replay | The same seed twice gives a byte-identical trace. |
| P9 | the tick of a poller's task | Each task that a poller scheduled in `begin` runs in the same tick's `end`, when it is inside the bound. |

**Conformance scenarios in `src/conformance/conformance_tasks.zig`.** They run on io_uring and epoll in Docker and on kqueue on macOS, and a second time with the spin budget (decision 13):

- **(a) Two libraries on one loop.** Library A queues a task that schedules itself forever. Library B has a receive on a socket pair with a record, and a timer. The checks:
  - Both of B's events arrive.
  - The timer is late by no more than one run, against the same scenario with no task.
  - A's task runs exactly once in each tick.
- **(b) The tick of a task.** A task that a callback schedules runs in the tick that delivered the event. A task that a poller schedules runs in the same tick. A task that a task schedules runs in the next tick. That next tick does not block: a timer of 1 s must not be what ends it.
- **(c) Drain.** `drain` with tasks queued and no operation runs them all, and `deinit` after it does not halt. With a task that schedules itself forever, `drain` returns `error.TasksStillQueued`, and `deinit` after `discard_tasks` does not halt.
- **(d) A cost gate in `conformance_cost.zig`.** It bounds one run of `tasks_per_tick_max` empty tasks, against the best of twenty attempts. The bound is set an order of magnitude above what is measured.

**Halt scenarios.** The core ones go in a new grouped file, `tools/halt/core_scenarios_tasks.zig`, except the dispatch check, which goes in `tools/halt/core_scenarios_dispatch.zig` beside decision 26's scenarios. The owner checks go in `tools/halt/kqueue_scenarios_owner.zig`, `tools/halt/epoll_scenarios_owner.zig` and `tools/halt/uring_scenarios.zig`, beside the owner checks there. No scenario makes a Linux system call after its assertion, so none needs a `*_linux_scenarios.zig` file. Each scenario must die by a signal, and must return once its assertion is deleted.

| check | where | class | halt scenario |
|---|---|---|---|
| A task is not queued already: `task.next == null and tail != task` | `Tasks.push` | A: it adds one load of the task's line | `core_scenarios_tasks.zig`: push one task twice. Once the check is deleted, the second push makes the task its own `next`. The scenario then runs one `run` of 2 tasks and returns. |
| No tick inside a tick, reached from a task | `Dispatch.begin`, already there | A | `core_scenarios_dispatch.zig`: a task that calls `begin` |
| The caller owns the loop | `Loop.schedule`, `is_scheduled`, `tasks_queued`, `task_budget_left`, `discard_tasks` | B: `assert_owner` (C21) | `schedule` from a second thread, in each of the three owner files above |
| `discard_tasks` is not called inside a tick | `Loop.discard_tasks` | A | `core_scenarios_tasks.zig`: a task that calls `discard` through a `Dispatch` with `ticking` set |
| No task is queued at `deinit` | `assert_empty`, extended | C | `deinit` with a task queued, in each of the three owner files above |
| `head != null` and `count >= 1` before each pop | `Tasks.run` | A | `core_scenarios_tasks.zig`: a `Tasks` built by hand with `count = 2`, and one task as both `head` and `tail`. The start check passes, and the second pop finds `head == null`. |
| `tasks.count <= callbacks_outstanding` | `Dispatch.end`, after `call_records` | B | `core_scenarios_dispatch.zig`: one task queued, `callbacks_outstanding` at 1, and `end` called with a fabricated final event that names a record. `call_records` drops the count to 0, below `tasks.count`. |
| `count == 0` if and only if `head == null` if and only if `tail == null`; `count <= tasks_queued_max` | start of `Tasks.run` | B | `core_scenarios_tasks.zig`: a `Tasks` built by hand with `count = 1` and `head == null`, passed to `run` |
| A walk of the queue: its length is `count`, its last node is `tail`, and it ends within `tasks_queued_max` steps | after each push and each run | D | `core_scenarios_tasks.zig`: a `Tasks` built by hand with `count = 3` and two linked tasks, then one `push` |
| `@sizeOf(Task) == 16`, `@sizeOf(Tasks) == 24`, and the relations of the constants | comptime | comptime | none: the compiler refuses the build |

The run loop has no check of the count it ran. Its range is `constants.tasks_per_tick_max`, so that bound cannot fail, and a check of it could not be violated.

`error.TasksFull` and `error.TasksStillQueued` are error values and not assertions, as `error.PollersFull` is. The class A check in `push` adds one load of the task's line. That costs about C1 when the line is hot, and C3 (128 ns on `mac`) when it is cold. The class A checks in `run` read `head` and `count`, which the pop loads anyway, and each costs about one compare and one branch. These are priors. The class A switch of `assertion_options` measures them on the `task` workload below. No assertion is weakened or moved.

**The instruction gate.**

- The five workloads of today must stay within 2 percent on every section, with no new baseline. "What it costs" says what must be read for the epoll `timer` row first.
- Two workloads are added to `bench/work/work.zig`, each with its own baseline line:
  - `task`: one task scheduled and run in each tick. It measures the cost of a tick that exists only to run a task.
  - `tasks_64`: 64 tasks in one tick. It measures the run loop.

**Mutations.** Each one is reported as CAUGHT or NOT CAUGHT, against the narrowest target.

| mutation | target that must catch it |
|---|---|
| `tasks_per_tick_max` ignored | `test-core`, test 2 and P1 |
| the snapshot removed (`count` read on each pass) | `test-core`, test 3 and P2 |
| the pop from the tail (LIFO) | `test-core`, P3 |
| the snapshot taken before the pollers | `test-core`, test 12 and P9 |
| `begin` ignores `tasks.count` | `test-core` test 5, and conformance (b): the tick blocks until the 1 s timer |
| `schedule` does not add to `callbacks_outstanding` | `test-core` test 6, and conformance: the tick takes the fast path and the task never runs |
| the tasks run before `call_records` | `test-core`, test 4 |
| `task.next` not cleared at the pop | `test-core`, test 11: the head still points at the second task, so its second `push` halts |
| `tail` not cleared when the queue empties | `test-core`, P6 and the class D walk |
| the `TasksFull` check skipped | `test-core`, test 7 |
| `drain` ignores `tasks_queued` | `test-core` test 10, and conformance (c) |
| `discard` does not subtract from `callbacks_outstanding` | `test-core`, test 10 (`idle()` stays false) and P7 |
| `task_budget_left` capped at the queue length | `test-core`, test 9 |
| `task_budget_left` not 0 outside a run | `test-core`, test 9 |
| the scheduled-twice check deleted | `halt-check`, `core_scenarios_tasks.zig` |
| the `head != null` check deleted | `halt-check`, `core_scenarios_tasks.zig` |
| the queue-shape check deleted | `halt-check`, `core_scenarios_tasks.zig` |
| the class D walk deleted | `halt-check`, `core_scenarios_tasks.zig` |
| the check in `discard_tasks` deleted | `halt-check`, `core_scenarios_tasks.zig` |
| the owner check in `Loop.schedule` deleted | `halt-check`, each of the three owner files |
| the `deinit` check deleted | `halt-check`, each of the three owner files |
| the check `tasks.count <= callbacks_outstanding` deleted | `halt-check`, `core_scenarios_dispatch.zig` |

**No model yet.** The queue is a FIFO with a count bound. The reference-model property test covers it more cheaply than a TLA+ model or a Lean proof, which a later change to `tasks.zig` would have to update in the same commit. A model comes with groups, if groups come. A task never crosses threads, so the queue needs no race suite of its own. Amended on 2026-11-06: the race gate runs `conformance_storm.zig`, in which other threads post to a loop while its pollers, records and tasks run.

## Open questions

These are in the order that Camilo should rule on them.

1. **Core or a library?** Should the run queue be in core, or should each library build one over a decision 26 `Poller`? The poller form changes nothing in rotor and passes decision 17's test. Core gives one order and one budget across libraries, takes no poller slot, and runs a continuation in the tick that caused it. Proposed answer: core. colibri's `fetch` completions and cocuyo's ready list are the same queue written twice, and stompy wrote a third.
2. **The run point.** Should the tasks run in `end`, after the records? Proposed answer: yes, so a continuation that I/O caused runs in the same tick.
3. **One counter or two?** Should queued tasks fold into `callbacks_outstanding`, with the class B check `tasks.count <= callbacks_outstanding`? Or should `records_in_flight` stay separate, with `idle()` reading a third word? Proposed answer: the separate counter, if the instruction gate shows that it costs nothing measurable, because it keeps decision 26's halt whole. The fold otherwise.
4. **The layout in `Tables`.** Should `Tasks` be inline (24 B, `Dispatch` from 72 B to 96 B) or behind a pointer that the program hands in (8 B, `Dispatch` from 72 B to 80 B)? Proposed answer: inline, so a library needs no setup from the program. The pointer form is the fallback if the gate or a quiet `mac` run shows a move.
5. **The budget.** Is `tasks_per_tick_max = 64` right, and may a caller set a lower budget in `Loop.Options`? Is `task_budget_left` right as guidance that the loop does not enforce? Proposed answer: the constant alone in version one, and the value as defined here. Read colibri's and cocuyo's counts per turn before the value is fixed, and set it from the `tasks_64` workload.
6. **The queue limit.** Is `tasks_queued_max = 65,536` a useful bound? Proposed answer: keep the named limit and `TasksFull`, as TigerStyle and the unbounded-loop lint ask.
7. **The error of `drain`, and its recovery.** Should `drain` fail with a new `error.TasksStillQueued`, with `discard_tasks` as its recovery? The other choice has no recovery: a program that gets the error cannot call `deinit`, so the error acts as an assertion. Proposed answer: the new error and `discard_tasks`, because the kernel holds nothing and a caller must have a way out of an operational error.
8. **The epoll `timer` row.** Decision 26's container count put it 2.9 percent over its baseline. Settled before the ruling: CI counted 1092 on arm64, as the container did, and 89ab0f9 raised the row to it.
9. **Take a task back.** Should there be an `unschedule(task)`? It is O(n) on a singly linked queue, or it needs a back link that makes `Task` 24 B. Proposed answer: not in version one. A library runs its tasks out, or leaves a flag in its own struct and returns early from `run`. `discard_tasks` covers shutdown only.
10. **Tasks and the spin window.** Should `end` report that it ran tasks, so that the callers of `tick_backend` move `active_ns`? Proposed answer: no. A run of tasks is not activity for the window, and the record states it. The other answer amends decision 13 and touches the gate.
11. **A host that owns the wait, and a poller that returned true.** A host cannot read whether a poller returned true, so it cannot apply the rule of decision 23 to it. Proposed answer: keep the rule for tasks in this record, and raise the poller case in decision 23.
12. **Scheduling groups.** Do they come when a consumer shows a measured need? An example is cocuyo's DNSSEC verification against packet I/O: up to 16 RSA-4096 checks for each message, a cost that was recalled and not measured. Proposed answer: wait. Use deficit round robin in task counts, with a stated `cost`, `schedule_in` and models, in a record of their own.
13. **A time quota.** Is one wanted at all? Proposed answer: no, not in this record. If one is wanted later, it follows decision 13's spin: the backend reads the clock, a count bound stays, the option is off by default, and decisions 9 and 13 are amended first.
14. **A task across threads.** Should a `post` be able to carry a task? Decision 26, open question 2 lets a payload carry a record's address inside one process. Proposed answer: no. A library that receives a post schedules its own task from its poller.
15. **Decision 7 and the cold hint.** `@branchHint(.cold)` on `tick_dispatched` in three backend files had no ledger row. Settled before the ruling: d12d078 added the three files to decision 7 for this use, with ledger rows H1 to H3.

## Sources

- Seastar `task.hh`: https://raw.githubusercontent.com/scylladb/seastar/master/include/seastar/core/task.hh
- Seastar `future.hh`: https://raw.githubusercontent.com/scylladb/seastar/master/include/seastar/core/future.hh
- Seastar `reactor.cc` (`run_some_tasks`, `run_tasks`, `account_runtime`): https://raw.githubusercontent.com/scylladb/seastar/master/src/core/reactor.cc
- Seastar `reactor_backend.cc` (how each backend sets the flag): https://raw.githubusercontent.com/scylladb/seastar/master/src/core/reactor_backend.cc
- Seastar `preempt.hh`: https://raw.githubusercontent.com/scylladb/seastar/master/include/seastar/core/preempt.hh
- Seastar `scheduling.hh`: https://raw.githubusercontent.com/scylladb/seastar/master/include/seastar/core/scheduling.hh
- Seastar `CMakeLists.txt` (`SEASTAR_SCHEDULING_GROUPS_COUNT`, default 16): https://raw.githubusercontent.com/scylladb/seastar/master/CMakeLists.txt
- Seastar tutorial (§4, §26): https://docs.seastar.io/master/tutorial.html
- Seastar issue 3768, the backlog livelock: https://github.com/scylladb/seastar/issues/3768
- Seastar commit c175cb5, the quota timer moved from signals: https://github.com/scylladb/seastar/commit/c175cb527806
- ScyllaDB, the I/O scheduler: https://www.scylladb.com/2016/04/29/io-scheduler-2/
- Glommio documentation: https://docs.rs/glommio/latest/glommio/
- Tokio, the 2019 scheduler: https://tokio.rs/blog/2019-10-scheduler
- Tokio, the 2020 preemption budget: https://tokio.rs/blog/2020-04-preemption
- TigerBeetle, `next_tick` (PR 3619): https://tigerbeetle.com/newsletters/2026-06-17-may-in-tigerland
- libuv design: https://docs.libuv.org/en/v1.x/design.html
- libxev: https://github.com/mitchellh/libxev
- Go runtime `proc.go`: https://github.com/golang/go/blob/master/src/runtime/proc.go
- Zig 0.16 release notes, `std.Io`: https://ziglang.org/download/0.16.0/release-notes.html

## What was built

Built on 2026-11-06. The code is `src/core/tasks.zig`, the queue in `src/core/dispatch.zig`, the
calls each backend's `Loop` exports through `core.dispatch.Calls`, and `shutdown.drain`. It
differs from the proposal in four places. The counter this record calls `callbacks_owed` was
renamed `callbacks_outstanding` the same day, by Camilo's choice, because "owed" is not a word
programmers use for it. This record uses the new name.

1. **One counter (open question 3).** The queued tasks fold into `callbacks_outstanding`. With the
   queue in place, a third compare in `idle()` counted 4 more instructions on the work gate's
   `post` and 7 on `post-operation` on `mac`. The gate's counts are the same on every run, so that
   cost is measurable, and the ruling chose the fold. No class B check of
   `tasks.count <= callbacks_outstanding` was built. A scenario cannot prove it: with the check deleted, the run's own subtraction
   underflows and halts. The overflow checks of the subtractions stay.
2. **The class D walk is a function the tests call**, `Tasks.assert_queue`, as the slot table's
   and the timer heap's are. `push` and `run` do not call it.
3. **The owner checks are in one place.** `core.dispatch.Calls(Loop)` holds the pollers' and the
   tasks' calls once, for all three backends. So one halt scenario in each of the kqueue and the
   epoll owner files proves the check.
4. **`end` calls `run` before it subtracts.** A compound `callbacks_outstanding -= tasks.run()` reads the
   count before the call, and loses the 1 that a task adds when it schedules a task. The kqueue
   conformance suite found it as an integer overflow.

### What it measured

The instruction gate, on `mac` with `/usr/bin/time -l`, and on arm64 Linux with cachegrind in a
container on `mac`. A program that schedules no task pays nothing that the gate shows: `post`
counted 1236 against 1241 before this record, on `mac`.

| workload | kqueue | io_uring | epoll |
|---|---:|---:|---:|
| `task`: one tick that runs one task | 610 | 531 | 607 |
| `tasks-64`: one tick that runs 64 tasks | 4407 | 3692 | 3768 |

The cost gate of `conformance_cost.zig` read 31 ns in Debug on `mac` for one task of a full run,
`schedule` and the run together. Its bound is 300 ns.

The work gate first counted 15 more instructions on `post` with the two task workloads added. The
cause was the bench, not rotor: `work.zig` ran every workload through one switch inside one loop,
and the new cases changed how the compiler laid out that loop. It now compiles one loop for each
workload.

### How it is checked

- `tasks.zig`: eight unit tests for order, the budget, the snapshot, a full queue, a task that
  frees its record, `left`, a head that schedules itself, and `discard`.
- `tasks_test.zig`: the seeded property test against a reference model, 64 seeds, each run three
  times: twice to replay, and once with every task at another address.
- `dispatch.zig`: a task that a record queues, a task that a poller queues, a task that schedules
  itself, and `discard_tasks`.
- `dispatch_test.zig`: the seeded property test of `Dispatch` against the reference model of
  `dispatch_test_model.zig`, added on 2026-11-06. It runs 64 seeds of 300 steps, each seed three
  times, as `tasks_test.zig` does. The steps are these:
  - the program adds and removes pollers, and an add can find the table full;
  - the program notes operations with a record, and queues tasks between ticks;
  - a tick calls `begin`, then `end` with a batch of events, or `abandon`;
  - the program calls `discard_tasks` between ticks.

  A batch holds `more` and final events with a record and plain events, in an order that the seed
  shuffles. Records, pollers and tasks queue tasks inside the tick, and a record notes one more
  operation. After every step the test checks P3, P7 and P9, the wait that `begin` returns,
  `idle`, the order of the pollers and the order of the queue. P9 adds no oracle of its own: the
  equal traces of P3 imply it. It also checks that the plain events come back in order, unchanged,
  with `dispatched` clear. The test makes no call that halts by contract.

  On 2026-11-06 I ran nineteen mutations of `dispatch.zig` against `zig build test-core`. Each one
  was CAUGHT, and the property test failed on each one. Seven of them failed no other test:
  - `note_submitted` that counts one for a batch;
  - `idle` that ignores the pollers;
  - `begin` that stops at the first poller that worked, or calls the pollers in reverse order;
  - `call_records` that lowers the count on a `more` event, drops a plain `more` event, or sets
    `dispatched` on a kept event.

  The other twelve mutations also failed a unit test of `dispatch.zig`. They are listed here:
  - `schedule` that does not count, and `discard_tasks` that does not lower the count;
  - `idle` that ignores the count, and `begin` that ignores a queued task or a poller that worked;
  - `end` that runs the tasks first, runs none, or subtracts with a compound operator;
  - `call_records` that does not move a plain event, or skips the record of a `more` event;
  - `remove_poller` that swaps the last poller in, and `add_poller` that refuses one poller early.
- `shutdown.zig`: `drain` runs the queued tasks, and fails with `TasksStillQueued` at its bound.
- `conformance_tasks.zig`, on every backend: a task that never stops beside a timer, where each task
  runs, and `drain`.
- `conformance_storm.zig`, on every backend and in the race gate, added on 2026-11-06: a peer loop
  and three remotes post to a loop that runs pollers, timers with a record, and tasks that schedule
  themselves again. Each sender's messages arrive once and in order, and the count received is the
  posts less the `mailbox_full` refusals. Once the pollers are removed and no task is queued, a tick
  with a wait of 2 s ends soon after a post. The seed of every choice is printed on a failure.
- `tools/halt/core_scenarios_tasks.zig`: six halt scenarios, and one owner scenario in each of the
  kqueue and the epoll owner files.

Mutations, 23, each CAUGHT. Against `zig build test-core`:

- the budget ignored, the snapshot removed, and `push` at the head;
- `begin` that ignores a queued task, `schedule` that does not count, and the tasks run before the
  records;
- the pop that keeps the link or the tail, `push` with no `TasksFull`, and `drain` that ignores the
  queue;
- `discard` that does not lower the count, `left` not reset, and `idle` that ignores the count;
- the compound subtraction, and `end` that runs no task.

Against `zig build halt-check`: the checks of a task queued twice, of a head before the pop, of a
tail beside the head, of the walk, of `discard_tasks` in a tick, of the owner, and of a task left at
`deinit`. Against the kqueue conformance suite: a `Loop.schedule` that skips the count.

### Amendment of 2026-11-06: decision 28

A task holds `call: *const Call`, a static entry with the task's name and its function, as a
record does (decision 26, amendment of 2026-11-06). `Task` stays 16 B. `Tasks.run` stores each
task's name in the loop's heartbeat before it calls the task, so a watch on another thread can name
a task that never returns. Ruling 2 of decision 28 raised the `task` and `tasks-64` rows of
`bench/baseline/work.txt` to the counts that store costs.
