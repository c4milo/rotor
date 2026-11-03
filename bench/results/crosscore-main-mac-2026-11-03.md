# One cross-core message, 7bce4d2 against main, `mac`, 2026-11-03

On 2026-09-29 two changes reached the cross-core row on kqueue. `6e4c0b7` cut a tick's own work per
message, and `rotor_post` began to send with `Loop.post`. `mac` was busy that day, so both landed on
paired rounds on GitHub's macOS runners (`crosscore-own-work-github-macos-2026-09-29.md`,
`crosscore-loop-post-github-macos-2026-09-29.md`, `crosscore-main-github-macos-2026-11-01.md`).
This run takes the rate on `mac`.

## How the run was made

- `./zig-out/bin/crosscore_runner` with its defaults, from two builds of
  `zig build bench-crosscore bench-alternatives`. The base is `7bce4d2`, the parent of `6e4c0b7`.
  The change is `b2825d7`, which was main on 2026-11-01. It does not hold `51cb619`, the fix of
  issue 10.
- Each side runs its own `crosscore_runner` against its own directory. libuv and libxev are built
  from the same sources on both sides, so they show how far the machine moved between the two.
- Six rounds. A round is one `crosscore_runner` call for each side, and each call runs every
  candidate five times. Odd rounds run the base first, and even rounds run main first.
- Apple M1 Pro, 10 cores, 32 GiB, macOS 26.6.2 build 25G83.

`mac` was not quiet. A script read the load once a minute, and started the rounds once three
readings in a row showed a 1-minute load under 4 and no process above 110 percent of a core. By
Camilo's choice of 2026-11-02 that rule replaced a 1-minute load under 1 and no process above 50
percent, because a Chrome renderer and `fseventsd` had each held a core for days. The rounds began
at 10:55:40 UTC at a load of 3.20, 3.16 and 3.78, and ended at 10:57:31 UTC at 3.51, 3.25 and 3.73.
Every row carries **OTHER WORK**, and about half carry **RUNS DISAGREE**. No number here enters
`docs/costs.md`.

## What the run shows

A rate is the median of the six round medians, in messages per second. "Main over base" is the
median, lowest and highest over the six rounds, of main's rate over the base's rate, minus 1, in
percent.

| candidate | rate, 7bce4d2 | rate, main | main over base: median (lowest to highest) | p50 ns, base to main | p99 ns, base to main | rows that disagreed, base / main |
| --- | ---: | ---: | --- | --- | --- | --- |
| rotor | 496,650 | 590,434 | +17.9 (+16.8 to +33.1) | 1,687 to 1,543 | 6,527 to 6,287 | 3 / 3 of 6 |
| libuv | 579,010 | 595,268 | +1.8 (-2.1 to +5.4) | 1,521 to 1,521 | 6,218 to 5,947 | 4 / 5 of 6 |
| libxev | 515,686 | 517,724 | +0.5 (-0.9 to +2.0) | 1,687 to 1,687 | 6,751 to 6,671 | 3 / 2 of 6 |

| measure, median of six rounds | 7bce4d2 | main |
| --- | ---: | ---: |
| rotor's rate over libuv's, in the same call | 0.836 | 0.986 |

- rotor gained at least 16.8 percent in every round, where libuv and libxev moved less than 5.4.
- The +33.1 comes from round 6, whose base row is low, at a spread of 34 percent.
- On `mac` rotor is now 1.4 percent behind libuv on this row, and 14 percent ahead of libxev. The
  parity bar of decision 2 is not met yet.

## Each round

Each cell is the round's median rate, in messages per second, with that row's spread in
parentheses.

| round | first | rotor, base | rotor, main | libuv, base | libuv, main | libxev, base | libxev, main |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | base | 493,731 (12%) | 576,652 (17%) | 601,265 (17%) | 588,847 (16%) | 506,708 (8%) | 516,739 (6%) |
| 2 | main | 505,122 (9%) | 591,052 (16%) | 573,582 (44%) | 604,296 (17%) | 507,978 (19%) | 514,149 (9%) |
| 3 | base | 504,011 (3%) | 592,641 (9%) | 570,626 (10%) | 598,252 (11%) | 515,519 (10%) | 519,023 (4%) |
| 4 | main | 488,845 (7%) | 590,792 (4%) | 584,439 (14%) | 578,529 (14%) | 516,707 (6%) | 518,709 (3%) |
| 5 | base | 499,569 (12%) | 590,076 (5%) | 597,445 (9%) | 596,013 (4%) | 520,078 (11%) | 519,963 (18%) |
| 6 | main | 438,291 (34%) | 583,466 (28%) | 572,490 (8%) | 594,523 (28%) | 515,853 (2%) | 511,151 (14%) |
