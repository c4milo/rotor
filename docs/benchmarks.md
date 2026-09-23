# Benchmarks

This file holds the current measurements of rotor against libuv and libxev, how they were taken,
and how to take them again. Every table links to the recorded run it comes from, in
[`bench/results/`](../bench/results). [`bench/alternatives/README.md`](../bench/alternatives/README.md)
is the full record: every experiment, the rows rotor loses and why, and the pinned version of each
alternative.

## How a row is measured

- **One loop.** Each candidate's server runs one event loop on one thread. The client runs in the
  runner's own process.
- **Candidates alternate.** Each round runs every candidate once, in turn, so a machine that drifts
  during the run affects them all alike. A row is the median of three or five rounds.
- **Spread.** The fastest run minus the slowest, divided by the median, in percent. A row with a
  spread of 10 percent or more is marked **RUNS DISAGREE** and decides nothing.
- **Other work.** The harness reads how busy the machine was just before and after each run. A row
  taken while another job used half a core or more is marked **OTHER WORK**.
- **Each library in its cheapest mode.** A row names the mode, so no result depends on driving an
  alternative badly.

## Machines

| machine | processor | system | backend |
|---|---|---|---|
| `mac` | Apple M1 Pro | macOS 26.6.2 | kqueue |
| `github` | a GitHub-hosted runner, 4 virtual x86-64 CPUs: an AMD EPYC 9V74 on one run, an Intel Xeon 6973P-C on another | Linux 6.17 | io_uring |

The GitHub runner pool hands out a different processor from run to run, and the ratios between
the candidates move with it: on the same code, a candidate's rate as a share of rotor's differed by
up to 22 percentage points between the two processors below. Its rows show what rotor does on
x86-64, and not how it performs on any one machine. The Linux machine rotor is meant to run on in
production has not been chosen, so no number is taken on it yet.

## TCP echo

Each connection sends a message and waits for it to come back. Messages per second, p50 and p99
latency in µs, spread in percent, and the server's peak memory in MB where the run measured it.

### `mac`, kqueue, 2026-09-22

[run](../bench/results/echo-mac-2026-09-22.md)

| connections | payload | candidate | messages per second | p50 µs | p99 µs | spread % |
|---:|---:|---|---:|---:|---:|---|
| 16 | 4 KiB | rotor | 159,103 | 92 | 207 | 2 |
| 16 | 4 KiB | libuv | 158,001 | 92 | 217 | 0 |
| 16 | 4 KiB | libxev | 128,484 | 118 | 238 | 0 |
| 16 | 64 KiB | rotor | 61,937 | 260 | 444 | 3 |
| 16 | 64 KiB | libuv | 63,673 | 232 | 489 | 3 |
| 16 | 64 KiB | libxev | 63,193 | 224 | 496 | 2 |
| 64 | 4 KiB | rotor | 151,102 | 381 | 844 | 2 |
| 64 | 4 KiB | libuv | 148,613 | 430 | 1,028 | 5 |
| 64 | 4 KiB | libxev | 164,166 | 319 | 782 | 12 **RUNS DISAGREE** |
| 64 | 64 KiB | rotor | 56,632 | 1,114 | 1,950 | 1 |
| 64 | 64 KiB | libuv | 57,000 | 1,122 | 2,015 | 2 |
| 64 | 64 KiB | libxev | 53,869 | 1,212 | 1,761 | 1 |

### `github` on an AMD EPYC 9V74, io_uring, 2026-09-22

[run](../bench/results/echo-sized-pool-github-2026-09-22.md). The run also measured 8 and 16 KiB
payloads and `std.Io.Threaded`.

| connections | payload | candidate | messages per second | p50 µs | p99 µs | spread % | peak memory MB |
|---:|---:|---|---:|---:|---:|---|---:|
| 16 | 4 KiB | rotor | 136,066 | 116 | 151 | 1 | 3.96 |
| 16 | 4 KiB | libuv | 130,510 | 121 | 174 | 1 | 3.31 |
| 16 | 4 KiB | libxev | 121,730 | 130 | 176 | 1 | 3.31 |
| 16 | 64 KiB | rotor | 26,044 | 614 | 672 | 2 | 6.16 |
| 16 | 64 KiB | libuv | 25,785 | 623 | 655 | 0 | 4.33 |
| 16 | 64 KiB | libxev | 28,257 | 565 | 651 | 2 | 4.33 |
| 64 | 4 KiB | rotor | 138,324 | 459 | 494 | 1 | 8.57 |
| 64 | 4 KiB | libuv | 131,967 | 485 | 635 | 0 | 8.57 |
| 64 | 4 KiB | libxev | 133,410 | 479 | 508 | 1 | 8.57 |
| 64 | 64 KiB | rotor | 26,362 | 2,425 | 2,572 | 0 | 12.45 |
| 64 | 64 KiB | libuv | 25,808 | 2,490 | 2,589 | 2 | 8.87 |
| 64 | 64 KiB | libxev | 29,035 | 2,245 | 2,490 | 2 | 8.87 |

### `github` on an Intel Xeon 6973P-C, io_uring, 2026-09-22

[run](../bench/results/echo-sized-pool-github-xeon-2026-09-22.md). The run also measured 8 and
16 KiB payloads and `std.Io.Threaded`.

| connections | payload | candidate | messages per second | p50 µs | p99 µs | spread % | peak memory MB |
|---:|---:|---|---:|---:|---:|---|---:|
| 16 | 4 KiB | rotor | 231,410 | 68 | 93 | 2 | 3.99 |
| 16 | 4 KiB | libuv | 193,095 | 75 | 162 | 0 | 3.11 |
| 16 | 4 KiB | libxev | 173,880 | 93 | 113 | 0 | 3.11 |
| 16 | 64 KiB | rotor | 65,718 | 241 | 285 | 0 | 6.09 |
| 16 | 64 KiB | libuv | 62,755 | 249 | 399 | 1 | 4.13 |
| 16 | 64 KiB | libxev | 58,491 | 274 | 322 | 1 | 4.13 |
| 64 | 4 KiB | rotor | 239,611 | 266 | 319 | 1 | 8.37 |
| 64 | 4 KiB | libuv | 199,081 | 319 | 401 | 2 | 8.37 |
| 64 | 4 KiB | libxev | 189,242 | 340 | 403 | 1 | 8.37 |
| 64 | 64 KiB | rotor | 57,665 | 1,106 | 1,401 | 2 | 12.48 |
| 64 | 64 KiB | libuv | 60,983 | 1,040 | 1,237 | 8 | 8.68 |
| 64 | 64 KiB | libxev | 58,140 | 1,098 | 1,384 | 2 | 8.68 |

rotor's server holds more memory at 64 KiB than the others, because its buffer group holds two
64 KiB buffers per connection where the others hold one.
[`bench/alternatives/README.md`](../bench/alternatives/README.md#rotor-loses-the-64-kib-row-on-io_uring-on-clean-rows)
records what is known about the 64 KiB rows.

## Accept storm

Every connection opens at once, sends one byte and reads it back. Connections per second and
spread.

### `github` on an AMD EPYC 9V74, io_uring, 2026-09-22

[run](../bench/results/echo-sized-pool-github-2026-09-22.md)

| connections | candidate | connections per second | spread % |
|---:|---|---:|---|
| 16 | rotor | 33,553 | 5 |
| 16 | libuv | 28,507 | 3 |
| 16 | libxev | 31,967 | 4 |
| 64 | rotor | 37,476 | 23 **RUNS DISAGREE** |
| 64 | libuv | 32,055 | 0 |
| 64 | libxev | 35,855 | 1 |

On `mac`, seven of the eight storm rows disagree by 17 to 84 percent, so the storm decides nothing
there ([run](../bench/results/storm-mac-2026-09-22.md)).

## Timer churn on `mac`

Timers on a 1 ms period, each library in its cheapest mode: rotor's and libuv's own repeating
timer, and libxev's callback re-arming its timer
([run](../bench/results/timers-modes-mac-2026-09-22.md)). Lateness is how long after its deadline
a timer fired.

| timers | candidate | fires per second | p50 late µs | p99 late µs | spread % |
|---:|---|---:|---:|---:|---|
| 256 | rotor (repeating) | 255,974 | 169 | 527 | 0 |
| 256 | libxev | 220,901 | 180 | 250 | 1 |
| 256 | libuv (repeating) | 209,337 | 185 | 757 | 3 |
| 4,096 | rotor (repeating) | 4,094,231 | 793 | 1,075 | 0 |
| 4,096 | libxev | 3,252,874 | 53 | 1,051 | 2 |
| 4,096 | libuv (repeating) | 2,024,570 | 1,089 | 1,353 | 3 |

Each timer is asked for 1,000 fires per second, and only rotor keeps that rate. libxev fires closer
to its deadline. A rotor timer is scheduled from its previous deadline, so it never drops a period;
the others schedule the next fire from the clock when a timer fires, so they fire less often, and
each fire is less late.

## One cross-core message on `mac`

Two loops on two cores send a message back and forth, each waiting in its tick for the other's
([run](../bench/results/crosscore-mac-2026-09-22-after.md)). One message is half a round trip.
rotor's message carries a 16-byte payload; libuv's and libxev's carry none.

| candidate | messages per second | p50 ns | p99 ns | spread % |
|---|---:|---:|---:|---|
| rotor | 384,127 | 2,007 | 8,031 | 14 **RUNS DISAGREE** |
| libuv | 518,732 | 1,500 | 6,000 | 4 |
| libxev | 434,027 | 2,007 | 8,031 | 8 |

## File reads and writes on `mac`

A 256 MiB file on the internal NVMe, 32 operations in flight
([run](../bench/results/files-mac-2026-09-22.md)). kqueue cannot complete a file operation. `rotor`
runs each call on the loop's thread, and `rotor (registered, offload)` hands it to a pool of threads
the program supplies.

| workload | block | candidate | operations per second | spread % |
|---|---:|---|---:|---|
| sequential read | 4 KiB | rotor (registered, offload) | 125,285 | 2 |
| sequential read | 4 KiB | libuv (thread pool) | 123,006 | 1 |
| sequential read | 4 KiB | rotor | 44,878 | 3 |
| random read | 4 KiB | rotor (registered, offload) | 48,095 | 3 |
| random read | 4 KiB | libuv (thread pool) | 48,145 | 1 |
| random read | 4 KiB | rotor | 12,452 | 0 |
| sequential write, then `fdatasync` | 4 KiB | rotor (registered, offload) | 662 | 94 **RUNS DISAGREE** |
| sequential write, then `fdatasync` | 4 KiB | libuv (thread pool) | 2,005 | 28 **RUNS DISAGREE** |
| sequential write, then `fdatasync` | 4 KiB | rotor | 5,181 | 7 |

On synced writes, one thread flushing in order is faster than several threads each waiting on the
drive's flush.

## Taking the numbers again

```bash
zig build bench-echo bench-crosscore bench-alternatives
```

That builds rotor's programs and fetches and builds the pinned libuv and libxev. Then:

| workload | command |
|---|---|
| TCP echo | `./zig-out/bin/echo_runner` |
| accept storm | `./zig-out/bin/echo_runner --workload storm` |
| timer churn | `./zig-out/bin/timers_runner` |
| one cross-core message | `./zig-out/bin/crosscore_runner` |
| file reads and writes | `./zig-out/bin/reads_runner PATH`, where `PATH` is a file on the drive to measure |

Each prints a Markdown table in the form above. Take numbers on an idle machine: a row marked
**OTHER WORK** was shared with another job. `echo_runner --baseline bench/baseline/echo.txt` also
checks a run against the recorded ratios for its processor, which is what the `comparison` job of
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) does.
