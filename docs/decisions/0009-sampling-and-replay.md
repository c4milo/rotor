# 9. Sampling and counters that do not break replay

Status: accepted for implementation on 2026-09-19. This record resolves the third collision
between the Abseil Performance Hints and the project rules.

Amended on 2026-09-19 by decision 10: rotor has no simulator, so the rules about the simulator's
streams (the second bullet of rule 2, rule 3, the first bullet of rule 4) and the three-trace
replay gate have nothing to apply to. Rules 1, 2, 5 and 6 stand: statistics never steer control
flow, the sampling decision is a function of the operation sequence, and a consumer's simulator
that replays the same calls therefore sees the same samples.

## The collision

The Performance Hints say statistics are sampled and never unconditional. A sampling decision
is a choice, and a choice made from the host clock, from a counter that timing drives, or from
the fault generator's stream makes two runs of one seed differ. The project rule is that one
seed replays byte-identically.

## Decision

### Rule 1: statistics are write-only to the loop

No control flow in `core`, `sim` or a backend reads a statistic. The loop increments and
records; only the caller reads. So a statistic, sampled or not, cannot change which operation
runs next. Counters the loop needs for correctness, such as `in_flight`, are state and not
statistics, and they are exact.

### Rule 2: the sampling decision is a function of the operation sequence

Every loop numbers the operations it accepts: `operation_sequence`, a 64-bit count that
`submit` advances. An operation is sampled when
`operation_sequence & sample_mask == sample_phase`. The mask is a power of two minus one, as
the Hints advise, so the decision is one AND and one compare on a value `submit` already holds.

- `operation_sequence` is not a free-running counter. It advances only when the caller submits,
  so the same calls give the same samples.
- In the simulator, `operation_sequence` is the op clock. `sample_phase` comes from a generator
  seeded with a value derived from the run's seed and kept apart from the generator that draws
  faults and completion order.
- On a real backend, `sample_phase` is a configuration value, zero by default. No entropy source
  is read.

### Rule 3: sampling never touches the fault stream

The generator behind `sample_phase` is its own stream. Turning statistics on or off, or changing
`sample_mask`, draws nothing from the stream that orders completions and picks faults. So the
trace of a seed is the same with statistics off, on at 1 in 32, or on at 1 in 1.

### Rule 4: a sampled duration uses the clock the backend has

- In the simulator, a sampled operation's start and end are op clock values. The statistics of
  a seed are therefore as reproducible as its trace.
- On a real backend, the loop reads the monotonic clock once per tick, which it needs for the
  timer heap anyway (`0005-cancellation.md`). A sampled operation is stamped with the tick's
  time at submit and at reap, which costs no extra clock read and gives tick resolution. A
  caller that wants finer resolution for sampled operations turns on a per-sample clock read,
  C20, about 20 ns, paid by 1 operation in `sample_mask + 1`. At 1 in 32 that is under 1 ns per
  operation on average.

### Rule 5: hardware counters stay in `bench/`

`perf_event_open` and everything like it lives in the harness. No file under `src/` opens a
performance counter. The harness reads counters around a workload, from outside the loop.

### Rule 6: nothing logs on a hot path

No file in the six hot files of `0007-hot-path-ugliness.md` names `std.log` or `std.debug.print`.
A backend reports a condition by returning an error or by counting it. The lint enforces this
from milestone 2 with the same confinement rule.

## What a statistic costs

Unsampled, a latency record per operation is two clock reads, `2 × C20`, about 40 ns, which is
as much as the per-entry submission cost C8 itself. That is why it is sampled. Sampled at 1 in
32, the per-operation cost is the AND and compare, under 1 ns, plus the amortised record.

Event counts by operation kind are increments of a small array the loop owns. They are sampled
too, under the same decision, and scaled by `sample_mask + 1` when read. An exact count of
every operation would write a second cache line per operation for a number nobody reads at that
precision.

## Alternatives it beat

**Sample by the clock, every N microseconds.** Breaks replay outright, and costs a clock read
per operation to decide.

**Sample by a random draw from the run's generator.** Deterministic, but turning statistics on
shifts every later fault draw, so a failing seed stops failing when someone enables statistics
to study it. That defeats the purpose of both.

**No statistics in the simulator.** Then the statistics code is the one part of the loop the
simulator never runs.

**Exact counters, unsampled.** The Hints' point, and the arithmetic above.

## What was built, on 2026-09-19

`core/statistics.zig`, embedded in `core.Tables`, so both backends count the same way. The
loop counts sampled operations by kind, and the latency of each in one of
`constants.latency_buckets` buckets, one per power of two of nanoseconds. The start and the end
are the tick's clock, which the loop read for the timer heap, so a measurement costs no clock
read (rule 4).

Two things the record did not settle, settled by building it:

- **A multishot operation records no latency.** Its final event comes when it is cancelled or
  fails, so the span from submit to that event is a lifetime and not a latency. It is counted
  among the sampled and left out of the buckets.
- **There is no way to turn statistics off**, because the record gives none and the cost it
  argues from is the sampled cost. `sample_mask` of 0 samples every operation; a mask and a
  phase that cannot meet sample none.

`starts`, one 64-bit stamp per slot, is the only memory this added: the caller hands it over with
the rest of the loop's memory.

## How it is checked

One simulator gate, the replay gate, runs each seed three times: statistics off, 1 in 32, and
1 in 1. It requires the three traces to be byte-identical, and the two statistics outputs of
any one setting, run twice, to be byte-identical.

Decision 10 removed the simulator and with it the three-trace replay gate. What replaces it for
rule 2 is a test of the decision itself: `submitted` is called with one sequence and a range of
clocks whose low bits differ, and the decision it makes must not change. A conformance scenario
then checks rule 1 on both real backends, by running one workload at two sampling settings and
requiring the same events.

Mutations, 24 of 24 CAUGHT. Four were NOT CAUGHT when first run, and each named a missing test:
the start stamp never written (every test clock began at 0), a multishot operation recording a
latency, the decision made from the clock (every test clock was a multiple of four), and the
latency measured from another slot's start (only one operation was ever in flight).
