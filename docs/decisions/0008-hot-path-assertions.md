# 8. Which assertions live on the hot path

Status: accepted for implementation on 2026-09-19. **The measurement this record depends on has
not been made.** No submit path and no reap path existed to measure when this record was written.
So this record states a provisional rule, the experiment that confirms or changes it, and the
thresholds, all fixed before the numbers exist. Milestones 2 and 3 run the experiment and report
the numbers, and the rule is then ratified or amended here.

Measured in part on 2026-09-24, on `github`, for io_uring: class A's own cost is 2.1 percent of a
`nop` round at batch 32 in the median of five runs on one processor, against a threshold of 2, and
less than the noise on the echo workload on three processors. The last section reads it. The owner
ruled the same day that the echo clause decides, so the question is closed for io_uring and no
assertion moves. On epoll, measured the same day, class A cost less than the echo workload's noise
on three processors, which closes the question there by the echo clause. Class B alone, step 3's
counts and kqueue are still not measured.

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

Amended on 2026-09-23 by the owner's ruling: an assertion that only rotor's own code or the
kernel's answer can break also gets a scenario, when a scenario can reach it through the
function's own parameters. `core.file_call.result` takes its system call as a parameter, so a
scenario hands it a made-up answer, and both of its assertions have one. An assertion that no
parameter reaches, such as a tick's check of what the kernel returned, gains no parameter for
this: that parameter would sit on the path every tick runs, only to prove an assertion.

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
  stands, unmeasured. The flag was built on 2026-09-24, and the last section reads what it
  measured.

`docs/costs.md` measured a miss to memory (C3) at 128 to 185 ns against a per-entry budget (C8) of
52 ns, so the dividing line above, memory and not count, holds with more room than the priors gave
it.

## Results, 2026-09-22, `github`: the experiment is decidable, and this is what it costs

The same benchmark on the x86-64 machine `docs/costs.md` added the same day: a GitHub-hosted
runner, an Intel Xeon Platinum 8370C, five rounds alternating
(`bench/results/decision-8-github-2026-09-22.md`). Nanoseconds per operation, the five rounds in
order:

| batch | ReleaseSafe | ReleaseFast | ReleaseSafe costs |
|---|---|---|---|
| 8 | 101, 101, 101, 101, 101 | 94, 94, 94, 94, 94 | 7.4 percent |
| 32 | 80, 80, 80, 80, 80 | 74, 73, 73, 73, 73 | 9.0 percent |
| 64 | 77, 77, 77, 77, 77 | 70, 70, 70, 70, 70 | 10.0 percent |
| 128 | 76, 76, 77, 76, 76 | 69, 69, 69, 69, 69 | 10.4 percent |

**The machine problem is solved.** `orbstack` could not resolve a 2 percent question because its
rounds disagreed by 25 percent and ReleaseSafe came out faster in four of five. Here every round of
each mode repeats to within 1 ns, so a difference of 6 ns is a measurement.

**What the 9 to 10 percent is, and what it is not.** ReleaseFast removes every assertion of every
class and every bounds and overflow check, so this is the upper bound this record already said it
would be: class A and class B together, plus the safety checks, on the workload built to be the
worst case for them. It is **not** class A's own cost, and this record's threshold — 2 percent for
class A in total — is still untested.

**What is missing is step 2 of the experiment**, the comptime flag that compiles class A out alone.
It is still not built, so the thresholds stand as fixed and the provisional rule stands unmeasured.
What changed on 2026-09-22 is that building the flag is now worth the work: before, on the only
Linux available, the answer would have been lost in the noise.

## Results, 2026-09-24, `github`: what class A costs alone

Step 2 is built. `src/core/assertion_class.zig` holds the switch, `build/modules.zig` generates it
as `core`'s `assertion_options` import (an edge the owner approved on 2026-09-24), and two builds
turn it off: `uring_nop_no_class_a`, and the `rotor_echo` that `zig build bench-echo-no-class-a`
installs in `zig-out/no-class-a/`. Each is ReleaseSafe with class A compiled out and every other
assertion and safety check kept. build.zig offers no option for it.

The switch covers 49 sites on io_uring: the 35 class A sites a `nop` passes through, in `core`'s
`operation.zig`, `slot_table.zig`, `slot.zig`, `statistics.zig`, `tables.zig`, `slot_list.zig`
and `handle.zig` and in `uring`'s `uring_ring.zig`, `uring_submit.zig` and `uring_reap.zig`, and
14 more that a message of the echo workload passes through: its receive from a provided-buffer
group, its send, `Event.outcome` and the buffer given back. The per-operation assertions of
connection setup and teardown, of errors, and of the other kinds still call `std.debug.assert`.

The CI job `costs` was started by hand eight times, and each start got its own runner
(`bench/results/decision-8-class-a-github-2026-09-24.md`). Each ran `uring_nop_safe`,
`uring_nop_fast` and `uring_nop_no_class_a` in turn, five rounds each. Runs 6 to 8 also ran the
echo half.

### The `nop` workload

At batch 32, the median and the range of a round's time over the five rounds, in ns:

| run | processor | ReleaseSafe | class A off | ReleaseFast | class A costs | every check costs |
|---|---|---|---|---|---|---|
| 1 | EPYC 7763 | 3,856 (3,847 to 3,877) | 3,797 (3,787 to 3,827) | 3,657 | 1.5 percent | 5.2 percent |
| 2 | EPYC 7763 | 3,917 (3,888 to 3,957) | 3,817 (3,797 to 3,888) | 3,666 | 2.6 percent | 6.4 percent |
| 3 | EPYC 7763 | 3,877 (3,848 to 4,017) | 3,797 (3,787 to 3,798) | 3,647 | 2.1 percent | 5.9 percent |
| 4 | EPYC 9V45 | 3,105 (3,025 to 3,235) | 3,104 (3,075 to 3,175) | 3,044 | 0.0 percent | 2.0 percent |
| 5 | EPYC 7763 | 3,857 (3,857 to 3,867) | 3,807 (3,778 to 3,808) | 3,656 | 1.3 percent | 5.2 percent |
| 6 | Xeon Platinum 8573C | 2,413 (2,392 to 2,430) | 2,399 (2,354 to 2,433) | 2,161 | 0.6 percent | 10.4 percent |
| 7 | EPYC 7763 | 3,877 (3,848 to 3,907) | 3,788 (3,778 to 3,797) | 3,657 | 2.3 percent | 5.7 percent |
| 8 | EPYC 9V74 | 4,347 (4,336 to 4,427) | 4,256 (4,116 to 4,326) | 4,137 | 2.1 percent | 4.8 percent |

What class A costs at the other batch sizes, in percent of the ReleaseSafe round. "Overlap" marks
a cell where the five rounds with class A and the five without overlap:

| run | processor | batch 8 | batch 64 | batch 128 |
|---|---|---|---|---|
| 1 | EPYC 7763 | 0.1 (overlap) | 1.4 | 1.6 |
| 2 | EPYC 7763 | 0.1 (overlap) | 2.2 | 1.7 |
| 3 | EPYC 7763 | 0.0 (overlap) | 1.5 | 1.4 |
| 4 | EPYC 9V45 | -2.0 (overlap) | 2.5 (overlap) | -1.5 (overlap) |
| 5 | EPYC 7763 | 0.8 (overlap) | 1.4 | 1.6 |
| 6 | Xeon Platinum 8573C | 2.1 (overlap) | 1.1 (overlap) | 1.0 (overlap) |
| 7 | EPYC 7763 | 1.6 | 1.7 | 1.7 |
| 8 | EPYC 9V74 | 1.9 | 1.4 (overlap) | 1.5 |

Batch 1 is left out: the runner's clock moves in steps of about 10 ns, and a round of one `nop`
takes about 550 ns, so a 2 percent difference is one step.

- **On the EPYC 7763, class A is measured, and it sits at the threshold.** Five runs landed there.
  At batch 32 to 128, the rounds with and without class A are apart in 14 of 15 cells. The median
  of the five runs is 2.1 percent at batch 32, 1.5 at batch 64 and 1.6 at batch 128. Four cells of
  fifteen are above 2 percent, all at batch 32 or 64.
- **The one EPYC 9V74 run agrees:** 2.1 percent at batch 32.
- **The Xeon Platinum 8573C and the EPYC 9V45 cannot resolve it.** Their rounds overlap at every
  batch size.
- **Class A is a third to a half of every check** on the two AMD processors that resolve it: 2.1
  of 5.7 percent on the EPYC 7763 and 2.1 of 4.8 on the EPYC 9V74, at batch 32.
- **The processor changes the answer.** At batch 8 to 128 every check costs 6.7 to 11.6 percent on
  the Xeon Platinum 8573C, 7.4 to 10.4 on the Xeon Platinum 8370C of 2026-09-22, 3.8 to 6.4 on the
  EPYC 7763, 3.7 to 4.8 on the EPYC 9V74 and 1.0 to 3.3 on the EPYC 9V45.

### The echo workload

Runs 6 to 8 ran `echo_runner --candidates rotor --payloads 4096` against the server rotor ships and
against the one with class A compiled out, alternating, three times each. Each run of the runner is
three rounds of four seconds. Echoes per second, the median and the range of the three runs:

| run | processor | connections | class A on | class A off | off against on |
|---|---|---|---|---|---|
| 6 | Xeon Platinum 8573C | 16 | 210,040 (208,301 to 213,078) | 211,237 (207,082 to 215,304) | +0.6 percent |
| 6 | Xeon Platinum 8573C | 64 | 214,784 (210,805 to 217,873) | 212,802 (212,609 to 215,576) | -0.9 percent |
| 7 | EPYC 7763 | 16 | 129,102 (128,963 to 129,163) | 127,400 (125,846 to 128,648) | -1.3 percent |
| 7 | EPYC 7763 | 64 | 130,500 (130,396 to 130,770) | 130,030 (129,826 to 130,652) | -0.4 percent |
| 8 | EPYC 9V74 | 16 | 127,359 (126,697 to 127,413) | 127,017 (126,550 to 127,706) | -0.3 percent |
| 8 | EPYC 9V74 | 64 | 128,910 (128,647 to 129,138) | 128,231 (127,208 to 128,726) | -0.5 percent |

Class A compiled out made the echo server no faster. It was slower in five cells of six. The
largest gain was 0.6 percent, and the three runs of the server with class A differ by up to 3.4
percent. Without class A the binary is 8,032 to 9,832 bytes smaller, so the switch did remove
code; each runner builds for its own processor, so the sizes differ by run. So on the echo
workload, class A costs less than the noise, on all three processors.

### What the two thresholds say

- The `nop` threshold is 2 percent. On the EPYC 7763 class A's median is 2.1 percent at batch 32,
  0.1 percentage points over, and under it at batch 64 and 128. Over it, this record moves the
  costliest class A assertion to class B or D. No run measures one assertion alone, so which one
  is costliest is not known.
- The echo clause says that when class A costs less than the noise of the echo workload, the
  record says so and the question is closed for that backend. It does, on io_uring.

The two point different ways at batch 32.

### Ruling, 2026-09-24

The owner ruled that the echo clause decides for io_uring. Class A costs less than the noise of the
echo workload there, so the question is closed for io_uring, and no assertion moves. The `nop`
median of 2.1 percent at batch 32 stays recorded above. The reasons:

- The echo workload is the realistic case, and on it class A cost nothing measurable on three
  processors.
- The `nop` excess is 0.1 percentage points, inside the 1.3 to 2.6 percent that five runs on one
  processor gave.
- No run measures one assertion alone, so moving "the costliest" would be a guess.

The question stays open for kqueue, which was not measured. epoll is below.

### epoll, 2026-09-24

epoll is the backend a process runs where the kernel refuses io_uring (decision 20). Commit
`57dbc22` switched the 18 class A sites an echo message passes through there: in epoll's own
submit, perform, reap and buffer files, and in the readiness table, the buffer group, `Slot.bytes`
and the `Tables` functions that finish an operation the flush performed, which kqueue shares. It
also added `zig build bench-echo-epoll-class-a`, which builds the epoll echo server twice, class A
on and off. The costs job ran the echo half on epoll three times, on three processors
(`bench/results/decision-8-class-a-github-2026-09-24.md`, runs 9 to 11). Echoes per second, the
median and the range of three runs of the runner:

{table}

- Class A compiled out gained at most 0.8 percent, and lost in two cells of six. The three runs of
  the server with class A differ by 2.3 to 3.0 percent at 64 connections.
- In one cell, the EPYC 9V74 at 64 connections, the two ranges do not overlap: the runs without
  class A were 0.8 percent faster, by nine echoes a second between the nearest runs. That is still
  less than the 2.5 percent the runs with class A spread over in that cell.
- Without class A the x86-64 binary is about 2.2 KB larger, not smaller. The compiler inlines
  differently when the checks are gone; the switch did change the code.

So on epoll too class A costs less than the noise of the echo workload, and by the echo clause the
question is closed for epoll. There is no `nop` benchmark for epoll, so the two clauses cannot
disagree there as they did on io_uring.

Still not measured:

- Class B alone. Step 2 asks for it the same way, and it has no switch.
- Step 3's `perf stat` counts of branches, branch misses and L1 misses. They were not taken.
- kqueue. The `nop` benchmark runs on io_uring only, and the echo half ran on io_uring and epoll.
