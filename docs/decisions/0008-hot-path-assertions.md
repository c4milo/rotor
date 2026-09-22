# 8. Which assertions live on the hot path

Status: accepted for implementation on 2026-09-19. **The measurement this record depends on has
not been made.** No submit path and no reap path existed to measure when this record was written.
So this record states a provisional rule, the experiment that confirms or changes it, and the
thresholds, all fixed before the numbers exist. Milestones 2 and 3 run the experiment and report
the numbers, and the rule is then ratified or amended here.

Amended on 2026-09-19 by decision 10: class D assertions run in Debug test builds, since there is
no simulator for them to run in.

Amended on 2026-09-19 after the slot table landed: "How it is checked" asks for a test that
violates each class A and B assertion and expects the halt. A Zig test cannot expect a panic in
its own process, so the slot table's commit reports four deleted assertions as NOT CAUGHT. The
check is now `zig build halt-check`, part of `zig build test`: `tools/halt_check.zig` runs each
scenario of `tools/halt/` in a child process and requires it to reach its violating statement and
then die by a signal. A canary whose scenarios do not halt must fail the check. An assertion a
caller's mistake can reach gets a scenario; a mutation that deletes one is measured against `zig
build halt-check`.

## The collision

TigerStyle keeps assertions on in production, roughly two per function. The Performance Hints
say to keep the hot path clear. rotor builds in Debug and ReleaseSafe only, so every `assert`
and every bounds and overflow check is live in production.

## What an assertion costs

An assertion that holds is a compare and a branch the predictor gets right. When its operands
are already in registers or in L1, that is under 1 ns, less than one C1. It never pays C4, the
mispredict, in a correct program. The cost that matters is elsewhere: an assertion that reads
memory the function would not otherwise read pays C2 or C3, 3 to 50 ns, and that is the size of
the whole per-entry budget (C8, 20 to 60 ns).

So the dividing line is memory, not count.

## Provisional rule

An assertion may stay on the hot path when it reads nothing the function has not already
loaded. Every other assertion moves to the narrowest place that still checks the same thing.

| class | where it runs | examples |
|---|---|---|
| A. Per operation, ReleaseSafe | submit and reap | the slot's generation matches the handle; the slot's state is `submitted` when its completion arrives; the index is below the table's capacity; `in_flight` is at least 1 before it is decremented; an unregistered O_DIRECT buffer is block-aligned |
| B. Per batch, ReleaseSafe | once in `submit`, once in `tick` | the calling thread owns the loop (`0004-threading.md`); ring head and tail are consistent; free count plus in-flight count equals capacity; the batch is not longer than the named limit |
| C. At registration or init, ReleaseSafe | slow path | a registered buffer's alignment and length, checked once and not per operation; descriptor validity; every named limit's relation to the others; kernel feature probes |
| D. Debug only | anywhere | walking a queue to check membership; verifying the whole heap property after each timer change; poisoning a freed slot and checking the poison on claim; checking that the free list has no cycle |

Class C is the Hints' "precompute expensive information" and "check at module boundaries"
applied to assertions: stompy's `assert_transfer` makes five checks per operation, and with a
registered buffer four of them are facts about the registration.

Class D holds assertions whose cost grows with the structure's size. They still run in every
simulator test, because the simulator's gates run in Debug as well as ReleaseSafe.

Bounds and overflow checks the compiler inserts follow the same rule. They stay, unless a
ledger row of `0007-hot-path-ugliness.md` removes one with `@setRuntimeSafety(false)`, and that
row must show the check was one the code had already made.

## The experiment

1. The workload is the NOP microbenchmark behind C7 to C9: batches of 32 no-op submissions and
   their reaps, on one pinned core. It is the worst case for assertions, because the operation
   itself does no work. The echo workload at 4 KiB runs beside it as the realistic case.
2. A comptime flag, which exists only in the benchmark build and is never offered by
   `build.zig` to consumers, compiles class A out. Class B is measured the same way.
3. Report nanoseconds per operation with and without, the difference, the run-to-run noise, and
   `perf stat` counts of branches, branch misses and L1 misses for both.

## Thresholds, fixed now

- Class A in total may cost up to 2 percent of NOP throughput. Above that, the costliest
  assertion moves to class B or D until the total is under, and this record lists what moved.
- If class A in total costs less than the noise on the echo workload, the record says so and
  the question is closed for that backend.
- Class B may cost up to 1 percent at a batch of 32.
- No assertion is deleted to meet a threshold. It moves to a slower class, and class D still
  runs it under the simulator.

## Alternatives it beat

**All assertions everywhere, unmeasured.** That is TigerStyle's default, and it is likely
affordable. But "likely" is a prior, and the brief asks for the measurement.

**ReleaseFast for the hot files.** It removes every check at once, measured or not, and a
wrong index in the reap path then corrupts memory silently in production.

**Assertions in Debug only on the hot path.** The slot generation check is what turns a stale
completion into a halt. Without it, the failure is a callback on a recycled slot. It is
class A because it must run in production, and it reads a line the reap has already loaded.

## How it is checked

- Milestones 2 and 3 report the experiment's numbers for the uring and kqueue backends, and this
  record gains a results section.
- Each class A and B assertion has a test that violates it and expects the halt. The mutation
  that deletes the assertion must be reported `CAUGHT`.

## Results, 2026-09-22, `orbstack`

`bench/uring/nop.zig` in ReleaseSafe against ReleaseFast, five rounds each, alternating, on one
virtual CPU (`bench/results/decision-8-orbstack-2026-09-22.md`). Nanoseconds per operation, the
five rounds in order:

| batch | ReleaseSafe | ReleaseFast |
|---|---|---|
| 1 | 250, 250, 250, 250, 334 | 333, 292, 292, 333, 333 |
| 8 | 83, 83, 78, 78, 104 | 93, 93, 93, 93, 93 |
| 32 | 63, 62, 62, 62, 78 | 70, 69, 70, 69, 70 |
| 64 | 58, 59, 59, 59, 72 | 66, 66, 66, 67, 67 |
| 128 | 57, 57, 57, 57, 70 | 64, 64, 64, 64, 64 |

Two things this says, and one it cannot:

- ReleaseSafe was not slower than ReleaseFast in four rounds of five at every batch size, and one
  ReleaseSafe round was 25 percent slower than the other four. The difference between the modes is
  inside the difference between rounds of one mode, so this machine cannot resolve a 2 percent
  question. The likely cause is the one `docs/costs.md` names for `orbstack`: a virtual CPU may be
  backed by an efficiency core, and neither program can see or choose that.
- The upper bound the experiment asked for is therefore not established here. What can be said is
  that every check ReleaseSafe adds costs less than the noise of this machine, which at batch 32
  is 25 percent.
- The comptime flag of step 2, which compiles class A out alone, is not built: the benchmark build
  offers ReleaseSafe and ReleaseFast and nothing between. The thresholds stay as fixed, and the
  experiment waits for the `linux` machine and for that flag. Until then the provisional rule
  stands, unmeasured.

`docs/costs.md` measured a miss to memory (C3) at 128 to 185 ns against a per-entry budget (C8) of
52 ns, so the dividing line above, memory and not count, holds with more room than the priors gave
it.
