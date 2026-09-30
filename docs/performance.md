# Performance work in rotor

This is rotor's appendix to pepegrillo's performance method, which `zig build guide` installs to
`zig-out/docs/performance/` from the commit `build.zig.zon` pins. `performance.md` there is the
method's entry point, `performance_hardware.md` holds its step 4, and `performance_zig.md` holds
what Zig 0.16 does to hot code. The method holds the part every project on pepegrillo shares. This
file holds what is rotor's own: its instruments, its admission rule, the units that wait on I/O,
its baselines, its costs and the pitfalls it has paid for. Where rotor does not yet do what the
method asks, this file says so, and the last section lists what is open.

## The filter and the judge

The filter answers in a minute on a development machine. No number from it goes into a document.

- **Instructions per unit, on `mac`.** `/usr/bin/time -l` counts the instructions a process retired,
  user and kernel together. Two runs of different lengths are differenced, so start-up cancels:
  202,000 round trips less 2,000, divided by the 200,000 between them
  (`bench/results/crosscore-own-work-github-macos-2026-09-29.md`). A count moves far less with
  other work than a time does. It stands in for time only where rotor does not spin: a loop given a
  spin budget (decision 13) retires instructions while it waits.
- **Where the time goes, on `mac`.** `sample`, the macOS sampling profiler, by function.
- **Kernel calls per unit, on Linux.** `bench/calls/count_calls.sh` counts the system calls,
  io_uring requests, poll arms and io-wq jobs of rotor's echo servers per echo, from the kernel's
  tracepoints. `bench/calls/cpu_per_echo.sh` gives the CPU time per echo of the server and the
  client.

The judge's numbers are the ones rotor publishes.

- **The harness**, on a machine `docs/costs.md` names: `echo_runner`, `timers_runner`,
  `crosscore_runner` and `reads_runner`. Every candidate runs in one harness run, alternating, with
  its version pinned (`docs/benchmarks.md`).
- **The machines.** `mac` is an Apple M1 Pro on macOS, where kqueue is measured when the machine is
  quiet. `github` is a GitHub-hosted x86-64 runner, measured by the `costs` job started by hand.
  `orbstack` is the Linux virtual machine on `mac`, and fills its own column of `docs/costs.md` and
  nothing else. `linux`, the machine rotor is deployed on, is not named, so no io_uring number yet
  speaks for production.
- **Where a number is published:** `docs/costs.md`, from named machines only; `bench/results/`,
  which holds every run; and `docs/benchmarks.md` and `bench/alternatives/README.md`, which read
  from it.
- **Where it is not:** no number from CI enters `docs/costs.md`. CI's runners are neither named nor
  quiet, and their comparisons are regression gates. By Camilo's ruling of 2026-09-29, one change
  landed on paired rounds taken on GitHub's macOS runners while `mac` was busy; its rate on `mac` is
  still to be taken.

## The admission rule in numbers

What rotor applies today:

- A row is the median of its runs, and its spread is the fastest run less the slowest, over the
  median, as in the method. A row whose spread is 10 percent or more carries **RUNS DISAGREE** and
  decides nothing (`bench/harness/series.zig`, `spread_unreliable_percent`). A row taken while the
  machine did other work carries **OTHER WORK** (`bench/harness/other_work.zig`).
- Runs per row: 3 for echo and the accept storm, 5 for timer churn and the cross-core message. The
  method asks for 5.
- A `perf` commit carries the harness number, the command and the machine. A change the harness
  cannot show does not land as a `perf` commit (CLAUDE.md, Performance discipline).
- Three gates catch a regression after a change lands:

| gate | what it holds | the limit | where it runs |
|---|---|---|---|
| cost gates | a poll, one fire of a repeating timer, one operation of a batch submit | the best of 20 attempts under a bound an order of magnitude above what was measured | `zig build test`, every push |
| call gate | kernel calls per echo, per row | ceilings set by the rules in `bench/baseline/calls.txt` | Linux x86-64 and arm64, every push |
| echo baseline | each candidate's echoes per second as thousandths of rotor's, per processor | the highest ratio of several runners, plus 50 thousandths | the nightly comparison on Linux x86-64 and arm64 |

Not yet set, and asked of Camilo in the last section:

- **The floor** a win or a loss must pass. The change of 2026-09-29 landed on a median gain of 4.8
  percent, with 22 of 30 paired rounds ahead, by ruling.
- **The layout noise**: how far a rebuild alone moves a number on the judge. It has not been
  measured.
- **Paired jobs.** rotor has run them twice, each from a workflow on a branch that is never merged:
  `ab-wait-timer` on 2026-09-27 and `crosscore-ab` on 2026-09-29. The method asks for at least two
  paired jobs in which an input wins past the noise in every one and no input loses in any.

## Units that wait on I/O

| unit | what the judge reports | how load is offered |
|---|---|---|
| echo round trip | echoes per second; p50, p99, p999 and p9999 of the round trip | 16 or 64 connections, each sending its next message when its last came back |
| cross-core message | messages per second; percentiles of one message, half a round trip | two loops sending one message back and forth |
| accept | connections accepted per second | 16 or 64 connections at once |
| timer fire | fires per second; percentiles of how late each fired | timers armed on a fixed period |

Every generator here waits for a reply before it sends again. The method asks for a generator that
sends on a schedule, because one that waits sends nothing while the system stalls, and its
percentiles leave the stall out. The judge does not report the maximum either. Of the kernel's
counts per unit, rotor counts system calls; it does not count wakeups or context switches.

## The baselines

- libuv v1.52.1, libxev at `9ce8e8e`, and `std.Io.Threaded` of Zig 0.16.0, pinned in `build.zig.zon`
  and built by `zig build bench-alternatives`. `std.Io.Uring` does not compile on Zig 0.16.0
  (`bench/alternatives/README.md`).
- Each runs a program rotor wrote against its public API, in the cheapest mode it offers, and a row
  names the mode.
- The regression baselines are `bench/baseline/echo.txt`, ratios per processor, and
  `bench/baseline/calls.txt`, ceilings per row.
- **rotor has read their source.** `bench/alternatives/README.md` settled decision 3's table and
  checked how each candidate is driven against libuv's and libxev's source, cited by file and line.
  The method treats a baseline as an oracle and a number, compared by sampling its binary and never
  by reading its source.

## The costs table

`docs/costs.md` holds the costs, each cell the median with the p99 in parentheses, in nanoseconds,
and the run it came from. The rows the method names:

| cost | row | `mac` | `orbstack` | `github` |
|---|---|---:|---:|---:|
| first-level cache hit | C1 | 0.93 (1.32) | 0.93 (1.44) | 1.67 (1.96) |
| miss to memory | C3 | 128 (199) | 185 (327) | 120 (135) |
| branch mispredict | C4 | 5.77 (8.34) | 5.78 (9.32) | 8.34 (10.1) |
| smallest system call, `getppid` | C6 | 112 (133) | 88.9 (160) | 124 (171) |
| copy of 64 KiB | C23 | not measured | not measured | 1,587 (2,032) |

The `linux` column is empty until that machine is named.

## Pitfalls rotor has paid for

Each row was seen in a measurement. The pitfalls that belong to Zig are in the method's
`performance_zig.md`.

| symptom | cause | rule | evidence |
|---|---|---|---|
| rotor lost the cross-core row by four times on `mac` | every polling `kevent` parked in the kernel for 12 µs | a tick with nothing to ask the kernel makes no call, and a cost gate bounds a poll | decision 12, point 6 |
| a wait timer fired about 1.2 ms late, about 100 ms at background priority, and macOS CI flaked | `EVFILT_TIMER` without `NOTE_CRITICAL` is coalesced | the wait timer asks for `NOTE_CRITICAL` | `52cf22c`, decision 12, point 7 |
| a tick's instructions fell, and its time on GitHub's runners fell by more than they explain | a 1 ms periodic wakeup speeds a cross-core ping-pong on those virtual machines | time a change on the judge, and split a gain into its causes before claiming it | `fde2e41` |
| two shapes of one unchanged server swapped places from round to round | one run of one candidate is not evidence | alternate candidates, take several runs, and print the spread beside the median | `bench/alternatives/README.md` |
| the load mark fired on runs nothing else touched | the load average counted the harness's own processes | read the machine's busy CPU in a pause before and after each run | `3cf29f5` |
| one candidate's ratio to rotor differed by 12.5 points between two runners, with no change to the code | the ratio moves with the processor | hold a run only to its own processor's section | `bench/harness/baseline.zig` |
| an arm64 section taken from four runs failed two of the next four runs on one row | four runners did not show how far that row moves | take a section from all the runs there are, and retake it when a run passes it without a change | `89a4430` |
| the gate called a steady candidate a regression | its ratio divided by a rotor median whose runs disagreed | decide nothing when either side's runs disagree | `e84ec8d` |
| GitHub's macOS runners disagreed on 134 and 138 of 160 echo rows | noise inside the virtual machine, which stayed with Spotlight's indexing off | no baseline section for them; measure kqueue on `mac` when it is quiet | `bench/results/echo-github-macos-2026-09-27.md` |
| `strace` found fewer io_uring calls than the server made | a tracer that stops the process at each call changes how the server batches | count calls with the kernel's tracepoints | `bench/calls/count_calls.sh` |
| libuv measured 141 to 230 thousandths higher before a fix to rotor's echo server | the server gave a provided buffer back twice at 64 KiB, and the client never compared the bytes | the client compares what comes back | `db9e39e`, `34763cc` |
| file rows on GitHub's runners measured the disk | the runner's file system is an Azure cloud volume | the comparison there leaves the file workload out | `.github/workflows/ci.yml`, the `comparison` job |
| a test waited for 65 received pieces and got 33 | an io_uring completion ring holds two completions per entry, and a multishot receive ends when the ring is full | size the ring for the burst a test sends | `b277a87` |
| a test's 20 ms wait for a 5 ms timer ended first on a busy runner | a busy virtual machine delays a timer by more than a test's margin | bound a wait by far more than the event needs, and return when the event comes | `7bce4d2` |

## Commands

```bash
zig build guide
zig build bench-echo bench-crosscore bench-alternatives
./zig-out/bin/echo_runner --baseline bench/baseline/echo.txt
./zig-out/bin/echo_runner --workload storm
./zig-out/bin/timers_runner
./zig-out/bin/crosscore_runner
zig build bench-costs
sudo BIN=zig-out/bin sh bench/calls/count_calls.sh
BIN=zig-out/bin sh bench/calls/cpu_per_echo.sh
gh workflow run ci -f comparison_runs='[1, 2, 3, 4]'
```

The last line runs the comparison on four runners of each kind at once, which is how a baseline
section is taken.

## What is open

Each needs Camilo's ruling before rotor meets the method:

1. The floor a win or a loss must pass, and whether it is the 10 percent at which a row's runs
   disagree.
2. Measuring the layout noise on the judge.
3. Five runs per echo row in place of three.
4. A committed workflow for paired jobs, base and change built and run in one job.
5. A generator that sends on a schedule for the echo and cross-core units, and the maximum in the
   judge's report.
6. Counting wakeups and context switches per unit beside system calls.
7. Whether rotor keeps reading the baselines' source to check how each is driven.
