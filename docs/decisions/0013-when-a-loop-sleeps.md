# 13. When a loop sleeps

Status: **proposed** on 2026-09-20, from measurement. A proposed record is not a licence to build
what it describes (CLAUDE.md). What would accept it is at the end.

Decision 4 prices a cross-core message and never prices the sleep it interrupts. The measurements
below say the sleep is almost the whole cost, so the record that governs it should exist.

## What the loop does today

`tick(events, wait_ns)` hands what the caller allows, bounded by the nearest deadline, to
`io_uring_enter` or to `kevent`, and the loop blocks there until something arrives. A loop with
nothing to do sleeps at once. That is the whole policy, and nothing in any record chose it.

## What it costs

Read on `orbstack` on 2026-09-20, threads pinned with `sched_setaffinity`. Nothing here is
admissible (`docs/costs.md`, rule 1); the ratios are what the argument rests on.

| measurement | ns |
|---|---|
| C14, loopback round trip, both ends on one core | 1,458 |
| C15, the same, ends on two pinned cores | 13,334 to 14,813 |
| C19, cross-core message, receiver already awake | about 100 |
| C17, cross-core message by `MSG_RING`, receiver asleep | about 16,300 |

C15 and C17 agree at about 15,000 ns and share one thing: each wakes a thread that was asleep.
C19 crosses the same boundary with the receiver awake for about 100 ns. **Crossing a core is
nearly free. Waking a thread on another core is not.**

Measured on 2026-09-22 on `orbstack`, with both threads pinned (`docs/costs.md`): C14 1,416 ns, C15
9,333 ns (8,896 to 13,000 across three runs), C19 98 ns, C17 10,981 ns. The ratios hold.

`bench/uring/post.zig` measures the same thing through rotor's own loops, which is what decides
whether the loop can act on it:

| how the receiving loop waits | one message, ns |
|---|---|
| blocks until the message arrives | 11,021 |
| never blocks, ticks without waiting | 687 |
| ticks without waiting for 50 µs, then blocks | 729 |

A bounded spin recovers fifteen sixteenths of the sleep, for 6 percent more than a loop that
burns a core outright.

## The proposal

A loop may stay awake for a bounded time after its last completion before it blocks.

1. **A named budget, and a caller who sets it.** `Loop.Options` gains a spin budget in
   nanoseconds, default 0, which is today's behaviour exactly. A caller that wants the trade asks
   for it. No default changes without a measurement on a named machine.
2. **The budget is spent only when there is something to wait for.** A tick the caller asked not
   to block in never spins. A tick whose deadline is nearer than the budget blocks instead, so a
   spin never makes a timer late.
3. **The spin is a tick without a wait, and nothing else.** No new path, no new state machine:
   the loop already ticks without waiting. What changes is how long it does that before it asks
   the kernel to block it.
4. **The budget is a function of what the caller submitted and of the clock, never of a
   statistic.** Decision 9, rule 1 keeps statistics out of control flow, and an adaptive budget
   that reads one would break it. If a budget is ever made adaptive, what it reads must be state
   and not a statistic, and this record must be amended first.

## What is not measured, and what that means

- **The case the spin is wrong for.** In the benchmark the peer always answers inside the window,
  so the spin always pays. A loop whose work has stopped burns the whole budget and sleeps
  anyway: a core spending 50 µs per idle cycle. Nothing here measures a fleet of mostly-idle
  loops, which is the case that decides whether any default above 0 is defensible.
- **What the budget should be.** 50 µs was picked because it is far above one message and far
  below one sleep. No measurement chose it.
- **kqueue.** Every number here is io_uring. The kqueue backend's wake is an `EVFILT_USER`
  trigger, and C18 read about 25,000 ns on a loaded machine. The trade is likely the same shape
  and is unmeasured.
- **Whether a spinning loop hurts its neighbours.** A core that spins is a core not yielded. On a
  machine running one loop per core that is free; on a shared machine it is not.

## Alternatives it beat

**Leave it alone: always block.** What the loop does today. It pays about 10 µs on every handoff
to an idle loop, which decision 4's model makes the common case for work that crosses cores. It
is the right default and the wrong only option.

**Always spin.** 687 ns against 729, so the bounded spin costs 6 percent of the benefit and keeps
the ability to sleep. A loop that never sleeps cannot share a machine, and rotor's caller may not
own the machine.

**`IORING_SETUP_SQPOLL`.** A kernel thread polls the submission queue, so submission needs no
syscall at all. It is a kernel thread per ring, which decision 4 rules out ("holds no lock and
starts no thread"), and libuv's own opt-in path uses it, which decision 3 records. It solves the
submission half and not the wake half.

**Wake the target from the sender, more cheaply.** What `MSG_RING` already does; C17 is that
number. There is nothing cheaper to reach for.

**An adaptive budget from the start.** It needs a signal, and the obvious signals are statistics,
which rule 4 above forbids on the control path. A fixed budget that a caller sets is measurable
and cannot break replay; an adaptive one is a second record once there is a measurement to fit.

## How it is checked, if it is built

Every check is on the real kernel: rotor has no simulator (decision 10).

1. A conformance scenario for the surface: a loop with a budget returns the same events in the
   same order as one without, for every scenario the suite already runs. Statistics and timing
   change; behaviour does not.
2. A scenario that a spin never makes a timer late: a tick whose nearest deadline is inside the
   budget blocks rather than spins, checked by the deadline the event carries.
3. `bench/uring/post.zig`'s three modes, which exist, plus a fourth measurement the record
   needs: a loop that is idle, to price the budget it wastes.
4. Mutations, reported `CAUGHT` or `NOT CAUGHT`: the budget ignored, the budget applied to a tick
   the caller asked not to block in, the budget applied past a nearer deadline, the clock read
   once instead of per round.

## What would accept this record

- The numbers above, or their shape, from a machine `docs/costs.md` names. Every figure here is
  from a container on a development Mac.
- A measurement of the idle case, which decides whether the default may ever be above 0.
- The owner's ruling on the one question no measurement answers: whether a rotor loop is
  entitled to burn a core it was not given.
