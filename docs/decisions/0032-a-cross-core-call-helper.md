# 32. A cross-core call

Status: proposed on 2026-11-07. Nothing is built. Every cost here is a prior: a row of
`docs/costs.md`, a row of `bench/baseline/work.txt`, or an instruction count from arithmetic.
Nothing was measured for this record.

It amends decision 2, because it adds a row to the "In version one" table. It also amends these
records:

- decision 4, at the room for a post in a ring, and at the tags a post may carry;
- decision 5, with a rule of one result for each call;
- decision 21, at the content of a `Mailbox` and at `header_version`;
- decision 26, at the count `callbacks_outstanding` and its property P7;
- decision 27, at `discard_tasks` and at the bound of the task queue;
- decision 29, at `message_tag_max` and at the compare in the drain.

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

Read in Seastar's `include/seastar/core/smp.hh` on 2026-11-07: the timeout of
`smp_submit_to_options` covers only the wait to be processed on the remote shard, and not the run
there. A `work_item` takes `current_scheduling_group()` when the caller's shard builds it. That the
target then runs it in that group was not traced.

Recalled, and not checked: a pair queue holds 128 items, `batch_size` is 16, and a `submit_to`
cannot be cancelled.

rotor keeps the pointer to a record, a bound on the requests out for each pair, and a reply path
that cannot fail. It drops the heap, the admission wait, and the second queue.

## The decision, as proposed

1. **A `Service` is one kind of call.** The program declares it once, with a context, a request
   type, a reply type and a handler. It holds one station for each loop.
2. **A call is a record that the caller owns.** The ring carries its address. The record is the
   target's from the push until the target answers, and the caller's again when its result runs.
3. **Each loop runs calls in a station task that its own service owns.** The drain links a call to
   the target's station, and a return to the caller's station. No task crosses threads.
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
        /// One station for each loop, indexed by `LoopId`. Program memory, 128 B each.
        stations: [constants.loops_max]core.CallStation,
        /// Every station unused. A program declares the service once, as a static.
        pub const init: @This();
        pub const Call = CallRecord(Request, Reply);

        /// The loop of `shared` serves this service with `context`. Its thread calls it before
        /// its first tick. It halts on a station that serves, and in a decision 21 group.
        pub fn serve(service: *@This(), shared: *SharedLoop, context: *Context,
            options: ServeOptions) void;
        /// The loop of `shared` stops. A call that reaches it later gets `target_stopped`.
        pub fn stop_serving(service: *@This(), shared: *SharedLoop) void;
        /// Sends `request` to loop `target`. On an error nothing was sent, and `finish` does
        /// not run. It halts when `call` is out already.
        pub fn send(service: *@This(), shared: *SharedLoop, target: LoopId, call: *Call,
            request: Request, options: CallOptions) CallError!void;
    };
}

/// The caller's record, in the caller's struct. Size 48 B + Request + Reply, alignment 8.
pub fn CallRecord(comptime Request: type, comptime Reply: type) type {
    return struct {
        link: core.CallLink,
        request: Request,
        reply: Reply,

        /// `finish` runs exactly once for each `send` that returns success.
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
    /// On the loop clock (`now_ns`). 0: none. The target compares it before the handler runs.
    deadline_ns: u64 = 0,
};
pub const ServeOptions = struct {
    /// Decision 30's group for this station's task, from the program. No default: a library
    /// writes `.default` to use the loop's own group (decision 30, rule 3).
    scheduling_group: SchedulingGroup,
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
    fn on_appended(writer: *Writer, result: rotor.CallResult(AppendReply)) void {
        switch (result) { .replied => |reply| ..., .expired => ..., .target_stopped => ... }
    }
};
try append.send(shared, journal_core, &writer.append_call, .{ .bytes = ... }, .{});
```

| wrong use | result |
|---|---|
| a request, a reply or a context of the wrong type | fails to compile |
| a handler with the wrong signature, or `.now` with no reply | fails to compile |
| a `finish` that does not take the service's `CallResult` | fails to compile |
| a call from a `Remote` | fails to compile |
| a `serve` that names no scheduling group, or a literal group | fails to compile |
| a `send` of a record that is out | halts |
| a second answer, or an answer from another thread | halts |
| a call that reaches a loop that never served the service | halts, on the target |
| `serve` on a station that serves, or in a decision 21 group | halts |
| `deinit` while a call is out or held, or while a station serves | halts |

### The flow

1. **`send` on the caller C.** It writes the request, and in the link `origin`, `target`,
   `deadline_ns`, `generation + 1` and the state `out`. It calls `call`.
2. **`call`.** At `calls_per_pair_max` in `calls_out` of ring C to T, it returns `CallsFull`.
   Otherwise it pushes `{ payload = &link, tag = message_tag_call, reserved = generation }`
   through `push_post`. On success it adds 1 to `calls_out` and to `callbacks_outstanding`. On an
   error it sets `idle` again and changes nothing else.
3. **The drain on T.** One compare, `tag > message_tag_max`, sends a reserved tag to a cold
   function, `Inbox.take_reserved`. It checks the link, sets `held`, links it to `stations[T]`,
   adds 1 to `callbacks_outstanding`, and schedules the station task when it is not queued. It
   writes no event.
4. **The station task on T.** It takes at most `task_budget_left() + 1` links, oldest first, and
   calls `charge_task` with the count after the first (decision 30). For each link: a station that
   stopped answers `target_stopped`, and a deadline at or before the cached `now_ns` answers
   `expired`. In both cases the handler does not run. Otherwise the handler runs: `.now` answers
   `replied`, and `.later` keeps the call held. The task schedules itself again while its list
   holds links. A task that a task queues runs in the next tick (decision 27), so one link for
   each run would serve one call for each tick.
5. **`answer` on T.** It sets `answered`, and pushes `{ payload = &link, tag =
   message_tag_return, reserved = generation }` through `push`, which sees all 256 slots. It
   subtracts 1 from `callbacks_outstanding`.
6. **The drain on C.** It checks the link, subtracts 1 from `calls_out`, sets `back`, links it to
   `stations[C]`, and schedules that station's task.
7. **The station task on C.** It takes links as in step 4. For each one it sets `idle`, subtracts
   1 from `callbacks_outstanding`, and calls `finish`. So `finish` may send the same record again.

A call to the caller's own loop uses no ring. `call` links the record to its own station as
`held`. The station's `self_out` bounds such calls at `calls_per_pair_max`. The handler and
`finish` run in later task runs, never inside `send`.

### Ownership, the analogue of decision 5

**Each `send` that returns success makes at most one run of the handler and exactly one run of
`finish`. A `send` that returns an error makes neither.**

| state | owner | who writes it |
|---|---|---|
| `idle` | the caller | the caller's station task, just before `finish` |
| `out` | the target, from the push | the caller's `send`, before the push |
| `held` | the target | the target's drain, or `call` for a call to self |
| `answered` | the caller's loop, from the push | the target's `answer`, before the push |
| `back` | the caller's loop | the caller's drain |

- Each change of owner is a ring push, with the `.seq_cst` store of `tail`, and a pop, with the
  load of `tail`. `mailbox.zig` argues these orderings for a slot's bytes. They also make the
  request visible to the target, and the reply to the caller. The record needs no atomic.
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
2. Each return in ring T to C answers a call that C counts in `calls_out` until C drains it. So
   while T pushes one return, the others are at most 31.
3. So a return push sees at most 255 used slots. A failed return push halts (class B).

| error | meaning | what the caller does |
|---|---|---|
| `CallsFull` | 32 calls are out to that target | send again from a later `finish`, or answer its client "busy" |
| `MailboxFull` | the ring holds 224 messages | send again in a later tick, from its own task |
| `LoopNotFound` | the target has no loop, or it left | the stop order below |

rotor keeps no hidden queue, and this record adds no counter. If Camilo rules R5 as proposed,
W9's exact counts of refusals count these errors on the slow path.

### The task queue and the fair tick

- Each station has one task, which the drain schedules only when it is not queued. So a loop holds
  at most one station task for each service.
- A station task is pushed to its group with the limit `tasks_queued_max` + `services_max`.
  Decision 30 makes `tasks_queued_max` a cap for each group, so a program that fills that group
  cannot make a drain fail.
- The first schedule of a station on a loop sets `attached` in the station, and adds 1 to a new
  byte `stations` in decision 30's `Groups` header, in its padding. Above `services_max` it halts
  (class B, cold). So too many services halt at the first call, and not only under load.
- A station run takes at most `task_budget_left() + 1` links, and counts as one start of
  `tasks_per_tick_max`. Its charge is at most `task_budget_left()`, which is at most
  `tasks_per_tick_max`. A comptime assert holds `tasks_per_tick_max <= task_charge_max` (64 and 64),
  so the charge never passes decision 30's bound. Call and return messages take no slot of `events`,
  and W3's cursor pops them inside the mailbox share. So a flood of calls cannot starve I/O or
  another sender.
- Each `Service` type has its own static `Task.Call`, named after its handler, whose `function` is
  core's one `station_run`. So decision 28's heartbeat and stall record name the service.
- `discard_tasks` halts on a station task whose list holds links (class C, cold). It knows the
  task by one compare of `task.call.function` with `station_run`. A call cannot be discarded,
  because its caller waits for `finish`.

### Scheduling groups (decision 30)

The target chooses the scheduling group, at `serve`. Decision 30's group ids belong to one loop, so
a caller's group means nothing on the target. Seastar tags the work with the caller's group (read
in `smp.hh`, see "Seastar"). The drain schedules a station task with
`schedule_in(station.scheduling_group, task)`. Decision 30 is built before this record, so the
group exists from the first build. A loop that calls and does not serve runs its returns in
`.default` (open question 9).

### A target that stops (W4)

A station has three states: `unused`, `serving` and `stopped`. `serve` and `stop_serving` change
them, on the station's own loop. `serve` and `stop_serving` change a second new byte, `serving`,
in the padding of decision 30's `Groups` header, and `deinit` halts while it is above 0 (class C). So a loop that ends always leaves
its stations `stopped`.

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
| `CallLink` | new, in the caller's record | 48 B, 8 (comptime assert) |
| `CallStation` | new, in the program's `Service` | 128 B, 128 (comptime assert) |
| `Service` | new, in program memory | 32 KiB at `loops_max` 256 |
| `Mailbox` | `calls_out: u32` after `tail` | 4352 B, 128: no change (comptime assert) |
| `Groups` (decision 30) | `stations: u8`, `serving: u8`, in 2 B of its 5 B of padding | 536 B, 8: no change (comptime assert) |
| `Dispatch`, `Tasks`, `Inbox`, `Tables` | none. Decision 30 leaves no padding in `Dispatch` | no change |
| `Task.Call` | one static entry for each `Service` type | static data |

The overflow assert of `callbacks_outstanding` (decision 30) gains the station tasks and the calls:
`services_max + 2 * (loops_max - 1 + services_max) * calls_per_pair_max`, which is 17,360. A loop
counts a call it sent and a call it holds, and `self_out` bounds the calls to self at
`calls_per_pair_max` for each station.

```zig
/// The part of a call that the loops link and post (decision 32). Size 48 B, alignment 8.
pub const CallLink = struct {
    next: ?*CallLink, // the list of the station that holds it; its owner writes it
    stations: *[constants.loops_max]CallStation, // the service's stations; `send` writes it
    finish: *const Finish, // a static entry, as `Task.Call` is; `init` writes it
    deadline_ns: u64, // 0: none
    generation: u32, // plus 1 for each `send`; the message's `reserved` carries it
    origin: LoopId,
    target: LoopId,
    state: State, // idle, out, held, answered, back
    outcome: u8, // replied, expired, target_stopped; `answer` writes it
    // 6 B of padding
};

/// One service on one loop. Only that loop's thread writes it. Size 128 B, alignment 128.
pub const CallStation = struct {
    task: Task, // 16 B: its `call` is the service's static entry, whose function is `station_run`
    head: ?*CallLink, // the links to run, oldest first
    tail: ?*CallLink,
    context: ?*anyopaque, // `serve` writes it
    run: *const fn (station: *CallStation, link: *CallLink) void, // the service's trampoline
    queued: u32,
    held: u32, // calls answered `.later` and not yet answered
    self_out: u16,
    state: enum(u8) { unused, serving, stopped },
    attached: bool,
    scheduling_group: SchedulingGroup, // `serve` writes it; `.default` on a loop that only calls
    // 67 B of padding to 128
};
```

The 128 B is `mailbox_index_alignment`, so two loops' stations never share a line on Apple
silicon. 64 B is enough on x86-64 (open question 6).

New constants in `src/core/constants.zig`, each with a doc comment:

| constant | value | comptime assert |
|---|---|---|
| `calls_per_pair_max` | 32, a prior | `< mailbox_messages` |
| `mailbox_posts_max` | `mailbox_messages - calls_per_pair_max` = 224 | `>= messages_per_drain` |
| `services_max` | 16, a prior | `tasks_queued_max + services_max` fits in u32 |
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
| memory | 0 in `Mailbox` and `Dispatch`; 2 B of padding in decision 30's `Groups` |

So each row of the work gate is expected to stay inside its 2 percent. The gate must show it
before the build lands. The one change of behaviour: a post gets `MailboxFull` at 224 messages in
a ring, where it got it at 256.

| one call round trip, both loops awake | instructions |
|---|---|
| `send` and `call`: owner, state, the registry's decision 21 flag, `calls_out`, `push_post`, the wake note | about 40 |
| drain on T: the cold branch, 4 compares, the link, the schedule | about 30 |
| station task on T: the task run, the state, the deadline, the trampoline (C5); a run of several links shares the task run | about 30 |
| `answer`: state, `push`, the wake note | about 25 |
| drain on C: compares, `calls_out`, the link, the schedule | about 30 |
| station task on C: the task run, `finish` (C5) | about 25 |
| **sum** | **about 180** |

- In the shape of the `post` row, 1247 instructions, a call round trip is about 1,430.
- Latency awake: two messages, 2 x C19 (97.0 ns on `mac`), and the record's lines, about 2 x C3
  (128 ns on `mac`): about 450 ns.
- A target that sleeps adds what a post's wake adds: C18 (18,125 ns on `mac`) on kqueue, C17 on
  io_uring, sent at the sender's next flush (F19).
- A target holds at most (`loops_max` - 1) x 32 = 8,160 calls in its station lists. That is a
  bound, and not a memory cost: the records are the callers'.

## Determinism

- A station runs its links in the order its loop popped them, which is W3's cursor order.
- The deadline is compared with the tick's cached `now_ns`, so no new clock read happens (decision
  9, rule 4). A replay twin supplies `now_ns`, as it does for timers.
- `discard_tasks` compares `task.call` with one static entry for equality. No decision depends on
  the order or the value of a pointer.
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
- **Decision 27.** Open question 14 stands: the drain schedules a station task that the receiving
  loop's own service owns, and links the caller's record to it. `discard_tasks` halts on a
  station with links. A station task has its own bound above `tasks_queued_max`.
- **Decision 28.** `SharedLoop.library_calls` gains `call` and `answer`.
- **Decision 29.** `message_tag_max` falls by two. The drain's compare becomes `>`.
- **Decision 30.** It is built first. The target's scheduling group, which `serve` names, runs the
  station task. A station run follows decision 30's rule for a cost that varies, and charges each
  link after the first. `stations` and `serving` sit in the padding of its `Groups` header, and its
  overflow assert gains the calls. `discard_tasks` halts on a station with links in any group.
- **Decision 31.** A handler that answers `.later` after a file operation keeps its call `held`
  while the I/O queue holds that operation. The call's deadline does not reach the operation.

## Alternatives it beat

| alternative | why it lost |
|---|---|
| a future, as Seastar returns | it needs memory for each call, and rotor allocates nothing |
| a second ring for each pair, for replies, as Seastar has | it doubles the registry, which grows as N squared (F14) |
| the caller's task scheduled on the target's queue | it carries a task across threads, which decision 27, open question 14 rules out |
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

**Unit tests in core, with no `Loop`:**

1. A ring with 224 posts and 31 returns takes one more return. `push_post` refuses at 224, and
   `push` takes 256.
2. `calls_out` refuses the 33rd call, and a drained return lowers it.
3. The drain takes a call and a return, writes no event, and links each to the right station.
4. A station run takes at most `task_budget_left() + 1` links, and charges the rest. It answers
   `expired` and `target_stopped` with no handler run, and sets `idle` before `finish`.
5. A property test seeded from `core.random`, which prints its seed: two model loops in one
   thread make a random mix of posts, calls, calls to self, `.now` and `.later` answers,
   deadlines, `stop_serving` and drains with small event arrays. Invariants: a return push never
   fails; `calls_out` stays at 32 or less; each accepted call gets one `finish` and at most one
   handler run; `callbacks_outstanding` is 0 at the end.

**Conformance scenarios** on each backend, and again with the spin budget: 10,000 calls between
two loops with checked replies; the 33rd call to one target gives `CallsFull`; ring T to C holds
224 posts while 32 calls are out, and all 32 returns arrive; a call wakes a target that sleeps; a
`.later` answer after a timer; a past deadline gives `expired` with no handler run; a call to self
uses no ring; a loop releases its id, a second loop claims it and serves the call that waited.

**Race gate.** Four loops call each other with deadlines while one stops serving. The oracle: for
each loop, calls accepted = `replied` + `expired` + `target_stopped`, and every `calls_out` is 0.

**Model.** `spec/tla/call/Call.tla`, checked by `zig build tla`: two loops, one record reused, a
bounded ring with posts, `.later`, and `stop_serving`. Invariants: one result for each send; no
write by the target while the caller owns the record; the return push never fails; `calls_out`
equals the records `out`, `held` or `answered`. Mutants, which must fail: posts ignore the
reserve; the drain does not lower `calls_out`; `idle` is set after `finish`; a `stopped` station
runs the handler.

**Compile-fail tests** (`zig build test-compile-fail`): a handler that returns `void`; `.now` with
no reply; a `finish` that takes a reply of another type; a `send` with a `Remote`.

**Halt scenarios** in `tools/halt/`:

| scenario | check | class |
|---|---|---|
| `send` of a record that is out | state `idle` | B |
| a second `answer`, or one from another thread | state `held`, owner | B |
| a call to a loop that never served | station state `unused` | B |
| `serve` on a station that serves | station state | C |
| `serve` or `call` in a group registry | `registry.group` | B |
| `take_reserved` with a wrong origin, target or generation, through its parameters | the link | B |
| a return with `calls_out` at 0, through its parameters | `calls_out` | B |
| more than `services_max` stations on one loop | `stations` | B |
| `discard_tasks` with a station that holds links | the list | C |
| `deinit` with a call out, or a station that serves | `assert_empty` | C |

**Mutations,** each against the narrowest target, each expected `CAUGHT`:

| mutation | target |
|---|---|
| `push_post` uses 256 | `test-core`, tests 1 and 5 |
| `answer` uses `push_post` | `test-core`, test 1, and the 224-post scenario |
| `call` does not raise `calls_out`, or the drain does not lower it | `test-core`, test 2 |
| the drain writes a call as an event | `test-core`, test 3 |
| the station runs every link in one run | `test-core`, test 4 |
| the station does not call `charge_task` | `test-core`, test 4 |
| the deadline check or the `stopped` check removed | `test-core`, test 4 |
| `idle` set after `finish` | `test-core`, test 4 |
| `callbacks_outstanding` not raised for a call out | `test-core`, test 5, and `halt-check` |
| `answer` does not wake a target that sleeps | conformance, each backend |
| a call to self goes through a ring | `test-core`, test 5 |
| each halt deleted | `halt-check`, or the Linux gate where a Linux call follows it |

**The work gate** holds every row within 2 percent, and gains a `call` row. `conformance_cost.zig`
gains a bound for a call round trip, at 10 times the measured value.

## Open questions

Each one has a proposed answer.

1. **`calls_per_pair_max`.** (a) 32. (b) 64, which leaves 192 slots for posts. *Proposed: (a),
   until stompy measures the depth of its journal pipeline. `CallsFull` says when it is reached.*
2. **The reserve.** (a) A constant 224 for every program. (b) A registry option that turns calls
   on, at one load for each post. *Proposed: (a). (b) is the fallback if the loss of 32 slots costs
   a consumer, for example a `Remote` or a decision 21 group.*
3. **A call to self.** (a) Through the station, with no ring. (b) A halt, as a post to self halts.
   *Proposed: (a). stompy's shard is a hash of the key, so about 1 call in N is local.*
4. **A call to a loop that never served.** (a) A halt on the target. (b) A `not_served` result.
   *Proposed: (a). It is a mistake of the program, and a halt stops the process at once.*
5. **A target whose thread exits on a fatal tick error (F6).** (a) R7's end call answers its held
   calls `target_stopped`. (b) The calls stay stranded until the process restarts. *Proposed: (a),
   in the record that rules R7 and R8. Until then, (b), and the guide says so.*
6. **The size of a station.** (a) 128 B on every target. (b) 64 B on x86-64. *Proposed: (a). A
   service costs 32 KiB once for each process.*
7. **`services_max`.** (a) 16. (b) 8. *Proposed: (a). stompy plans fewer than 8 today.*
8. **The generation in `Message.reserved`.** (a) Keep it, and check it on both sides. (b) Drop it,
   because a call message never outlives its record. *Proposed: (a). It costs one compare, catches
   a corrupted message, and is ready for an epoch of R8.*
9. **The group of a loop that calls and does not serve.** Its station runs `finish` in `.default`,
   which no library source names, against decision 30, rule 3. (a) Keep `.default`, and the guide
   says so. (b) Add `Service.attach(shared, options)`, which sets the caller's station group without
   `serve`, and halt at a `send` from a station that is neither attached nor serving. *Proposed:
   (a) for version one: each stompy core serves and calls, so `serve` names the group. (b) when a
   consumer has a loop that only calls.*

## Ask before

These items of CLAUDE.md's "Ask before" apply:

| item | today | proposed |
|---|---|---|
| building what decision 2 leaves out | no cross-core call | a new row |
| a named limit: the room for a post | 256 of 256 | `mailbox_posts_max`, 224 of 256 |
| a named limit: `message_tag_max` | `0x7fff_efff` (decision 29) | `0x7fff_effd` |
| new named limits | | `calls_per_pair_max` 32, `services_max` 16, two tags |
| the layout of a hot structure: `Mailbox` | | `calls_out` on the `tail` line; size unchanged; `header_version` + 1 |
| the layout of decision 30's `Groups` | | `stations` and `serving`, 1 B each, in its padding; size unchanged |
| the bound of the task queue | `tasks_queued_max` for each group (decision 30) | + `services_max` for station tasks; the push's assert `queued_max <= tasks_queued_max` changes with it |
| the overflow assert of `callbacks_outstanding` | decision 30's sum | + 17,360 for station tasks and calls |

- **New public names:** `Service`, `CallRecord`, `Answer`, `CallResult`, `CallOptions`,
  `ServeOptions`, `CallError`, `CallLink`, `CallStation`, and `call` and `answer` on `SharedLoop`
  and on each `Loop`.
- **New halts** in `discard_tasks` and in `deinit`. They change decision 27's shutdown contract.
- **Records not yet built:** W3 first, then decision 29, then decision 30, then this record. W4's
  `leave`, and R7 and R8 come later. This record states what it needs of each.

It adds no dependency, no edge to the module graph, and no file to decision 7's list. It weakens no
assertion, and moves none to a slower class.

## Sources

- Camilo's choice of 2026-11-07 of three Seastar features.
- The robustness plan of 2026-11-06: findings F3, F4, F6, F7, F12, F14 and F19; work items W3, W4
  and W9; rulings R5 to R8.
- Three drafts of this record of 2026-11-07, "minimal", "correct" and "operator", and two reviews
  of them. This record takes the first, with parts of the other two.
- Seastar's `src/core/reactor.cc`, `smp_message_queue`, read in a local copy on 2026-11-07. The
  facts that the section "Seastar" marks as recalled were not checked.
- Decisions 2, 4, 5, 8, 9, 18, 21, 26, 27, 28 and 29.
- `src/core/mailbox.zig`, `src/core/remote.zig`, `src/core/inbox.zig`, `src/core/tasks.zig`,
  `src/core/shared_loop.zig`, `src/core/operation.zig` and `src/core/constants.zig` at `5e9490d`.
- `bench/baseline/work.txt` and `docs/costs.md` at `5e9490d`.
