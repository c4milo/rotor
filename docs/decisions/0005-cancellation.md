# 5. Cancellation and timeout semantics

Status: accepted for implementation on 2026-09-19. The owner gave the instruction to implement and
did not rule on the open questions below, so the implementation follows the proposed answer to
each until a ruling changes it.

Amended on 2026-09-19 by decision 10: rotor has no simulator. "What the simulator injects" is
replaced by tests that hand the backend fabricated completions in each order rule 2 allows, the
buffer poisoning of rule 3 is dropped, and the mutations under "How it is checked" run against
those tests and the conformance suite.

## Context

An operation submitted to io_uring is in the kernel. Cancelling it is a request, and the kernel
may have finished the operation already, may be half way through it, or may never find it. The
buffer the operation names stays the kernel's until the kernel says otherwise. On kqueue an
operation is either waiting for readiness in user space or running inline, so nothing is ever
"in the kernel" in that sense. The two backends must still show the caller one behaviour, and
the simulator must be able to produce every order the kernel can.

stompy's layer has no cancellation. This record is new ground.

## Decision

### Rule 1: every operation ends with exactly one final event

Whatever happens, a submitted operation produces one final `Event`, and its slot is freed when
that event is reaped and at no other moment. A multishot operation produces any number of
events flagged `more` and then one final event without the flag. No path frees a slot early,
and none drops a final event. The generation in the `Handle` (`0001-interface.md`) rises when
the slot is freed, so a handle kept past the final event no longer matches and is refused.

### Rule 2: cancel is a request, and the target's final event is the answer

`cancel(handle)` queues a request and returns. It produces no event of its own. The caller
learns the outcome from the target's final event, which holds one of:

- `error.Canceled`: the cancel won and nothing was transferred.
- A byte count greater than zero: the operation made progress before the cancel reached it. A
  transfer of some bytes reports the bytes, never `Canceled`. The caller must see them, because
  the peer or the disk already has.
- The operation's ordinary result: the operation finished first and the cancel found nothing.

The backend consumes the kernel's completion for the cancel request itself. "Not found" and
"already running" are not errors to the caller: both mean the target's final event is on its
way or already reaped. Cancelling a handle whose generation no longer matches does nothing, and
that is legal, because the race between a reap and a cancel is one the caller cannot avoid.

### Rule 3: the buffer belongs to the loop until the final event

From `submit` until the final event is reaped, the caller must not read, write, reuse or free
the operation's buffer. Calling `cancel` changes nothing about that. This is the rule that
covers a completion whose operation is already in the kernel: the kernel may still write into
the buffer after `cancel` returns, and only the final event says it has stopped.

rotor cannot assert this rule on the real backends, since it cannot see what the caller does
with its memory. The simulator can: it poisons a cancelled operation's buffer until the final
event and fails the run if the caller's checksum of it changes early.

### Rule 4: a timeout is a cancel the loop issues

An operation may carry a deadline. When the deadline passes first, the loop cancels the
operation, and the final event follows rule 2 with `error.Timeout` in place of `error.Canceled`.
Bytes transferred still win over `Timeout`.

- On io_uring the deadline is a linked timeout entry, so the kernel arms and disarms it with the
  operation and the pair costs `2 × C8`.
- On kqueue and in the simulator the deadline is an entry in the timer heap below.

### Rule 5: timers live in user space

A standalone timer is an entry in a 4-ary min-heap the loop owns, indexed by slot and bounded
by `timers_max`. The loop passes the nearest deadline as the wait argument of its one syscall
per tick: the `EXT_ARG` timeout on io_uring, which stompy's layer already uses, and the
`timeout` argument of `kevent`.

Cost: arming or cancelling a timer is a heap update, about `log4(n)` swaps in memory the loop
just touched, a few C1 or C2 each. The alternative, one `IORING_OP_TIMEOUT` per timer and one
`IORING_OP_TIMEOUT_REMOVE` per cancel, costs `2 × C8` plus kernel timer work, and every cancel
becomes a race of the kind rule 2 exists for. With the heap, cancelling a timer is synchronous
and has no race: the entry is removed and its final event, `Canceled`, is queued for the next
reap.

One code path serves both backends and the simulator, so timer order is the same everywhere.

### Rule 6: closing a descriptor cancels its operations first

Closing a descriptor does not cancel operations io_uring already holds for it. So `close` is an
operation that first cancels everything in flight for the descriptor
(`IORING_ASYNC_CANCEL_FD` with `IORING_ASYNC_CANCEL_ALL`), and closes it when the last final
event has been queued. The caller sees the cancelled operations' final events, then the close's.

### Rule 7: deinit requires an empty loop

`deinit` asserts that nothing is in flight, as stompy's does. `cancel_all` cancels every
operation, and `drain` ticks until the loop is empty or a named bound of rounds passes, and
returns an error when the bound passes first.

### What kqueue does to look the same

An operation waiting for readiness is cancelled by deleting its filter in the next changelist.
That always succeeds at once. The final event is still delivered at the next reap and never
from inside `cancel`, so the caller's code sees one shape: request now, answer later.

## What the simulator injects

For every cancel, the seed decides which of the three outcomes of rule 2 happens, and for a
transfer, how many bytes moved first. For every close, the seed orders the final events. The
simulator enforces rule 1 by counting: a run halts, with its seed and op, if a slot is freed
without a final event or a final event arrives twice.

## Alternatives it beat

**Cancel frees the slot at once and late completions are dropped by generation.** Simpler for
the caller, and wrong for the buffer: the caller would reuse memory the kernel is still writing.
Rule 3 needs rule 1.

**Cancel produces its own event.** Two events per cancelled operation, a second slot per
cancel, and nothing the caller can do with the extra answer.

**Kernel timers.** Costed under rule 5.

**A timer wheel.** Constant-time arming beats the heap at very large timer counts. The heap is
simpler and bounded, and the timer-churn workload will say whether `log4(n)` shows. If it does,
the wheel replaces the heap behind the same interface.

## How it is checked

Simulator tests for each rule, each proved by a mutation reported `CAUGHT` or `NOT CAUGHT`:

1. Free the slot on cancel: rule 1's counter must catch it.
2. Report `Canceled` when bytes moved: a partial-write test must catch it.
3. Deliver the final event from inside `cancel`: an ordering test must catch it.
4. Close without cancelling first: the close test must catch it.

On the real backends, a test cancels a receive on an idle socket and a read that has already
completed, and checks both outcomes.

## Open questions for review

1. Should `cancel` of a stale handle be legal, as proposed, or a programmer error that halts?
   Legal is proposed because the caller cannot avoid the race.
2. Is a transfer's partial byte count on timeout what stompy's callers want, or do they want
   the whole operation failed? The kernel reports the bytes either way.
