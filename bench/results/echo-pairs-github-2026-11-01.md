# Paired echo runs of rotor at 92a97d4 and at main, 2026-11-01

The retake of 2026-11-01 (`echo-retake-github-2026-11-01.md`) found that on the AMD EPYC 9V74 and
9V45 almost every ratio rose. A ratio divides another candidate's rate by rotor's. So it cannot show
whether rotor got slower, or the other candidates got faster on those runners. These runs measure
rotor's own echo server before and after, on one runner at a time.

## How the runs were made

- The workflow `.github/workflows/ab-echo.yml` is on the branch `ab-echo`, at `217d936`. That branch
  is never merged.
- The base is `rotor_echo` built at `92a97d4`, of 2026-09-25. The change is `rotor_echo` built at
  `71c44ac`, which was main on 2026-11-01. Both sides use main's `echo_runner` and main's
  `libxev_echo`, so libxev is the same binary on both sides.
- Each job runs four pairs. A pair is one `echo_runner` run of each side: three rounds a row, of
  4 seconds each, on io_uring, on one core. Pairs 1 and 3 run the base first, and pairs 2 and 4 run
  the change first.
- Runs 41308882275 and 41314368830, of 8 jobs each, were started by hand. No job ran on an EPYC
  9V74.

A cell is one job's median, over its four pairs, of the change's rate over the base's rate, minus
1, in percent. A negative cell means main was slower. A pair gives no number when the row's rounds
disagreed on either side. A cell from fewer than four pairs shows their count in parentheses. The
binary of libxev is the same on both sides, so its rows show how far the runner itself drifted.

## What the runs show

- On the EPYC 7763, 9 jobs, every cell of rotor and `rotor (accumulate)` is within 1.5 percent,
  except one of -2.1. libxev's cells are from -2.2 to +1.4.
- On the EPYC 9V45, 3 jobs, rotor's cells are from -3.0 to +2.9, and libxev's from -2.0 to +2.3.
  The first job was slower at 16 connections and 64 KiB for both shapes of rotor. The two later
  jobs were not.
- Single pairs on the 9V45 spread by up to about 10 percent. So a change of less than about 3
  percent does not show there.

So rotor's echo server did not get slower from `92a97d4` to `71c44ac` on the 9V45 or the 7763,
within what these runners can show. The ratios that rose in the retake come from the runners. The
EPYC 9V74 is not checked.

## The jobs

### AMD EPYC 7763 64-Core Processor

| connections | payload | candidate | 124854908302 | 124854908312 | 124854908400 | 124854908463 | 124871198161 | 124871198174 | 124871198200 | 124871198214 | 124871198240 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 16 | 4 KiB | libxev | -1.1 | -0.5 | -0.3 | -0.2 | -0.9 | +0.3 | -0.1 | -0.0 | +0.3 |
| 16 | 4 KiB | rotor | -0.5 | -0.3 | +0.2 | +0.7 | -0.3 | +0.3 | -0.5 | -0.7 | +0.2 |
| 16 | 4 KiB | rotor (accumulate) | +0.5 | +1.1 | +0.1 | +1.5 | +0.5 | +0.2 | +0.0 | +0.3 | -0.2 |
| 16 | 64 KiB | libxev | +0.9 | -0.2 | +0.0 | -0.3 | -0.5 | -0.9 | +1.4 | -1.1 | +0.2 |
| 16 | 64 KiB | rotor | +0.5 | +0.8 | +0.4 | +0.3 | -0.2 | -0.3 | -0.2 | +0.1 | +0.0 |
| 16 | 64 KiB | rotor (accumulate) | -0.1 | -0.0 | +0.0 | -0.2 | -0.5 | +0.2 | -0.3 | +0.7 | -0.0 |
| 64 | 4 KiB | libxev | +0.2 | -0.1 | -0.5 | -0.1 | -0.3 | -0.9 | -0.2 | -0.6 | +0.5 |
| 64 | 4 KiB | rotor | +0.3 | -0.7 | +0.5 | -0.1 | -0.3 | +0.1 | -0.2 | -0.5 | -0.4 |
| 64 | 4 KiB | rotor (accumulate) | -0.3 | +0.4 | +0.1 | +0.1 | -0.2 | -0.4 | -0.3 | +0.4 | +0.1 |
| 64 | 64 KiB | libxev | -1.8 (3) | -0.2 | -0.2 | +0.2 | -0.6 | -1.3 (1) | -0.1 (3) | -2.2 (3) | -0.7 |
| 64 | 64 KiB | rotor | -0.4 | -1.2 | +0.1 | -0.5 | -0.6 | -0.4 | -0.1 | -0.9 | -0.3 |
| 64 | 64 KiB | rotor (accumulate) | -2.1 | +0.4 | +0.3 | +0.2 | -0.4 | +0.6 | -0.1 | -0.4 | -0.7 |

### AMD EPYC 9V45 96-Core Processor

| connections | payload | candidate | 124854908175 | 124871197998 | 124871198226 |
| --- | --- | --- | --- | --- | --- |
| 16 | 4 KiB | libxev | +0.3 | -0.6 | +2.3 |
| 16 | 4 KiB | rotor | -2.4 (3) | -0.4 | -1.4 |
| 16 | 4 KiB | rotor (accumulate) | -0.1 | +0.4 | +2.0 |
| 16 | 64 KiB | libxev | -1.5 | +0.8 | +1.1 (3) |
| 16 | 64 KiB | rotor | -2.6 | +0.9 | +1.6 |
| 16 | 64 KiB | rotor (accumulate) | -3.0 | -0.9 | +0.2 |
| 64 | 4 KiB | libxev | -1.2 | +2.2 | -2.0 |
| 64 | 4 KiB | rotor | -0.8 | +1.9 | +0.8 |
| 64 | 4 KiB | rotor (accumulate) | -1.7 | +1.3 | +0.6 |
| 64 | 64 KiB | libxev | +0.4 | +1.1 | -0.3 |
| 64 | 64 KiB | rotor | +2.9 (3) | +1.1 (3) | +1.6 |
| 64 | 64 KiB | rotor (accumulate) | +0.2 | +0.7 | +1.5 |

### INTEL(R) XEON(R) PLATINUM 8573C

| connections | payload | candidate | 124854908389 | 124854908423 |
| --- | --- | --- | --- | --- |
| 16 | 4 KiB | libxev | +1.4 | +0.7 (3) |
| 16 | 4 KiB | rotor | -0.6 | +0.4 |
| 16 | 4 KiB | rotor (accumulate) | +0.5 | -0.1 |
| 16 | 64 KiB | libxev | +0.6 | -1.2 |
| 16 | 64 KiB | rotor | -0.0 | -0.1 |
| 16 | 64 KiB | rotor (accumulate) | -1.2 | -0.4 |
| 64 | 4 KiB | libxev | -1.7 | -3.2 (3) |
| 64 | 4 KiB | rotor | -0.4 | -0.6 |
| 64 | 4 KiB | rotor (accumulate) | +0.4 | -0.2 |
| 64 | 64 KiB | libxev | -0.4 | +0.1 |
| 64 | 64 KiB | rotor | +0.4 | +0.2 |
| 64 | 64 KiB | rotor (accumulate) | +0.6 | +0.7 |

### Intel(R) Xeon(R) 6973P-C

| connections | payload | candidate | 124871198115 |
| --- | --- | --- | --- |
| 16 | 4 KiB | libxev | -0.3 |
| 16 | 4 KiB | rotor | +0.8 |
| 16 | 4 KiB | rotor (accumulate) | +0.0 |
| 16 | 64 KiB | libxev | +1.8 |
| 16 | 64 KiB | rotor | -1.7 |
| 16 | 64 KiB | rotor (accumulate) | -0.7 |
| 64 | 4 KiB | libxev | -2.0 (1) |
| 64 | 4 KiB | rotor | +2.1 (3) |
| 64 | 4 KiB | rotor (accumulate) | -0.2 |
| 64 | 64 KiB | libxev | -2.0 |
| 64 | 64 KiB | rotor | -2.2 |
| 64 | 64 KiB | rotor (accumulate) | -1.7 |

### Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz

| connections | payload | candidate | 124854908464 |
| --- | --- | --- | --- |
| 16 | 4 KiB | libxev | +0.2 |
| 16 | 4 KiB | rotor | -0.2 |
| 16 | 4 KiB | rotor (accumulate) | +1.7 |
| 16 | 64 KiB | libxev | +2.3 |
| 16 | 64 KiB | rotor | -1.0 |
| 16 | 64 KiB | rotor (accumulate) | +0.6 |
| 64 | 4 KiB | libxev | +0.1 |
| 64 | 4 KiB | rotor | -0.1 |
| 64 | 4 KiB | rotor (accumulate) | -0.7 |
| 64 | 64 KiB | libxev | +2.8 |
| 64 | 64 KiB | rotor | -4.2 (2) |
| 64 | 64 KiB | rotor (accumulate) | +1.1 |
