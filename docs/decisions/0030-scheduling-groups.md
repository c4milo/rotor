# 30. Scheduling groups

Status: accepted on 2026-11-07 (see "Ruling, 2026-11-07"), and built on 2026-11-07 on the branch
`decision-30` (see "What was built"). The costs in the sections after "What was built" are
priors: a row of `docs/costs.md` at the `mac` median, or an instruction count from arithmetic over
the code at `5e9490d` and the counts of `bench/baseline/work.txt`. "What was built" holds the
measured counts.

## What was built, 2026-11-07

The groups are built on io_uring, epoll and kqueue, through `src/core/scheduling/` and the public
module. These parts differ from the design below:

1. **The bulk credit adds `r - 1` visits of credit, not `r`.** So the first group of the next pass
   that reaches a credit above 0 starts a task, as `r` passes of skips would do. With `r` visits
   the first group of that pass would take one visit too many. The property test holds the run to
   a model of plain DRR with no bulk credit (G1). The class A check after a bulk credit therefore
   asks for a start within one pass, not at the next visit. `proofs/RotorProofs/Drr.lean` proves
   that the pass starts a task (`bulk_then_start`).
2. **`turn_group` is stored once in each run, by `leave_tasks`, with the group of the last task.**
   A stall names a group only when its turn called one task, and then the last task is that task.
3. **`task_budget_left` on the groups path** reads the ready mask at the call. With no other group
   ready, it answers the starts left in the tick.
4. **The class B check of a ready lane** holds its count, its head and tail, and the sum of the
   counts. `startable <= count` moved to `Groups.assert_lanes` (class D), because the run's snapshot
   writes `startable` again before it reads it.
5. **`Task.Call.cost` has a default of 1**, so a `Call` written by hand compiles unchanged. The
   groups path halts on a cost outside 1 to `task_charge_max` (class A).
6. **`charge_task` on the path with one group** checks that one call charges at most
   `task_charge_max`. It cannot check the sum of a task's charges there without a write for each
   task.
7. **The compile-fail cases of the named groups are programs.** A test's root is Zig's test runner,
   so `build/compile_fail.zig` builds those five files as executables, with a `program` flag on
   each case. "How tests name groups" said that no file under `build/` changes.
8. **`Loop.memory_bytes` is no longer a multiple of 64 bytes**, because `Groups` is 536 B. The
   echo server rounds each loop's block of its array up to `memory_alignment`.
9. **`Dispatch` stays 104 B**, not 96 B: decision 29's `until_ns` is in it.
10. **Not built, because their records are not built:** the limit `tasks_queued_max +
    call_tasks_max`, `Task.Call.call_record` and the halt of `discard_tasks` on a call's task
    (decision 32), and the count of `TasksFull` for each group (W9).

Two class A checks have no halt scenario, because no parameter reaches them (decision 8): a run
ends within `visits_per_run_max` visits, and a bulk credit is followed by a start. A mutation that
removes the bulk credit makes the first halt in `zig build test-core`.

**The default shares and `task_charge_max` are not fixed yet** (open question 9). The build uses
the proposed 100 and 64. The work gate's new rows, with every group at one value of the shares, on
`mac` (`/usr/bin/time -l`, an M1 Pro, macOS 26.6.2, a load average of about 20) and on arm64 Linux
(cachegrind of Valgrind 3.25.1 in an arm64 container on `mac`):

| row | shares | `mac` kqueue | arm64 io_uring | arm64 epoll |
|---|---|---|---|---|
| `tasks-64`, for comparison | none | 4555 | 3922 | 3954 |
| `tasks-groups-4` | 100 | 12939 | 12328 | 12359 |
| `tasks-groups-4` | 200 | 10721 | not measured | not measured |
| `tasks-groups-4` | 400 | 9630 | 9004 | 9035 |
| `tasks-groups-4` | 1000 | 9085 | not measured | not measured |
| `tasks-groups-16` | 100 | 13622 | 13012 | 13043 |
| `tasks-groups-16` | 400 | 10309 | 9697 | 9728 |

At the default shares a visit starts one task, and `tasks-groups-4` counts about 2.8 times
`tasks-64` on `mac`, against the prior of 1.3 times. A visit costs about 69 instructions on `mac`,
from the rows at 100 and 400. The other 60 or so for each task are `schedule_in` and the start of
a task on the groups path, which ReleaseSafe checks. No line of `bench/baseline/work.txt` changed.

The older rows on `mac` stay within their lines. On arm64 Linux the path with one group counts more
than the base commit `cb38fef`: io_uring `post` +2, `post-operation` +4, `task` +8, `record` +7
and `poller` +6, and epoll `task` +10, `record` +9 and `poller` +8. That path gains a store of
`turn_group` in `leave` and `leave_tasks` and a store of `phase` before a run, and no count
separates the two. At `cb38fef`,
io_uring `post`, `task` and `poller` were already over their lines with Valgrind 3.25.1. With the
change, `post-operation` and `record` are over too.

## Ruling, 2026-11-07

Camilo ruled on decisions 30, 31 and 32 together. For this record:

1. **This record is accepted** with the proposed answer to each open question, and with the items
   of "Ask before" that the proposal held.
2. **Groups have names.** He ruled on decision 32 that the caller of a cross-core call names the
   group that the call runs in on the target. Seastar does the same. So decision 30 gains groups
   by name, and every loop agrees on what a group is. "Named groups" below is the design.
3. **Decision 31 is accepted for capacity and shares.** Its rate rule waits for its own ruling, and
   the W7 disk bench runs before decision 31 is built.
4. **The build order** is W3 (the fair tick order), decision 29, this record, then decision 32.
   Decision 31 follows the W7 bench.

Later the same day he ruled on the four choices that the named groups added, each with its proposed
answer. Before this ruling, the list "Left for Camilo" held them:

5. **The program declares its names in its root source file**, as `rotor_scheduling_groups`. The
   public module `rotor` reads it through `@import("root")`, as std reads `std_options`, and passes
   its table to each loop at init. Core reads no root file. A program then has one declaration, and
   a mismatch cannot compile. The other choice was a table that the program hands to the
   `Registry`, and two registries could then hold two tables.
6. **A named group's shares come from the declaration at init.** One loop may change its own
   shares with `set_scheduling_group_shares`, as Seastar's `set_shares` acts on its own shard. The
   other choice was one value for every loop, with no change after init.
7. **Core's machinery is generic over a comptime table, and each test passes its own table.** No
   custom test runner is added. "How tests name groups" gives the reasons.
8. **The default shares and `task_charge_max` are fixed from the `tasks-groups-4` row** before the
   build lands (open question 9). The other choice was to fix them before the record is accepted,
   which would undo the acceptance until the row exists.

He also ruled that a cross-core call carries a task of its own, as a Seastar `work_item` is a
task. The same ruling removed the call lanes (decision 32, "Ruling, 2026-11-07"). So `Groups` holds
no call lanes. Later the same day he ruled on two choices of that design that touch this record,
each with its proposed answer (decision 32, ruling items 11 and 12):

9. **A call's task has its own limit.** Decision 32 pushes a call's task with the limit
   `tasks_queued_max + call_tasks_max` = 82,368, a call to self included. So the cap of each group
   refuses only `schedule` and `schedule_in`. The eight bounds of "A queue cap for each group"
   read that sum.
10. **`Task.Call` gains `call_record: bool`** in its padding, so `discard_tasks` can halt on the
    queued task of a call. `Task.Call` stays 32 B.
11. **The comptime assert `tasks_per_tick_max <= task_charge_max` stays, for a new reason.** The
    proposal gave decision 32's lane run as its reason, and the lane run is gone. The charge of the
    guidance for a cost that varies is at most `task_budget_left()`. The assert keeps that charge at
    or under `task_charge_max`.

It builds on decisions 26, 27 and 28, and it fits with defect 3 of the robustness plan (W3, the fair
tick order), which is ruled and is built before decision 29. It amends these records:

- decision 2, because decision 27 put "scheduling groups and shares" in "Not in version one";
- decision 27, at "How groups could come later", open question 12, `holds` and `tasks_queued`;
- decision 28, at `SharedLoop`'s refused calls, `Stall` and the heartbeat;
- decision 9, rule 7, because open question 6 is ruled (b): an exact count of `TasksFull` for each
  group, with W9;
- decision 29, because open question 1 is ruled yes: its `reserve_group` and `GroupsFull` become
  `reserve_buffer_group` and `BufferGroupsFull`. Decision 29's own file still holds the old names.
  A separate change to that file follows this record.

## Context

On 2026-11-07 Camilo chose to add three features of Seastar to rotor: scheduling groups, a disk I/O
scheduler and a cross-core call helper. This record is the first of the three. Decision 31 is the
disk I/O scheduler, and decision 32 is the cross-core call helper.

The consumer is stompy. It runs one loop for each CPU core. colibri (QUIC and HTTP) and cocuyo (DNS)
share each core's loop with stompy's journal and object store. Today each library queues its
deferred work as tasks in one FIFO (decision 27). One budget of 64 starts in each tick serves all of
them in the order of the `schedule` calls. So a library that queues many tasks takes most of the
core. Seastar's tutorial shows the same effect: 1,000 fibers against 1 take about 90 percent of the
CPU (decision 27, "How groups could come later").

Decision 27 said what a later record must state:

- **The rule.** Deficit round robin (DRR), with a cursor and a deficit that persist across ticks.
  Ties break by group index and never by address.
- **The cost.** Fairness in tasks is not fairness in CPU time. A cost that the caller states is the
  deterministic repair, because Seastar's measured run time needs the clock.
- **The models.** A Lean proof of the bounds comes with groups.

Seastar's design (`scheduling.hh`, read for the drafts of this record on 2026-11-07):

- `create_scheduling_group(name, shares)` makes a group on every shard. The header recommends
  shares from 1 to 1000.
- `set_shares` acts only on the shard that calls it.
- `max_scheduling_groups()` is a build constant. Its default of 16 is from `CMakeLists.txt`, which
  decision 27 read.
- `scheduling_group::update_io_bandwidth` exists, so the group also carries the I/O limits. rotor
  does not follow this: decision 31 gives its I/O classes an index space of their own (its open
  question 1).

Seastar charges a group by its measured run time (recalled from decision 27's reading of
`reactor.cc`). That reads the clock at each switch of group, and non-negotiable 2 excludes it. So
rotor charges a group in **cost units that the task states**, and never in time.

Camilo's requirements apply: wrong use fails to compile, and where the compiler cannot see it, it
halts at once. A program that uses no group runs decision 27's code within the work gate's 2
percent.

## The decision

1. **A group is a task queue with shares, on one loop.** Each loop has a fixed table of
   `scheduling_groups_max` (16) groups, carved from its memory at init. Group 0, `.default`, is
   today's queue.
2. **The program declares or reserves the groups, and hands each library its group at init.**
   Shares are the program's policy. `SharedLoop` refuses the reserve and the change of shares with
   a compile error.
3. **A library names its group in each `schedule_in`.** `SharedLoop` refuses the plain `schedule`,
   so a library cannot put a task in `.default` without the word `.default` in its source.
4. **The loop serves the groups by DRR in cost units.** A task costs 1 unit, or a comptime cost
   from `Task.init_cost`, plus the units it adds with `charge_task`. Shares are in hundredths of a
   unit, so equal groups at the default shares take turns task by task.
5. **The tick bound does not change.** One tick starts at most `tasks_per_tick_max` (64) tasks in
   every mode. A cost changes how the groups share the loop. It does not change how long a tick is.
6. **Records and pollers are not in groups.** W3 bounds which events reach a tick. This record
   bounds which tasks run after them.
7. **A named group is the same group on every loop.** The program declares its named groups once,
   in its root source file. Each loop reserves them at init as ids 1 to n, in the order of the
   declaration. A cross-core call names one (decision 32).

The record adds six public names: `SchedulingGroup`, `reserve_scheduling_group`,
`set_scheduling_group_shares`, `schedule_in`, `charge_task` and `Task.init_cost`. Named groups add
three more: `SchedulingGroupName`, `NamedSchedulingGroup` and `named_scheduling_group`, with the
method `NamedSchedulingGroup.scheduling_group`. The public module `rotor` also reads one declaration
of the program's root file, `rotor_scheduling_groups`.

### The surface

```zig
// src/core/scheduling.zig (new). Pure: it takes no *Loop and reads no clock. Exported from rotor.

/// A task queue with shares on one loop (decision 30). Only `reserve_scheduling_group` and
/// `NamedSchedulingGroup.scheduling_group` make an id other than `.default`, so a literal fails to
/// compile. An I/O class of decision 31 is a separate id, `IoClass`. Size 1 B.
pub const SchedulingGroup = enum(u8) { default = 0, _ };
pub const ReserveSchedulingGroupError = error{SchedulingGroupsFull};

// src/core/tasks.zig: Task stays 16 B. Its static Call gains `cost`, and grows from 24 B to 32 B.
pub const Call = struct {
    name: [:0]const u8,
    function: *const fn (task: *Task) void,
    /// The units that one run costs before any `charge_task`. `init` sets 1.
    cost: u16,
};
/// As `init`, with a cost that the compiler checks: 1 <= cost <= task_charge_max.
pub fn init_cost(
    comptime Parent: type,
    comptime field: []const u8,
    comptime handler: fn (parent: *Parent) void,
    comptime cost: u16,
) Task;

// rotor.Loop only. SharedLoop refuses both: "only the program sets the groups and their shares".
/// Reserves the lowest free id with `shares` (1 to scheduling_shares_max). The named groups hold
/// ids 1 to n from init, so the first reserve returns n + 1. The id belongs to this loop only. It
/// is the program's until `deinit`, and no call gives it back (as decision 29's buffer groups).
pub fn reserve_scheduling_group(loop: *Loop, shares: u16) ReserveSchedulingGroupError!SchedulingGroup;
/// Sets the shares of `.default` or of a reserved group. It counts from the group's next visit.
pub fn set_scheduling_group_shares(loop: *Loop, group: SchedulingGroup, shares: u16) void;

// rotor.Loop only: unchanged, and the same as schedule_in(.default, task). SharedLoop refuses it:
// "a library names its group: schedule_in(group, task)".
pub fn schedule(loop: *Loop, task: *Task) ScheduleError!void;

// rotor.Loop and SharedLoop.
/// Queues `task` in `group`. Returns TasksFull when that group holds tasks_queued_max tasks.
pub fn schedule_in(loop: *Loop, group: SchedulingGroup, task: *Task) ScheduleError!void;
/// Inside a task's run only: adds `units` to the cost of the task that runs now.
pub fn charge_task(loop: *Loop, units: u16) void;
```

These calls keep their names and change as stated:

| call | with groups |
|---|---|
| `is_scheduled(task)` | true when the task is queued in any group of the loop |
| `tasks_queued()` | the sum over all groups |
| `task_budget_left()` | the smaller of the starts left in the tick and the whole units left in the group's visit; with no other group ready, today's value |
| `discard_tasks()` | unlinks every group, and resets every deficit, the cursor and the open visit. It halts on the queued task of a call of decision 32. |
| `drain`, `deinit` | read the sum, so `TasksStillQueued` and the `deinit` halt cover all groups |

Use in stompy's program, and in a library:

```zig
// stompy's root source file: the groups that a cross-core call can name.
pub const rotor_scheduling_groups = .{ .quic = 400, .dns = 100, .journal = 200 };

// stompy's program, on each core. colibri makes cross-core calls, so its option is a
// NamedSchedulingGroup.
var server = try colibri.Server.init(loop.shared(), .{
    .scheduling_group = rotor.named_scheduling_group(.quic),
});
// stompy's compactor makes no call. Its group needs no name, and its option is a SchedulingGroup.
const compaction = try loop.reserve_scheduling_group(50);
var compactor = try Compactor.init(loop.shared(), .{ .scheduling_group = compaction });

// colibri, inside the library: the named group gives the id for its own schedule_in.
const group = server.scheduling_group.scheduling_group();
try server.loop.schedule_in(group, &connection.task);
```

A library option takes a `NamedSchedulingGroup` when the library makes cross-core calls. It takes a
`SchedulingGroup` when the library makes none. A `SchedulingGroup` does not convert to a
`NamedSchedulingGroup`, so the compiler refuses a reserved group where a call needs a name.

### Named groups

Camilo ruled this design on 2026-11-07 (items 5 to 7 of the ruling).

A reserved id belongs to one loop. Two loops that reserve in two orders give one id two uses. A
cross-core call names the group that it runs in on the target (decision 32). So a group that a
call names must be the same group on every loop.

The program declares its named groups once, in its root source file. The field order is the id
order, and each value is the group's shares at init. Core never reads the root file: its machinery
is generic over a comptime declaration. The public module `rotor` binds the public names to the
root's declaration. It reads it through `@import("root")`, as std reads `std_options`.

```zig
// src/core/scheduling.zig. Core reads no root file.

/// The named groups of `declaration`, a struct literal such as `.{ .quic = 400, .dns = 100 }`.
/// It refuses the name `default`, shares of 0 or above scheduling_shares_max, and more than
/// scheduling_groups_max - 1 names, with a compile error.
pub fn Named(comptime declaration: anytype) type {
    return struct {
        /// The names, in the order of the declaration: `enum { quic, dns }`.
        pub const Name: type;
        /// The count n and the shares of ids 1 to n, for a loop's options.
        pub const table: NamedTable;
        /// The id is 1 plus the name's place in the declaration.
        pub fn group(comptime name: Name) NamedSchedulingGroup;
    };
}

/// What `Loop.init` reserves: n, and the shares of ids 1 to n. Size 32 B, alignment 2.
pub const NamedTable = struct { count: u8, shares: [constants.scheduling_groups_max - 1]u16 };

/// A group that is the same group on every loop of the program. Only `Named(...).group` makes an
/// id other than `.default`, so a literal fails to compile. Size 1 B.
pub const NamedSchedulingGroup = enum(u8) {
    default = 0,
    _,

    /// The same id as a `SchedulingGroup` of the loop that calls it, for `schedule_in`.
    pub fn scheduling_group(group: NamedSchedulingGroup) SchedulingGroup;
};

// src/rotor/rotor.zig, the public module. Built from the root's `rotor_scheduling_groups`, and
// empty when the root declares none.
const root_groups = core.scheduling.Named(root_declaration);
pub const NamedSchedulingGroup = core.scheduling.NamedSchedulingGroup;
/// The program's names: `enum { quic, dns, journal }` for stompy. An undeclared name fails to
/// compile.
pub const SchedulingGroupName = root_groups.Name;
pub fn named_scheduling_group(comptime name: SchedulingGroupName) NamedSchedulingGroup;
```

These rules apply:

- **A program has one declaration.** Its root file holds it. The backends' `Loop.Options` gain a
  field `named_groups: NamedTable`, empty by default. The public `Loop.Options` does not carry it:
  its `lower` (`src/rotor/rotor_loop.zig`) sets it to `root_groups.table` for every loop. So two
  loops of a program cannot disagree, and no check at run time is needed.
- **Every loop reserves the names at init.** `Loop.init` gives ids 1 to n their declared shares,
  before any `reserve_scheduling_group`, and stores n in `Groups.named`. So a named group exists on
  every loop from its first tick, and a target cannot lack one.
- **`Named` checks the declaration** at comptime, with the limits above.
- **Shares belong to each loop.** `set_scheduling_group_shares` changes them only on the loop that
  makes the call, as Seastar's `set_shares` acts only on its own shard. The name and the id do not
  change.
- **A forged id halts.** `@enumFromInt` compiles, as it does for decision 29's `BufferGroup`.
  Decision 32's `send` halts on an id above n, and the target checks the id again.
- **A library takes a `NamedSchedulingGroup` from the program** when it makes calls. It calls
  `scheduling_group()` for its own `schedule_in`. The compiler does not stop a library that calls
  `named_scheduling_group` itself, because `SchedulingGroupName` comes from the program's root. The
  guide says that the program hands each library its group, as rule 2 says.
- **A loop that uses no names pays nothing new.** The names are comptime. `Loop.init` writes the
  shares of n lanes, and no path of a tick reads the table.

### How tests name groups

The root of `test-core`, of the conformance executables and of the halt runner is not the program.
For a test, root is Zig's own test runner, which declares no `rotor_scheduling_groups`. So a test
cannot rely on the root's declaration. This record chooses the generic machinery above, and no
custom test runner. Camilo ruled it on 2026-11-07:

- A unit test in core calls `Named(.{ .low = 100, .high = 300 })` and passes its `table` to
  `Groups.reserve_named`.
- A conformance scenario passes such a table in the backend's options, so `Loop.init` reserves it.
  Each scenario can choose its own table, n = 0 included.
- A halt scenario file is the root of its own executable (`build/halt.zig`). A scenario that goes
  through the public module declares `rotor_scheduling_groups` in that file. A scenario that goes
  through core passes a table.
- The compile-fail tests are each the root of their own program, so each declares what it needs.

The other choice was a `test_runner` in `build/` for `test-core`, the conformance executables and
the halt runner, which declares `rotor_scheduling_groups`. It lost for three reasons:

- It is a copy of Zig's test runner, which rotor must keep in step with each Zig release.
- It gives every test of an executable one declaration. A test could not try two tables, or n = 0,
  in the same executable.
- Core would read the root file, so core's types would depend on the program. No core type does
  that today.

This choice adds no build step and changes no file under `build/`. It adds one field to the
backends' options, which "Ask before" lists.

### The rule: DRR in cost units

| term | meaning |
|---|---|
| unit | a task unit: the cost of one run of a task with cost 1. The guide states a unit as one slice of the size that decision 27's guidance asks for. Nothing in core measures it. Decision 31's I/O unit, 4 KiB moved, is a different measure. |
| shares | 1 to 1000, in hundredths of a unit (`scheduling_unit_credit` = 100). The default of 100 gives one unit at each visit. |
| deficit | a group's credit in hundredths of a unit, an `i32` that persists across ticks |
| visit | the span in which the cursor stays at one group |
| startable | the group's count at the start of the run: decision 27's snapshot, for each group |

`run_groups` does these steps:

1. **Snapshot.** For each ready group, `startable = count`. A task that a task queues runs in the
   next tick, as decision 27 says.
2. **Visit.** From `cursor`, take the next group with `startable > 0`: rotate the ready mask, then
   count its trailing zeros. If the visit is not open, add `shares` to `deficit` and open it.
3. **Start.** While `deficit > 0` and `startable > 0` and the tick has starts left, pop the head,
   subtract `cost * 100` from `deficit`, and call the task. `charge_task` subtracts more during the
   call. A deficit can become negative: that is debt, and later visits repay it.
4. **Close.** When `deficit <= 0` or `startable == 0`, set `deficit = @min(deficit, 0)`: unused
   credit is dropped and debt is kept. Clear the ready bit if the group is empty, close the visit,
   and move the cursor on.
5. **Bulk credit.** If one full pass over the startable groups starts no task, every one is in debt.
   Add `r * shares` to each, with `r = min over them of ceil((1 - deficit) / shares)`. That is the
   result of `r` passes of debt skips, in one pass of arithmetic. The next visit then starts a task.
6. **Stop** after `tasks_per_tick_max` starts, or when no group has `startable > 0`. The cursor, the
   open visit and each deficit persist. A visit that the tick's bound cut resumes in the next tick
   and gets no second credit.

The visit loop's range is `visits_per_run_max = tasks_per_tick_max * (2 * scheduling_groups_max + 1)`,
a named constant derived at comptime. Each start uses at most two visits of each group (one skip,
one start), plus one bulk credit, so the range bounds the run. The unbounded-loop lint sees the
bound in the loop's form.

**Bounds that the proof and the property test hold:**

- Each deficit stays in `[1 - task_charge_max * 100, shares_max]`.
- Over `n` rounds in which a group `g` stays startable, the units it is served differ from
  `n * shares_g / 100` by less than `task_charge_max`. The units served in a visit are
  `shares + deficit_before - deficit_after`, so the sum telescopes.
- A group with a deficit at or above 0 at the start of a round starts a task in that round. A round
  holds at most `sum over the other groups of ceil(shares / 100)` starts, so it ends within
  `ceil(that / 64) + 1` ticks. At 15 other groups at 1000 shares, that is 4 ticks.
- A group in debt `d` waits `ceil((1 - d) / shares)` rounds. A large charge at small shares is a
  long wait, and that is the fairness the shares ask for.

**The path with one group.** `Dispatch` holds a ready mask of groups 1 to 15. When it is 0 at the
start of `end`, only `.default` can hold tasks, and `end` runs decision 27's `Tasks.run` unchanged.
That run keeps no account: when no other group waits, DRR gives `.default` the whole budget anyway.
A `charge_task` in it checks its bound and changes no deficit. So a program that reserves no group
runs decision 27's run, and a program with groups pays the groups path only in a tick where a group
other than `.default` holds a task.

### How a task states its cost

- **A fixed cost:** `Task.init_cost(Parent, "task", run, 4)`. The compiler refuses 0 and values
  above `task_charge_max`. The groups path reads `call.cost` from the static `Call`, on the line of
  `function`.
- **A cost that varies:** the task calls `charge_task(units)` before it returns. Decision 27's
  guidance becomes a count that the loop keeps: do at most `task_budget_left() + 1` slices, then
  call `charge_task(slices - 1)` when there were more than one, then schedule again if work is left.
- **A task that understates its cost** takes more CPU than its shares. The stall record names it,
  with its group (below).

### Records and pollers

Records and pollers are not in groups and are not charged:

- A record is the final event of an operation. The tick calls it when the kernel answers
  (non-negotiable 5). To hold it back, the loop would need a store for the event, and it allocates
  nothing. A deferral would also break decision 26's rule that records run in event order.
- A poller runs once in each tick, and `pollers_max` (8) bounds them.
- W3 bounds the records of a tick through the `events` slice, a rotating sender cursor and the
  reserves of event slots.

The guide states the rule: a record or a poller does a small, fixed amount of work, and puts the
rest in a task in its library's group. A record that does too much shows in the stall record by
name. Decision 31 charges a disk operation to its I/O class, not to a group, in I/O units of bytes
and operations.

### Stalls and counts

- **`Stall.group: ?SchedulingGroup`** fills 2 B of the 4 B of padding after `callbacks`, so `Stall`
  stays 32 B. `note_stall` writes it when `callbacks == 1` and that callback was a task. It is part
  of the stall record of decision 9, rule 7, and no control flow reads it.
- **`Heartbeat.turn_group: u8`** fills padding after `watchers`. `end` stores "none" before its
  records. The groups path stores the group once at each visit, and the path with one group stores
  0 once in each run. So a stall of one task names its group, and a stall of one record names no
  group.
- **No count on the hot path.** An exact count of the units or tasks of each group is a write for
  each task. CLAUDE.md's rule is that statistics are sampled, and rule 7 is the one exception, for a
  stall. Open question 6 asks about a count of `TasksFull` for each group on the refusal path, which
  W9 would hold.

## Layout

| structure | change | size, alignment | where |
|---|---|---|---|
| `SchedulingGroup` | new, `u8` | 1 B | the caller's |
| `NamedSchedulingGroup` | new, `u8`; ids 1 to n are the declaration's | 1 B | the caller's |
| `NamedTable` | new: `count: u8`, `shares: [15]u16`, in the backends' `Loop.Options` | 32 B, 2 | the options, read once at init |
| `Dispatch` | `ticking: bool` and `polling: bool` become `phase: Phase` (`u8`: idle, polling, records, tasks, group_tasks). `groups_ready: u16`, the ready mask of groups 1 to 15, takes the freed byte and the 1 B of padding | **stays 96 B, 8** (64 + 24 + 4 + 2 + 1 + 1). A build confirms it. | `Tables` |
| `Tasks` | no field changes. `count` stays the count of `.default` only, so `run` stays true. By ruling item 9, a call's task in `.default` can take `count` above `tasks_queued_max`. So four bounds read `tasks_queued_max + call_tasks_max`. They are the assert in `push`, the count check in `assert_shape`, the loop bound of `discard`, and the walk bound of `assert_queue` | 24 B, 8 | `Dispatch` |
| `Lane` | `head`, `tail` (8 + 8), `count: u32`, `startable: u32`, `deficit: i32`, `shares: u16`, 2 B pad. Lane 0 keeps its queue in `Dispatch.tasks` and uses only `startable`, `deficit` and `shares` | 32 B, 8 | `Groups` |
| `Groups` | `lanes: [16]Lane` (512 B), `end_mark: Task` (16 B), `reserved: u8`, `cursor: u8`, `visit_open: bool`, 5 B pad. Decision 32 puts its cold counts `stations: u8` and `serving: u8` in 2 B of the pad. `named: u8`, n, takes 1 B more of the pad, and `reserved` is n after init. Decision 32 adds nothing else: a call carries its own task, and `Groups` holds no call lanes. | 536 B, 8 | carved from the loop's memory by `Layout.take`, as decision 28's heartbeat is |
| `Tables` | gains `groups: *Groups` | + 8 B | — |
| `Task.Call` | gains `cost: u16`, and `call_record: bool` in its padding (ruling item 10), true only for the entries of decision 32's calls | 24 B to 32 B, static data | the binary |
| `Stall` | gains `group` in its padding | stays 32 B | `Statistics` |
| `Heartbeat` | gains `turn_group: u8` in its padding | no change in size. A build confirms it. | its own line |

Each loop's memory grows by 544 B. The new structures carry comptime asserts of their sizes. The
size of `Groups` does not depend on n, so its assert is one constant.

**The end mark.** Groups 1 to 15 end their queues at `&groups.end_mark`, not at null. So a task that
is queued in any group of any loop has a `next` that is not null, or is the tail of `.default`. The
class A check in `push` stays the one it is today, `task.next != null or tasks.tail == task`, and it
now catches a task queued twice in any two groups of one loop. It also catches a task at the tail of
a group of another loop, which decision 27's check missed. The mark is never called: the pop
compares the next head with it before any call. The compare is one of identity, as `tail == task`
is, and it decides nothing from an address's value.

**A queue cap for each group.** Each group refuses at its own `tasks_queued_max` (65,536). So a
library that floods its group gets `TasksFull`, and the other libraries on the core can still
schedule. The overflow assert of `callbacks_outstanding` becomes
`scheduling_groups_max * tasks_queued_max + operations_max <= maxInt(u32)`. Decision 32 adds its
call tasks and its calls to that sum.

By ruling item 9, the cap refuses only `schedule` and `schedule_in`, the calls of the program and
of a library. Decision 32 pushes a call's task with
the limit `tasks_queued_max + call_tasks_max`. So a program that fills a group cannot make a drain
fail. `call_tasks_max` is 16,832 (decision 32, "The task queue and the fair tick"). Each bound of a
queue's length reads that sum:

- in `Tasks`, for `.default`: the assert in `push`, the count check in `assert_shape`, the loop
  bound of `discard` and the walk bound of `assert_queue`;
- in `Groups`, for groups 1 to 15: the assert of a lane's push, the count check of a lane's shape,
  the loop bound of a lane's discard and the walk bound of `Groups.assert_lanes`.

With the old bound, `discard` stops after 65,536 tasks. A call's task behind 65,536 tasks of the
program is then not reached, and `discard_tasks` does not halt on it by name.

## Tick order

- **`begin`** returns a wait of 0 when `worked or tasks.count != 0 or groups_ready != 0`. The mask
  is on `Dispatch`'s line, beside `tasks`.
- **`end`** stores "none" in `turn_group`, calls the records, then runs
  `if (groups_ready == 0) tasks.run(heartbeat) else groups.run(dispatch, heartbeat)`, and subtracts
  the starts from `callbacks_outstanding`, as today.
- **`idle()`** does not change. `callbacks_outstanding` already counts the tasks of every group.
- **The heartbeat** names each task before its call, on both paths, as decision 28 says.

## Determinism

- The order is a function of the program's calls (the reserves, the shares, the `schedule_in`
  calls, the costs and the charges) and of the kernel's answers through the records.
- Nothing reads the clock, `std.Random` or uninitialised memory. Ties break by group index.
- The loop compares two addresses only for identity: `tail == task`, and a next head against the
  end mark. A property test runs the same tasks at other addresses and gets the same trace.
- `tools/lint/determinism.zig` holds `scheduling.zig` with no exemption.
- Decision 4 says that a scheduler's order is what replay cannot reproduce. That is a scheduler that
  moves work between cores. This one moves nothing, and its order replays from the call sequence.

## Where it meets the records

| record | how |
|---|---|
| W3, the fair tick order | W3 decides which events, and so which records, reach a tick: a rotating sender cursor and reserves of event slots. This record decides which tasks run after the records. The two keep separate state, both are a cursor and a count with no clock, and tasks take no event slots. A tick still returns to the backend after at most 64 starts, so each tick still reaches W3's mailbox drain. |
| decision 2 | Remove "scheduling groups and shares" from "Not in version one", and add a row to "In version one". A time quota and preemption stay out. |
| decision 27 | `schedule(task)` stays on `Loop`. `tasks_per_tick_max` and `Tasks.left` keep their meaning. `holds`, `tasks_queued` and `discard_tasks` cover every group. Its open question 12 is answered. |
| decision 28 | `SharedLoop` refuses `schedule`, `reserve_scheduling_group` and `set_scheduling_group_shares`, and gains `schedule_in` and `charge_task`. `Stall` and the heartbeat gain the group. |
| decision 29 | A wake reaches a poller, and the poller schedules into its library's group. Open question 1 renames its `reserve_group`. |
| decision 31 | Its I/O classes are a separate index space, `IoClass`, bounded by `io_classes_max` for each loop's queue (its open question 1). A file operation names a class, not a group, and the task that submits it does not change the class. `scheduling_groups_max` bounds only the groups of this record. |
| decision 32 | A call names a `NamedSchedulingGroup`, which crosses in the call's record. Each record carries its own `Task`. On the target, the drain schedules that task in the named group, and the task runs the handler. On the caller, the drain schedules the same task in the same group, and the task runs `finish`. Each run is one task of cost 1, and a handler that does more calls `charge_task`. `discard_tasks` halts on the queued task of a call. The overflow assert above gains the call tasks and the calls. |
| decisions 10 and 24 | A twin of the surface brings the new names, with the same DRR order. |
| decision 13 | A run of tasks is not activity for the spin window, in every group. |

## What it costs

Priors only. The baseline counts are from `bench/baseline/work.txt` at `5e9490d`: `task` 630,
`tasks-64` 4558 and `poller` 588 on `macos-aarch64-kqueue`, and `tasks-64` 4158 on
`linux-x86_64-uring`.

| case | what it adds | prior |
|---|---|---|
| a tick on the fast path (no record, poller or task) | nothing: `idle()` reads the same two words | 0 instructions |
| a dispatched tick, no group ready | a load of `groups_ready` and an `or` in `begin`; a test and a branch in `end`; the store of "none" to `turn_group`; the store of 0 after a run | about 5 to 6 instructions. `poller` +0.9 percent, `task` +0.9 percent, `tasks-64` +0.1 percent. A layout move can count more (decision 27, "Layout risk"). |
| `schedule`, and `schedule_in(.default)` | none in `schedule`. `schedule_in` adds the class A id compare and a branch | 0, and about 3 instructions |
| `schedule_in(g)`, g not `.default` | the id compare, the lane address, the push with the end mark, the ready bit, the cap compare | about 12 instructions |
| one task on the groups path | the cost load (same line as `function`), a multiply, a subtraction, the deficit compare, the `startable` decrement, the end-mark compare | about +6 instructions on today's 10 or so |
| one visit | rotate and count trailing zeros, the credit, the close, the cursor, the `turn_group` store | about 13 instructions |
| the start of a run with groups | the class B shape check and the snapshot, over the ready groups | about 5 instructions for each ready group |
| the bulk credit | one division for each startable group | about 20 instructions for each group; only after debt |
| 64 tasks in 4 groups at shares 100 | 64 visits, because each visit runs one task | about 4558 + 64 × 6 + 64 × 13 + 20 = about 5800 on `macos-aarch64-kqueue`, about 1.3 times `tasks-64`. At shares 400 each, 16 visits: about 5150. |
| `charge_task` | the owner check (C21), the phase test, a multiply, a subtraction and the floor compare | about 8 instructions |
| named groups | none on a tick: the names are comptime, and `Loop.init` writes the shares of n lanes | 0 |
| memory | `Groups` 536 B, `Tables` + 8 B; `Dispatch`, `Tasks`, `Stall` and `Heartbeat` keep their sizes | 544 B for each loop, 34 KiB on 64 cores |

The groups path touches the `Groups` header and one line for each two lanes it visits. A cold line
is C3 (128 ns on `mac`), which the instruction gate cannot see. A program with no group touches no
line of `Groups`.

## Alternatives it beat

| alternative | why it lost |
|---|---|
| Seastar's charge by measured run time | It reads the clock at each switch of group (C20, 16.4 ns), and non-negotiable 2 excludes it. |
| a time quota for a tick | The same: a quota that changes what a tick runs is excluded. |
| stride or vruntime selection | No gap at large ratios, but a scan of 16 groups for each task and a wrapping compare. DRR with the bulk credit has the same bounds at the shares range proposed. |
| shares in whole units, 1 to 1000 | One visit at 1000 shares holds about 16 ticks of starts, and the latency bound grows to hundreds of ticks. Hundredths keep a visit near one task at the default. |
| shares in whole units, 1 to 64 | A coarse ratio, and not Seastar's range. |
| debt repaid only by visits, with no bulk credit | At shares 1 and a charge of 64 units, a run needs up to 6,400 passes over 16 groups before one start. |
| a group field in `Task` | `Task` grows from 16 B to 24 B, for every task of every program. |
| a view bound to a group, `loop.shared_in(group)` | `*SharedLoop` stops being the loop's address. Every library call pays a dependent load, which no gate row sees, and decision 28's contract changes. |
| `schedule(group, task)` on `Loop` too | It breaks the program's own calls, with no gain: the program owns the groups. |
| `schedule(task)` kept on `SharedLoop` | A library that has a group can put a task in `.default` by mistake, and that compiles. |
| the library reserves its own group | Shares are the program's policy. A library cannot know how colibri weighs against the journal. |
| a scan of the other tails in `push` | It finds a task queued twice, but costs about 2 instructions in each `schedule` of a program with no group: `tasks-64` +2.8 percent. The end mark costs nothing on that path. |
| exact counts of units and tasks for each group | A write for each task on the hot path. Statistics are sampled. |
| the group table inside each backend `Loop` | It moves the size of a hot structure by 0.5 KiB. `Layout.take` puts it on lines of its own. |
| a bound of 64 units, not 64 starts, for a tick | It changes the meaning of a named limit and of `Tasks.left`. Open question 4 keeps it as a choice. |

## How it would be checked

**Unit tests, in `scheduling.zig`, with no `Loop`:**

| test | what it shows |
|---|---|
| reserve | the lowest id first, then `SchedulingGroupsFull` |
| named groups | init gives ids 1 to n their declared shares, in order, and a reserve after it returns n + 1. The test passes the `table` of its own `Named(...)` to `Groups.reserve_named`, as "How tests name groups" says. |
| shares 100 and 300, both full | units served 1 : 3 exactly over 4 rounds |
| a charge of 64 at shares 1 | the group skips through one bulk credit, and the run ends |
| a close | positive credit is dropped, debt is kept |
| a cut visit | the cursor and the open visit persist across runs, and no second credit is added |
| the snapshot | a task queued by a task in another group runs in the next tick |
| the bound | a run starts at most 64 tasks |
| `set_scheduling_group_shares` | it counts from the next visit |
| `discard_tasks` | every group empties, and each deficit and the cursor reset |
| the cap | a full group returns `TasksFull` while another group schedules |
| `init_cost` | a task of cost 8 subtracts 800 |
| the end mark | a task in group 3 pushed to group 5, or to `.default`, is caught by `holds` |
| no group ready | the trace equals decision 27's |

**Property test, `scheduling_test.zig`,** seeded from `core.random`, which prints its seed when it
fails: 64 seeds of 300 steps, each run three times, twice to replay and once with the tasks at
other addresses. A reference model in `dispatch_test_model.zig` runs plain DRR with exact integers.

| property | statement |
|---|---|
| G1 | the trace equals the model's |
| G2 | each deficit stays in its bounds |
| G3 | the window bound of the served units, for each pair of groups that stay startable |
| G4 | at most 64 starts in a run, and a run ends within `visits_per_run_max` visits |
| G5 | scheduled = run + discarded + queued, for each group |
| G6 | `callbacks_outstanding` = records in flight + the sum of the group counts |
| G7 | the same trace at other addresses |
| G8 | `begin` waits 0 if and only if a group holds a task |

**Conformance, `conformance_scheduling.zig`,** on all three backends, and again with the spin budget:

- Two libraries at shares 100 and 300 schedule themselves forever beside a receive on a socket pair
  and a timer. The ratio of units holds within G3, and the receive and the timer arrive.
- A group of tasks of cost 64 runs beside a group of unit tasks. The unit group is served within its
  bound, and a timer and a post still arrive within 2 ticks. This checks the fit with W3.
- `drain` and `discard_tasks` across groups.
- A loop whose options hold a table of two names has ids 1 and 2 at their declared shares, and its
  first reserve returns 3. A loop with the empty table reserves no name.
- A cost gate row: one run of 64 tasks in 16 groups, bounded at ten times what is measured.

**The work gate:** today's rows stay within 2 percent, with no baseline raised. New rows
`tasks-groups-4` and `tasks-groups-16`, 64 tasks each, get their own lines.

**Halt scenarios, `tools/halt/core_scenarios_scheduling.zig`:**

| check | class |
|---|---|
| the group id is at most `reserved` | A, one compare |
| shares in 1 to `scheduling_shares_max` | B |
| `charge_task` inside a task's run (`phase` is tasks or group_tasks) | B |
| a deficit at or above `1 - task_charge_max * 100` after a charge | A, one compare |
| a bulk credit is followed by a start | A |
| the end mark is never popped as a task | A |
| the shape of each ready lane: count 0 if and only if head null if and only if tail null; ready bit if and only if count above 0; `startable <= count`; the sum at most `callbacks_outstanding` | B, once in each run |
| a walk of each lane, through `Groups.assert_lanes` | D, the tests |

The owner checks of the new calls go in the kqueue and epoll owner files. `deinit`'s class C check
reads the sum.

**Compile-fail tests (`zig build test-compile-fail`):** a literal group id; `schedule`,
`reserve_scheduling_group` and `set_scheduling_group_shares` on a `SharedLoop`; `init_cost` with
cost 0 and with a cost above `task_charge_max`; `named_scheduling_group` with a name the root does
not declare; and a `Named` declaration with the name `default`, with shares 0 or above 1000, or with
more than 15 names.

**Mutations**, each reported `CAUGHT` or `NOT CAUGHT`:

| mutation | target |
|---|---|
| the cursor reset at each run | `test-core`, G1 and G3 |
| init reserves the named groups in reverse order | `test-core`, the named-groups unit test |
| init ignores the declared shares | `test-core`, the named-groups unit test |
| `Loop.init` does not reserve the table of its options | conformance, the named-groups scenario |
| `@min(deficit, 0)` removed at a close | `test-core`, G2 |
| debt cleared when a group empties | `test-core`, G3 |
| credit added again on a resumed visit | `test-core`, G1 |
| the snapshot read on each pass | `test-core`, G1 and the unit test |
| ties broken by address order | `test-core`, G7 |
| the ready bit not cleared | `test-core`, G8, and `halt-check` |
| `begin` ignores `groups_ready` | `test-core` G8, and the conformance scenario blocks on its timer |
| the static cost ignored | `test-core`, unit test |
| `charge_task` changes nothing | `test-core`, G3 |
| the bulk credit removed | `halt-check` and G4 |
| the cap reads the total and not the group | `test-core`, unit test |
| `discard_tasks` skips groups 1 to 15 | `test-core`, G5 |
| the end mark replaced by null | `test-core`, the end-mark unit test |
| `turn_group` not stored | `test-core`, a fabricated stall |
| each assertion of the table deleted | `halt-check` |

**Models:** `proofs/RotorProofs/Drr.lean` proves the deficit bounds and the window bound of G3. It
mirrors `Groups.run`, and a change to one changes the other in the same commit. No TLA+ model is
added: a run is on one thread. `spec/tla/wake/` needs no change, because its `DrainNoWait` already
lets a queued task make any tick wait 0.

## Open questions

Camilo ruled on each one on 2026-11-07, with its proposed answer. Question 8 meets his ruling on
decision 32, and its answer says how.

1. **Names.** Should decision 29's `reserve_group` and `GroupsFull` (accepted, not built) become
   `reserve_buffer_group` and `BufferGroupsFull`, so that "group" alone never names two things?
   Decision 21's group of processes is a third use, and decision 32 calls it "a decision 21
   group" in each place. *Ruled: yes, before decision 29 is built.*
2. **The plain `schedule` on a `SharedLoop`.** (a) Refuse it, so a library names its group in each
   call. (b) Keep it as `.default`, as decision 27 sketched, and rely on the guide and a conformance
   scenario. *Ruled: (a). It breaks each library's `schedule` calls once, and wrong use then fails
   to compile.*
3. **Shares.** (a) 1 to 1000, in hundredths of a unit, default 100. (b) 1 to 64 whole units.
   *Ruled: (a), Seastar's range, with the bulk credit to keep the run bounded.*
4. **Does a cost bound the tick?** (a) No: 64 starts in every mode, and a cost weighs only the
   shares. (b) 64 units, so a run of costly tasks gives the core back to I/O sooner, at the price of
   a change to a named limit and to `Tasks.left`. *Ruled: (a). A later record takes (b) if a
   consumer measures I/O latency behind costly tasks.*
5. **A queue cap for each group.** *Ruled: yes, `tasks_queued_max` for each group, with the
   overflow assert rewritten.*
6. **Counts for each group.** (a) None in this record. (b) An exact count of `TasksFull` for each
   group, written only on the refusal path, beside W9's counts of refusals. (c) A sampled count of
   the ticks in which a group's snapshot was left unserved. *Ruled: (b) with W9, and (c) in a later
   record.*
7. **Reserve after the first tick.** *Ruled: yes, between ticks. A reserve inside a tick halts
   (class C).* A reserved id belongs to its loop only. A group that a cross-core call names is a
   named group, which every loop reserves at init (see "Named groups").
8. **A comptime name for a group.** It would let statistics print the group's name, at 8 B for each
   lane. *Ruled: no name for statistics. A stall already names the task, and through it the
   library.* Camilo's ruling on decision 32 adds comptime names for a different purpose: one id for
   one group on every loop. Those names live in the root's declaration, and a lane stores none, so
   a lane stays 32 B.
9. **Default shares and `task_charge_max`.** 100 and 64 are priors. *Ruled: read colibri's and
   cocuyo's slices for each turn, and fix them from the `tasks-groups-4` row.* The proposed answer
   fixed them before the record was accepted. Camilo accepted the record before that row exists.
   So the step moves: *ruled on 2026-11-07, the defaults are fixed from that row before the build
   lands.*
10. **stompy's design note** refuses weighted DRR (decision 27, "How groups could come later").
    *Ruled: stompy's note changes in the same release, with one group for each purpose: foreground,
    journal, compaction.*
11. **The order of the build.** *Ruled: W3, then decision 29, then this record, then decision 32.
    Decision 31 waits for the W7 bench and does not depend on this record.* This record changes no
    step that W3 changes, but both edit the guide's section on fairness. Decision 32 needs
    `NamedSchedulingGroup` for its `CallOptions`, and puts two counts in `Groups`.

## Left for Camilo

Nothing. Camilo ruled the last item, the reason for the comptime assert, on 2026-11-07 (ruling
item 11).

## Ask before

| item | what changes |
|---|---|
| building what decision 2 leaves out of version one | scheduling groups were put in "Not in version one" by decision 27. Camilo accepted this record on 2026-11-07. |
| new named limits in `src/core/constants.zig` | `scheduling_groups_max` = 16 (this record only; decision 31 has `io_classes_max`), `scheduling_shares_max` = 1000, `scheduling_shares_default` = 100, `scheduling_unit_credit` = 100, `task_charge_max` = 64, and the derived `visits_per_run_max`; a comptime assert `tasks_per_tick_max <= task_charge_max`, so the charge of the guidance for a cost that varies, at most `task_budget_left()`, never passes `task_charge_max`. Camilo ruled this reason on 2026-11-07, after the lane run was gone (ruling item 11) |
| a named limit changes meaning | `tasks_queued_max` becomes a cap for each group, and its overflow assert is rewritten |
| the limit of a push (ruled on 2026-11-07, ruling item 9) | a call's task is pushed with the limit `tasks_queued_max + call_tasks_max`, for every group and for a call to self. In `Tasks`, the assert in `push`, `assert_shape`, the loop bound of `discard` and the walk of `assert_queue` read that sum. In `Groups`, a lane's push assert, its shape check, its discard and the walk of `Groups.assert_lanes` read it too |
| the layout of a hot structure | `Dispatch` merges `ticking` and `polling` into `phase` and gains `groups_ready: u16`, at 96 B; `Tables` gains 8 B; `Task.Call` grows from 24 B to 32 B; `Stall` and `Heartbeat` gain a field in their padding; the loop's memory grows by 544 B |
| the layout of `Groups` | `named: u8` in 1 B of its padding; the size stays 536 B; ruled on 2026-11-07 |
| the layout of `Task.Call` (ruled on 2026-11-07, ruling item 10) | `call_record: bool` in its padding; the size stays 32 B |
| the public surface and the tag | six new names; `SharedLoop` refuses `schedule`, which breaks colibri, cocuyo and stompy once; a twin of the surface must follow (decisions 10 and 24) |
| the public surface | three more names, `SchedulingGroupName`, `NamedSchedulingGroup` and `named_scheduling_group`, and the method `NamedSchedulingGroup.scheduling_group`; ruled on 2026-11-07 |
| a declaration that the public module reads from the program | `rotor` reads `rotor_scheduling_groups` through `@import("root")`. It is not an edge of `build/modules.zig`, and core does not read it. Ruled on 2026-11-07. |
| the backends' `Loop.Options` | a field `named_groups: NamedTable`, empty by default, which the public options do not carry. No file under `build/` changes, and no build step is added. Ruled on 2026-11-07. |
| decision 9, rule 7 | an exact count of `TasksFull` for each group, on the refusal path, with W9 (open question 6) |
| a new Lean file | `proofs/RotorProofs/Drr.lean`, kept in step with `Groups.run` |
| none of these | no dependency, no file on decision 7's list, and no assertion moved. The limit of ruling item 9 widens eight bounds by `call_tasks_max`. Camilo ruled it on 2026-11-07. No other assertion is weakened. If the gate later asks for a cold hint on `run_groups`, that is a separate ask. |

## Sources

- Seastar `scheduling.hh`, read for the drafts on 2026-11-07:
  https://raw.githubusercontent.com/scylladb/seastar/master/include/seastar/core/scheduling.hh
- Seastar `io_priority_class.hh`, read for the drafts on 2026-11-07. It now holds only an id type:
  https://raw.githubusercontent.com/scylladb/seastar/master/include/seastar/core/io_priority_class.hh
- Seastar `CMakeLists.txt`, `SEASTAR_SCHEDULING_GROUPS_COUNT` (default 16), read by decision 27.
- Seastar `reactor.cc`, `account_runtime`, read by decision 27.
- Seastar tutorial, §26: https://docs.seastar.io/master/tutorial.html
- Recalled and not checked: a Seastar continuation inherits the group it runs in
  (`with_scheduling_group`); Seastar's I/O classes now follow scheduling groups; ScyllaDB changes
  the shares of background groups at run time through backlog controllers.
- The robustness plan of 2026-11-06, defect 3 and W9.
- `src/core/tasks.zig`, `src/core/dispatch/dispatch.zig`, `src/core/shared_loop.zig`,
  `src/core/statistics.zig`, `src/core/stall.zig`, `src/core/constants.zig` and
  `bench/baseline/work.txt`, at `5e9490d`.
