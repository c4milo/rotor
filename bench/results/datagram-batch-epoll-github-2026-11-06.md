# epoll's batch receive on GitHub's Linux runners, 2026-11-06

Decision 20's amendment of 2026-11-06 lets epoll's reap take several datagrams with one `recvmmsg`.
These runs measured it in three steps against main at `54ea0c1`, whose `src/` is v0.9.0's.

## How the runs were made

- The workflow `.github/workflows/ab-recvmmsg.yml` built `rotor_datagram_epoll` with
  `zig build bench-linux`, at the change and at `54ea0c1`, in ReleaseSafe for musl on the runner's
  processor. It ran on branches that are never merged: `ab-recvmmsg`, `ab-recvmmsg-2` and
  `ab-recvmmsg-3`. Each run had three jobs on `ubuntu-24.04` and three on `ubuntu-24.04-arm`, one
  core, kernel 7.0.0-1017-azure.
- **Round trips**: one datagram of 1,200 bytes at a time, with 1 and 64 round trips in flight,
  3 seconds a run.
- **Bursts**: `--burst`, four segmented sends in flight, each of 4 or 16 datagrams of 1,200
  bytes, with coalescing off and on, 3 seconds a run.
- Each job ran four pairs of each, and alternated the order of the two sides between pairs. A cell
  is the median over the job's four pairs, and in brackets the lowest and the highest pair.
- These are CI numbers, so none enters `docs/costs.md`.

## The three steps

| run | the change | 1 in flight, range of the six jobs' medians |
|---|---|---|
| 42216424771 | every receive asks for 8 | -5.7 to -4.4 percent |
| 42221904953 | only a receive the reap before also served batches | -4.7 to -0.9 percent |
| 42224053742 | the same, with the reader found once per readiness | -1.1 to +0.0 percent |

- **The first step lost at 1 in flight in every job.** Each readiness held one datagram, and a
  batch of 8 took 8 buffers, gave 7 back, filled 8 headers, and made the kernel look for a second
  datagram.
- **The second step made the calls of `54ea0c1` at 1 in flight**, and still lost. cachegrind, on
  arm64 in Docker, counted 4,955 instructions per round trip against `54ea0c1`'s 4,605: the reap
  found the reader twice, through three function layers.
- **The third step found the reader once**: 4,720 instructions against 4,612.
- At 64 in flight and on bursts the three steps measured alike.

## The third step, round trips

| processor | job | in flight | `54ea0c1`, per s | change, per s | change against `54ea0c1` | p50 µs, `54ea0c1` → change | ticks per round trip, `54ea0c1` → change |
|---|---:|---:|---:|---:|---|---|---|
| Neoverse N2 (0xd49) | 1 | 1 | 142,323 | 142,041 | -0.1% (-0.7 to +0.3) | 6.9 → 6.9 | 2.000 → 2.000 |
| Neoverse N2 (0xd49) | 2 | 1 | 143,571 | 143,578 | +0.0% (-0.7 to +0.4) | 6.9 → 6.9 | 2.000 → 2.000 |
| Neoverse N2 (0xd49) | 3 | 1 | 142,722 | 142,569 | -0.1% (-0.5 to +1.1) | 6.9 → 6.9 | 2.000 → 2.000 |
| AMD EPYC 9V45 | 1 | 1 | 84,483 | 83,773 | -0.7% (-1.6 to +0.4) | 11.7 → 11.7 | 2.000 → 2.000 |
| AMD EPYC 9V45 | 3 | 1 | 81,328 | 81,387 | -1.1% (-1.6 to +1.5) | 12.2 → 12.2 | 2.000 → 2.000 |
| AMD EPYC 9V74 | 2 | 1 | 77,332 | 77,204 | -0.0% (-1.6 to +0.1) | 12.8 → 12.8 | 2.000 → 2.000 |
| Neoverse N2 (0xd49) | 1 | 64 | 155,004 | 186,984 | +20.5% (+20.0 to +21.5) | 413.1 → 340.7 | 1.000 → 0.125 |
| Neoverse N2 (0xd49) | 2 | 64 | 156,038 | 186,002 | +19.5% (+18.1 to +19.9) | 409.7 → 341.6 | 1.000 → 0.125 |
| Neoverse N2 (0xd49) | 3 | 64 | 155,905 | 187,147 | +20.0% (+19.0 to +20.5) | 409.6 → 339.2 | 1.000 → 0.125 |
| AMD EPYC 9V45 | 1 | 64 | 90,719 | 102,130 | +12.5% (+12.4 to +12.7) | 704.9 → 625.8 | 1.000 → 0.125 |
| AMD EPYC 9V45 | 3 | 64 | 87,612 | 98,576 | +13.9% (+9.6 to +15.5) | 722.8 → 649.6 | 1.000 → 0.125 |
| AMD EPYC 9V74 | 2 | 64 | 82,917 | 96,320 | +16.3% (+15.6 to +17.3) | 770.5 → 661.7 | 1.000 → 0.125 |

No run lost a datagram.

## The third step, bursts

| processor | job | coalesce | burst | `54ea0c1`, datagrams per s | change, datagrams per s | change / `54ea0c1` | datagrams per tick, `54ea0c1` → change |
|---|---:|---|---:|---:|---:|---|---|
| Neoverse N2 (0xd49) | 1 | off | 4 | 70,434 | 419,777 | 5.97x (5.94 to 6.00) | 1.0 → 8.0 |
| Neoverse N2 (0xd49) | 1 | off | 16 | 36,857 | 247,988 | 6.74x (6.50 to 6.78) | 1.0 → 8.0 |
| Neoverse N2 (0xd49) | 1 | on | 4 | 382,572 | 1,306,979 | 3.42x (3.41 to 3.43) | 4.0 → 16.0 |
| Neoverse N2 (0xd49) | 1 | on | 16 | 1,224,132 | 3,697,824 | 3.03x (2.98 to 3.06) | 16.0 → 64.0 |
| Neoverse N2 (0xd49) | 2 | off | 4 | 70,306 | 412,363 | 5.86x (5.84 to 5.88) | 1.0 → 8.0 |
| Neoverse N2 (0xd49) | 2 | off | 16 | 36,655 | 241,570 | 6.61x (6.53 to 6.63) | 1.0 → 8.0 |
| Neoverse N2 (0xd49) | 2 | on | 4 | 376,277 | 1,289,582 | 3.43x (3.40 to 3.45) | 4.0 → 16.0 |
| Neoverse N2 (0xd49) | 2 | on | 16 | 1,204,013 | 3,724,511 | 3.09x (3.05 to 3.12) | 16.0 → 64.0 |
| Neoverse N2 (0xd49) | 3 | off | 4 | 70,374 | 416,589 | 5.93x (5.86 to 5.96) | 1.0 → 8.0 |
| Neoverse N2 (0xd49) | 3 | off | 16 | 36,662 | 243,821 | 6.65x (6.57 to 6.70) | 1.0 → 8.0 |
| Neoverse N2 (0xd49) | 3 | on | 4 | 381,396 | 1,298,322 | 3.41x (3.40 to 3.43) | 4.0 → 16.0 |
| Neoverse N2 (0xd49) | 3 | on | 16 | 1,215,333 | 3,701,325 | 3.04x (2.99 to 3.09) | 16.0 → 64.0 |
| AMD EPYC 9V45 | 1 | off | 4 | 43,253 | 263,916 | 6.11x (6.06 to 6.15) | 1.0 → 8.0 |
| AMD EPYC 9V45 | 1 | off | 16 | 25,138 | 171,004 | 6.80x (6.77 to 6.84) | 1.0 → 8.0 |
| AMD EPYC 9V45 | 1 | on | 4 | 231,077 | 769,570 | 3.33x (3.26 to 3.37) | 4.0 → 16.0 |
| AMD EPYC 9V45 | 1 | on | 16 | 872,437 | 2,706,885 | 3.11x (3.06 to 3.13) | 16.0 → 64.0 |
| AMD EPYC 9V45 | 3 | off | 4 | 39,609 | 240,196 | 5.98x (5.68 to 6.77) | 1.0 → 8.0 |
| AMD EPYC 9V45 | 3 | off | 16 | 23,256 | 158,056 | 6.70x (6.55 to 7.59) | 1.0 → 8.0 |
| AMD EPYC 9V45 | 3 | on | 4 | 214,885 | 710,503 | 3.27x (3.12 to 3.63) | 4.0 → 16.0 |
| AMD EPYC 9V45 | 3 | on | 16 | 785,689 | 2,471,859 | 3.13x (3.00 to 3.18) | 16.0 → 64.0 |
| AMD EPYC 9V74 | 2 | off | 4 | 40,484 | 242,965 | 6.00x (5.95 to 6.04) | 1.0 → 8.0 |
| AMD EPYC 9V74 | 2 | off | 16 | 23,710 | 159,710 | 6.72x (6.68 to 6.92) | 1.0 → 8.0 |
| AMD EPYC 9V74 | 2 | on | 4 | 213,074 | 702,533 | 3.30x (3.25 to 3.42) | 4.0 → 16.0 |
| AMD EPYC 9V74 | 2 | on | 16 | 755,454 | 2,320,822 | 3.08x (3.05 to 3.13) | 16.0 → 64.0 |

## What the runs show

- **One datagram at a time costs what it cost before**, within these runners' noise: every job's
  lowest and highest pair crossed zero. The reap does about 110 more instructions per round trip.
- **Many datagrams in flight take one tick per 8**, and the round trips rose 12.5 to 20.5 percent.
- **Bursts without coalescing rose 6 to 7 times**, because a burst no longer overflows the socket
  buffer at one datagram per tick. With coalescing on they rose 3.0 to 3.4 times, and epoll took
  3.7 million datagrams per second on the Neoverse N2, about what io_uring took with coalescing on
  in `datagram-coalesce-epoll-github-2026-11-05.md`.
