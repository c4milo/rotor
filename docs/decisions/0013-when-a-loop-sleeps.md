# 13. When a loop sleeps

Status: **proposed** on 2026-09-20, from measurement. A proposed record is not a licence to build
what it describes (CLAUDE.md). What would accept it is at the end. On 2026-09-24 the owner chose to
leave it proposed until the idle case is measured on a named machine. The same day its figures were
brought up to date with what `docs/costs.md` and `bench/results/` now hold, and the idle case was
measured on `github` for io_uring; the last section reads it. The record stays proposed until the
owner rules.

Decision 4 prices a cross-core message and never prices the sleep it interrupts. The measurements
below say the sleep is almost the whole cost, so the record that governs it should exist.

## What the loop does today

`tick(events, wait_ns)` hands what the caller allows, bounded by the nearest deadline, to
`io_uring_enter` or to `kevent`, and the loop blocks there until something arrives. A loop with
nothing to do sleeps at once. That is the whole policy, and nothing in any record chose it.

## What it costs

Read on `orbstack` on 2026-09-20, threads pinned with `sched_setaffinity`. When this was written
the numbers were not admissible (`docs/costs.md`, rule 1), and the argument rested on the ratios.
The owner named `orbstack` a measurement machine later that day, and the readings of 2026-09-22
below fill its column.

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
9,333 ns (8,896 to 13,000 across three runs), C19 98 ns, C17 10,981 ns. The ratios hold. On `github`,
the x86-64 runner, C19 is 36.0 ns and C17 is 8,724 ns: the same shape on a second architecture.

`bench/uring/post.zig` measures the same thing through rotor's own loops, which is what decides
whether the loop can act on it:

| how the receiving loop waits | one message, ns, first run | five runs on 2026-09-22, ns |
|---|---|---|
| blocks until the message arrives | 11,021 | 11,041 to 11,479 |
| never blocks, ticks without waiting | 687 | 666 to 1,354 |
| ticks without waiting for 50 µs, then blocks | 729 | 687 to 1,375 |

The five runs are `docs/costs.md`'s, taken on `orbstack` beside decision 8's experiment. A bounded
spin recovers almost all of the sleep when the peer answers inside the window. The first run put the
spin 6 percent above a loop that never blocks. That difference is inside the spread of the five runs,
so it is not measured.

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

- **The case the spin is wrong for.** Measured on 2026-09-24 for io_uring, in the last section.
  What follows is how it stood before. In the benchmark the peer always answers inside the window,
  so the spin always pays. A loop whose work has stopped burns the whole budget and sleeps
  anyway: a core spending 50 µs per idle cycle. Nothing here measures a fleet of mostly-idle
  loops, which is the case that decides whether any default above 0 is defensible.
- **What the budget should be.** 50 µs was picked because it is far above one message and far
  below one sleep. No measurement chose it.
- **kqueue.** The kqueue backend's wake is an `EVFILT_USER` trigger. C18, that wake, is now
  measured on `mac`: 18,125 ns median, 46,750 ns p99. C19 on `mac` is 97.0 ns. So the shape is the
  same as io_uring's. `bench/crosscore/rotor_post.zig` ran rotor's three modes on `mac` on
  2026-09-22, one run each (`bench/results/crosscore-mac-2026-09-22-after.md`): p50 2,007 ns when
  the receiver waits, 501 ns when it spins, and 501 ns when it spins and then waits. Those are the
  harness's histogram buckets, and the waiting row of that file is marked as disagreeing across
  runs and taken under other work. The comparison with libuv and libxev runs rotor in its waiting
  mode only, because neither offers a mode that polls (`bench/alternatives/README.md`), so the
  spinning rows are rotor against itself. The idle case is not measured on kqueue either.
- **Whether a spinning loop hurts its neighbours.** A core that spins is a core not yielded. On a
  machine running one loop per core that is free; on a shared machine it is not.

## Alternatives it beat

**Leave it alone: always block.** What the loop does today. It pays about 10 µs on every handoff
to an idle loop, which decision 4's model makes the common case for work that crosses cores. It
is the right default and the wrong only option.

**Always spin.** The five runs above put the two within each other's spread (666 to 1,354 ns
against 687 to 1,375 ns), and the bounded spin keeps the ability to sleep. A loop that never sleeps
cannot share a machine, and rotor's caller may not own the machine.

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

- The numbers above, or their shape, from a machine `docs/costs.md` names. Done: `orbstack` and
  `github` for io_uring, `mac` for kqueue. `orbstack` is a virtual machine on the `mac` machine's
  cores, and `github` is a shared runner, so neither is quiet.
- A measurement of the idle case, which decides whether the default may ever be above 0. Done for
  io_uring on `github` on 2026-09-24, in the last section. Not done for kqueue or epoll.
- The owner's ruling on the one question no measurement answers: whether a rotor loop is
  entitled to burn a core it was not given.

## Results, 2026-09-24, `github`: the idle case

`bench/crosscore/rotor_post.zig` gained `--gap-us N`: the measuring loop waits N microseconds before
each ping, so the answering loop has had nothing to do for that long when the ping arrives. The
program reads the CPU time the answering loop's thread used over the measured round trips, with
`CLOCK_THREAD_CPUTIME_ID`, and prints it per round trip. The CI job `costs` ran it on io_uring at
gaps of 0, 20, 100 and 1,000 µs, in the three modes, 2,000 round trips each, three rounds. The job
was started by hand three times, and each start got a different processor
(`bench/results/decision-13-idle-github-2026-09-24.md`). The spin budget is the 50 µs this record
proposes.

CPU time the answering loop used per round trip, in µs, the median and the range of three rounds:

| processor | mode | gap 0 | gap 20 µs | gap 100 µs | gap 1,000 µs |
|---|---|---|---|---|---|
| Xeon Platinum 8573C | waiting | 6.4 (6.3 to 7.2) | 6.7 (6.6 to 6.8) | 7.9 (7.7 to 8.0) | 10.3 (10.0 to 10.3) |
| Xeon Platinum 8573C | spin then wait | 2.8 (2.8 to 3.0) | 23.0 (22.9 to 23.0) | 54.8 (54.7 to 54.9) | 55.4 (55.4 to 55.4) |
| Xeon Platinum 8573C | spinning | 2.7 (2.7 to 2.8) | 22.8 (22.8 to 22.9) | 102.9 (102.9 to 102.9) | 1003.3 (1003.3 to 1003.3) |
| EPYC 7763 | waiting | 12.9 (10.9 to 13.1) | 15.5 (14.2 to 16.9) | 17.2 (14.1 to 17.3) | 21.0 (20.8 to 21.0) |
| EPYC 7763 | spin then wait | 4.6 (4.6 to 4.6) | 24.7 (24.7 to 24.7) | 59.9 (59.7 to 59.9) | 60.7 (60.7 to 60.9) |
| EPYC 7763 | spinning | 4.4 (4.4 to 4.4) | 24.4 (24.4 to 24.4) | 104.7 (104.7 to 104.8) | 1004.9 (1004.9 to 1004.9) |
| EPYC 9V74 | waiting | 13.2 (12.9 to 13.4) | 14.1 (13.7 to 14.3) | 14.0 (13.7 to 14.3) | 14.6 (14.3 to 14.6) |
| EPYC 9V74 | spin then wait | 5.3 (5.2 to 5.4) | 25.3 (25.3 to 25.4) | 58.3 (58.1 to 58.3) | 58.9 (58.8 to 58.9) |
| EPYC 9V74 | spinning | 5.2 (5.1 to 5.2) | 25.4 (25.1 to 25.5) | 105.6 (105.5 to 105.6) | 1006.4 (1006.2 to 1006.4) |

The round trip, in µs, the median and the range of three rounds:

| processor | mode | gap 0 | gap 20 µs | gap 100 µs | gap 1,000 µs |
|---|---|---|---|---|---|
| Xeon Platinum 8573C | waiting | 15.9 (15.3 to 23.0) | 16.2 (16.1 to 16.4) | 18.3 (18.0 to 19.1) | 14.8 (14.5 to 15.0) |
| Xeon Platinum 8573C | spin then wait | 2.6 (2.6 to 2.8) | 2.7 (2.6 to 2.8) | 11.7 (11.7 to 11.7) | 12.4 (12.3 to 12.5) |
| Xeon Platinum 8573C | spinning | 2.5 (2.5 to 2.5) | 2.6 (2.5 to 2.6) | 2.6 (2.6 to 2.6) | 3.0 (2.9 to 3.0) |
| EPYC 7763 | waiting | 24.3 (22.5 to 24.6) | 32.3 (32.3 to 32.3) | 32.8 (32.6 to 32.8) | 28.7 (28.7 to 28.8) |
| EPYC 7763 | spin then wait | 4.3 (4.3 to 4.3) | 4.3 (4.3 to 4.3) | 17.4 (17.3 to 17.4) | 18.6 (18.6 to 18.8) |
| EPYC 7763 | spinning | 4.1 (4.1 to 4.1) | 4.1 (4.1 to 4.1) | 4.2 (4.1 to 4.2) | 4.5 (4.5 to 4.6) |
| EPYC 9V74 | waiting | 26.5 (23.8 to 26.5) | 25.9 (25.6 to 26.0) | 26.6 (26.5 to 26.6) | 18.3 (18.2 to 19.5) |
| EPYC 9V74 | spin then wait | 4.9 (4.8 to 5.1) | 4.9 (4.8 to 4.9) | 15.2 (15.2 to 15.3) | 17.0 (17.0 to 17.0) |
| EPYC 9V74 | spinning | 4.9 (4.7 to 4.9) | 5.0 (4.8 to 5.0) | 5.1 (5.1 to 5.2) | 6.0 (6.0 to 6.0) |

What the runs say:

- **Inside the budget, the spin pays.** At a 20 µs gap the loop that spins first answers a round
  trip in 2.7 to 4.9 µs, against 16 to 32 µs for the loop that waits. It spends 23 to 25 µs of CPU
  per round trip on it, which is the gap, against 7 to 16 µs.
- **After the budget, the spin is spent for nothing.** At gaps of 100 µs and 1 ms the loop spins its
  50 µs, then sleeps and is woken as the waiting loop is. It uses 55 to 61 µs of CPU per round trip,
  against 8 to 21 µs for the waiting loop: 40 to 47 µs more per message.
- **In this benchmark the idle case costs CPU and not time.** After the budget, the round trip is
  still shorter with the spin, 12 to 19 µs against 15 to 33 µs, because the measuring loop's own
  spin catches the reply and only one of the two directions pays a wake.
- **With no gap the spin costs less CPU than the sleep.** 2.8 to 5.3 µs per round trip against 6.4
  to 13.2 µs: a sleep and a wake cost more CPU than the message.
- **As a share of a core.** The CPU per round trip over the time between two pings, the gap plus
  the round trip: at one message per millisecond, 1.0 to 2.0 percent of a core waiting and 5.5 to
  6.0 percent with the spin. At a 100 µs gap, 7 to 13 percent waiting and 49 to 51 percent with the
  spin.

Not measured:

- **The worst case.** A peer whose message comes just after the budget spins all of it every time
  and is woken anyway. That gap, near 50 µs, was not run.
- kqueue and epoll. Every number here is io_uring. The `mac` machine was too busy to measure.
- Many loops on one machine at once, and any budget other than 50 µs.

The measurement this record asked for now exists for io_uring. It prices the budget and does not
decide it: whether a rotor loop may spend up to 50 µs of a core per message it was not given is the
owner's question at the end of "What would accept this record".
