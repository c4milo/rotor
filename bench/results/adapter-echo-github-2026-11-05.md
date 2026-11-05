# The echo comparison of std.Io on rotor's adapter, 2026-11-05

Decision 22's steps 1 and 2 put a `std.Io` over a rotor loop. Before step 3 was built, Camilo asked
whether the adapter harms rotor. These runs measure what code written against `std.Io` gets on the
adapter. The adapter adds no code to rotor's own paths: steps 1 and 2 changed nothing in `core` or
the backends.

## How the runs were made

- `bench/alternatives/std_io_echo.zig` gained `--backend rotor`, which runs its unchanged `serve`
  on the adapter: one loop, 512 fibers of 256 KiB, the calls it does not run on the loop handed to
  `std.Io.Threaded`. The echo runner gained the candidate `std.Io on rotor`.
- CI run 42092473598 ran the `comparison` job of `.github/workflows/ci.yml` by hand on the branch
  `adapter-measure`, at `d175c61`: three runs on each kind of runner, io_uring on Linux, one core,
  three rounds a row of 4 seconds each.
- The x86-64 runs were on an AMD EPYC 9V45 (run 1), an Intel Xeon 8370C (run 2) and an AMD EPYC
  9V74 (run 3). The arm64 runs were on CPU part `0xd49`. macOS run 2 was cancelled, and runs 1 and
  3 were on an Apple M1 (Virtual).

A cell is a candidate's echo rate as a share of rotor's own server in the same run, as the
baseline's ratios are: the median over the runs, and in brackets the lowest and the highest. A row
is flagged when its rounds disagreed or other work was busy. These are CI numbers, so none enters
`docs/costs.md`.

## What the runs show

| machine | connections | payload | runs | std.Io on rotor | std.Io.Threaded | adapter over Threaded | rows flagged |
|---|---:|---:|---:|---|---|---|---:|
| Linux x86-64 | 16 | 4096 | 3 | 94% (89–95) | 59% (52–64) | 160% (140–180) | 0/15 |
| Linux x86-64 | 16 | 8192 | 3 | 96% (94–98) | 58% (51–65) | 162% (149–188) | 0/15 |
| Linux x86-64 | 16 | 16384 | 3 | 94% (90–94) | 59% (49–63) | 159% (148–184) | 0/15 |
| Linux x86-64 | 16 | 65536 | 3 | 86% (80–88) | 73% (73–79) | 111% (111–118) | 1/15 |
| Linux x86-64 | 64 | 4096 | 3 | 95% (90–96) | 59% (49–66) | 161% (146–185) | 1/15 |
| Linux x86-64 | 64 | 8192 | 3 | 93% (85–94) | 59% (50–65) | 158% (143–170) | 0/15 |
| Linux x86-64 | 64 | 16384 | 3 | 90% (78–94) | 59% (51–66) | 153% (144–154) | 0/15 |
| Linux x86-64 | 64 | 65536 | 3 | 87% (79–89) | 70% (69–77) | 116% (114–126) | 0/15 |
| Linux arm64 | 16 | 4096 | 3 | 91% (90–93) | 64% (64–65) | 142% (141–145) | 0/15 |
| Linux arm64 | 16 | 8192 | 3 | 87% (86–87) | 65% (63–67) | 135% (129–138) | 0/15 |
| Linux arm64 | 16 | 16384 | 3 | 75% (74–77) | 70% (70–71) | 107% (104–110) | 1/15 |
| Linux arm64 | 16 | 65536 | 3 | 76% (75–77) | 94% (93–96) | 81% (78–82) | 1/15 |
| Linux arm64 | 64 | 4096 | 3 | 73% (73–78) | 62% (62–63) | 118% (118–124) | 0/15 |
| Linux arm64 | 64 | 8192 | 3 | 74% (70–74) | 67% (64–68) | 110% (109–110) | 0/15 |
| Linux arm64 | 64 | 16384 | 3 | 71% (70–73) | 75% (72–76) | 97% (92–98) | 1/15 |
| Linux arm64 | 64 | 65536 | 3 | 81% (80–82) | 96% (94–97) | 85% (82–86) | 0/15 |

- On x86-64, `std.Io` code on the adapter ran at 86 to 96 percent of rotor's own server, and at 1.1
  to 1.6 times `std.Io.Threaded`'s rate.
- On arm64, it ran at 71 to 91 percent of rotor's own server. It was ahead of `std.Io.Threaded` at
  4 and 8 KiB, level at 16 KiB with 64 connections, and 15 to 19 percent behind at 64 KiB.
- The gap to rotor's own server grows with the payload. The adapter reads and writes one buffer a
  call, where rotor's server takes the speed sources, which `std.Io` cannot reach (decision 1).
- macOS gave nothing: 79 of the 80 rows of its two runs were flagged, with ratios from 58 to 226
  percent.
- Each run of the adapter peaked at about 135 MB of resident memory, against 4 to 12 MB for rotor's
  server and about 27 MB for `std.Io.Threaded`. That is the program's 512 stacks of 256 KiB: the
  ReleaseSafe allocator writes every byte it hands out, which is recalled and not checked here.
