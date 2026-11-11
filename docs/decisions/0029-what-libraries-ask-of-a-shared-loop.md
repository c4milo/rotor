# 29. What libraries on a shared loop ask of it

Status: accepted on 2026-11-06 (see "Ruling"), and **built** on 2026-11-07 with the names of
decision 30 (see "What was built"). Every cost in the sections before "What was built" is a prior:
a row of `docs/costs.md` at the `mac` median, or an instruction count from arithmetic. Nothing was
measured for this record before the ruling.

**Names.** Decision 30 renamed two names of this record: `reserve_group` is `reserve_buffer_group`
in the code, and `GroupsFull` is `BufferGroupsFull`. The sections before "What was built" keep the
old names.

Amended on 2026-11-08 by decision 32. `message_tag_max` stays `0x7fff_efff`, and a post still
accepts a tag up to `message_tag_wake`, with one compare. The tags of a call and of its return
are `message_tag_wake + 1` and `message_tag_wake + 2`, which no post accepts. The drain's compare
is `tag > message_tag_max`, which finds the wake, a call and a return. A ring whose visit read
such a tag hands the rest of the drain to its backend's slow path, which takes each one in the
order of its ring. A drain that took a wake still tells the dispatch.

Amended on 2026-11-11 by decision 33, step 3. The pollers moved to the reactor, the module `reactor`,
and the stored limit stayed in the core:

- `WaitLimit` is declared in `src/core/core.zig`, and the compiler prints `core.WaitLimit`.
  `Completion` and `Poller` are declared in `src/reactor/reactor.zig`. Their functions are in
  `src/reactor/dispatch/dispatch_callbacks.zig`.
- `Dispatch.until_ns` is `stored_limit` in the core's `Tables`. On a reactor, only the reactor's
  code writes it, through the port's `stored_limit()`. It writes it at steps 1, 4 and 5 of "What
  the loop does" in section 2. Step 2, `Tables.wait_bound`, reads it as before.
- A plain `rotor.Loop` gains `wait_until`, which stores the limit. Only the program calls it.
- Section 2 rejected `bound_wait(at_ns)` beside the poller's answer, because a poller would have
  two ways to say "do not block". Decision 33 keeps one way on each kind of loop: `wait_until` on
  a plain loop, and a poller's `WaitLimit` on a reactor. `wait_until` fails to compile on a reactor
  and on `SharedLoop`. So decision 33 does not reverse that choice.
- The `wait_limit` of section 4 is the loop's in `src/core/loop_calls.zig`, and the reactor's in
  `src/reactor/dispatch/dispatch_calls.zig`. The reactor's answers `.now` while a task is queued,
  and otherwise the loop's answer.
- The drain hands a wake to the hook that the reactor attaches with `attach_reserved`. The hook,
  `Dispatch.take_reserved` in `src/reactor/call/call_loop.zig`, stores `.now` while a poller is
  added. This replaces `Dispatch.note_wake`. A plain loop has no hook, and drops a wake.
- `BufferGroup`, `reserve_buffer_group` and `Message.wake` stay in the core.

## Ruling, 2026-11-06

Camilo accepted this record with the proposed answer to each open question, and the "Ask before"
items it lists:

1. **`reserve_group` returns a `BufferGroup`**, which the library keeps, and each call that names a
   group takes one (open question 1).
2. **A reservation ends at the loop's `deinit`**, and no call gives it back (open question 2).
3. **It is built with decision 28, before the `v0.10.0` tag** (open question 3). Decision 28 is
   built first, because this record builds on its `SharedLoop`.

It builds on decision 28: a library holds a `*rotor.SharedLoop`, and the handlers keep their
parameters. `SharedLoop` gains `reserve_group`, as decision 28 says. It amends these records:

- decision 26, at what a poller returns;
- decision 27, at its open questions 11 and 14;
- decision 23, at the cycle of a host that sleeps in its own wait, and at its open question 1;
- decision 15, at how a buffer group id is chosen;
- decision 21, at the layout version of the registry's header.

## Context

On 2026-11-06 Camilo ruled that the draft of decision 28 splits in two. Decision 28 keeps correct
use and stalls. This record takes four things that libraries on a shared loop ask for. His two
requirements apply to both records:

1. **The shared-loop API is simple to use correctly.** Wrong use fails to compile. Where the
   compiler cannot see it, wrong use halts at once.
2. **rotor gives tools that prevent and monitor stalls.** Decision 28 holds them.

So this record adds a public name only where a document or one call is not enough. For each
topic, it first asks whether they are enough.

The inputs are colibri's friction list (colibri decision 156, step 44), items 1 to 3, and the
usability review of 2026-11-06, items 6, 7 and 9. Two faults that the draft found are fixed
already: `call_records` lowers the count after the record's call (206127e, decision 26, "Correction
of 2026-11-06"), and the count is `callbacks_outstanding` (0b367bc).

### What the code does today

These facts were read from the tree at `e31ea1a`:

- **No library receives a post.** Decision 26 sends each message to the caller of `tick`, which is
  the program. colibri arms a one-shot timer of 50 ms only to see a flag that another thread set.
- **A poller returns a `bool`** (`dispatch.zig:47`). True makes the tick wait 0 ns. A poller cannot
  bound the wait at a deadline. A timer cannot move, so colibri cancels a timer and arms a second
  one each time a QUIC deadline moves.
- **A buffer group id is a `u16` literal below `buffer_groups_max` (16).** cocuyo writes 0 and 1,
  and colibri writes 1. On one loop, the second `provide_buffers` of id 1 halts
  (`kqueue_buffers.zig:41`), in the second library, which may not be the one at fault.
- **`tick` returns the count of events that no record took.** So 0 does not mean idle. A host that
  sleeps in its own wait cannot read the nearest timer (decision 23, open question 1), or whether
  a poller asked for a wait of 0 (decision 27, open question 11).

## The decision, as proposed

1. **A wake.** Another thread stores a flag that a library owns, then posts `rotor.Message.wake`.
   The loop drops the wake, hands no event to anyone, and does not block before its pollers run.
2. **A deadline.** A poller returns a `rotor.WaitLimit`: `.now`, `.none`, or `.at(ns)`. The tick
   bounds its wait at the least limit, as it bounds it at the nearest timer.
3. **Reserved group ids.** A library calls `reserve_group()` once at init. It gets the lowest free
   id as a `rotor.BufferGroup`, and keeps it until the loop's `deinit`. Each call that names a
   group takes that type, so a literal fails to compile.
4. **The host.** `tick` keeps its `u32`. A host calls `wait_limit()` as its last call before it
   sleeps. It returns a `WaitLimit`, and changes nothing.

The record adds five public names: `Message.wake`, `WaitLimit`, `BufferGroup`, `reserve_group` and
`wait_limit`. `reserve_group` is its one call that a library makes.

### 1. A wake from another thread (colibri item 1)

| answer | what it adds | result |
|---|---|---|
| a document only: the program forwards a library's messages | nothing | rejected: the program must then know each library's messages, which decision 26 ended |
| a doorbell, as the draft of decision 28 proposed | `Doorbell`, `Bell`, `ring` on four types, `doorbells_max`, a fourth handler kind | rejected: five names do what a flag and a poller do |
| **one reserved message** | `Message.wake` | chosen |

The rule:

1. The library keeps a flag, a `std.atomic.Value(bool)`, in its own struct, and adds a poller.
2. Another thread stores the flag with release order. Then it posts `rotor.Message.wake` through its
   `Remote` or its own loop's `post`.
3. The loop takes the wake from its mailbox, writes no event, and stores `.now` in the loop's wait
   limit (section 2). So the tick does not block, and the next tick's `begin` calls the poller.
4. The poller loads the flag with acquire order. It acts, or it schedules its task.

```zig
// Any thread that holds a `Remote` (decision 4).
pub fn stop(client: *Client, remote: *rotor.Remote) rotor.PostError!void {
    if (client.stop_asked.swap(true, .release)) return; // a wake is on its way already
    remote.post(client.loop_id, rotor.Message.wake) catch |err| switch (err) {
        error.MailboxFull => {}, // see below
        else => |e| return e,
    };
}

// The poller, on the loop's thread. `client.loop` is the `*rotor.SharedLoop` it took at init.
fn poll(client: *Client) rotor.WaitLimit {
    if (client.stop_asked.load(.acquire)) client.begin_stop();
    return client.next_limit();
}
```

What follows from the rule:

- **No address crosses threads.** A wake carries no payload. A wake that arrives after the library
  removed its poller finds nothing. So decision 27, open question 14 keeps its reason.
- **Wakes coalesce in the flag.** A sender that posts only when `swap` changes the flag sends one
  wake for each change.
- **`MailboxFull` on a wake is safe to drop.** The ring from this sender then holds messages. By
  decision 12, point 6, the loop's tick does not block while it does. Since W3 (amended on
  2026-11-07, by Camilo's ruling) the sender cursor visits this sender within
  `ceil((L - 2) / ceil(M / 32)) + 1` ticks, so the ring empties and the loop can sleep again. A
  later tick calls the poller, and the poller sees the flag. Before W3 the drain started at sender
  0 at each tick, and a sender above the busy ones was never visited.
- **A wake counts in the mailboxes' share.** A wake writes no event, but the drain counts it as one
  message of its visit. So a ring of wakes cannot keep the drain longer than `messages_per_drain`
  per visit.
- **A hosted loop is as today.** A wake is a post, so it does not make the wait descriptor readable
  (decision 23, open question 2).

Where the loop takes a wake:

- **In core, on all three backends.** Each backend drains its mailboxes through
  `Inbox.drain_mailboxes`: kqueue and epoll before the wait and after it, io_uring at
  `uring_tick.zig:37` and `:64`. A post on io_uring also goes through the mailboxes
  (`uring_submit.zig:61`, `uring.zig:312`). The drain compares each tag with `message_tag_wake`.
- **The wait choice does not change.** Each backend chooses its wait after the first drain, through
  `wait_bound` (`kqueue_tick.zig:43`, `epoll_tick.zig:48`, `uring_tick.zig:186`). `wait_bound` reads
  the limit, so a wake that the first drain took gives no wait on each backend.
- **A wake stores `.now` only while a poller is in the table.** Only then does each tick run
  `begin`, which writes the limit again. On a loop with no poller, the drain drops the wake and
  stores nothing, so no stale `.now` keeps the loop from a wait.

The tag:

```zig
// src/core/constants.zig
/// The largest tag that a caller's `Message` may carry (decision 29: one less than before).
pub const message_tag_max: u32 = 0x7fff_efff;
/// The tag of `Message.wake`, the old `message_tag_max`. The loop drops such a message
/// (decision 29).
pub const message_tag_wake: u32 = 0x7fff_f000;

// src/core/operation.zig, in `Message`
/// Wakes the loop it is posted to, and reaches no one (decision 29).
pub const wake: Message = .{ .payload = 0, .tag = constants.message_tag_wake };
```

- The five checks of a tag at a post compare with `message_tag_wake`, the value they compare with
  today: `remote.zig:108`, `operation.zig:333`, `kqueue_remote.zig:72`, `uring_remote.zig:79` and
  `epoll_remote.zig:66`.
- `Event.message` keeps its assertion at `message_tag_max` (`event.zig:120`). So a wake that
  reaches an event halts.
- The comptime asserts of the errno margin move from `message_tag_max` to `message_tag_wake`:
  `constants.zig:184-185` and `uring_errno.zig:120`. The margin stays exact:
  `(1 << 31) - 0x7fff_f000` is 4096, against `errno_max` 4095.
- **Decision 21.** A process of an older build may send tag `0x7fff_f000` as data. The registry's
  `header_version` goes from 1 to 2, so such a process cannot join the group.

### 2. A deadline that a poller moves (colibri item 2, review item 7)

| answer | what it adds | result |
|---|---|---|
| a document only: cancel the timer and arm one more | nothing | rejected: two records and two operations for each moved deadline, the cost colibri reports |
| `reset_timer(handle, after_ns)` | a timer call | rejected: decision 2 lists timers as "arm, cancel". A heap entry in flight needs new rules, and io_uring does kernel work for each move |
| `bound_wait(at_ns)`, beside the `bool` | one call | rejected: two ways to say "do not block" |
| **the poller's answer becomes a limit** | `WaitLimit` | chosen: one answer, one type |

```zig
// src/core/dispatch.zig
/// How long a tick may wait, on the loop's clock (`now_ns`). A poller returns it, and a host
/// reads it from `Loop.wait_limit` (decision 29). Size 8 B: it comes back in one register.
pub const WaitLimit = enum(u64) {
    /// Work is left: do not wait. Decision 26's `true`.
    now = 0,
    /// Nothing here bounds the wait. Decision 26's `false`.
    none = std.math.maxInt(u64),
    _,

    /// Wait until `at_ns` at the latest. `.at(0)` is `.now`, and `.at(maxInt(u64))` is `.none`.
    pub fn at(at_ns: u64) WaitLimit {
        return @enumFromInt(at_ns);
    }
};
```

- A poller's handler keeps decision 26's parameters, `fn (parent: *Parent)`, and returns
  `WaitLimit` in place of `bool`. A handler that returns `bool` fails to compile, so each consumer
  moves once and cannot miss one.
- Each value means one thing, and no value is wrong. So `at` has no assertion.

What the loop does:

1. `begin` folds the answers into `Dispatch.until_ns`, the least of them. It still returns 0 when
   that value is `.now` or a task is queued, and the caller's wait otherwise.
2. `wait_bound` takes the least of the nearest timer and `until_ns`. Each backend calls it after
   R1, its clock read at the start of the tick. So a poller's deadline meets the same stamp as a
   timer's, with no new clock read.
3. A limit at or before that stamp gives no wait. The next `begin` calls the poller again, and the
   poller sees its deadline due.
4. `end` stores `.now` in `until_ns` after it called a record or a task, while a poller is in the
   table. Such a call can change what a poller would answer. Only `wait_limit` reads that store,
   because the next `begin` writes `until_ns` before the next `wait_bound`.
5. A `remove_poller` that empties the table writes `.none`. So a tick on the fast path never reads
   a stale limit.

A poller reads `now_ns` as the last tick stored it (decision 26, "What was built"). A deadline that
it reads as ahead may be due by R1. Step 3 then gives a tick that does not block, so the poller is
late by at most one such tick.

colibri's loss, PTO, ACK-delay and pacing deadlines become one poller:

```zig
fn poll(quic: *Quic) rotor.WaitLimit {
    const deadline = quic.connection_timer.next(&quic.connection) orelse return .none;
    if (deadline.at_ns > quic.loop.now_ns()) return .at(deadline.at_ns);
    quic.on_instant();
    return .now;
}
```

The deadline moves with no timer operation, no cancel and no second record.

### 3. Buffer group ids that cannot clash (colibri item 3)

| answer | what it adds | result |
|---|---|---|
| a document only: the program hands each library its ids | nothing | rejected: each program counts the ids of each library, and a clash names the wrong library |
| `provide_buffers` returns a `BufferGroup` | one type | rejected: an id goes back to the loop at each `release_buffers`, so another library can take it, and a stale id then names that library's group |
| `reserve_group() u16`, and a halt on an id that is not reserved | one call, a mask | rejected: a literal compiles, and halts only at run time |
| **`reserve_group()` returns a `BufferGroup`, which the library keeps** | one call, one type | chosen: a literal fails to compile, and an id is one library's for the loop's life |

```zig
// src/core/buffer_group.zig, exported from `rotor`.
/// A buffer group id of one loop. Only `reserve_group` makes one, so a library cannot name
/// another library's group by a literal (decision 29). Size 2 B.
pub const BufferGroup = enum(u16) { _ };

// rotor.Loop, and `SharedLoop`, which decision 28 says gains it.
/// Reserves the lowest id that no caller holds, and returns it. The id is the caller's until the
/// loop's `deinit`. error.GroupsFull when all `buffer_groups_max` ids are reserved.
pub fn reserve_group(loop: *Loop) error{GroupsFull}!BufferGroup;
```

The rule:

1. A library calls `reserve_group` once, at init, and keeps the id in its struct.
2. It calls `provide_buffers` and `release_buffers` with that id, as often as it needs.
3. It never gives the id back. Only the loop's `deinit` ends the reservation.

- These take `BufferGroup` in place of `u16`: `provide_buffers`, `provide_datagram_buffers`,
  `datagram`, `give_back_buffer`, `release_buffers`, `provided_buffer`, `Operation.receive_group`,
  `Operation.receive_from`, and the fields `Operation.Target.group` and `ReceiveFrom.group`. Each
  call keeps its other parameters.
- A literal such as `release_buffers(1)` fails to compile. A deliberate `@enumFromInt` compiles, as
  decision 28's `@ptrCast` does. A provide with an id that no caller reserved halts (new, class C,
  on a cold path). A cast to another library's id is not seen.
- The id is the lowest one that is not reserved, a function of the order of the calls. The group
  table gains a mask of reserved ids, a `u16`.
- No assertion is weakened. A release of an id with no group still halts (`kqueue_buffers.zig:52`).
  A provide of an id with a group still halts (`kqueue_buffers.zig:41`). Without a cast, only the
  library that holds the id can reach it, so the halt is in the library at fault.
- One datagram shape for each loop stands (decision 15).

This breaks each caller of `provide_buffers`: cocuyo, colibri and `examples/guide.zig` call
`reserve_group` at init. Cost: a scan of a 16-bit mask at each reservation, which is cold.

### 4. What a host reads before it sleeps (decision 23, review item 6)

| answer | what it adds | result |
|---|---|---|
| a document only: a host wakes on a period of its own | nothing | rejected: a host cannot see a poller's `.now` or a deadline, and stompy's 10 ms period is a wait of up to 10 ms |
| a struct return from `tick` | a new return type | rejected: it changes decision 1's batch shape for each caller |
| `Loop.must_not_sleep() bool` (review item 6) | one call | rejected: it gives neither a poller's deadline nor the next timer |
| a call that also marks the sleep in decision 28's heartbeat | a store | rejected: decision 28 turns the stall count off on such a host, so nothing reads the mark |
| **one call that reads the limit** | `wait_limit` | chosen |

```zig
// rotor.Loop. Program only (class B owner check). It halts inside a tick (class B).
// `SharedLoop` does not declare it, because only the program sleeps.
/// The host's last call before it sleeps in its own wait (decision 29). Returns how long it may
/// sleep. It changes no state.
pub fn wait_limit(loop: *Loop) WaitLimit;
```

It returns `.now` when any of these holds:

- a task is queued;
- operations wait to be submitted, or results wait to be handed over;
- a mailbox still holds messages;
- an offload worker's result is in a ring to the loop. The build added it, and Camilo ruled on
  2026-11-07 that it stays (see "What was built", item 2);
- a tick kept a kernel error, which the next tick returns (decision 5, amendment of 2026-11-06).
  The review of the build added it on 2026-11-07 (see "What was built", item 6);
- the least of the nearest timer and `until_ns` is at or before `now_ns`. This covers a poller that
  returned `.now`, a deadline that is due, a wake that the last tick took, and a record or a task
  that the last tick called.

Otherwise it returns `.at` of that least value, or `.none` when neither a timer nor a poller limit
exists. It reads no clock.

The host's cycle:

1. Tick with a wait of 0.
2. Call `wait_limit()`. On `.now`, go to step 1.
3. Sleep in its own wait, with `wait_descriptor()` among what it waits on. On `.at(t)`, sleep for
   `t -| loop.now_ns()` at most. On `.none`, the host's own wait bounds the sleep.

What follows:

- **Stalls are as decision 28 says.** A host sets `stall_turn_ns = null` and watches no heartbeat.
  This record does not change that.
- `now_ns` is the stamp of the last tick, so the sleep is late by at most the host's own work since
  that tick. So a host does its own work before step 1.
- Posts and wakes still do not make the descriptor readable (decision 23, open question 2).

Cost: the call is cold, and a kernel wait follows it. It answers decision 23, open question 1, and
closes decision 27, open question 11.

## Determinism

- `begin` takes the least of the pollers' answers, so the table order does not change the result.
- `wait_bound` compares a limit with the stamp R1, as it compares a timer.
- `wait_limit` reads state and no clock.
- `reserve_group` returns the lowest id that is not reserved, a function of the calls.
- When a wake arrives depends on another thread, as for any post (decision 4). The loop decides
  only that its tick does not block.

## Where it meets the records

- **Decision 1.** `tick` and its batch shape do not change.
- **Decision 2.** Each item extends a row that version one has: posts, pollers, provided buffers
  and a host that owns the wait. This record adds no row.
- **Decision 4 and non-negotiable 4.** A wake is a post. No new call crosses threads.
- **Decision 12, point 6.** The sleep handshake does not change. The model of `spec/tla/wake/` does
  not change, because a wake is a post.
- **Decision 13.** A wake makes a tick not block. It hands over no event, so it does not move
  `active_ns`.
- **Decisions 10 and 24.** `src/core/surface.zig` gains `WaitLimit`, `BufferGroup`,
  `reserve_group` and `wait_limit`. A twin brings them.
- **Decision 15.** A group id comes from `reserve_group`.
- **Decision 21.** `header_version` goes from 1 to 2.
- **Decision 23.** The host's cycle calls `wait_limit`. Open question 1 is answered.
- **Decision 26.** A poller returns `WaitLimit`, and keeps its parameters. Open question 2 keeps
  its answer: a post carries no record.
- **Decision 27.** Open question 11 is closed. Open question 14's answer now reads: "A library that
  another thread wakes reads its own flag in its poller, after a `Message.wake`."
- **Decision 28.** This record follows its one view. `SharedLoop` gains `reserve_group`, and its
  calls that name a group take `BufferGroup`. `SharedLoop` does not declare `wait_limit`. A host
  sets `stall_turn_ns = null`, as decision 28 says, and `wait_limit` marks nothing.

## What it costs

Every number here is a prior, from the `macos-aarch64-kqueue` section of `bench/baseline/work.txt`.
Each row counts the most this record can add. The same instructions apply to each Linux section:
the drain and `wait_bound` are core's.

| item | added |
|---|---|
| each message that a drain takes | one compare of the tag, about 2 instructions |
| each tick that calls `wait_bound` | a load and a min, about 3 instructions |
| each poller in a dispatched tick | a min, about 2 instructions |
| each dispatched tick | the store of `until_ns` in `begin` (1); in `end`, a test of the poller count (about 2) |
| a wake | a post: C18 (18,125 ns on `mac`) to a kqueue loop that sleeps, C17 on io_uring, C19 (97.0 ns on `mac`) to a loop that is awake; then the poller's load of its flag, C1 |
| memory | `until_ns`, 8 B in `Dispatch`; the mask of reserved ids, 2 B in the group table |

Open question 3 proposes that both records land in one series. So the table gives this record
alone, and the sum with decision 28's priors: 7 for each tick, 5 for each dispatched tick, and 2
for each callback. Decision 28's table has no `record` or `poller` row, so those two sums are this
record's arithmetic.

| row | baseline | this record | prior | with decision 28 | prior |
|---|---:|---|---:|---|---:|
| `post` | 1218 | drain compare (2), `wait_bound` (3) | about 1223, +0.4 percent | + 7 | about 1230, +1.0 percent |
| `post-operation` | 3051 | the same, over two ticks (10) | about 3061, +0.3 percent | + 14 | about 3075, +0.8 percent |
| `timer` | 1111 | `wait_bound` (3) | about 1114, +0.3 percent | + 7 | about 1121, +0.9 percent |
| `batch` | 24624 | `wait_bound` (3) | under +0.1 percent | + 7 | under +0.1 percent |
| `wait` | 5408 | `wait_bound` (3) | under +0.1 percent | + 9 | about 5420, +0.2 percent |
| `task` | 610 | `begin` (1), `end` (2) | about 613, +0.5 percent | + 14 | about 627, +2.8 percent |
| `tasks-64` | 4407 | the same (3) | under +0.1 percent | + 140 | about 4550, +3.2 percent |
| `record` | 1222 | `wait_bound` (3), `begin` (1), `end` (2) | about 1228, +0.5 percent | + 14 | about 1242, +1.6 percent |
| `poller` | 570 | the poller's min (2), `begin` (1), `end` (2), `wait_bound` (3) | about 578, +1.4 percent | + 14 | about 592, +3.9 percent |

Alone, each row stays inside the tolerance of 2 percent. With decision 28, `task`, `tasks-64` and
`poller` pass it. Decision 28's open question 2 asks for new baselines for `task` and `tasks-64`.
This record asks for the `poller` baseline when both land (see "Ask before"). The `poller` row,
added at `e31ea1a`, holds the cost of each poller.

## Alternatives it beat

The tables of smaller answers above hold the main ones. These are the others:

- **A task address in a post's payload** (the review's first form of item 9). A task freed while a
  message is in flight gives a call through a stale pointer, which corrupts memory where it should
  halt (non-negotiable 6).
- **`Remote.schedule`, or an atomic bit that any thread may set with a wake.** It is a second call
  between threads beside `post`, which amends non-negotiable 4, decision 4 and the wake model. A
  thread that wakes a loop holds a `Remote`, and no consumer asked for more.
- **A wake as a call of its own, `Remote.wake` and `Loop.wake`.** A call on each type that posts,
  where a reserved tag adds one name. It catches no misuse that the tag misses.
- **A wake in `Message.reserved`.** A post operation's slot keeps only the payload and the tag
  (`slot.zig:182-184`), so the wake would be lost on that path.
- **A wake that `Dispatch.end` drops.** On a loop with no poller and no record, `end` does not run,
  and a late wake reaches the program.
- **A flag for "a wake was taken" in each backend's wait choice.** Three backends change. A store
  of `.now` in `until_ns` reaches `wait_bound` and `wait_limit` through a word they read already.
- **A call that gives a reserved id back.** A library that ends before its loop keeps its id, and
  16 ids bound that. One more call, and its misuse, buy nothing that a consumer asked for (open
  question 2).

## How it would be checked

**Unit tests in core, with no `Loop`:**

1. `begin` with `.none`, `.now`, `.at` in the past and in the future, and two pollers whose least
   limit wins.
2. `wait_bound` with a poller limit before the nearest timer, after it, and with none. A
   `remove_poller` that empties the table resets `until_ns`.
3. `Inbox.drain_mailboxes` takes a wake and writes no event. It stores `.now` with a poller in the
   table, and nothing with none.
4. `end` stores `.now` after a record or a task while a poller is in the table.
5. Core's part of `wait_limit` reads `.now` with a task queued, after a wake, after a record, with
   a mailbox that holds messages, and with a poller that returned `.now`. It reads `.at` with a
   timer or a poller limit, and `.none` with neither.
6. `reserve_group` returns the lowest id that is not reserved, and `GroupsFull` after 16. A
   provide, a release and a provide again use the same id.

**Conformance scenarios** on each backend, and again with the spin budget:

- A poller returns `.at` 5 ms ahead, and the caller's wait is 1 s. The tick returns before 500 ms, a
  loose bound against noise, and the next `begin` sees the deadline due.
- A `Remote` stores a flag and posts a wake before the tick. The tick, with a wait of 1 s, returns
  before 500 ms, and the next tick's poller sees the flag. On io_uring this is the drain at
  `uring_tick.zig:37`.
- A `Remote` posts three wakes to a loop that sleeps. No event reaches the program.
- A post operation sends a wake. No event reaches the program.
- A wake to a loop with no poller gives no event, and the next tick with a wait of 20 ms blocks.
- A host cycle: `wait_limit` reads `.now` after a tick that called a record, and after a tick that
  took a wake, then `.at` with a timer armed.
- Two libraries on one loop each reserve a group, provide buffers and receive into them. Neither
  sees the other's buffers.

**Race gate.** A `Remote` stores a flag and posts a wake while the loop sleeps. The poller sees the
flag.

**Compile-fail tests** (decision 28's `zig build test-compile-fail`): a literal group id passed to
`release_buffers`, and a poller that returns `bool`.

**Halt scenarios** in `tools/halt/`. Each one must die by a signal, and must return once its
assertion is deleted:

| scenario | check | class |
|---|---|---|
| `wait_limit` inside a tick | `ticking` | B |
| a provide with an id that no caller reserved | the reserved mask | C |

**Mutations,** each against the narrowest target:

| mutation | target |
|---|---|
| `begin` ignores a poller's limit | `test-core`, test 1, and the 5 ms scenario |
| `wait_bound` ignores `until_ns` | `test-core`, test 2, and the 5 ms scenario |
| `remove_poller` does not reset `until_ns` | `test-core`, test 2 |
| the drain writes a wake as an event | `test-core`, test 3, and the three-wakes scenario |
| the drain does not store `.now` on a wake | `test-core`, test 3, and the wake-before-the-tick scenario |
| the drain stores `.now` with no poller | `test-core`, test 3, and the no-poller scenario |
| `end` does not store `.now` after a callback | `test-core`, test 4, and the host cycle |
| `wait_limit` ignores `until_ns`, and misses a wake or a poller's `.now` | `test-core`, test 5, and the host cycle |
| `wait_limit` ignores a mailbox that holds messages | the host cycle: `test-core` does not reach the backend's call |
| `wait_limit` ignores a kept tick error | `test-core`, with a fabricated kept error |
| `reserve_group` returns an id that is reserved | `test-core`, test 6, and the two-library scenario |
| a release clears the reservation | `test-core`, test 6 |
| each halt deleted | `halt-check` |
| a type changed back to `u16` or `bool` | `test-compile-fail` |

**The instruction gate** holds each row within 2 percent for this record alone. **The call gate**
counts no new call for each echo.

## Open questions

These are in the order that Camilo should rule on them. Each has a proposed answer.

1. **Group ids.** (a) `reserve_group` returns a `BufferGroup`, which the library keeps, and each
   call that names a group takes one. (b) `provide_buffers` returns a `BufferGroup`, with no new
   call. A released id can then go to another library. (c) A `u16` from `reserve_group`, and a halt
   on an id that is not reserved. A literal compiles and halts at init. *Proposed: (a). A literal
   fails to compile, and a stale id cannot name another library's group.*
2. **The life of a reservation.** (a) It ends at the loop's `deinit`, and no call gives it back.
   (b) A `release_group` call gives it back. *Proposed: (a). A library lives as long as its loop in
   each consumer today. A program that starts and ends libraries on one loop more than 16 times
   gets `GroupsFull`.*
3. **When to build.** (a) With decision 28, before the `v0.10.0` tag. Decision 28 changes what a
   library holds, and this record changes what a poller returns, so each consumer moves once.
   (b) After decision 28, with a second break. *Proposed: (a).*

## Ask before

These items of CLAUDE.md's "Ask before" apply:

| item | today | proposed |
|---|---|---|
| a named limit: `message_tag_max` | `0x7fff_f000` | `0x7fff_efff` |
| a new named limit: `message_tag_wake` | | `0x7fff_f000` |
| the size of a hot structure: `Dispatch` | not measured for this record | 8 B more: `until_ns` |
| the group table | | a mask of reserved ids (2 B) |
| a new baseline, when both records land | `poller` 570 | the measured count, a prior of about 592 |

- **A tag with a new effect.** A caller in the same process that posts tag `0x7fff_f000` as data
  today gets a wake after this record: no event, and no halt. A check cannot tell that tag from
  `Message.wake`. No consumer writes it: on 2026-11-06 no Zig file of colibri, cocuyo or stompy
  holds the literal, and stompy's `io_message.zig:34` reads `message_tag_max`, so it follows the
  new value. A process of an older build is refused by decision 21's `header_version`.
- **`Dispatch`** sits in `Tables`, an auto-layout struct. A build reports its size and where the
  compiler places the new field before the layout is fixed, as decision 27 did.

The record adds no dependency, no edge to the module graph, and no file to decision 7's list. It
weakens no assertion. It changes the API of decisions 15 and 26: the calls that name a group and a
poller's handler. No tag holds that API yet, because `v0.9.0` is older than decision 26.

## What was built

Built on 2026-11-07, before decision 30, by the build order of decision 30's ruling. Decision 30,
open question 1, renamed two names of this record before the build: `reserve_group` is
`reserve_buffer_group`, and `GroupsFull` is `BufferGroupsFull`. The other sections keep the old
names. The code:

- `src/core/dispatch/dispatch_callbacks.zig` holds `Completion`, `Poller` and `WaitLimit`, split
  from `dispatch.zig` for the 500-line limit. `dispatch.zig` declares each one.
- `Dispatch.until_ns`, a `WaitLimit`. The compiler put it at offset 88, after `tasks`. `Dispatch`
  is 104 bytes, and its alignment stays 8. A comptime assert holds both.
- `Dispatch.note_wake`, which the drain calls, and `Dispatch.limit_between_ticks`, which halts
  inside a tick.
- `Tables.wait_bound` takes the least of the nearest timer and `until_ns`. `Tables.wait_limit` is
  core's part of the host's call.
- `Inbox.drain_mailboxes` takes the loop's `*Dispatch`. `Inbox.holds_messages` reads every ring to
  the loop.
- `src/core/buffer_group.zig`: `BufferGroup`, `ReserveError` and `Reservations`, the mask. Each
  backend's `Loop` holds the mask as `buffer_groups`, beside `groups`, and resets it at `init`.
- `wait_limit` is written once, in `dispatch_calls.zig`, for the three backends. The public module
  declares it, and `SharedLoop` does not.
- `src/rotor/rotor_loop_buffers.zig` holds the buffer calls of the public `Loop`, split from
  `rotor_loop.zig` for the 500-line limit.
- `tools/compile_fail/release_buffers.zig` and `tools/compile_fail/poller.zig`.
- `src/conformance/conformance_wait_limit.zig` holds the scenarios of the poller's limit, the wakes
  and the host. `conformance_buffer_release.zig` holds the two libraries on one loop. The scenario
  of the wakes from another thread is the race gate's scenario too.

Where the code differs from the proposal:

1. **The drain writes a wake with no branch.** A first build compared the tag in a branch. The
   compiler then made the ring's pop a call, and each tick paid it. On `mac`, the `timer` row of
   the work gate counted 1,179 instructions, against 1,151 at `48cacba`. Now the drain writes the
   event of each message. A wake gets tag 0, and the count of events does not grow for it. The
   drain counts the wakes as the messages the ring gave less the events it wrote. The event of a
   wake is in a place that the next message takes, or that no caller reads. `Event.message` keeps
   its check of the tag of each message that is not a wake.
2. **`wait_limit` reads the offload's rings too.** A worker's result is in a ring to the loop, as a
   message is, and the host would sleep on it. The record named only the mailboxes. Camilo ruled
   on 2026-11-07 that the read stays.
3. **More halt scenarios than the table of "How it would be checked".** The owner checks of
   `reserve_buffer_group` and `wait_limit`, on each backend. The halt of a provide with a group that
   no caller reserved runs on each backend, through `tools/halt/buffer_release.zig`. The check of
   `wait_limit` inside a tick runs through `Dispatch.limit_between_ticks`.
4. **`bench/echo/rotor_echo.zig` keeps the group that `reserve_buffer_group` gives each loop.** The
   first build named the first group, 0, by a cast, and `serve` asserted that the loop gave that
   id. Camilo ruled on 2026-11-07 that the server gets its group as every library does. Each loop's
   handlers now take a `Serving`: the loop and its group.
5. **The halt scenarios that take a tag above the limit post `message_tag_wake + 1`.** A tag of
   `message_tag_max + 1` is the wake's tag now, which a post accepts.
6. **`wait_limit` returns `.now` while a tick's kernel error is kept.** A tick whose kernel call
   fails after it produced events returns the events and keeps the error for the next tick
   (decision 5, amendment of 2026-11-06). The first build did not read the kept error. A host that
   ticked once and trusted `wait_limit` then slept, and the error stayed unreturned until a wake.
   The review of 2026-11-07 found it. The check is in `dispatch_calls.zig`, so it holds on the three
   backends. `test-core` holds it with a fabricated kept error (decision 10).
7. **kqueue's `provided_buffer` checks the group id with `assert_class_a`, and no longer with
   `assert`.** It moved to `kqueue_buffers.zig` with the other buffer calls, and took the class of
   io_uring's check. With class A compiled out, an id at or above `buffer_groups_max` reads out of
   the group table. Only `reserve_buffer_group` makes a `BufferGroup`, so such an id needs a cast.
8. **A poller's limit ends a spin before it starts, as a timer does** (decision 13, point 2). The
   pollers run once in a tick, before its spin, so the spin's polls do not call them. The first
   build gave the spin only the nearest timer. A tick whose poller limit fell inside the spin's
   window then polled until the window ended, late by up to the budget. Now each backend's
   `spin_then_wait` reads `Tables.earliest_deadline_ns`, the least of the timer and the limit.
   The scenario is in `conformance_spin.zig`.

The instruction gate on `mac` on 2026-11-07, section `macos-aarch64-kqueue`, with
`zig build work-gate`. The column `48cacba` is the tree before this record, measured the same day.
The baseline is `bench/baseline/work.txt`, which this build does not change.

| row | baseline | `48cacba` | this build | against the baseline |
|---|---:|---:|---:|---:|
| `post` | 1217 | 1200 | 1226 | +0.7 percent |
| `post-operation` | 3114 | 3114 | 3158 | +1.4 percent |
| `timer` | 1151 | 1151 | 1159 | +0.7 percent |
| `batch` | 24624 | 24806 | 24801 | +0.7 percent |
| `wait` | 5296 | 5299 | 5311 | +0.3 percent |
| `task` | 615 | 606 | 620 | +0.8 percent |
| `tasks-64` | 4558 | 4535 | 4543 | -0.3 percent |
| `record` | 1283 | 1283 | 1296 | +1.0 percent |
| `poller` | 573 | 564 | 575 | +0.3 percent |

Each row is inside the tolerance of 2 percent. Against `48cacba`, `post` grew by 2.2 percent and
`task` by 2.3 percent, more than the priors of "What it costs". The priors counted 5 and 3
instructions for those rows, and the gate counted 26 and 14. Two runs of the same build differed
by up to 4 instructions on a row. The baselines do not change: a new `poller` baseline waits for
the build of both records, as "Ask before" says.

## Sources

- colibri's friction list of 2026-11-06, from colibri decision 156, step 44: items 1 to 3.
- The usability review of 2026-11-06: items 6, 7 and 9.
- The first draft of decision 28, of 2026-11-06, sections 6 to 9, which this record replaces.
- Decision 28 as proposed on 2026-11-06, after Camilo split the first draft.
- `src/core/dispatch.zig`, `src/core/inbox.zig`, `src/core/tables_deadline.zig`,
  `src/core/constants.zig`, `src/core/event.zig`, `src/core/buffer_group.zig`, the tick files of
  the three backends, `src/kqueue/kqueue_buffers.zig`, `src/uring/uring_errno.zig` and
  `src/rotor/rotor_loop.zig` at `e31ea1a`.
- `bench/baseline/work.txt` and `docs/costs.md` at `e31ea1a`.
