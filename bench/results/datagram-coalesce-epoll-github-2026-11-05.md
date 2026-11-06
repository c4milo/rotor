# Datagram bursts on epoll and io_uring, GitHub's Linux runners, 2026-11-05

The run of `datagram-coalesce-github-2026-11-05.md` measured io_uring only, because
`zig build bench-echo` does not install `rotor_datagram_epoll`. This run measures both backends with
coalescing on against off, at v0.9.0.

## How the runs were made

- The workflow `.github/workflows/ab-datagram-epoll.yml` is on the branch `ab-datagram-epoll`, at
  `19a4be4` over `5a5d7d7`, the commit of v0.9.0. That branch is never merged. Run 42152323289 ran
  it on 2026-11-06 UTC: three jobs on `ubuntu-24.04` and three on `ubuntu-24.04-arm`, one core,
  kernel 7.0.0-1017-azure.
- `zig build bench-linux` built `rotor_datagram` and `rotor_datagram_epoll` in ReleaseSafe for
  musl on the runner's processor. Each ran `--burst` with 4 segmented sends in flight, each of 4 or
  16 datagrams of 1,200 bytes, into buffers that hold 65,535 bytes of payload, for 3 seconds.
- Each job ran four pairs, and alternated the order of the two sides between pairs. A cell is the
  median over the job's four pairs of the ratio of on to off, and in brackets the lowest and the
  highest pair. The rates beside it are the median of each side.
- The rate counts the datagrams the receiver took. The kernel drops what a full socket buffer
  cannot hold, and the program does not count those.
- These are CI numbers, so none enters `docs/costs.md`.

## Bursts, coalescing on against off

| processor | job | backend | burst | off, datagrams per s | on, datagrams per s | datagrams per receive, on | on / off, median (lowest–highest) |
|---|---:|---|---:|---:|---:|---:|---|
| AMD EPYC 9V74 | 2 | epoll | 4 | 40,385 | 214,145 | 4.0 | 5.31x (5.27 to 5.33) |
| AMD EPYC 9V74 | 2 | epoll | 16 | 23,779 | 763,434 | 16.0 | 32.08x (31.96 to 32.22) |
| AMD EPYC 9V74 | 2 | io_uring | 4 | 416,474 | 746,024 | 4.0 | 1.79x (1.78 to 1.80) |
| AMD EPYC 9V74 | 2 | io_uring | 16 | 664,018 | 2,428,238 | 16.0 | 3.65x (3.62 to 3.69) |
| AMD EPYC 9V74 | 3 | epoll | 4 | 40,274 | 214,015 | 4.0 | 5.31x (5.26 to 5.36) |
| AMD EPYC 9V74 | 3 | epoll | 16 | 23,714 | 763,572 | 16.0 | 32.21x (32.15 to 32.55) |
| AMD EPYC 9V74 | 3 | io_uring | 4 | 418,580 | 747,755 | 4.0 | 1.79x (1.75 to 1.79) |
| AMD EPYC 9V74 | 3 | io_uring | 16 | 663,396 | 2,413,305 | 16.0 | 3.63x (3.62 to 3.66) |
| Intel Xeon Platinum 8370C | 1 | epoll | 4 | 62,104 | 343,496 | 4.0 | 5.54x (5.51 to 5.57) |
| Intel Xeon Platinum 8370C | 1 | epoll | 16 | 33,687 | 1,142,067 | 16.0 | 33.81x (33.76 to 34.01) |
| Intel Xeon Platinum 8370C | 1 | io_uring | 4 | 657,431 | 1,182,439 | 4.0 | 1.80x (1.78 to 1.80) |
| Intel Xeon Platinum 8370C | 1 | io_uring | 16 | 1,037,490 | 3,354,454 | 16.0 | 3.24x (3.22 to 3.25) |
| Neoverse N2 (0xd49) | 1 | epoll | 4 | 70,375 | 380,399 | 4.0 | 5.40x (5.39 to 5.44) |
| Neoverse N2 (0xd49) | 1 | epoll | 16 | 36,629 | 1,221,844 | 16.0 | 33.31x (33.17 to 33.59) |
| Neoverse N2 (0xd49) | 1 | io_uring | 4 | 747,470 | 1,360,431 | 4.0 | 1.82x (1.81 to 1.83) |
| Neoverse N2 (0xd49) | 1 | io_uring | 16 | 1,053,815 | 3,593,691 | 16.0 | 3.41x (3.33 to 3.45) |
| Neoverse N2 (0xd49) | 2 | epoll | 4 | 70,252 | 376,989 | 4.0 | 5.36x (5.34 to 5.39) |
| Neoverse N2 (0xd49) | 2 | epoll | 16 | 36,737 | 1,207,794 | 16.0 | 32.84x (32.61 to 33.02) |
| Neoverse N2 (0xd49) | 2 | io_uring | 4 | 738,478 | 1,353,624 | 4.0 | 1.83x (1.81 to 1.84) |
| Neoverse N2 (0xd49) | 2 | io_uring | 16 | 1,033,661 | 3,525,518 | 16.0 | 3.42x (3.35 to 3.45) |
| Neoverse N2 (0xd49) | 3 | epoll | 4 | 70,110 | 377,783 | 4.0 | 5.39x (5.38 to 5.40) |
| Neoverse N2 (0xd49) | 3 | epoll | 16 | 36,573 | 1,216,512 | 16.0 | 33.18x (32.85 to 33.44) |
| Neoverse N2 (0xd49) | 3 | io_uring | 4 | 740,607 | 1,354,401 | 4.0 | 1.83x (1.81 to 1.84) |
| Neoverse N2 (0xd49) | 3 | io_uring | 16 | 1,039,668 | 3,568,466 | 16.0 | 3.42x (3.39 to 3.62) |

With coalescing off, every receive carried 1.0 datagram on both backends.

## Ticks per receive, pair 1 of the Neoverse N2's job 2

| backend | coalesce | burst | datagrams | receives | ticks |
|---|---|---:|---:|---:|---:|
| io_uring | on | 4 | 4,059,424 | 1,014,856 | 253,714 |
| io_uring | on | 16 | 10,719,680 | 669,980 | 167,495 |
| io_uring | off | 4 | 2,209,408 | 2,209,408 | 138,088 |
| io_uring | off | 16 | 3,103,040 | 3,103,040 | 48,485 |
| epoll | on | 4 | 1,133,236 | 283,309 | 283,309 |
| epoll | on | 16 | 3,614,032 | 225,877 | 225,877 |
| epoll | off | 4 | 210,301 | 210,301 | 210,301 |
| epoll | off | 16 | 110,832 | 110,832 | 110,832 |

## What the runs show

- **io_uring repeats the first run.** Coalescing received bursts of 4 1.75 to 1.84 times as fast,
  and bursts of 16 3.22 to 3.69 times, at v0.9.0 as at `8aa37db`.
- **On epoll every tick took exactly one receive.** Decision 20 rules that one readiness serves one
  operation per direction. With coalescing off a burst takes one tick per datagram, the socket
  buffer fills, and the kernel drops the rest. epoll then received 23,000 to 70,000 datagrams per
  second, a tenth or less of io_uring's rate, and bursts of 16 came slower than bursts of 4.
- **Coalescing hides most of that rule.** One receive takes a whole burst, so epoll gained 5.3 to
  5.5 times at bursts of 4 and 32 to 34 times at bursts of 16. With coalescing on, epoll reached
  28 to 34 percent of io_uring's rate.
- **The gain on epoll is mostly the rule's cost, not GRO's.** io_uring with coalescing off takes
  every datagram a burst brings, so its ratio is what GRO gains. epoll's larger ratio also counts
  what one receive per tick loses when bursts arrive.
