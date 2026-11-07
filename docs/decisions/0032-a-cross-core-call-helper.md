# 32. A cross-core call

Status: accepted on 2026-11-07 (see "Ruling, 2026-11-07"). Nothing is built. Every cost here is a
prior: a row of `docs/costs.md`, a row of `bench/baseline/work.txt`, or an instruction count from
arithmetic. Nothing was measured for this record.

## Ruling, 2026-11-07

Camilo ruled on decisions 30, 31 and 32 together. For this record:

1. **This record is accepted** with the proposed answer to each open question, and with the items
   of "Ask before" that the proposal held, except for the question in item 2.
2. **The caller chooses a call's group** (open question 10). His words were "B now, named groups".
   The caller names the scheduling group that the call runs in on the target, as Seastar does.
   Decision 30 gains groups by name, so every loop agrees on what a group is. "Scheduling groups
   (decision 30)" below is the design.
3. **Decision 30 is accepted.** Decision 31 is accepted for capacity and shares. Its rate rule waits
   for its own ruling, and the W7 disk bench runs before decision 31 is built.
4. **The build order** is W3 (the fair tick order), decision 29, decision 30, then this record.
   Decision 31 follows the W7 bench.

Later the same day he ruled on the four choices that the design for item 2 added. Before this
ruling, the list "Left for Camilo" held them:

5. **No default group on the target.** `ServeOptions` is gone. Every call names its group, and a
   call that wants no group of its own writes `.default`. The other choice was a default group in
   `ServeOptions`, and the group of a call would then depend on the target again.
6. **Each call carries its own task, as Seastar does.** He chose this over both proposed choices.
   They were one call lane for each group id on each loop, and a task for each service and group
   in each station. Seastar's `work_item` derives from `task`, and is built with
   `task(current_scheduling_group())` (read in `smp.hh`, see "Seastar"). So each `CallRecord`
   carries a `Task`. The target's drain schedules it in the group that the caller named, and it
   runs the handler. The caller's drain schedules it in the same group, and it runs `finish`. The
   call lanes are removed. "The task queue and the fair tick" is the design.
7. **The names and the tests follow decision 30.** The program declares its names in its root
   source file, and a test passes its own table (decision 30, ruling items 5 and 7).
8. **`finish` runs in the call's group on the caller's loop** (open question 9). No
   `Service.attach` is added.

The per-call task added four more choices. Later the same day he ruled on them, each with its
proposed answer:

9. **`CallLink` is 64 B, and keeps the pointer `calls_out`.** Item 6 put the task in the record,
   at 16 B more in the caller's record. The 16 B `Task` takes the place of the lane's
   8 B `next`, and the 8 B pointer names the count that `finish` lowers. The other choice was 56 B
   with no pointer, at several dependent loads for each call ("Alternatives it beat"). With the
   pointer, `CallStation` holds `loop` in place of `run` and `entry`, and `self_out` becomes a
   `u32`. The station stays 128 B.
10. **`calls_out` falls when `finish` runs**, on the caller's thread, and not when the drain pops
    the return. So the calls of one pair bound the queued tasks of calls.
11. **A call's task has its own limit.** Each push of a call's task uses the limit
    `tasks_queued_max + call_tasks_max` = 82,368, and so does a call to self. The cap of each
    group refuses only `schedule` and `schedule_in`. Each bound of a queue's length reads the sum
    (decision 30, "A queue cap for each group"). Two other choices lost ("Alternatives it beat").
12. **`Task.Call` gains `call_record: bool`** in its padding, so `discard_tasks` halts on the queued
    task of a call. `Task.Call` stays 32 B.

It amends decision 2, because it adds a row to the "In version one" table. It also amends these
records:

- decision 4, at the room for a post in a ring, and at the tags a post may carry;
- decision 5, with a rule of one result for each call;
- decision 21, at the content of a `Mailbox` and at `header_version`;
- decision 26, at the count `callbacks_outstanding` and its property P7;
- decision 27, at `discard_tasks`, at the bound of the task queue, and at open question 14 for a
  call;
- decision 29, at `message_tag_max` and at the compare in the drain;
- decision 30, which gains named groups for this record, two counts in its `Groups`, and a limit
  for the push of a call's task.

## Context

On 2026-11-07 Camilo chose to add three Seastar features to rotor: scheduling groups (decision
30), a disk I/O scheduler (decision 31) and a cross-core call helper. This record is the call
helper. His requirements apply to it:

1. **The API is simple to use correctly.** Wrong use fails to compile. Where the compiler cannot
   see it, wrong use halts at once.
2. **It is robust under one reactor per core.** stompy runs one loop per CPU core. colibri and
   cocuyo share each core's loop.

stompy shards by key. A request that arrives on core 3 for a key of core 7 runs on core 7, and its
answer comes back to core 3. Its journal lives on one core, and every core appends to it.

### What the code does today

- A loop sends a 16-byte `Message` to another loop through a single-producer single-consumer ring
  of 256 messages, one for each ordered pair of loops (decision 4).
- A message becomes an `Event` for the program. A post carries no record (decision 26, open
  question 2), and no task (decision 27, open question 14, ruled on 2026-11-06).
- Decision 29 is accepted and not built. It reserves `message_tag_wake` (`0x7fff_f000`) and sets
  `message_tag_max` to `0x7fff_efff`.
- W3 of the robustness plan, a fair tick order, is ruled and comes first. It drains the senders
  from a rotating cursor, inside a reserve of `events` for the mailboxes.

So each consumer builds its own request record, reply path, count of requests out, and answer to
`MailboxFull`.

### Seastar

`smp::submit_to(shard, func)` runs `func` on another shard and returns a future. This record
checked these facts in a local copy of Seastar's `src/core/reactor.cc`:

- Each ordered pair of shards has two lock-free queues: `_pending` for requests and `_completed`
  for replies.
- `submit_item` takes one unit of a semaphore for each `smp_service_group` and target, through
  `get_units(sem, 1, timeout)`. So the timeout applies to the wait for admission.
- Requests wait in `pending_fifo`, and replies in `_completed_fifo`, until `batch_size` of them
  are ready. A `work_item` is a heap object, and its pointer crosses the cores.

Read in Seastar's `include/seastar/core/smp.hh` on 2026-11-07:

- The timeout of `smp_submit_to_options` covers only the wait to be processed on the remote shard,
  and not the run there.
- `work_item` derives from `task`. The caller's shard builds it with
  `task(current_scheduling_group())`, so each call is a task that carries its group.
- How the target's scheduler then puts that task in the group's run queue was not traced.

Recalled, and not checked: a pair queue holds 128 items, `batch_size` is 16, and a `submit_to`
cannot be cancelled.

rotor keeps the pointer to a record, a bound on the requests out for each pair, and a reply path
that cannot fail. It also keeps the caller's choice of group, and a task in each call. It drops the
heap, the admission wait, and the second queue.

## The decision

1. **A `Service` is one kind of call.** The program declares it once, with a context, a request
   type, a reply type and a handler. It holds one station for each loop.
2. **A call is a record that the caller owns.** The ring carries its address. The record is the
   target's from the push until the target answers, and the caller's again when its result runs.
3. **The caller names the group, and each call carries its own task.** A call names a named group
   of decision 30. The target's drain schedules the record's task in that group, and the task runs
   the handler. The caller's drain schedules the same task in the same group, and the task runs
   `finish`. A loop schedules the task only on its own queue, and only while it owns the record.
4. **Each accepted call ends with exactly one result** at the caller: `replied`, `expired` or
   `target_stopped`.
5. **A return never meets a full ring.** A post sees 224 of 256 slots, and at most 32 calls are
   out on each pair. Above that, `send` returns `CallsFull` at once.
6. **A loop that makes no calls pays nothing** on any path that the work gate counts.

### The surface

```zig
// src/rotor/rotor_service.zig, exported from `rotor`.
pub fn Service(
    comptime Context: type,
    comptime Request: type,
    comptime Reply: type,
    comptime handler: fn (context: *Context, call: *CallRecord(Request, Reply)) Answer(Reply),
) type {
    return struct {
        /// One station for each loop, indexed by `LoopId`. Program memory, 128 B each. The type
        /// also has one static `Task.Call`, named after `handler`, which a call's task runs on the
        /// target.
        stations: [constants.loops_max]core.CallStation,
        /// Every station unused. A program declares the service once, as a static.
        pub const init: @This();
        pub const Call = CallRecord(Request, Reply);

        /// The loop of `shared` serves this service with `context`. Its thread calls it before
        /// its first tick. It halts on a station that serves, and in a decision 21 group.
        pub fn serve(service: *@This(), shared: *SharedLoop, context: *Context) void;
        /// The loop of `shared` stops. A call that reaches it later gets `target_stopped`.
        pub fn stop_serving(service: *@This(), shared: *SharedLoop) void;
        /// Sends `request` to loop `target`. On an error nothing was sent, and `finish` does
        /// not run. It halts when `call` is out already, and on a forged group id.
        pub fn send(service: *@This(), shared: *SharedLoop, target: LoopId, call: *Call,
            request: Request, options: CallOptions) CallError!void;
    };
}

/// The caller's record, in the caller's struct. Size 64 B + Request + Reply, alignment 8. Its
/// link holds the call's task and the pointer `calls_out` (ruling items 6 and 9).
pub fn CallRecord(comptime Request: type, comptime Reply: type) type {
    return struct {
        link: core.CallLink,
        request: Request,
        reply: Reply,

        /// `finish` runs exactly once for each `send` that returns success, in the call's task.
        /// `init` builds a static `Task.Call` for it, named after `Parent` and `field`.
        pub fn init(comptime Parent: type, comptime field: []const u8,
            comptime finish: fn (parent: *Parent, result: CallResult(Reply)) void) @This();
        pub fn is_out(call: *const @This()) bool;
        /// Target side: the request, from the handler's start until the answer.
        pub fn request_of(call: *const @This()) *const Request;
        /// Target side, after `.later`: answers once, on the target's thread.
        pub fn answer(call: *@This(), shared: *SharedLoop, reply: Reply) void;
    };
}

/// What a handler returns. The compiler requires a choice, and a reply with `.now`.
pub fn Answer(comptime Reply: type) type {
    return union(enum) { now: Reply, later };
}
/// What `finish` receives. The caller must switch on it.
pub fn CallResult(comptime Reply: type) type {
    return union(enum) { replied: *const Reply, expired, target_stopped };
}
pub const CallOptions = struct {
    /// The group the handler runs in on the target, and `finish` runs in on the caller (decision
    /// 30, "Named groups"). No default: a call that wants no group of its own writes `.default`.
    group: NamedSchedulingGroup,
    /// On the loop clock (`now_ns`). 0: none. The target compares it before the handler runs.
    deadline_ns: u64 = 0,
};
pub const CallError = error{ CallsFull, MailboxFull, LoopNotFound };
```

`SharedLoop` and each `Loop` gain `call` and `answer`, which take a `*CallLink`. Only `Service`
and `CallRecord` call them. A `Remote` gets neither, so a thread with no loop cannot call.

stompy's journal, as an example. `Journal.append` queues the call and returns `.later`, and it
calls `answer` after the fsync:

```zig
const Append = rotor.Service(Journal, AppendRequest, AppendReply, Journal.append);
var append: Append = .init; // one for the process; the journal's core calls `serve`

const Writer = struct {
    append_call: Append.Call = .init(Writer, "append_call", on_appended),
    group: rotor.NamedSchedulingGroup, // from the program: named_scheduling_group(.journal)
    fn on_appended(writer: *Writer, result: rotor.CallResult(AppendReply)) void {
        switch (result) { .replied => |reply| ..., .expired => ..., .target_stopped => ... }
    }
};
try append.send(shared, journal_core, &writer.append_call, .{ .bytes = ... },
    .{ .group = writer.group });
```

| wrong use | result |
|---|---|
| a request, a reply or a context of the wrong type | fails to compile |
| a handler with the wrong signature, or `.now` with no reply | fails to compile |
| a `finish` that does not take the service's `CallResult` | fails to compile |
| a call from a `Remote` | fails to compile |
| a `send` that names no group, a group of type `SchedulingGroup`, or a name the program did not declare | fails to compile |
| a `send` of a record that is out | halts |
| a `send` with a forged group id (`@enumFromInt` above the declared count) | halts, at the caller |
| a second answer, or an answer from another thread | halts |
| a call that reaches a loop that never served the service | halts, on the target |
| `discard_tasks` while the task of a call is queued | halts |
| `serve` on a station that serves, or in a decision 21 group | halts |
| `deinit` while a call is out or held, or while a station serves | halts |

### The flow

1. **`send` on the caller C.** It writes the request. In the link it writes `origin`, `target`,
   `group`, `deadline_ns`, `generation + 1` and the state `out`. It also writes the address of the
   count of ring C to T, `calls_out`, and the service's static entry in `task.call`. It calls
   `call`.
2. **`call`.** It halts on a group id above C's `Groups.named`. At `calls_per_pair_max` in
   `calls_out` of ring C to T, it returns `CallsFull`. Otherwise it pushes
   `{ payload = &link, tag = message_tag_call, reserved = generation }` through `push_post`. On
   success it adds 1 to `calls_out` and to `callbacks_outstanding`. On an error it sets `idle`
   again and changes nothing else.
3. **The drain on T.** One compare, `tag > message_tag_max`, sends a reserved tag to a cold
   function, `Inbox.take_reserved`. It checks the link, the group included, sets `held`, and adds 1
   to `callbacks_outstanding`. It schedules the record's task in the link's group on T, as
   `schedule_in` does, with the limit of "The task queue and the fair tick". It writes no event.
4. **The record's task on T.** Its entry is the service's static `Task.Call`, named after the
   handler. When the service's station on T has stopped, it answers `target_stopped`. When the
   deadline is at or before the cached `now_ns` of the station's loop, it answers `expired`. In
   both cases the handler does not run. Otherwise the handler runs: `.now` answers `replied`, and
   `.later` keeps the call held. The task is one task of cost 1 (decision 30). A handler that does
   more work calls `charge_task`, as any task does.
5. **`answer` on T.** It sets `answered`, and pushes `{ payload = &link, tag =
   message_tag_return, reserved = generation }` through `push`, which sees all 256 slots. It
   subtracts 1 from `callbacks_outstanding`.
6. **The drain on C.** It checks the link and sets `back`. It writes the record's `finish` entry in
   `task.call`. It schedules the record's task in the call's group on C, with the same limit as
   step 3. It subtracts 1 from `callbacks_outstanding` for the call, and the queued task counts in
   its place until it runs.
7. **The record's task on C.** Its entry is the `finish` entry, named after the caller's field. It
   sets `idle`, subtracts 1 from the count that `link.calls_out` names, and calls `finish`. So
   `finish` may send the same record again. `calls_out` falls here, and not in the drain (ruling
   item 10). So the calls of one pair stay at or below `calls_per_pair_max` until each `finish`
   runs, and that bounds the queued tasks of calls.

A call to the caller's own loop uses no ring. The station's `self_out` bounds such calls at
`calls_per_pair_max`: `send` writes its address in the link's `calls_out`. The steps change:

- **`call`** checks the group id and the count, as step 2 does. It adds 1 to `self_out`. It adds 1
  to `callbacks_outstanding` for the call out, as step 2 does. It adds 1 more for the call held, as
  step 3 does. Then it sets `held` and schedules the record's task in the call's group on its own
  loop.
- **`answer`** pushes nothing. It subtracts 1 from `callbacks_outstanding` for the call held, as
  step 5 does. It subtracts 1 more for the call out, as step 6 does. Then it sets `back`, writes the
  `finish` entry, and schedules the task again in the same group.
- **Each push of the task** adds 1 to `callbacks_outstanding`, as any push does. It uses the limit
  `tasks_queued_max + call_tasks_max`, as the drain does. So `call` never meets `TasksFull`, which
  `CallError` cannot state (ruling item 11).
- **The overflow assert** counts a call to self twice, out and held, in its `services_max` term
  (see "Layout").

The handler and `finish` run in later task runs, never inside `send`.

### Ownership, the analogue of decision 5

**Each `send` that returns success makes at most one run of the handler and exactly one run of
`finish`. A `send` that returns an error makes neither.**

| state | owner | who writes it |
|---|---|---|
| `idle` | the caller | the record's task on the caller's loop, just before `finish` |
| `out` | the target, from the push | the caller's `send`, before the push |
| `held` | the target | the target's drain, or `call` for a call to self |
| `answered` | the caller's loop, from the push | the target's `answer`, before the push |
| `back` | the caller's loop | the caller's drain, or `answer` for a call to self |

- Each change of owner is a ring push, with the `.seq_cst` store of `tail`, and a pop, with the
  load of `tail`. `mailbox.zig` argues these orderings for a slot's bytes. They also make the
  request visible to the target, and the reply to the caller. The record needs no atomic.
- The record's task belongs to the loop that owns the record. Only that loop's thread queues it,
  on its own queue. The target's run pops the task before the handler, and the pop clears `next`.
  So the task is not queued on the target when `answer` pushes the return, and the caller's push
  meets an unqueued task. On the target, the push of the return is the last read or write of the
  record, its task included.
- The program must not touch the request or the reply while `is_out` is true. Zig cannot refuse
  that, as it cannot refuse a write to a `Completion` in flight.
- **A call message never outlives its record.** The record leaves `out` only when its message is
  popped. The caller cannot free it before `finish`: `drain` does not end, and `deinit` halts,
  while `callbacks_outstanding` counts it.

### Backpressure, and why a return cannot fail

- A new `Mailbox.push_post` refuses at `mailbox_posts_max` = 256 - `calls_per_pair_max` = 224.
  `core.remote.send` uses it, so it covers `Loop.post`, the post operation, `Remote.post`,
  `Message.wake` and `call`.
- `Mailbox.push` keeps all 256 slots. `answer` uses it, and so do the offload's result rings,
  whose `offload_in_flight_max` equals `mailbox_messages` (decision 18).
- `calls_out` is a `u32` on the producer's `tail` line of ring C to T, in bytes that are padding
  today. Only C's thread writes that line, so the count needs no atomic.

The proof:

1. Each post in ring T to C was pushed while the ring held fewer than 224 messages. So the posts
   in it are at most 224.
2. Each return in ring T to C answers a call that C counts in `calls_out` until its `finish` runs.
   So while T pushes one return, the others are at most 31.
3. So a return push sees at most 255 used slots. A failed return push halts (class B).

| error | meaning | what the caller does |
|---|---|---|
| `CallsFull` | 32 calls to that target have not yet run their `finish` | send again from a later `finish`, or answer its client "busy" |
| `MailboxFull` | the ring holds 224 messages | send again in a later tick, from its own task |
| `LoopNotFound` | the target has no loop, or it left | the stop order below |

rotor keeps no hidden queue, and this record adds no counter. If Camilo rules R5 as proposed,
W9's exact counts of refusals count these errors on the slow path.

### The task queue and the fair tick

Camilo chose a task for each call on 2026-11-07, as Seastar's `work_item` is a task. The task is
`CallLink.task`, in the caller's record. Each run of it is one task of decision 30.

- **A call's task is queued only while its loop owns the record.** On the target it waits from
  the drain until the handler runs. On the caller it waits from the drain of the return until
  `finish` runs. A call to self waits once for each of the two runs.
- **The calls bound the queued tasks of calls.** `calls_out` counts a call from `send` until its
  `finish` runs (step 7). So on one loop L, at one time, these tasks can wait:
  - calls from each other loop to L: at most `calls_per_pair_max` each, so (`loops_max` - 1) x 32
    = 8,160;
  - calls of L that came back to L: at most `calls_per_pair_max` for each other loop, so 8,160
    more;
  - calls to self: at most `calls_per_pair_max` for each station, `self_out`, and at most
    `services_max` stations, so 16 x 32 = 512.
- So `call_tasks_max` = (2 x (`loops_max` - 1) + `services_max`) x `calls_per_pair_max` =
  (510 + 16) x 32 = 16,832, a new constant derived at comptime. It is about a quarter of
  `tasks_queued_max` (65,536), so the calls alone never fill a group.
- **A full group cannot make a drain fail.** The program's own tasks can fill a group to its cap,
  and a drain cannot refuse a call that it popped. So the drain pushes a call's task with the limit
  `tasks_queued_max + call_tasks_max` = 82,368. The cap refuses only `schedule` and `schedule_in`. A
  group's `u32` count holds the sum. Each bound of a queue's length reads the sum too (decision 30,
  "A queue cap for each group"). Camilo ruled this limit on 2026-11-07 (ruling item 11).
- The first `serve` or `send` of a service on a loop sets `attached` in its station. It also adds 1
  to a new byte `stations`, in the padding of decision 30's `Groups` header. Above `services_max` it
  halts (class B, cold). So too many services halt at the first call, and not only under load.
- A call's task counts as one start of `tasks_per_tick_max`, as any task does. Call and return
  messages take no slot of `events`, and W3's cursor pops them inside the mailbox share. So a flood
  of calls cannot starve I/O or another sender. Decision 30's DRR shares each group's starts
  between its calls and its other tasks.
- **The stall record names the exact call.** Decision 28's run stores the name of each task's
  static entry in `running` before the call. On the target, the entry is the service's static
  `Task.Call`, named after its handler. On the caller, it is the record's `finish` entry, named
  after the caller's field. So a stall of one call's task names that call, with its group (decision
  30). This adds no store: the store of `running` is the one that each task run makes.
- `discard_tasks` halts on a queued task whose static entry has `call_record` set (class C, cold).
  It reads each task's entry in the walk that it makes anyway. A call cannot be discarded, because
  its caller waits for `finish`. Camilo ruled the flag on 2026-11-07 (ruling item 12).

### Scheduling groups (decision 30)

The caller chooses the scheduling group, by Camilo's ruling of 2026-11-07. Seastar does the same:
its `work_item` is a task, built with `current_scheduling_group()` on the caller's shard (read in
`smp.hh`, see "Seastar"). A reserved group id belongs to one loop. So a call names a
`NamedSchedulingGroup`, which decision 30's declaration makes the same group on every loop.

- **The group crosses in the link.** `send` writes the group in a byte of `CallLink`. The target
  reads the link in the drain anyway, so the 16-byte `Message` does not change, and `reserved`
  keeps the generation. The ring's push and pop make the byte visible, as they do for the request.
- **The target runs the handler in that group.** The drain schedules the record's task in the
  group `group.scheduling_group()`, on the target's own thread. No thread writes the queue of
  another loop.
- **The caller runs `finish` in the same group.** The drain on the caller schedules the same task
  in the call's group on its own loop. So a loop that calls and does not serve runs `finish` in a
  group that its source names. Camilo ruled this answer to open question 9 on 2026-11-07.
- **A forged id halts.** Core's `call` compares the id with the caller's `Groups.named`, and halts
  above it (class B). The check reads the loop and not the root, so a test with its own table
  reaches it. `take_reserved` checks the id again on the target against its own `Groups.named`, with
  the other checks of the link. A target cannot lack a named group, because every loop reserves the
  declaration at init. Decision 30's check in `schedule_in` compares the id with `reserved`. So it
  does not catch a forged id that names a group of the target's own reserve.
- **The target sets no default.** `ServeOptions` is gone. A call that wants no group of its own
  writes `.default`, as decision 30, rule 3 asks of `schedule_in`.
- **A loop that makes no calls pays nothing new on the hot path.** No tick reads a structure of
  this record. A call adds a load and a compare at `call`, and the group's index at each drain:
  about 4 instructions. The load reads the `Groups` header, a line that `call` touches for nothing
  else, so a cold one costs C3.

### A target that stops (W4)

A station has three states: `unused`, `serving` and `stopped`. `serve` and `stop_serving` change
them, on the station's own loop. `serve` and `stop_serving` change a second new byte, `serving`,
in the padding of decision 30's `Groups` header, and `deinit` halts while it is above 0 (class C).
So a loop that ends always leaves its stations `stopped`.

This record asks three things of W4's `Loop.leave()`, which is not designed yet:

1. After `leave`, `call` to that loop returns `LoopNotFound` before the push. `remote.send`
   already reads the target's entry before it pushes (`remote.zig:87-91`). W4 decides the mark.
2. `leave` pops each inbound ring to empty. A call that it pops reaches a `stopped` station and
   gets `target_stopped`.
3. `answer` is never refused, so a loop that leaves still gets back the calls it sent.

A window stays: a sender reads the entry, the target pops for the last time, and then the sender
pushes. The call stays in the ring, and its record stays `out`, so it stays valid.

- When a loop claims the id again, decision 4 says it reads the ring. If it serves again, it
  serves the call. If not, the `stopped` station answers `target_stopped`.
- When no loop claims the id, the call is stranded. The caller's `drain` returns `StillInFlight`,
  and decision 28's heartbeat names the loop that waits.

The stop order in `docs/using.md` closes the window:

1. Every loop stops calls and posts, through a flag of the program, then a barrier.
2. Every loop runs `drain`, again on `StillInFlight`, until it holds no call and has none out.
3. Every loop calls `stop_serving` for each service, then W4's `leave`, `cancel_all`, `drain` and
   `deinit`.

A target whose thread exits after a fatal tick error (F6) strands the calls it holds (open
question 5).

### Decision 21 groups

A pointer does not cross a process. `call` and `serve` halt in a registry of a group (class B, one
load). The drain halts on a call or return tag in a group (class B, cold). That catches a peer of
an older build that sent such a tag as data. A program passes an index into its shared region in
a plain `Message`.

## Layout

| structure | change | size, alignment |
|---|---|---|
| `CallLink` | new, in the caller's record. `task: Task` takes the place of the lane's `next`, and `calls_out: *u32` is added (ruling items 6 and 9) | 64 B, 8 (comptime assert); the proposal had 48 B, and 56 B without the pointer |
| `CallStation` | new, in the program's `Service`. With the per-call task it holds `loop` in place of `run` and `entry`, and `self_out` is a `u32` | 128 B, 128 (comptime assert) |
| `Service` | new, in program memory | 32 KiB at `loops_max` 256 |
| `Mailbox` | `calls_out: u32` after `tail` | 4352 B, 128: no change (comptime assert) |
| `Groups` (decision 30) | `stations: u8`, `serving: u8`, in 2 B of its padding; no call lanes | 536 B, 8: no change |
| `Message` | none: the group crosses in `CallLink`, and `reserved` keeps the generation | 16 B: no change |
| `Dispatch`, `Tasks`, `Inbox`, `Tables` | none. Decision 30 leaves no padding in `Dispatch` | no change |
| `Task.Call` | one static entry for each `Service` type and one for each `finish`. `call_record: bool` in its padding (ruling item 12) | 32 B (decision 30): no change; static data |

The overflow assert of `callbacks_outstanding` (decision 30) gains the calls and their tasks. The
term is `2 * (loops_max - 1 + services_max) * calls_per_pair_max + call_tasks_max`, which is
17,344 + 16,832 = 34,176. A loop counts a call that it sent until its return reaches the drain,
and a call that it holds until it answers. A queued call's task counts as any task does.
`self_out` bounds the calls to self at `calls_per_pair_max` for each station. The proposal's first
term, `services_max` call tasks, is gone.

```zig
/// The part of a call that the loops schedule and post (decision 32). Size 64 B, alignment 8.
pub const CallLink = struct {
    task: Task, // 16 B; its `call` is the service's entry on the target, `finish` on the caller
    stations: *[constants.loops_max]CallStation, // the service's stations; `send` writes it
    finish: *const Task.Call, // a static entry named after the caller's field; `init` writes it
    calls_out: *u32, // the count of ring origin to target, or the station's `self_out`
    deadline_ns: u64, // 0: none
    generation: u32, // plus 1 for each `send`; the message's `reserved` carries it
    origin: LoopId,
    target: LoopId,
    state: State, // idle, out, held, answered, back
    outcome: u8, // replied, expired, target_stopped; `answer` writes it
    group: NamedSchedulingGroup, // the caller's choice; `send` writes it
    // 5 B of padding
};

/// One service on one loop. Only that loop's thread writes it. Size 128 B, alignment 128.
pub const CallStation = struct {
    context: ?*anyopaque, // `serve` writes it
    loop: ?*SharedLoop, // `serve` writes it; a call's task reads `now_ns` and answers through it
    held: u32, // calls answered `.later` and not yet answered
    self_out: u32, // calls to self that have not yet run their `finish`
    state: enum(u8) { unused, serving, stopped },
    attached: bool,
    // 102 B of padding to 128
};
```

Before the ruling, each loop held 16 call lanes of 32 B in `Groups`, 512 B, which every service
shared. The per-call task removes them. In their place each call pays 16 B in its record. The
`Task` takes 8 B more than the lane's `next`, and `calls_out` takes 8 B.

The 128 B is `mailbox_index_alignment`, so two loops' stations never share a line on Apple
silicon. 64 B is enough on x86-64 (open question 6).

New constants in `src/core/constants.zig`, each with a doc comment:

| constant | value | comptime assert |
|---|---|---|
| `calls_per_pair_max` | 32, a prior | `< mailbox_messages` |
| `mailbox_posts_max` | `mailbox_messages - calls_per_pair_max` = 224 | `>= messages_per_drain` |
| `services_max` | 16, a prior | `<= maxInt(u8)`, the byte `stations` |
| `call_tasks_max` | `(2 * (loops_max - 1) + services_max) * calls_per_pair_max` = 16,832; ruling item 11 | `tasks_queued_max + call_tasks_max` fits in u32 |
| `message_tag_max` | `0x7fff_effd` (decision 29: `0x7fff_efff`) | `< message_tag_call` |
| `message_tag_call` | `0x7fff_effe` | `< message_tag_return` |
| `message_tag_return` | `0x7fff_efff` | `< message_tag_wake` |

`message_tag_wake` stays `0x7fff_f000`, the highest tag. So decision 29's errno margin assert, on
the wake tag, covers the two new tags: `(1 << 31) - 0x7fff_f000` is 4096, against `errno_max`
4095. The five checks of a tag at a post (decision 29's list) become `tag <= message_tag_max or
tag == message_tag_wake`. A caller's message passes at the first compare.

## What it costs

Every number is a prior. The baselines are the `macos-aarch64-kqueue` section of
`bench/baseline/work.txt`.

| path, on a loop that makes no calls | added |
|---|---|
| each tick | 0 |
| each drained message | 0: `tag > message_tag_max` replaces decision 29's `== message_tag_wake` |
| each post | 0: `push_post` compares with 224 where `push` compares with 256 |
| a wake | 1 compare at the post |
| memory | 0 in `Mailbox`, `Dispatch` and `Groups`: the two counts use 2 B of the padding of decision 30's `Groups`. The per-call task adds no structure to a loop. |

So each row of the work gate is expected to stay inside its 2 percent. The gate must show it
before the build lands. The one change of behaviour: a post gets `MailboxFull` at 224 messages in
a ring, where it got it at 256.

| one call round trip, both loops awake | instructions |
|---|---|
| `send` and `call`: owner, the load of `Groups.named` and the group compare, state, the registry's decision 21 flag, `calls_out` and the link's pointer to it, the entry in `task.call`, `push_post`, the wake note | about 44 |
| drain on T: the cold branch, 5 compares, the state, the group's index, one push of the record's task (decision 30's `schedule_in(g)` row, about 12) | about 30 |
| the record's task on T: one task run on the groups path (decision 30, about 16, with the heartbeat's store that each task run makes), then the trampoline: the station, its state, the deadline, the handler (C5) | about 28 |
| `answer`: state, `push`, the wake note | about 25 |
| drain on C: compares, the state, the `finish` entry in `task.call`, one push of the record's task | about 28 |
| the record's task on C: one task run, the state, `calls_out` through the link's pointer, `finish` (C5) | about 24 |
| **sum** | **about 179** |
| a visit of decision 30 on each side, when the group is not `.default` and the visit runs only the call's task | up to 2 x 13 more |

- In the shape of the `post` row, 1247 instructions, a call round trip is about 1,430, or about
  1,450 with the two visits.
- So each call costs one push and one task run on each loop. A loop that makes no calls and
  serves none runs none of these paths.
- Latency awake: two messages, 2 x C19 (97.0 ns on `mac`), and the record's lines, about 2 x C3
  (128 ns on `mac`): about 450 ns.
- A target that sleeps adds what a post's wake adds: C18 (18,125 ns on `mac`) on kqueue, C17 on
  io_uring, sent at the sender's next flush (F19).
- A loop queues at most `call_tasks_max` = 16,832 tasks of calls. That is a bound, and not a
  memory cost: the records and their tasks are the callers'. Each call costs 16 B more in its
  record than in the proposal (see "Layout").

## Determinism

- A loop queues the tasks of calls in the order that it popped the calls, which is W3's cursor
  order. Inside a group they run in that order. Decision 30's DRR order chooses when each group
  runs, from the call sequence.
- The deadline is compared with the tick's cached `now_ns`, so no new clock read happens (decision
  9, rule 4). A replay twin supplies `now_ns`, as it does for timers.
- `discard_tasks` reads the static entry of each queued task. No decision depends on the order or
  the value of a pointer.
- When a call arrives depends on another thread, as for any post (decision 4).

## Where it meets the records

- **Decision 2.** A new row: cross-core calls in one process.
- **Decision 4 and non-negotiable 4.** A call is a post. No new call crosses threads, and the loop
  starts no thread. A post sees 224 slots.
- **Decision 5.** Its rule of one final event gets an analogue for calls.
- **Decision 8.** No class A site: a call is on neither the nop path nor the echo path.
- **Decision 12, point 6.** The sleep handshake does not change, so `spec/tla/wake/` does not.
- **Decision 18.** The offload's result rings keep `push` at 256.
- **Decision 21.** `Mailbox` gains `calls_out`, and two tags become reserved. `header_version`
  changes, best in the same bump as decision 29's.
- **Decision 26.** Open question 2 left a record in a post to a later record. This is that record.
  `callbacks_outstanding`, and P7, also count calls out and calls held.
- **Decision 27.** Open question 14 says that a post carries no task, and that a library
  schedules its own task. A call message carries the address of a record that holds a task.
  Camilo's choice of 2026-11-07 amends the question for calls only. The target's own thread
  schedules the task, after the pop gives its loop the record. No thread writes the queue of
  another loop, and a plain post still carries no task. `discard_tasks` halts on the queued task
  of a call. The task of a call has its own limit above `tasks_queued_max`, `call_tasks_max` more
  (ruling item 11).
- **Decision 28.** `SharedLoop.library_calls` gains `call` and `answer`. The heartbeat names each
  call's task as it names any task: the service's handler on the target, `finish` on the caller.
- **Decision 29.** `message_tag_max` falls by two. The drain's compare becomes `>`.
- **Decision 30.** It is built first, with named groups. The caller's named group runs the handler
  on the target and `finish` on the caller, each in one task of cost 1. `stations` and `serving`
  sit in the padding of its `Groups` header. Its overflow assert gains the calls and their tasks.
  `discard_tasks` halts on the queued task of a call, through a flag in `Task.Call` (ruling item
  12). The bounds of a queue's length read `tasks_queued_max + call_tasks_max` (ruling item 11).
- **Decision 31.** A handler that answers `.later` after a file operation keeps its call `held`
  while the I/O queue holds that operation. The call's deadline does not reach the operation.

## Alternatives it beat

| alternative | why it lost |
|---|---|
| a future, as Seastar returns | it needs memory for each call, and rotor allocates nothing |
| a second ring for each pair, for replies, as Seastar has | it doubles the registry, which grows as N squared (F14) |
| the caller's thread schedules a task on the target's queue | it writes the queue of another loop from another thread, which decision 27, open question 14 rules out; here the target's own thread schedules the record's task |
| the target chooses the group, at `serve` | Camilo ruled for the caller's choice on 2026-11-07, as Seastar does |
| one call lane for each group id on each loop, which every service shares (the design before the ruling) | 512 B in each loop's `Groups`, and a limit of `tasks_queued_max` + 1 in each group. A lane run mixes services, so its stall record named only the service of its last link. It also added one store of `running` for each link. Camilo chose a task for each call on 2026-11-07. |
| a task for each service and group, in each station | 32 B for each group in each station, and 256 stations for each service; Camilo chose a task for each call on 2026-11-07 |
| a `CallLink` of 56 B, with no pointer `calls_out` | the task on the caller finds the ring's count through the station of its loop. That station must hold a pointer to the loop, and each call makes several dependent loads. Camilo ruled for 64 B with the pointer on 2026-11-07 (ruling item 9). |
| `calls_out` falls when the drain pops the return, as the proposal said | the tasks of returns that wait for `finish` then have no bound. A group with small shares can hold many of them while another group sends new calls. Under the ruled answer, a caller whose `finish` waits gets `CallsFull` sooner. The return proof holds under both (ruling item 10). |
| `schedule` and `schedule_in` refuse at `tasks_queued_max - call_tasks_max`, so the cap holds for every push | a library gets `TasksFull` at 48,704 tasks. That changes the meaning of a named limit for every program. The calls alone reach at most 16,832 tasks, about a quarter of `tasks_queued_max` (ruling item 11). |
| the drain stops popping a ring while the call at its head names a full group, so the call waits in the ring and the cap holds | one full group on T blocks every message behind the call in ring C to T (head-of-line). Posts, calls in other groups and the returns of T's own calls wait there. So the tasks of one group delay the work of every group. The drain also pops in batches today (`pop_into`), and this needs a read of the head before the pop (ruling item 11). |
| a count of the queued tasks of calls in the 2 B left in the `Groups` header, for `discard_tasks` | a write at each push and each run of a call's task. The flag `call_record` costs nothing on any path (ruling item 12). |
| the group in `Message.reserved`, beside a 24-bit generation | the target reads the link anyway; the link has room, and the generation keeps 32 bits |
| the handler called inline in the drain | its work is bounded by the mailbox share and not by `tasks_per_tick_max` |
| a state word with a CAS, and a `closed` bit read after the push | the sender that wins the CAS frees the record while the target may sit between its pop and its CAS; it also changes the sleep handshake |
| a sweep by the caller of its own ring to a target that left | the caller becomes a second consumer of a single-consumer ring |
| `cancel_call` | the target owns the record until it answers, so a cancel frees nothing sooner |
| a reserve in a registry field, in place of the constant 224 | one load for each post |
| an `Endpoint` that the program hands to each caller | `Service` holds a station for each loop, so a caller names a `LoopId` |
| `Outcome { held: bool }`, which only two calls make | Zig has no private fields, so a handler can build one |
| exact call statistics in `Statistics` | decision 9 allows sampled statistics; W9 counts refusals if R5 is ruled |
| a halt at the caller's `deinit` when a target stops | it gives the caller no result; `target_stopped` does |

## How it would be checked

**How tests name groups** (decision 30, ruled on 2026-11-07). For a test, root is Zig's own test
runner, which declares no `rotor_scheduling_groups`. So every test, scenario and mutation below that
needs n > 0 uses decision 30's generic machinery, as its "How tests name groups" says:

- Unit tests 3, 5 and 6, and the random groups of property test 8, call
  `core.scheduling.Named(.{ .low = 100, .high = 300 })` and pass its `table` to
  `Groups.reserve_named`.
- The conformance scenario at shares 100 and 300 passes that table in the backend's
  `Loop.Options`, so `Loop.init` reserves it on both loops.
- The halt scenario of a forged group id goes through the public module's `send`. Its file is the
  root of its executable, so it declares `rotor_scheduling_groups` itself, and `call` compares the
  forged id with that declaration's n.
- The mutations that point at tests 3, 5 and 6 are measured with these tables, so n > 0 there.

No custom test runner is added, and no file under `build/` changes.

**Unit tests in core, with no `Loop`:**

1. A ring with 224 posts and 31 returns takes one more return. `push_post` refuses at 224, and
   `push` takes 256.
2. `calls_out` refuses the 33rd call. A drained return does not lower it, and its `finish` does.
3. The drain takes a call and a return, and writes no event. It schedules the record's task in the
   call's group: with the service's entry on the target, and with the `finish` entry on the caller.
4. The record's task on the target answers `expired` and `target_stopped` with no handler run. On
   the caller it sets `idle` and lowers the count before `finish`.
5. A call in a named group runs its handler in that group on the target, and `finish` in that
   group on the caller. A loop that only calls runs `finish` in the call's group.
6. A group that holds `tasks_queued_max` tasks of the program refuses `schedule_in`, and its drain
   still takes the task of a call.
7. A fabricated stall in a call's task names the call's group. On the target it names the
   service's handler, and on the caller it names the caller's `finish` field.
8. A property test seeded from `core.random`, which prints its seed: two model loops in one
   thread make a random mix of posts, calls in random groups, calls to self, `.now` and `.later`
   answers, deadlines, `stop_serving` and drains with small event arrays. Invariants: a return push
   never fails; `calls_out` stays at 32 or less; the queued tasks of calls on each loop stay at or
   below the bound of "The task queue and the fair tick" for two loops; each accepted call gets one
   `finish` and at most one handler run, both in the call's group; `callbacks_outstanding` is 0 at
   the end.

**Conformance scenarios** on each backend, and again with the spin budget: 10,000 calls between
two loops with checked replies; the 33rd call to one target gives `CallsFull`; ring T to C holds
224 posts while 32 calls are out, and all 32 returns arrive; a call wakes a target that sleeps; a
`.later` answer after a timer; a past deadline gives `expired` with no handler run; a call to self
uses no ring; a loop releases its id, a second loop claims it and serves the call that waited;
calls in two named groups at shares 100 and 300 run their handlers in decision 30's ratio, within
its G3 bound.

**Race gate.** Four loops call each other with deadlines while one stops serving. The oracle: for
each loop, calls accepted = `replied` + `expired` + `target_stopped`, and every `calls_out` is 0.

**Model.** `spec/tla/call/Call.tla`, checked by `zig build tla`: two loops, one record reused, a
bounded ring with posts, `.later`, and `stop_serving`. Invariants: one result for each send; no
write by the target while the caller owns the record; the return push never fails; `calls_out`
equals the records `out`, `held`, `answered` or `back`; the record's task is queued on at most one
loop, and only on the loop that owns the record. Mutants, which must fail: posts ignore the
reserve; `finish` does not lower `calls_out`; `idle` is set after `finish`; a `stopped` station
runs the handler; the target schedules the task again after its return push.

**Compile-fail tests** (`zig build test-compile-fail`): a handler that returns `void`; `.now` with
no reply; a `finish` that takes a reply of another type; a `send` with a `Remote`; a `CallOptions`
with no group, or with a `SchedulingGroup`.

**Halt scenarios** in `tools/halt/`:

| scenario | check | class |
|---|---|---|
| `send` of a record that is out | state `idle` | B |
| `send` with a group id above the declared count, through `@enumFromInt` | the id | B |
| a second `answer`, or one from another thread | state `held`, owner | B |
| a call to a loop that never served | station state `unused` | B |
| `serve` on a station that serves | station state | C |
| `serve` or `call` in a group registry | `registry.group` | B |
| `take_reserved` with a wrong origin, target, generation or group, through its parameters | the link | B |
| a call's task on the caller whose count is 0, through a made-up record | `calls_out` | B |
| more than `services_max` stations on one loop | `stations` | B |
| `discard_tasks` with the task of a call queued | the entry's `call_record` | C |
| `deinit` with a call out, or a station that serves | `assert_empty` | C |

**Mutations,** each against the narrowest target, each expected `CAUGHT`:

| mutation | target |
|---|---|
| `push_post` uses 256 | `test-core`, tests 1 and 8 |
| `answer` uses `push_post` | `test-core`, test 1, and the 224-post scenario |
| `call` does not raise `calls_out`, or the task on the caller does not lower it | `test-core`, test 2 |
| the drain on the caller lowers `calls_out`, and `finish` does not | `test-core`, test 2, and the bound of test 8 |
| the drain writes a call as an event | `test-core`, test 3 |
| the drain schedules a call in `.default` and not in the link's group | `test-core`, tests 3 and 5 |
| the caller's drain schedules the `finish` in `.default` | `test-core`, test 5 |
| `send` does not write the service's entry in `task.call` | `test-core`, tests 3 and 7 |
| the caller's drain does not write the `finish` entry | `test-core`, tests 3 and 5 |
| the drain pushes a call's task with the cap of `schedule_in` | `test-core`, test 6 |
| `Loop.init` does not reserve the table of its options | conformance, the scenario at shares 100 and 300: `call` halts, because `Groups.named` stays 0 |
| `send` does not check the group id | `halt-check` |
| the deadline check or the `stopped` check removed | `test-core`, test 4 |
| `idle` set after `finish` | `test-core`, test 4 |
| `callbacks_outstanding` not raised for a call out | `test-core`, test 8, and `halt-check` |
| `answer` does not wake a target that sleeps | conformance, each backend |
| a call to self goes through a ring | `test-core`, test 8 |
| `discard_tasks` ignores `call_record` | `halt-check` |
| each halt deleted | `halt-check`, or the Linux gate where a Linux call follows it |

**The work gate** holds every row within 2 percent, and gains a `call` row. `conformance_cost.zig`
gains a bound for a call round trip, at 10 times the measured value.

## Open questions

Camilo ruled on each one on 2026-11-07. Questions 1 to 8 take the proposed answer. Question 10
takes the other answer, and he then ruled question 9 to follow it.

1. **`calls_per_pair_max`.** (a) 32. (b) 64, which leaves 192 slots for posts. *Ruled: (a), until
   stompy measures the depth of its journal pipeline. `CallsFull` says when it is reached.*
2. **The reserve.** (a) A constant 224 for every program. (b) A registry option that turns calls
   on, at one load for each post. *Ruled: (a). (b) is the fallback if the loss of 32 slots costs a
   consumer, for example a `Remote` or a decision 21 group.*
3. **A call to self.** (a) Through the loop's own task queue, with no ring. (b) A halt, as a post
   to self halts. *Ruled: (a). stompy's shard is a hash of the key, so about 1 call in N is local.*
   The proposal ran it through a call lane. With the per-call task, the loop schedules the record's
   task in the call's group.
4. **A call to a loop that never served.** (a) A halt on the target. (b) A `not_served` result.
   *Ruled: (a). It is a mistake of the program, and a halt stops the process at once.*
5. **A target whose thread exits on a fatal tick error (F6).** (a) R7's end call answers its held
   calls `target_stopped`. (b) The calls stay stranded until the process restarts. *Ruled: (a), in
   the record that rules R7 and R8. Until then, (b), and the guide says so.*
6. **The size of a station.** (a) 128 B on every target. (b) 64 B on x86-64. *Ruled: (a). A
   service costs 32 KiB once for each process.*
7. **`services_max`.** (a) 16. (b) 8. *Ruled: (a). stompy plans fewer than 8 today.*
8. **The generation in `Message.reserved`.** (a) Keep it, and check it on both sides. (b) Drop it,
   because a call message never outlives its record. *Ruled: (a). It costs one compare, catches a
   corrupted message, and is ready for an epoch of R8.* The group does not take room from it: the
   group crosses in `CallLink`.
9. **The group of a loop that calls and does not serve.** In the proposal, its station ran `finish`
   in `.default`, which no library source names, against decision 30, rule 3. (a) Keep
   `.default`, and the guide says so. (b) Add `Service.attach(shared, options)`, which sets the
   caller's station group without `serve`. The proposed answer was (a), and Camilo accepted the
   proposed answers except on the group. *Ruled on 2026-11-07, after question 10: `finish` runs in
   the call's group on the caller's loop.* No `Service.attach` is needed.
10. **Who chooses a call's group.** (a) The target, at `serve`, through `ServeOptions`. A group id
    then belongs to one loop. (b) The caller, in `CallOptions`, as Seastar does. A group id then
    names one group on every loop, so decision 30 gains named groups. *Ruled: (b), "B now, named
    groups". See "Scheduling groups (decision 30)".*

## Left for Camilo

Nothing. Camilo ruled every item of this list on 2026-11-07. Items 5 to 8 of "Ruling, 2026-11-07"
hold the first list. Items 9 to 12 hold the four choices of the per-call task. "Alternatives it
beat" holds the choices that lost.

## Ask before

These items of CLAUDE.md's "Ask before" apply:

| item | today | proposed |
|---|---|---|
| building what decision 2 leaves out | no cross-core call | a new row; accepted 2026-11-07 |
| a named limit: the room for a post | 256 of 256 | `mailbox_posts_max`, 224 of 256 |
| a named limit: `message_tag_max` | `0x7fff_efff` (decision 29) | `0x7fff_effd` |
| new named limits | | `calls_per_pair_max` 32, `services_max` 16, two tags |
| a new derived limit | | `call_tasks_max` = 16,832; ruled 2026-11-07 (ruling item 11) |
| the layout of a hot structure: `Mailbox` | | `calls_out` on the `tail` line; size unchanged; `header_version` + 1 |
| the layout of decision 30's `Groups` | | `stations` and `serving`, 1 B each, in its padding; no call lanes |
| the size of `CallLink`, in each caller's record | 48 B in the proposal | 64 B: `task: Task` in place of `next`, and `calls_out: *u32`; ruled 2026-11-07 (ruling items 6 and 9) |
| the layout of decision 30's `Task.Call` | 32 B (decision 30) | `call_record: bool` in its padding; size unchanged; ruled 2026-11-07 (ruling item 12) |
| the bound of the task queue | `tasks_queued_max` for each group (decision 30) | a call's task, a call to self included, is pushed with the limit `tasks_queued_max + call_tasks_max`. In `Tasks`, four bounds read that sum: the assert `queued_max <= tasks_queued_max` in `push`, the count check in `assert_shape`, the loop bound of `discard` and the walk bound of `assert_queue`. In decision 30's `Groups`, the same four of each lane read it. Ruled 2026-11-07 (ruling item 11). |
| the overflow assert of `callbacks_outstanding` | decision 30's sum | + 34,176 for the calls and their tasks |

- **New public names:** `Service`, `CallRecord`, `Answer`, `CallResult`, `CallOptions`, `CallError`,
  `CallLink`, `CallStation`, and `call` and `answer` on `SharedLoop` and on each `Loop`. `CallLink`
  and `CallStation` are public because the program's `CallRecord` and `Service` hold them.
- **`CallOptions.group`**, which takes decision 30's `NamedSchedulingGroup` and has no default.
  `ServeOptions` is gone. Camilo ruled both on 2026-11-07.
- **New halts** in `discard_tasks` and in `deinit`. They change decision 27's shutdown contract.
- **Records not yet built:** W3 first, then decision 29, then decision 30, then this record. W4's
  `leave`, and R7 and R8 come later. This record states what it needs of each.

It adds no dependency, no edge to the module graph, no file to decision 7's list, and no file
under `build/`. It moves no assertion to a slower class. The limit of ruling item 11 widens eight
bounds by `call_tasks_max`. They are the four of `Tasks` above, and the same four of each lane of
decision 30's `Groups`. Camilo ruled it on 2026-11-07. No other assertion is weakened.

## Sources

- Camilo's choice of 2026-11-07 of three Seastar features.
- The robustness plan of 2026-11-06: findings F3, F4, F6, F7, F12, F14 and F19; work items W3, W4
  and W9; rulings R5 to R8.
- Three drafts of this record of 2026-11-07, "minimal", "correct" and "operator", and two reviews
  of them. This record takes the first, with parts of the other two.
- Seastar's `src/core/reactor.cc`, `smp_message_queue`, read in a local copy on 2026-11-07. The
  facts that the section "Seastar" marks as recalled were not checked.
- Seastar's `include/seastar/core/smp.hh`, read on 2026-11-07: `work_item` derives from `task`, and
  is built with `task(current_scheduling_group())`.
- Decisions 2, 4, 5, 8, 9, 18, 21, 26, 27, 28 and 29.
- `src/core/mailbox.zig`, `src/core/remote.zig`, `src/core/inbox.zig`, `src/core/tasks.zig`,
  `src/core/shared_loop.zig`, `src/core/operation.zig` and `src/core/constants.zig` at `5e9490d`.
- `bench/baseline/work.txt` and `docs/costs.md` at `5e9490d`.
