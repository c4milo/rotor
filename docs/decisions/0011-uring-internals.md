# 11. Inside the uring backend

Status: accepted on 2026-09-19, by the author of the backend while writing it. Each point is a
choice the code embodies, with the alternative it beat. Two points amend decision 5, and each
says so. Nothing here is measured yet: every cost below is a prior from `docs/costs.md`, and
milestone 1's report either confirms a point or reopens it.

## 1. An operation's deadline lives in the timer heap, not in a linked timeout

Amends decision 5, rule 4, which said the deadline on io_uring is a linked timeout entry.

A linked timeout costs one more submission entry per operation and one more completion for the
backend to consume: `C8 + C9`, 25 to 80 ns with the priors. The heap costs one `arm` and one
`disarm`, a few cache references each in lines the loop has just touched, about 10 to 30 ns. The
heap is also the path the kqueue backend must use, so both backends time out an operation with
one piece of code, and a deadline fires in the same order on both.

What it gives up: precision. The loop notices a passed deadline at its next tick. A tick that
waits is bounded by the nearest deadline, so an idle loop wakes on time, and a busy loop is late
by at most one tick's work. When the deadline passes the loop issues an ordinary cancel with
`Slot.Flags.timed_out` set, and decision 5's rule 2 decides the outcome.

Test: the conformance suite's receive-with-deadline scenario, on both backends. The harness's
timer-churn workload measures arm and disarm; if a linked timeout measures faster, this point
reopens with that number.

### Amendment of 2026-11-01: an operation's deadline expires after the reap

Until this date each tick expired first, and then waited and reaped. After a long turn of the
caller's own, a receive whose bytes were already in the socket ended with `timeout`. On kqueue and
epoll the tick had not read the readiness yet. On io_uring, `DEFER_TASKRUN` posts the receive's
completion only inside an enter, and the cancel entry went into that same enter. Issue 10 reports
it, from a consumer that runs two loops on one thread.

Now every backend's tick ends an operation's deadline last, after its reap, through
`Tables.expire_after_reap`. An operation whose result is ready when the tick begins ends with that
result, so the loop's own cancel loses the race, as decision 5, rule 2 says a cancel can. A due
deadline still makes the tick poll, because `Tables.wait_bound` gives no wait when the nearest
deadline has passed.

A timer has no result on its way from the kernel, so it need not wait for the reap. At its start a
tick runs `Tables.finish_due_timers`, which finishes the due timers at the head of the heap and
stops at the first deadline of an operation. The rest expire after the reap, in the same tick and
still in deadline order. Without this step a tick whose only work was a due timer did more work on
kqueue, measured on `mac` with `zig build work-gate`:

| workload | baseline | expiry after the reap only | with `finish_due_timers` |
| --- | ---: | ---: | ---: |
| timer | 1,076 | 1,141 | 1,086 |
| batch | 23,928 | 24,446 | 24,300 |

The tolerance is 2 percent. The other three workloads stayed within it both ways.

What it costs:

- On io_uring a deadline's cancel entry goes to the kernel in the next tick, not in this one. That
  tick does not block while a cancel waits, so a busy loop is late by at most two ticks' work, not
  one. A loop that blocks is not later: its wait ends at the deadline, and its cancel entry went
  into the next tick before this date too.
- On kqueue and epoll a cancel ends a waiter at once, so the operation's final event is handed over
  in the same tick.
- A kqueue tick that asks the kernel nothing also expires, so a stream of messages cannot hold a
  due deadline off.

Tests: three conformance scenarios. In the first, a receive's bytes came before its deadline, and
the loop ticks late. In the second, a tick has an event of its own and a due timer. In the third,
a due timer sits behind an offloaded read's deadline in such a tick. The Lean model's `tick`
expires, drains, expires and drains again.

| mutation | target | result |
| --- | --- | --- |
| kqueue expires at the tick's start again | `test-conformance-kqueue` | CAUGHT |
| io_uring expires at the tick's start again | `conformance-uring`, Linux gate | CAUGHT |
| epoll expires at the tick's start again | `conformance-epoll`, Linux gate | CAUGHT |
| kqueue skips the expiry after the reap | `test-conformance-kqueue` | CAUGHT |
| io_uring skips the expiry after the reap | `conformance-uring`, Linux gate | CAUGHT |
| epoll skips the expiry after the reap | `conformance-epoll`, Linux gate | CAUGHT |
| kqueue's tick that makes no call skips the expiry | `test-conformance-kqueue` | CAUGHT |
| `finish_due_timers` does not stop at an operation's deadline | `test-conformance-kqueue` | CAUGHT |
| `expire_after_reap` returns at once when a deadline is due | `test-conformance-kqueue` | CAUGHT |
| kqueue's tick skips `finish_due_timers` | `work-gate` | CAUGHT |

## 2. A posted message travels in the completion's result, with the top bit set

*Replaced on 2026-09-25.* Camilo ruled that loops talk through shared memory on io_uring too
(decision 4, its amendment of that day). A message now goes through the mailbox ring the sender
has to the target, and an `IORING_OP_MSG_RING` carries no message: it wakes a target that sleeps,
and its completion, with `user_data` `constants.user_data_wake`, is dropped by both reaps. So the
result carries no tag, a result below -4095 means nothing, and `message_result_flag` is gone.
`core.constants.message_tag_max` stays, as a named limit every backend holds a tag to. What
follows is the point as it stood.

io_uring delivers a `MSG_RING` post as a completion whose `user_data` and 32-bit result are the
sender's to choose. The payload is any 64 bits, so `user_data` cannot mark the completion as a
message. The backend sets bit 31 of the result above the tag. An errno is at most 4095, so a
result below -4095 is a message and nothing else, and the reap tells the two apart with the
compare it already makes for a failed operation. The cost to the caller: a tag stops at
`0x7ffff000` (`core.constants.message_tag_max`).

The alternative is `IORING_MSG_RING_FLAGS_PASS`, which lets the sender choose the completion's
flags and leaves all 32 bits to the tag. It needs a kernel later than the 6.1 floor of decision
2 (recalled: 6.3). A tag of 31 bits is not worth a higher floor. The floor is 6.17 since
2026-09-27, which has it; the tag stays at 31 bits until something asks for the last one.

The sender's own completion says whether the post reached the target's ring: 0, or
`mailbox_full` when the target's completion ring could take no more, or `loop_not_found`. A
post is therefore an operation like any other, with a slot and one final event. A skip-success
flag would save the sender one completion per post (`C9`), and it would break decision 5's rule
1, that a slot is freed by its final event and by nothing else. That trade waits for C17's
measurement. Measured on 2026-09-22 (`docs/costs.md`): C17 is 10,981 ns and C9 is 11.7 ns on
`orbstack`, so the flag would save 0.1 percent of a message. The trade is settled against the flag.

## 3. Cancel requests wait as handles, not as slot links

A cancel whose target the kernel holds needs a submission entry, and the ring may have none. The
request waits in a queue of 64-bit handles, not on a list through `Slot.next`. The target can
finish and its slot can be claimed again before the cancel gets its entry. A link would then
point into another operation's slot. A handle goes stale instead, and `flush` drops it.

The queue holds two handles per slot: one left over from the last flush whose target has since
finished, and one for the operation that claimed the slot next. `flush` visits every queued
handle once per tick and keeps only those the kernel still holds, so the bound holds by
construction. Cost: 16 bytes per slot of the table.

## 4. A loop has no queue of events

Decision 1's first sketch had a queue for the events a loop produces itself: a timer that fired,
a cancel that won before the kernel saw the operation. The slot holds the result (`Slot.result`)
and waits on a list linked through the slots (`Loop.finished`). `tick` hands the event over and
releases the slot in one step, which is the moment decision 5's rule 1 names. The list is
bounded by the table, so it needs no capacity of its own and cannot overflow.

### Amendment of 2026-11-07: two lists, and a share of the events (W3)

Camilo ruled on 2026-11-07 for W3, the fair tick order, with the recommended answer to each of its
questions. Before W3 the finished list took every place of a tick first. A long list then kept the
messages of other loops and the kernel's answer out of the tick.

- Due timers wait on a list of their own, `Tables.fired`. The other results wait on `finished`.
  Both lists are first in, first out.
- A tick of `N` events keeps a reserve `K` for the kernel and a reserve `M` for the mailboxes.
  `core.tick_share.split` computes both from counts only. Before the tick enters the kernel, the
  two lists take at most `N - K - M` events.
- Of `F` places, `fired` takes up to `F - min(finished.count, F / 2)`, and `finished` takes the
  rest. When both lists are full, each takes about half.
- The places that a reserve does not use go back in the same tick: to the mailboxes, then to the
  lists. The rest of the lists wait for the next tick.
- A tick of fewer than `fair_events_min` events, 10, keeps no reserve and the order of before.

What changes for the caller:

- A timer's event can come before the event of an operation that finished earlier in the same
  tick. rotor promises no order between two operations (point 8). Due timers keep their order.
- A queued operation that a close ends can reach the caller after the close's completion. Point 5
  already tells the caller not to treat the close's event as the last event of the connection.
- On kqueue and epoll, an operation whose deadline passed ends through `cancel_module.request` and
  `finish_local`, at the back of `finished`. Its delay stays bounded. Under the share the list gets
  about half of `N`, so the delay is about twice that of before W3. When `fired` is also full, the
  list gets about a quarter of `N`, and the delay is about four times that of before W3.
- On io_uring the kernel's cancel ends such an operation, and its event comes in the kernel's
  places.

Decision 12, point 6 holds the sender cursor, the checks and the measured cost.

## 5. What `close` guarantees about order

Amends decision 5, rule 6, which promised the caller the cancelled operations' final events
before the close's.

A `close` submits two entries, hard-linked: a cancel of every operation in flight for the
descriptor (`IORING_ASYNC_CANCEL_FD` with `IORING_ASYNC_CANCEL_ALL`), then the close. The kernel
cancels an operation that waits on its internal poll, which is every socket operation, inside
the cancel itself, so its completion is posted before the close runs. The events reach the
caller in completion order, so for socket operations the promise holds.

It does not hold for an operation a kernel worker is running when the cancel arrives: that
completion can follow the close's. Enforcing the order in the loop needs a count of operations
in flight per descriptor, which is a table indexed by descriptor and one more cache line touched
at every submit and every reap (C2 or C3, 3 to 50 ns per operation, against a per-entry budget
of C8, 20 to 60 ns). That is too much to pay on every operation for an ordering that matters at
close. The caller's rule is therefore: free a connection's state at the final event of each of
its operations, and treat the close's event as the descriptor being gone, not as the last event
of the connection.

What the cancel is for is liveness. io_uring holds a reference to the file, not to the
descriptor number, so an operation in flight survives a plain `close(2)` and its slot would
never be freed.

## 6. A connect's address is converted into storage that lives until the enter returns

The caller passes `core.Address`, rotor's own type, and the kernel wants its own structure. The
backend converts into a scratch array with one element per submission entry, and reuses it after
`io_uring_enter` returns. This rests on the kernel reading a connect's address while the enter
runs, at issue or at the preparation of a deferred request (recalled from the 6.1 sources). The
conformance suite's connect scenarios reuse the scratch at once, so a kernel that reads later
fails them.

The alternative is storage per slot, 28 bytes that only a connect uses, which does not fit the
64-byte slot.

## 7. One tick submits at most one ring's worth

Operations beyond the submission ring's entries stay on the pending list for the next tick. The
alternative, entering the kernel again within the tick until the list is empty, breaks "one
system call per tick" (decision 3, source 4) exactly when the loop is busiest. A caller sizes
`Options.entries` to its batch. A tick never blocks while operations are pending.

When the completion ring has overflowed, the kernel refuses the submission with `EBUSY` and
takes no entry. The tick reaps, which makes room, and the entries go out at the next tick.

## 8. Two operations in flight on one socket have no order

The conformance suite found this one. With two receives in flight on one socket, io_uring woke
the second before the first, so the first bytes of the stream landed in the second buffer. The
kernel arms one internal poll per request and makes no promise about which it wakes first. The
kqueue backend serves the waiters of a descriptor oldest first, so the two backends differed.

rotor promises no order, and `Operation.Receive` and `Operation.Send` say so: a caller keeps one
receive and one send in flight per socket, which a multishot receive does by itself. For sends
the rule matters more than it looks: two sends in flight can swap, and a short send leaves a
gap that the other fills, which corrupts the stream.

The alternative is to keep the order in the loop: hold a descriptor's second operation back
until the first completes. That needs the table from descriptor to operations that point 5
refused for its cost on every operation, and it would turn a caller's mistake into a silent
serialisation. The suite's scenario accepts either order and checks that every byte arrives
once.

## 9. A registered descriptor is an index and a flag

Decision 2 puts registration in the first API. `register_descriptors` hands the kernel a list of
open descriptors, once per loop, with `IORING_REGISTER_FILES`. An operation then names one by its
index in that list, with `Operation.descriptor_registered` set, and `prepare` sets
`IOSQE_FIXED_FILE` on the entry. The index rides where the descriptor did: in `Slot.descriptor`,
with one bit of `Slot.Flags` beside it. The slot's size and layout do not change.

The rules the caller sees:

- The list is registered once and does not change. That is what decision 2 promised, and it is
  what a consumer with a few long-lived files and listeners needs.
- `core.Tables` records how many descriptors the loop registered, and `submit` halts on an index
  at or past that count. The mistake is the programmer's, and it halts the same way on both
  backends, before any kernel sees it.
- A registered descriptor must stay open while any operation can name it. The kernel keeps a
  reference of its own to each registered file until the ring closes. The kqueue backend keeps the
  number alone (decision 12, point 9). So the stricter rule is the one rule.
- A `close` names a descriptor of the process, never an index. A socket accepted by a registered
  listener is a descriptor of the process.

Alternatives it beat:

- **A descriptor type that is a union of a number and an index.** It says the same thing in the
  type, and it changes every operation's fields and every call site for a case most operations
  never use. The flag mirrors the kernel's own shape.
- **An index encoded in the descriptor's negative range.** One field and no flag, but a value
  whose meaning depends on its sign is the kind of cleverness a reader trips on, and `-1`, the
  usual mark of a failed open, sits next to the range.
- **Direct descriptors**: accepted sockets that live only in the ring's table and never enter the
  process's. They remove a descriptor-table write per accepted connection, and they need a table
  that changes while the loop runs, with a free list and a close by index. Decision 3's claim
  for source 1 is about files at high queue depth. Direct accept waits for a harness number that
  says the accept storm needs it.

The claim stays untested until milestone 4: decision 3, source 1 names the workload, random
O_DIRECT reads at queue depth 32 and above, registered against unregistered.

## Not built yet

- The sampled statistics of decision 9.
