# 14. Repeating timers

Status: accepted on 2026-09-20, by the owner, after the timer churn benchmark showed what the
absence costs. Decision 2's scope table says "timers: arm, cancel", and nothing in any record
chose to leave a repeat out; it was never considered.

Amended on 2026-09-23, by the owner: a cancel of a repeating timer whose fire is queued in the loop
and not yet handed over replaces that fire, and rule 5 says so. The Lean model found that such a
cancel was dropped and the timer kept firing (`proofs/README.md`, "What the proofs found").

## What the benchmark showed

`bench/timers/rotor_timers.zig` keeps N timers armed and re-arms each as it fires, because that
is the only way a caller can have a periodic timer today. The re-arm is the caller's:

```zig
fn arm(churn: *Churn, index: u32) void {
    due_ns[index] = now_ns() + churn.period_ns;
    _ = churn.loop.submit(&.{.{ .kind = .{ .timer = .{ .after_ns = churn.period_ns } } }}, &.{});
}
```

Two things are wrong with it, and the second is the one that matters.

1. **Every fire costs a `submit`**: a slot claimed, a slot filled, a push to the pending list, and
   a flush that walks it. `submit` enters no kernel, so this is cheap, and it is not nothing.
2. **The period is measured from when the caller re-armed, not from when the timer was due.** A
   caller that is late re-arming makes the next period late by the same amount, and the error
   accumulates. A timer asked to fire every millisecond for an hour will have fired fewer than
   3,600,000 times, and no caller can correct for it without reading the clock and doing the
   arithmetic the loop already did.

The measured lateness of rotor's timers therefore includes rotor's re-arm, and libuv's does not:
`uv_timer_start` takes a repeat and re-arms inside the loop. The comparison in
`bench/alternatives/README.md` charges rotor for something the API forces on it.

## Decision

`Operation.Timer` gains a period:

```zig
pub const Timer = struct { after_ns: u64, repeat_ns: u64 = 0 };
```

1. **`repeat_ns` of 0 is a one-shot timer**, which is every timer that exists today, unchanged.
2. **A repeating timer is a multishot operation**, and takes the convention that already exists
   for a multishot accept and a multishot receive: every fire is an event flagged `more`, and the
   one final event, flagged `more` off, comes when it is cancelled or fails. Decision 5's rule 1
   holds unchanged: exactly one final event, and the slot is the loop's until then.
3. **The next fire is scheduled from the deadline, never from the clock.** After a fire due at
   `D`, the next is due at `D + repeat_ns`. A loop that was late does not make the period late,
   and a run of an hour fires the number of times the arithmetic says.
4. **A deadline already past fires at the next tick, and is not skipped.** A loop held off its
   tick for ten periods hands the caller ten events, late, rather than one. A caller that wants
   coalescing can count; a caller that needs every tick of a clock cannot invent the ones the
   loop swallowed. This is the opposite of libuv, which skips, and it is stated here because it
   is the kind of difference that is otherwise found in production.
5. **Cancel is what it already is**: synchronous, raceless, and answered with one final event
   (decision 5, rule 5). A repeating timer that is cancelled stops; its final event says
   `canceled`. A tick can queue a fire and leave it for the next tick, when the caller's events
   have no room for it. A cancel between those ticks replaces the queued fire: that event becomes
   the final one and says `canceled`, and the fire is not handed over. A cancel of a timer whose
   deadline passed before the loop expired it drops that fire the same way, so the caller gets one
   answer whichever happened first.

## What it costs in memory: nothing

A `Slot` is 64 bytes and stays 64 bytes, because a timer already leaves two of its fields unused
and `assert_valid` proves it:

- `Slot.timeout_ns` holds `repeat_ns`. A timer may not carry a deadline — `assert_valid` halts on
  a timer whose `timeout_ns` is not 0 — so the field is free precisely when a timer needs it.
- `Slot.buffer` holds the deadline the timer last fired for, which rule 3 needs to schedule the
  next one. `fill` sets a timer's `buffer` to 0 and nothing reads it.
- `Slot.flags.multishot` marks it repeating, which is the flag a multishot accept and receive
  already use and which the reap paths already read.

So the change adds no field, no allocation and no comptime assert. That is the argument for this
shape over the alternatives below.

## Alternatives it beat

**Leave it to the caller, as today.** Every caller that wants a periodic timer writes the same
re-arm, and every one of them gets the drift of rule 3 wrong, because getting it right means
keeping the deadline and doing the arithmetic the loop already has in its heap. An API that makes
the wrong thing the easy thing is the API's fault.

**A separate `Operation.Repeat` kind.** A new arm of the closed union, a new arm in every
backend's exhaustive switch, and a second thing to cancel. A repeat is a timer with a period, and
the union is closed so that a kind means something.

**A repeat count, so a timer can fire N times and stop.** More surface, and a caller that wants it
counts the events it already receives and cancels. Nothing measured asks for it.

**Skip missed deadlines, as libuv does.** It makes a loop that was held off look punctual, which
is the opposite of what this project measures. Rule 4 chooses the honest answer and says so.

## How it is checked

Every check is on the real kernel, on both backends: rotor has no simulator (decision 10).

1. A conformance scenario: a repeating timer fires several times, each event flagged `more`, and
   a cancel ends it with one final event flagged off.
2. A scenario for rule 3, which is the whole point: a repeating timer whose loop is deliberately
   held off its tick still has its later deadlines at the original period, not at the period
   measured from when it was serviced. A timer that drifts fails it.
3. A scenario for rule 4: a loop held off for several periods hands over an event per missed
   deadline, and not one.
4. A halt scenario: a repeat longer than `constants.timeout_ns_max`, and a repeating timer that
   also carries a `timeout_ns`.
5. Mutations, reported `CAUGHT` or `NOT CAUGHT`: the next deadline taken from the clock instead
   of the last deadline, the `more` flag left off, the `more` flag left on for the final event,
   the slot released on a fire, a missed deadline skipped, `repeat_ns` of 0 treated as repeating.
6. Two scenarios for rule 5's queued fire: two repeating timers come due together, and a tick has
   room for one event. A cancel of the timer whose fire was left queued is answered by its next
   event, final and `canceled`. A second scenario reaches the same state, and `cancel_all` then
   `drain` empties the loop.

## What it does not change

`bench/timers/rotor_timers.zig` keeps its manual re-arm as a second mode, because that is what a
caller does when it wants a period measured from service and not from deadline, and because the
comparison against the shape libuv has needs both.
