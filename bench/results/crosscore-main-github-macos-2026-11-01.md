# One cross-core message, 7bce4d2 against main, GitHub macOS runners, 2026-11-01

On 2026-09-29 two changes reached the cross-core row on kqueue. `6e4c0b7` cut a tick's own work per
message (`crosscore-own-work-github-macos-2026-09-29.md`), and `rotor_post` began to send with
`Loop.post` (`crosscore-loop-post-github-macos-2026-09-29.md`). This run checks the row again with
main as the change, to show whether main keeps those gains. `mac` was busy that day, with a 1-minute
load average from 7 to 11, so the rate on `mac` is still to be taken.

## How the run was made

- Run 41347731225 of the `ab-crosscore` workflow, on the branch `ab-crosscore`, from 20:38 UTC on
  2026-11-01. The branch is never merged. It adds only `.github/workflows/ab-crosscore.yml` to main.
- The base is `7bce4d2`, the parent of `6e4c0b7`. The change is `b2825d7`, which was main.
- Three jobs, each on a `macos-latest` runner of its own: `Apple M1 (Virtual)`, 3 processors.
- Each job built both trees, then ran 10 rounds. A round is one `crosscore_runner --rounds 5` call
  for each side, and each side runs its own `crosscore_runner` against its own directory. Odd
  rounds run the base first, and even rounds run main first.
- libuv and libxev are built from the same sources on both sides, so they show how far the runner
  moved between the two sides.

The runners' load averages were 20 to 29 when the rounds began. Most rows carried **RUNS DISAGREE**:
8 to 10 of 10 rounds on jobs 124971058960 and 124971059190, and 4 to 8 on job 124971059157.

## What the run shows

A rate is the median of a job's 10 round medians, in messages per second. "Main over base" is the
median, lowest and highest over the 10 rounds, of main's rate over the base's rate, minus 1, in
percent.

### Job 124971059157, the quietest

| candidate | rate, 7bce4d2 | rate, main | main over base: median (lowest to highest) | p50 ns, base to main | p99 ns, base to main |
| --- | ---: | ---: | --- | --- | --- |
| rotor | 284,526 | 308,671 | +8.9 (+5.4 to +11.9) | 3,439 to 3,215 | 5,535 to 3,983 |
| libuv | 307,488 | 308,292 | -0.0 (-7.2 to +9.7) | 3,208 to 3,208 | 6,437 to 4,041 |
| libxev | 258,380 | 259,323 | +0.2 (-1.1 to +3.9) | 3,799 to 3,791 | 5,183 to 5,967 |

### Job 124971058960

| candidate | rate, 7bce4d2 | rate, main | main over base: median (lowest to highest) | p50 ns, base to main | p99 ns, base to main |
| --- | ---: | ---: | --- | --- | --- |
| rotor | 227,755 | 257,390 | +11.4 (-6.3 to +25.8) | 3,727 to 3,519 | 17,087 to 14,015 |
| libuv | 279,105 | 253,420 | -5.4 (-16.4 to +11.7) | 3,458 to 3,489 | 13,573 to 14,926 |
| libxev | 210,705 | 201,887 | -3.9 (-24.8 to +12.2) | 4,159 to 4,223 | 17,407 to 19,583 |

### Job 124971059190

| candidate | rate, 7bce4d2 | rate, main | main over base: median (lowest to highest) | p50 ns, base to main | p99 ns, base to main |
| --- | ---: | ---: | --- | --- | --- |
| rotor | 248,782 | 255,137 | +6.7 (-14.2 to +87.8) | 3,623 to 3,439 | 16,479 to 15,391 |
| libuv | 269,247 | 270,436 | -2.4 (-15.4 to +23.2) | 3,406 to 3,416 | 13,166 to 15,427 |
| libxev | 217,061 | 210,327 | -4.3 (-19.8 to +21.5) | 4,047 to 4,063 | 14,943 to 21,055 |

### rotor's rate over libuv's in the same call, median of 10 rounds

| job | 7bce4d2 | main |
| --- | ---: | ---: |
| 124971058960 | 0.861 | 0.996 |
| 124971059157 | 0.920 | 1.002 |
| 124971059190 | 0.929 | 1.003 |

On every job rotor's median rose by 6.7 to 11.4 percent, where libuv and libxev moved by -5.4 to
+0.2. On the three runners rotor and libuv are now level on this row. These runners are not a
named machine, so the parity bar of decision 2 is still decided on `mac`.
