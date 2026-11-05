# Datagram coalescing on GitHub's Linux runners, 2026-11-05

Decision 15's amendment of 2026-11-05 made the loop split a coalesced datagram, and made coalescing
the default. These runs measure both halves of that change: what the split costs where GRO cannot
help, and what coalescing gains where it can.

## How the runs were made

- The workflow `.github/workflows/ab-datagram.yml` is on the branch `ab-datagram`, at `e86826d`
  over `8aa37db`. That branch is never merged. Run 42130287360 ran it on 2026-11-05: three jobs on
  `ubuntu-24.04` and three on `ubuntu-24.04-arm`, on io_uring, one core.
- **Round trips.** `rotor_datagram` built at `9963bda`, the tree before the split, against
  `8aa37db`: one datagram of 1,200 bytes at a time into buffers of 1,592 bytes, with 1 and 64 round
  trips in flight, three seconds a run. Those buffers cannot hold a coalesced datagram, so after
  the change the receive turns GRO off, and what changes is the reap's added read of each
  datagram's control block.
- **Bursts.** `rotor_datagram --burst` at `8aa37db`: four segmented sends in flight, each of 4 or
  16 datagrams of 1,200 bytes, into buffers that hold 65,535 bytes of payload, with coalescing on
  against off, three seconds a run.
- Each job ran four pairs of each, and alternated the order between pairs. A cell is the median
  over the job's four pairs of the ratio of the two sides, and in brackets the lowest and the
  highest pair. The rates beside it are the median of each side.
- The epoll half did not run: `zig build bench-echo` does not install `rotor_datagram_epoll`, and
  the job's script did not stop at the missing program. Every row below is io_uring.
- These are CI numbers, so none enters `docs/costs.md`.

## Round trips, after the split against before

| processor | job | in flight | before, per s | after, per s | after / before, median (lowest–highest) |
|---|---:|---:|---:|---:|---|
| AMD EPYC 7763 | 1 | 1 | 67,960 | 67,614 | -0.2% (-1.4 to +0.2) |
| AMD EPYC 7763 | 1 | 64 | 83,304 | 82,869 | -0.5% (-0.7 to +0.0) |
| AMD EPYC 9V45 | 3 | 1 | 84,936 | 85,239 | +0.0% (-1.8 to +1.2) |
| AMD EPYC 9V45 | 3 | 64 | 106,453 | 104,902 | -1.6% (-2.4 to -0.3) |
| AMD EPYC 9V74 | 2 | 1 | 82,308 | 81,632 | -0.8% (-1.1 to +0.9) |
| AMD EPYC 9V74 | 2 | 64 | 107,250 | 106,688 | -0.5% (-0.9 to -0.4) |
| Neoverse N2 (0xd49) | 1 | 1 | 151,628 | 152,058 | +0.5% (-0.9 to +1.5) |
| Neoverse N2 (0xd49) | 1 | 64 | 193,640 | 191,328 | -1.2% (-2.0 to -0.4) |
| Neoverse N2 (0xd49) | 2 | 1 | 154,729 | 153,295 | -0.9% (-1.4 to -0.6) |
| Neoverse N2 (0xd49) | 2 | 64 | 197,906 | 195,381 | -1.3% (-2.3 to -0.5) |
| Neoverse N2 (0xd49) | 3 | 1 | 154,240 | 152,483 | -1.2% (-1.4 to -0.7) |
| Neoverse N2 (0xd49) | 3 | 64 | 198,599 | 196,634 | -1.0% (-1.7 to -0.3) |

## Bursts, coalescing on against off

| processor | job | backend | burst | off, datagrams per s | on, datagrams per s | datagrams per receive, on | on / off, median (lowest–highest) |
|---|---:|---|---:|---:|---:|---:|---|
| AMD EPYC 7763 | 1 | io_uring | 4 | 327,235 | 598,140 | 4.0 | 1.83x (1.81 to 1.84) |
| AMD EPYC 7763 | 1 | io_uring | 16 | 500,633 | 1,890,068 | 16.0 | 3.78x (3.77 to 3.80) |
| AMD EPYC 9V45 | 3 | io_uring | 4 | 419,804 | 767,062 | 4.0 | 1.83x (1.80 to 1.84) |
| AMD EPYC 9V45 | 3 | io_uring | 16 | 679,495 | 2,653,287 | 16.0 | 3.90x (3.88 to 3.97) |
| AMD EPYC 9V74 | 2 | io_uring | 4 | 417,133 | 748,748 | 4.0 | 1.80x (1.79 to 1.80) |
| AMD EPYC 9V74 | 2 | io_uring | 16 | 662,646 | 2,420,700 | 16.0 | 3.65x (3.65 to 3.66) |
| Neoverse N2 (0xd49) | 1 | io_uring | 4 | 737,047 | 1,352,867 | 4.0 | 1.84x (1.83 to 1.84) |
| Neoverse N2 (0xd49) | 1 | io_uring | 16 | 1,041,690 | 3,482,601 | 16.0 | 3.33x (3.31 to 3.39) |
| Neoverse N2 (0xd49) | 2 | io_uring | 4 | 743,139 | 1,353,795 | 4.0 | 1.82x (1.81 to 1.83) |
| Neoverse N2 (0xd49) | 2 | io_uring | 16 | 1,041,023 | 3,537,300 | 16.0 | 3.43x (3.38 to 3.56) |
| Neoverse N2 (0xd49) | 3 | io_uring | 4 | 743,107 | 1,347,611 | 4.0 | 1.82x (1.81 to 1.82) |
| Neoverse N2 (0xd49) | 3 | io_uring | 16 | 1,045,601 | 3,559,735 | 16.0 | 3.40x (3.36 to 3.44) |

## What the runs show

- **Coalescing pays where bursts arrive.** Bursts of 4 datagrams were received 1.79 to 1.84 times
  as fast with coalescing on, and bursts of 16 3.31 to 3.97 times, on every processor and in every
  pair. Each kernel receive carried a whole burst: 4.0 and 16.0 datagrams.
- **The split cost at most about 1 percent where GRO cannot help.** With 64 round trips in flight,
  every job's median was lower after the change, by 0.5 to 1.6 percent. With one in flight the
  medians were from -1.2 to +0.5 percent. Single pairs on these runners spread by about 2 percent
  (`echo-pairs-github-2026-11-01.md` found the same), so a change this small is at the edge of what
  they show.
- **What it means for a program.** A QUIC sender that bursts gets the gain once its peer runs this
  tree with buffers large enough to coalesce. A program that receives one datagram at a time, into
  small buffers, pays the read of the control block and gets nothing.
