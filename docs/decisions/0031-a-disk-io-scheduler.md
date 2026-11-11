# 31. A disk I/O scheduler

Status: accepted on 2026-11-07 for the capacity and share rules (see "Ruling, 2026-11-07"). The
rate rule is not accepted. Nothing is built. Every cost here is a prior: a row of `docs/costs.md`, a
row of `bench/baseline/work.txt`, or an instruction count from arithmetic. Nothing was measured for
this record.

Amended on 2026-11-11 by decision 33, which Camilo accepted on 2026-11-10. He ruled on 2026-11-08
that this scheduler goes in the reactor, the module `reactor` (decision 33, open question 9). It is
a holder in front of the core's `submit`, so a plain `rotor.Loop` pays nothing for it. Nothing of
this record is built, so no code moved. The capacity rule and the share rule do not change. These
parts of the text change:

- The amendments of decisions 11, 12 and 20 at the flush of a file operation do not apply. The
  scheduler is not a step of each backend's flush.
- The options are not on `Loop.Options` of every backend and of `rotor.Loop`. They are the
  reactor's. Decision 33 does not say which type of the reactor holds them.
- The note on decision 7's hot files does not apply: the flush files gain no branch.

The word "reactor" in requirement 2, "robust under one reactor per core", means one loop for each
CPU core. Since decision 33, a reactor in rotor is a value of `rotor.Reactor(Loop)`, and a plain
loop is not one. The requirement covers each loop of a core: a plain loop or a reactor.

## Ruling, 2026-11-07

Camilo ruled on decisions 30, 31 and 32 together. For this record:

1. **The capacity rule and the share rule are accepted**, with the proposed answer to each open
   question and the items of "Ask before" that they need.
2. **The rate rule waits for its own ruling** (open question 2). Decisions 9 and 13 are not amended
   until then.
3. **The W7 disk bench runs before the build** (open question 6). It measures io-wq caps of 2, 4
   and 8, and an fsync beside reads, on a named machine. Its numbers set the default costs (open
   question 5).
4. **The build order** is W3 (the fair tick order), decision 29, decision 30, then decision 32.
   This record follows the W7 bench. It needs nothing of decisions 30 and 32.

His ruling on decision 32 gives decision 30's groups names. I/O classes stay their own index space
(open question 1), so that ruling changes nothing here.

It amends decision 2, because it adds a row to the "In version one" table. It also amends these
records:

- decision 5, at rule 4 (a deadline) and rule 6 (a close), for the operations that a class holds;
- decision 18, at the held list of its amendment of 2026-11-06;
- decisions 11, 12 and 20, at the flush of a file operation;
- decisions 9 and 13, point 4, only if Camilo accepts the rate rule (section 5).

## Context

On 2026-11-07 Camilo chose to add three Seastar features to rotor: scheduling groups, a disk I/O
scheduler and a cross-core call helper. This record is the disk I/O scheduler. His requirements
apply to it:

1. **The API is simple to use correctly.** Wrong use fails to compile. Where the compiler cannot
   see it, wrong use halts at once.
2. **It is robust under one reactor per core.** stompy runs one loop per CPU core. colibri and
   cocuyo share each core's loop.

stompy's journal calls `fdatasync` after each batch of writes. Its object store reads and writes
large objects on the same disk, through the same loop. A group commit waits for its sync, so the
sync's latency is the commit's latency. Today nothing puts the sync ahead of the reads.

### What the code does today

These facts were read from the tree at `5e9490d`:

- **io_uring.** A flush puts each queued file operation into the submission ring in submit order.
  Nothing bounds how many are out. The kernel runs a buffered sync on io-wq, which
  `kernel_workers_max` (2) caps (`src/uring/constants.zig:23`). The robustness plan's F10 says that
  two slow syncs can then hold both workers while reads wait, with no count.
- **kqueue and epoll with the offload.** A flush hands out at most `offload_in_flight_max` (256)
  operations. Each further file operation waits on `InFlight.held`, one FIFO for all of them
  (`src/core/offload_in_flight.zig`, decision 18, amendment of 2026-11-06).
- **The order.** A sync submitted after 256 reads goes out after those 256 reads, on every backend.

### Seastar

Seastar keeps one `io_queue` for each device in each shard. A set of shards shares an `io_group`.
The shares of an I/O class are set for each scheduling group (`update_shares_for_class`). A
bandwidth limit is divided by the count of io groups. The reactor bounds its sleep at
`next_pending_aio()`. The default `io-latency-goal-ms` is 1.5 times `task-quota-ms`. A request's
cost is a ticket of operations and bytes, and the dispatch capacity is the tokens of one latency
goal. "Sources" marks which of these facts were read and which were recalled.

Seastar meets rotor's rules at three points:

- Its token bucket refills from the clock, and the shards of an io group share it through atomics
  (recalled). The clock conflicts with non-negotiable 2, and the atomics with non-negotiable 4.
- It binds an I/O class to the scheduling group that runs at submit. rotor's operations are data,
  and no control flow of a loop reads a "current group". Decision 30 stores the group of a task
  only for the stall record.
- Its queues grow on the heap. rotor allocates nothing.

## The decision

A program that wants a scheduler gives its loop an `IoQueue` at init, in its own memory. The queue
holds up to `io_devices_max` devices, and each device holds classes. A file operation (`read`,
`write`, `fdatasync`, `fsync`) names a class, or takes the default class. A loop with no `IoQueue`
runs today's path.

1. **The capacity rule.** Each device has a dispatch limit: `operations_max` operations out, and
   optionally `units_max` I/O units out. An I/O unit is a cost in bytes and operations. It is not
   decision 30's task unit. An operation goes out only when it fits. Its cost comes
   back at its final event, which is a kernel answer. This rule reads no clock.
2. **The share rule.** Among the classes of a device, the head of the class with the least pass
   goes out next. A dispatch adds `cost * stride` to that class's pass. Ties go to the lower class
   index. This is stride scheduling, and it reads no clock.
3. **The rate rule, for a later ruling.** A class may have a rate in units per second. It refills
   only from `Tables.now_ns`. It was not accepted on 2026-11-07, and it is not built until Camilo
   rules on it ("The rate rule, for a later ruling").

At a limit, an operation is held. It is never refused, and it ends with exactly one final event.

### The surface

```zig
// src/core/io_queue.zig (new). It is pure: it takes no *Loop and reads no clock.
/// A device of one queue. Only `add_device` makes one, so a literal fails to compile.
pub const IoDevice = enum(u8) { _ };
/// A class of file operations on one device. Only `add_class` makes one.
pub const IoClass = enum(u8) { _ };

pub const IoDeviceOptions = struct {
    /// Operations this loop may have out on the device: 1 .. offload_in_flight_max.
    operations_max: u16,
    /// Cost units this loop may have out on the device, or null for no limit in units.
    units_max: ?u32 = null,
    /// Cost = operation units + ceil(len >> unit_bytes_log2). Priors, to be set from W7.
    read_operation_units: u16 = 1,
    write_operation_units: u16 = 1,
    sync_units: u16 = 64,
    unit_bytes_log2: u5 = 12, // 1 unit = 4 KiB moved
};

pub const IoClassOptions = struct {
    /// 1 .. io_shares_max (1000), the range that decision 30's groups use.
    shares: u16,
};

/// 448 B, align 64, in the caller's memory.
pub const IoQueue = extern struct {
    pub const empty: IoQueue;
    pub fn add_device(queue: *IoQueue, options: IoDeviceOptions) error{IoDevicesFull}!IoDevice;
    /// The first class added is the default class.
    pub fn add_class(queue: *IoQueue, device: IoDevice, options: IoClassOptions)
        error{IoClassesFull}!IoClass;
};

// Loop.Options, on every backend and on rotor.Loop:
io: ?*core.IoQueue = null,

// Operation.Read, Write, Fdatasync and Fsync each gain one field. A socket operation has no
// such field, so a class on it fails to compile.
class: ?IoClass = null, // null: the default class, or no queue when the loop has none

// rotor.Loop and SharedLoop. Cold. It reads state and changes nothing.
pub fn io_state(loop: *const Loop, class: IoClass) IoState;
pub const IoState = struct { held: u32, device_operations_out: u16, device_units_out: u32 };
```

The program makes the devices and the classes before `Loop.init`. `Loop.init` seals the queue, and
an `add_device` or `add_class` after that halts (class C). So classes never change while the
queue runs, and the loop holds no state for a phase of setup. `SharedLoop` gives no way to reach the
queue, so a library cannot change the program's disk policy. A library that writes files takes an
`IoClass` from the program, as it takes a `SchedulingGroup` from the program (decision 30). This
differs from decision 29's `BufferGroup`, which a library reserves itself. Decision 30 seals
nothing: its shares change between ticks. This record fixes the I/O shares at `Loop.init`.

| wrong use | result |
|---|---|
| a literal class or device | fails to compile |
| a class on a socket operation | fails to compile |
| an add after `Loop.init` | halt, class C |
| shares 0 or above `io_shares_max`; `operations_max` 0 | halt at add, class C |
| under `.offload`, the sum of `operations_max` above `offload_in_flight_max` | halt at `Loop.init`, class C |
| a queue on kqueue or epoll with `file_policy` `.blocking` or `.refuse` | halt at `Loop.init`, class C |
| an `@enumFromInt` to an index the queue never returned | halt at submit, class A |
| a class on an operation of a loop with no queue | halt at submit, class A |
| a class of device A on a file of device B | not detected: an `fstat` per operation is a system call |

A `@enumFromInt` compiles, as it does for decision 29's `BufferGroup`. The halt catches it.

### What the user must know

These go into `docs/using.md`:

- **No order across classes.** Inside a class, the order is FIFO. A write and the sync after it
  stay in order only when the caller waits for the write's event before it submits the sync. That
  is true today too, because the kernel runs dispatched operations in no fixed order.
- **The cost model has no page cache.** Decision 2 puts buffered file I/O out of version one, so
  the model assumes O_DIRECT. macOS has no O_DIRECT (decision 2, "The correction"), so a cached
  read there costs what a device read costs.
- **N loops on one disk split it.** Each loop gets `operations_max` of its own. A program with 8
  loops on a disk that takes 64 operations gives each loop 8.
- **`operations_max` comes from a measured latency goal.** rotor does not derive it from a clock.

### The flow

1. **Submit.** Unchanged. `fill` writes the slot's `io` byte for every operation, next to
   `retries`. For a file operation of a loop with a queue, the byte holds the class index. For any
   other operation, it is 0. So a slot that held a charged read and now holds a receive carries no
   stale charge.
2. **Flush, the fast path.** A file operation goes out at once when its device holds nothing, and
   it fits the device's limits. The flush charges the device and the class, and adds the operation
   to this flush's batch: an SQE on io_uring, `hand_out` on kqueue and epoll. So the batch stays
   the default shape.
3. **Flush, the held path.** Otherwise the operation goes to the back of its class's list, through
   `Slot.next`, and stays `queued`. The flush arms its deadline, as `InFlight.hold` does (decision
   18, ruling (b)).
4. **The pump.** At the start of each flush, when `held_total != 0`, each device with held work
   picks the class with the least pass. If that class's head fits, it goes out. If it does not
   fit, that device stops for this flush. The pump never skips to a smaller head, so a large
   operation is never starved. The loop is bounded by `held_total`.
5. **The final event.** `Tables.finish` tests the slot's `charged` bit, on a line it has loaded
   already. When it is set, the queue gives back the cost and the operation. The cost is
   recomputed from `code`, `len` and the device, so the slot stores no cost. `len` does not change
   across a resubmit (read: `slot.zig` sets it only in `fill`). A requeue (io_uring `EAGAIN`) keeps
   the charge, because the operation is still on the device. A short read gives back its full cost.
6. **Cancel, deadline and close of a held operation.** These follow decision 18's rulings of
   2026-11-06. A cancel of a queued slot while some are held sets `IoQueue.canceled`. The next
   flush walks the class lists once, and ends each marked slot with `canceled`, or with `timeout`
   after an expiry. A `close` calls `IoQueue.end_descriptor` before the descriptor closes, so its
   held operations end before the close's own event (decision 5, rule 6). An operation that is out
   is cancelled as today, and its cost comes back at its final event.
7. **Sleep.** A class B assertion before a wait that blocks: `held_total == 0`, or some device has
   an operation out. The clamp below makes this always true, because a device with nothing out
   always takes its head.

**The clamp.** The cost is clamped to `units_max`, so an operation larger than the limit goes out
alone when its device has nothing out. It never waits without end.

**An idle class gets no credit.** When a class with nothing held and nothing out gets work, its
pass becomes the larger of its own pass and the device's pass, which is the pass of the last class
that the device dispatched. So a class that was idle cannot take a burst.

**Wrap.** A pass is a `u64`, compared by wrapping difference. A cost is below 2^21 units (a `u32`
length in 4 KiB units, plus a `u16`), and a stride is at most `io_stride_scale` = 2^20. So one
dispatch adds less than 2^41. With the idle clamp, the spread of the passes on one device stays far
below 2^63, so a wrapping compare is sound. A Lean lemma holds this.

## Layout

| structure | size | fields |
|---|---|---|
| `IoQueue` header | 64 B, one line | `held_total` u32, `device_count` u8, `class_count` u8, `canceled` bool, `sealed` bool, reserved |
| `Device` | 32 B, align 8 | `units_out` u32, `units_max` u32, `operations_out` u16, `operations_max` u16, `held` u32, `pass` u64, three operation costs u16, `unit_bytes_log2` u8, `class_mask` u8 |
| `Class` | 32 B, align 8 | `list` `SlotList` (12 B), `device` u8, `flags` u8, `shares` u16, `stride` u32, reserved u32, `pass` u64 |
| `IoQueue` | 448 B, align 64 | header, `[4]Device` (128 B), `[8]Class` (256 B) |
| `Slot.io` | 1 B | one of `Slot.reserved`'s 2 bytes: `packed struct(u8) { class: u3, charged: bool, reserved: u4 }` |
| `Tables.io` | 8 B | `?*IoQueue` |
| each file kind of `Operation` | 1 B | `class: ?IoClass`; expected to fit in padding |

Comptime asserts hold each size. `Slot` stays 64 B, with 1 reserved byte left. `Read` is an `i32`,
a 24 B `Buffer` and a `u64`, so the class byte probably fits in the 4 B after `file`. This is not
built, and an assert on `@sizeOf(Operation)` must show it. A build reports where `Tables.io` lands,
as decision 27 did for `Tasks`. Decision 30 adds `Tables.groups`, 8 B too, so one build reports
where both land. The queue's memory is the caller's, so a loop with no queue pays only the 8 B in
`Tables`.

New named limits in `src/core/constants.zig`:

| name | value | comptime assert |
|---|---|---|
| `io_devices_max` | 4 | `<= io_classes_max`, because each device needs a class |
| `io_classes_max` | 8 | `<= 8`, so the index fits `u3` |
| `io_shares_max` | 1000 | `io_stride_scale / io_shares_max >= 1` |
| `io_stride_scale` | 2^20 | the largest cost times it is below 2^62 |

## What it costs

Every number is a prior from arithmetic. The work gate decides, within 2 percent on every row.

| case | added |
|---|---|
| a tick of a loop with no queue | a load of `Tables.io` and a branch in the flush: about 2 instructions |
| each operation of any loop | the store of the `io` byte in `fill`, beside `retries`: 0 to 1 |
| each final event of any loop | a test of `charged` on the slot's loaded line: about 2 |
| a file operation on the fast path | cost (a table load, a shift, an add), 2 compares, 2 adds, a multiply and add for the pass, a byte store: about 12 |
| its final event | recompute the cost and subtract: about 8 |
| a held operation | link it: about 10; each dispatch from the pump, a scan of at most 8 classes: about 40 |
| a cancel, a close or a deadline of held work | one walk of the class lists, as `InFlight.held` walks today |
| memory | 448 B of the caller's for each loop with a queue; 8 B in `Tables` for each loop |

Against the smallest work-gate rows: `poller` on `linux-aarch64-uring` is 516 instructions, and
gains about 2 (0.4 percent). `timer` there is 1025, and gains about 5 (0.5 percent). The order of
the two branches matters little, so the gate may choose between a test of `charged` in `finish`
and a test of `Tables.io` first.

A sync then waits behind at most `operations_max` operations out on its device, plus its share of
the held ones. That claim needs the W7 bench on a named machine.

## Determinism

- **The capacity and share rules read no clock.** Each choice is a function of the order of
  submits, the order of final events (the kernel's answers) and the options.
- **Ties go to the class index.** Nothing compares, hashes or sorts by address. A property test
  shows that the same calls at other slot indices give the same order.
- **The pass is state.** No statistic steers it, which meets decision 9, rule 1.
- **The queue's delay is sampled.** A sampled slot carries the tick's stamp at submit and at
  dispatch, in a new phase `queued` of the sampled records. That needs no new clock read (decision
  9, rule 4).
- **No exact count is added.** `io_state` returns state that the queue needs anyway. Exact counts of
  deferrals and rate waits wait for ruling R5 and W9.
- **Lint.** `tools/lint/determinism.zig` holds `src/core/io_queue.zig` with no exemption.

## The rate rule, for a later ruling

A class may have `rate_units_per_s` and `burst_units`. Each is off by default. The rule is
proposed here so that the layout leaves room for it. It is built only after Camilo rules, and only
when stompy names a background class, such as scrub or compaction, that needs it.

- **It reads no clock.** `IoQueue.refill(now_ns)` takes `Tables.now_ns`, which the backend wrote at
  the tick's first stamp or after a wait that blocked (decision 9, rule 4).
- **It acts as a timer does.** "This class may dispatch again at T" is the same kind of fact as
  "this timer is due at T". The timer heap and each deadline already change what a tick does from
  the same stamp. A twin replays it from the same `now_ns` sequence.
- **It is not the excluded time quota.** A quota measures how long the caller's code ran, and cuts
  a run short by that measure. A refill measures no code and cuts no run.
- **Exact arithmetic.** `granted = (delta_ns * rate + remainder) / ns_per_s` in `u128`, and the
  remainder carries the rest. `delta_ns` is capped at the bucket's fill time. So an interval split
  into 1, 7 or 1,000 ticks grants the same tokens.
- **The wake.** While a class waits only for tokens, `wait_bound` takes the least of its wait and the
  refill time. The class B sleep assertion gains "or a refill time is in `wait_bound`".
- **Drain.** `drain` ends each operation that a rate holds with `canceled`, at its first round. So
  a correct program cannot fail `drain_rounds_max` because of a rate.
- **The cost.** A cold array of `[8]Limit`, 64 B each, adds 512 B to `IoQueue`. A refill is about
  25 instructions with one `u128` divide.

Decision 27 (its "Alternatives it beat") calls a budget sized from the gap between tick stamps "an
adaptive budget, which decision 13, point 4 forbids without an amendment". Its open question 13 asks
that decisions 9 and 13 are amended first. So the rate rule needs both: decision 9 gains a rule 8,
"A rate refills only at the tick's clock stamps, makes no clock read, and bounds the wait at its
refill time as a timer does". Decision 13, point 4 gains the same exception.

If Camilo refuses it, `docs/using.md` shows a pacer on the caller's side. It refills from
`Loop.now_ns` and delays its own submits. It loses the loop's deadline, cancel and close for the
operations it delays. So this record does not propose it.

## Where it meets the records

- **Decision 2.** A row in "In version one": "disk I/O: a fair queue of file operations in
  classes, with a dispatch limit for each device and shares for each class
  (`0031-a-disk-io-scheduler.md`)". A row in "Not in version one": a shared bucket across loops.
- **Decision 5.** Rule 4 (a deadline) and rule 6 (a close) also cover the class lists. Each held
  operation ends once, so rule 1 holds.
- **Decision 18.** With a queue, `Loop.init` asserts that the sum of `operations_max` is at or below
  `offload_in_flight_max`. So `InFlight.has_room` is true at each dispatch, and `InFlight.hold`
  gains a class C assertion that the loop has no queue. With no queue, the held list works as
  built. Rulings (a), (b) and (c) apply to each class list unchanged.
- **Decisions 11, 12 and 20.** With a queue, a file operation goes through the fast path or a class
  list before the SQE or `hand_out`. With no queue, nothing changes.
- **Decisions 26 and 28.** `SharedLoop` declares `io_state` only. A library cannot reach the queue.
- **Decision 27.** The rate rule is not the quota of open question 13. The pick reuses the stride
  rule that "How groups could come later" sketches.
- **Decision 30, scheduling groups (accepted 2026-11-07).** Classes are their own index space,
  `IoClass`, and decision 30 agrees. A named group of decision 30 is not a class either. A journal
  fsync from a request's task belongs to the journal's class, and not to the task's group. A later
  amendment may let a group name a default class. Decision 30 picks among groups by DRR. This
  record picks among classes by stride, for the reason in "Alternatives it beat".
- **Decision 32, the cross-core call helper.** A handler that answers `.later` after a file
  operation keeps its call `held` while this queue holds that operation. The call's deadline is
  compared only before the handler runs, so it does not reach the operation. A caller that needs a
  limit on the sync sets the operation's own deadline.
- **W3, the fair tick order (robustness plan, R3).** The scheduler runs in the flush, before the
  pending list, and makes no event. So it takes no share of `events`. A dispatched operation ends
  through the kernel's reserve or the offload's drain. A held operation ended by a cancel, a
  deadline or a close goes to the finished list, which W3 already shares out. The class pick has
  its own order and does not touch W3's sender cursor. The capacity rule also caps the file
  completions that can arrive in one tick, which shrinks F4's flood.
- **F10 and W7.** On io_uring a buffered sync still runs on io-wq's 2 workers. Until W7 measures
  caps of 4 and 8, the guide says to keep a sync class's device at `operations_max` of 2 or less.

## Alternatives it beat

| alternative | why it lost |
|---|---|
| no change: each consumer orders its own file work | stompy's journal and object store share one loop, and two orders on one disk give no bound |
| one limit for the whole loop, with no device | a slow disk uses the limit of a fast disk on the same loop |
| a cost table in device nanoseconds with no defaults | seven required fields that need a probe that does not exist; a wrong value schedules badly and never halts |
| a scheduler that is always on, with a default device | it caps io_uring at 256 out for programs that never asked, and every file operation pays |
| `add_io_device` and `add_io_class` on the loop, after init | a run-time phase in the loop; on `SharedLoop`, a library could change the program's policy |
| the class on the top-level `Operation` | a class on a socket operation compiles, and only a halt catches it |
| a shared bucket across loops (Seastar's io_group) | atomics between threads (non-negotiable 4), and one loop's dispatch then depends on when another thread runs |
| strict priority | a lower class can starve without bound |
| DRR, as decision 30 uses for tasks | a disk operation's cost spans 1 to about 2^21 I/O units, so a quantum below the largest cost needs decision 30's bulk credit; a scan of 8 classes at each dispatch is cheap beside a disk operation, where a scan of 16 groups for each task of 10 ns is not |
| a pump that skips to a smaller head | a large operation can starve |
| a time quota, or a refill counted per tick | the quota is excluded (decision 27, open question 13); a refill per tick measures the tick rate and no bandwidth |
| `ioprio` on the SQE | an NVMe device under the `none` elevator ignores it (recalled) |
| exact counts per class, written on each dispatch | decision 9 keeps statistics sampled; R5 allows exact counts only on the slow path |
| the scheduler under `.blocking` | an inline call is never out beside another, so a limit bounds nothing |
| remove `InFlight.held` now | it changes code of 2026-11-06 that a loop with no queue still needs |

## How it would be checked

**Unit tests in `src/core/io_queue.zig`**, with a fixture like `offload_in_flight.zig`'s:

1. FIFO inside a class.
2. Shares 3:1 over 4,000 equal dispatches give 3,000 and 1,000, within 1.
3. The device's operation limit and unit limit; an operation above `units_max` goes out alone.
4. The pump stops a device at a head that does not fit, and takes no smaller head.
5. An idle class gets no credit.
6. Ties go to the lower index.
7. A requeue keeps the charge. A short read gives back its full cost.
8. A slot that held a charged read, then a receive, gives back nothing.
9. Cancel, deadline and close of held operations, with the order kept.
10. Passes that start near 2^64 compare right.

**A property test** draws from `core.random`, and prints its seed. It runs random submits, final
events, cancels, closes and requeues. Its invariants: the units out equal the cost of the charged
slots; each operation has exactly one final event; no device stops while it has room and held work;
for two classes that hold work, each one's dispatched units stay within one maximum cost of its
share; the same calls at other slot indices give the same order.

**Conformance**, `src/conformance/conformance_io_queue.zig`, on io_uring and epoll in the Linux
gate, kqueue with `.offload` on macOS, and again with the spin budget:

- A bulk class with 256 reads and a journal class, at shares 100 and 1000. An fsync submitted last
  goes out within `operations_max` plus 10 dispatches.
- Each operation gets exactly one event.
- A held read with a deadline of 1 ms ends with `timeout`. A cancel ends a held read with
  `canceled`. A `close` ends a held write before its own event.
- Under `.offload`, 300 reads with a queue: `InFlight.held` stays empty.
- A loop with no queue keeps the trace of each scenario of today.

**The race gate** runs the conformance scenario on epoll with the offload.

**Halt scenarios** in `tools/halt/core_scenarios_io.zig`. Each must die by a signal, and return once
its assertion is deleted:

| scenario | class |
|---|---|
| an add after `Loop.init` sealed the queue | C |
| shares 0; `operations_max` 0 | C |
| the sum of `operations_max` above `offload_in_flight_max` under `.offload` | C |
| a queue with `file_policy` `.blocking` | C |
| `InFlight.hold` with a queue | C |
| a class index at or above `class_count` | A |
| a class on an operation of a loop with no queue | A |
| a release with nothing out | A |
| a sleep with work held and nothing out | B |
| `deinit` with work held or units out | C |

**Mutations**, each against the narrowest target. Each must be CAUGHT.

| mutation | caught by |
|---|---|
| the fast path ignores held work on its device | `test-core`, tests 1 and 2 |
| the idle clamp removed | `test-core`, test 5, and the property |
| the pump skips to a smaller head | `test-core`, test 4, and the TLA+ mutant |
| ties go to the higher index | `test-core`, test 6 |
| release uses the result in place of `len` | `test-core`, test 7 |
| a requeue charges again | `test-core`, test 7 |
| `fill` does not write the `io` byte | `test-core`, test 8 |
| the release is removed | the property, and the `deinit` halt |
| a close skips the class lists | the conformance close scenario |
| the cancel walk is skipped | the conformance cancel scenario |
| the deadline is armed at dispatch | the conformance deadline scenario |
| each class A, B or C assertion deleted | `halt-check` |

**The model.** `spec/tla/ioqueue/` holds one loop thread, two offload workers with result rings,
two devices, three classes, and cancel, close, deadline and sleep. Its invariants: OneFinalEvent;
CapacityExact (the units out equal the cost of the dispatched operations not yet reaped);
OffloadCount at or below `offload_in_flight_max`; HeldEmptyWithQueue; NoLostWake (a loop that
sleeps has a worker that owes a result, or nothing held). Its liveness: each held operation goes
out or ends. Mutants that must fail: a release removed, a sleep with no wake, a skip to a smaller
head, a push past the ring's bound.

**Lean**, in `proofs/`: the stride lag bound and the wrap lemma.

**Gates.** The work gate holds every row within 2 percent. A new row, `io-queue`, runs 64 reads
and fdatasyncs on a temporary file through two classes. It is Linux only, because cachegrind
counts user instructions and macOS counts the kernel's file work too. A cost-gate bound covers one
pick at 8 classes.

## Open questions

Camilo ruled on each one on 2026-11-07, with its proposed answer. The rate rule of question 2
waits for a ruling of its own.

1. **Classes and groups.** (a) Classes are their own index space. (b) A decision 30 group carries
   I/O shares, as Seastar binds them. *Ruled: (a). Disk shares and CPU shares are different
   resources: a journal sync costs little CPU and needs a large disk share. A later amendment may
   let a group name a default class.*
2. **The rate rule.** (a) Build the capacity and share rules now, and the rate rule after its own
   ruling, when stompy names a class that needs it. (b) All three now, after decisions 9 and 13
   are amended. (c) No rate rule; the pacer of the guide only. *Ruled: (a). The rate rule waits
   for its own ruling.*
3. **One disk, many loops.** (a) A static split: each loop gets its own `operations_max`. (b) A
   bucket shared through decision 21's memory, as Seastar's io group shares one (recalled).
   *Ruled: (a). A shared bucket puts a line that all cores write on each dispatch.*
4. **An operation with no class, on a loop with a queue.** (a) The default class. (b) A halt, so a
   class that was left out is loud. *Ruled: (a). A halt breaks a library that does not know the
   queue exists.*
5. **The default costs.** The read and write cost of 1 unit, 4 KiB a unit, and a sync of 64 units
   are priors. *Ruled: set them from the W7 bench of fsync beside reads on a named machine
   before the defaults are fixed.*
6. **W7 first.** (a) W7 measures io-wq caps of 2, 4 and 8 before this is built. (b) Build now, with
   the guide's rule of `operations_max` 2 or less for a sync class. *Ruled: (a). The W7 disk bench
   runs before the build. On io_uring the cap of 2 can hide the queue's order for buffered
   syncs.*
7. **`io_state`.** (a) Public, on both views, as state. (b) Left out until W9's counts. *Ruled:
   (a). It reads state the queue holds, and an operator needs to see held work.*
8. **A second pump after the reap.** Room that a reap frees goes out at the next flush, up to one
   tick later. (a) The flush only. (b) Also after the reap. *Ruled: (a), then measure.*
9. **The order of the build.** Decision 30 proposed W3, decision 29, decision 30, then decision 32.
   *Ruled: W3, decision 29, decision 30, decision 32, and this record after the W7 bench (open
   question 6). It needs nothing of decisions 30 and 32.*

## Ask before

These items of CLAUDE.md's "Ask before" apply:

| item | today | proposed |
|---|---|---|
| decision 2's scope | no disk scheduler | a row "disk I/O" in "In version one"; accepted 2026-11-07 |
| new named limits | | `io_devices_max` 4, `io_classes_max` 8, `io_shares_max` 1000, `io_stride_scale` 2^20 |
| a hot structure: `Tables` | | 8 B more: `io` |
| a hot structure: `Slot` | 2 reserved bytes | 1 becomes `io`; the size stays 64 B; `fill` writes it |
| a hot structure: `Operation` | | 1 B on each file kind; the size must not change |
| decision 18's held list | one FIFO for all file operations | empty when a queue is set; a new class C assertion in `hold` |
| the rate rule (not ruled; it waits for its own ruling) | | amend decision 9 (a rule 8) and decision 13, point 4 |
| the work gate | | a new row, `io-queue`, on Linux |
| the models | | a new `spec/tla/ioqueue/`, and two Lean lemmas |

- **Decision 7's hot files.** The flush in `uring_submit.zig`, `kqueue_submit.zig` and
  `epoll_submit.zig` gains plain branches. No ugly technique is used, so no ledger row is needed,
  and no file joins the list. `src/core/io_queue.zig` starts plain.
- **No assertion is weakened.** The record adds no dependency and no edge to the module graph:
  `io_queue.zig` lives in `core`.

## Sources

- Seastar `reactor.cc`, a copy in the session's scratchpad, read on 2026-11-07:
  `update_shares_for_queues` calls `update_shares_for_class` for each scheduling group;
  `update_bandwidth_for_queues` divides the bandwidth by `_num_io_groups`; `next_pending_aio`
  bounds the sleep; `io-latency-goal-ms` defaults to 1.5 times `task-quota-ms`.
- Seastar `doc/io-scheduler.md`: https://github.com/scylladb/seastar/blob/master/doc/io-scheduler.md.
  The drafts of this record read it: a ticket of operations and bytes, writes weighted against
  reads, a bucket that holds the tokens of one latency goal. It was not read again for this text.
- Recalled and not checked: an `io_queue` for each `dev_t`; the `fair_queue` cost per class over
  shares; an `io_group` bucket that shards share through atomics; I/O priority classes merged into
  `scheduling_group`; Seastar requires O_DIRECT; an NVMe device under `none` ignores `ioprio`;
  O_DIRECT reads on io_uring do not use io-wq.
- ScyllaDB, the I/O scheduler: https://www.scylladb.com/2016/04/29/io-scheduler-2/
- The robustness plan of 2026-11-06: F4, F10, W3, W7, W9, R3, R5, R10.
- The tree at `5e9490d`: `src/core/offload_in_flight.zig`, `src/core/slot.zig`,
  `src/core/operation.zig`, `src/core/tables.zig`, `src/uring/constants.zig`,
  `bench/baseline/work.txt`.
