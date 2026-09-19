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

## 2. A posted message travels in the completion's result, with the top bit set

io_uring delivers a `MSG_RING` post as a completion whose `user_data` and 32-bit result are the
sender's to choose. The payload is any 64 bits, so `user_data` cannot mark the completion as a
message. The backend sets bit 31 of the result above the tag. An errno is at most 4095, so a
result below -4095 is a message and nothing else, and the reap tells the two apart with the
compare it already makes for a failed operation. The cost to the caller: a tag stops at
`0x7ffff000` (`core.constants.message_tag_max`).

The alternative is `IORING_MSG_RING_FLAGS_PASS`, which lets the sender choose the completion's
flags and leaves all 32 bits to the tag. It needs a kernel later than the 6.1 floor of decision
2 (recalled: 6.3). A tag of 31 bits is not worth a higher floor.

The sender's own completion says whether the post reached the target's ring: 0, or
`mailbox_full` when the target's completion ring could take no more, or `loop_not_found`. A
post is therefore an operation like any other, with a slot and one final event. A skip-success
flag would save the sender one completion per post (`C9`), and it would break decision 5's rule
1, that a slot is freed by its final event and by nothing else. That trade waits for C17's
measurement.

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

## Not built yet

- Registered descriptors. `Operation` has no way to name one yet. Decision 3's source 1 claims a
  gain from them, and the claim stays untested until the harness can measure it.
- Provided-buffer groups, which a multishot receive needs. The submit and reap paths carry the
  group and the buffer id already; the registration calls are the next file.
- The sampled statistics of decision 9.
