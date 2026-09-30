# One cross-core message with less of rotor's own work per tick, GitHub macOS runners, 2026-09-29

Decision 12, point 6, its amendment of 2026-09-29. Five changes cut the work a kqueue tick does
itself per message:

1. `drain_mailboxes` and the offload's `drain` no longer fill a 512-byte array of messages first.
   ReleaseSafe writes a pattern over `undefined` memory, and a tick called each of them twice.
2. A tick that had events to hand over and made no kernel call returns without draining again.
3. The tick reads `CLOCK_MONOTONIC_RAW` with `clock_gettime_nsec_np`.
4. A wake's `kevent` call carries no timeout.
5. The mailbox ring writes messages straight into the caller's events (`Mailbox.pop_as`).

`mac` was not quiet that evening: its load average moved between 3 and 38. By Camilo's ruling of
2026-09-29 the rate was taken on GitHub's macOS runners instead, and the change landed on that
evidence. The rate on `mac` is still to be taken.

## Instructions per round trip, `mac`

`/usr/bin/time -l` counts instructions retired, user and kernel together. Each count is a run of
202,000 round trips minus a run of 2,000, divided by the 200,000 between them, so start-up cancels.
A count moves far less with other work than a time does, so these were taken at load averages of 6
to 23. macOS 26.6.2, Apple M1 Pro.

rotor's own code alone, from a program that runs `rotor_post`'s ping-pong on two loops in one
thread, so no tick blocks and no post wakes anyone. The program was not committed. Two runs per
build, which agreed to within one instruction:

| build | instructions per round trip | cycles per round trip |
|---|---:|---:|
| `7bce4d2` | 3,969 | 775 |
| change 1, first form: the arrays filled only for a ring that holds a message | 3,702 | 561 |
| and change 2 | 3,106 | 508 |
| and change 3 | 2,895 | 450 |
| and change 5, which replaced the first form of change 1 | 2,774 | 413 |

Change 4 is in the kernel, so this program cannot see it. A probe of two threads on two kqueues
sending an `EVFILT_USER` trigger back and forth, with no rotor, three runs each:

| how the trigger's call is made | instructions per round trip |
|---|---:|
| no timeout, as libuv makes it | 28,924 to 29,014 |
| a zero timeout, as rotor made it | 29,452 to 29,505 |
| either, both threads user-interactive | no change |

The two-thread `rotor_post` and `libuv_async`, three runs each:

| build | instructions per round trip |
|---|---:|
| rotor, `7bce4d2` | 34,936 to 35,585 |
| rotor, all five changes | 33,505 to 34,579 |
| libuv | 31,003 to 31,135 |

The gap to libuv went from about 4,000 instructions per round trip to about 2,700. The two libraries
make the same `kevent` calls: a library that counted them by dyld interposing found, per 100,000
round trips, 199,488 triggers and 199,514 waits for rotor, and 200,003 and 200,001 for libuv. rotor
also re-armed its wait timer in 2,356 of its calls, and skipped 512 wakes because the receiver had
not gone to sleep yet.

`sample`, the macOS sampling profiler, on the two-thread run put 79 of 4,402 samples outside
`kevent`. Half the samples are a thread waiting for its peer, so rotor's own code is about 4 percent
of the time a thread runs. What is left of the gap is time inside the kernel's wake path.

## The rate, GitHub macOS runners

Run 36660979844 of the `crosscore-ab` workflow, on the branch `experiment/crosscore-gap`, from
02:43 UTC on 2026-09-30. The branch is never merged. Its last two commits add the workflow, the
script `bench/crosscore/scratch_ab.sh`, and two switches: `ROTOR_BENCH_QOS=off` leaves rotor's
threads at the default QoS class, and `LIBUV_BENCH_QOS=on` puts libuv's in the user-interactive
class, as `bench/harness/placement.zig` puts rotor's and libxev's.

Three jobs, each on a `macos-latest` runner of its own: `Apple M1 (Virtual)`, 3 processors, 7 GiB,
macOS 26.6.2 build 25G83. Each built `7bce4d2` and the branch, then ran 10 rounds, each round:

```bash
crosscore_runner --directory "$before" --rounds 5
crosscore_runner --directory "$after" --rounds 5
ROTOR_BENCH_QOS=off crosscore_runner --directory "$after" --rounds 5 --only rotor
LIBUV_BENCH_QOS=on crosscore_runner --directory "$after" --rounds 5 --only libuv
```

The runners' load averages were 24 to 35 when the rounds began and 1.5 to 2.7 when they ended.
Every row the runner printed carried **OTHER WORK**, and most carried **RUNS DISAGREE**. The
instruction counts the script also took read 0: the virtual machine exposes no counters.

Each cell is the median of the runner's 10 round medians, in messages per second:

| candidate | job 109715457974 | job 109715458097 | job 109715458152 |
|---|---:|---:|---:|
| rotor, `7bce4d2` | 249,650 | 241,258 | 222,935 |
| rotor, all five changes | 260,314 | 234,798 | 249,255 |
| libuv | 265,861 | 252,728 | 251,440 |
| libxev | 223,340 | 209,224 | 199,240 |

Each round's rotor after the changes over rotor before them, and rotor over libuv in the same
`crosscore_runner` call:

| measure | job 109715457974 | job 109715458097 | job 109715458152 | all 30 rounds |
|---|---:|---:|---:|---:|
| rotor after over before, median | 1.031 | 1.047 | 1.059 | 1.048 |
| rounds where after was higher | 6 of 10 | 7 of 10 | 9 of 10 | 22 of 30 |
| rotor over libuv, before, median | 0.905 | 0.903 | 0.920 | |
| rotor over libuv, after, median | 0.933 | 0.933 | 0.956 | |

22 of 30 is a one-sided sign-test p of 0.008. The QoS class moved neither library beyond the noise:

| measure, median of 10 rounds | job 109715457974 | job 109715458097 | job 109715458152 |
|---|---:|---:|---:|
| rotor with no QoS class over rotor user-interactive | 1.042 | 0.956 | 0.991 |
| libuv user-interactive over libuv with no QoS class | 1.003 | 0.991 | 1.000 |

These runners have no efficiency cores, so on `mac`, whose scheduler chooses between two kinds of
core, the QoS question is still open.

## Each round

The median rate of each round's five runs, in messages per second.

### Job 109715457974

| round | rotor before | rotor after | libuv before | libuv after | libxev before | libxev after | rotor after, no QoS class | libuv, user-interactive |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 225,964 | 268,091 | 266,473 | 252,770 | 196,539 | 178,015 | 323,954 | 282,888 |
| 2 | 259,048 | 255,622 | 285,347 | 278,926 | 234,497 | 238,698 | 258,426 | 276,501 |
| 3 | 253,854 | 265,005 | 279,070 | 280,627 | 236,046 | 238,346 | 278,959 | 301,786 |
| 4 | 267,557 | 272,639 | 277,620 | 294,012 | 240,902 | 243,537 | 244,821 | 255,768 |
| 5 | 247,767 | 268,557 | 317,418 | 256,654 | 239,325 | 214,408 | 255,464 | 240,911 |
| 6 | 210,453 | 246,268 | 211,481 | 273,396 | 164,141 | 244,987 | 261,676 | 269,701 |
| 7 | 250,517 | 270,950 | 283,044 | 272,102 | 235,322 | 215,608 | 258,705 | 255,322 |
| 8 | 248,784 | 229,286 | 275,598 | 257,478 | 244,306 | 231,071 | 269,642 | 273,952 |
| 9 | 261,982 | 219,066 | 248,499 | 259,620 | 228,069 | 196,616 | 225,982 | 263,183 |
| 10 | 228,754 | 228,070 | 254,723 | 243,067 | 219,161 | 208,492 | 251,128 | 254,479 |

### Job 109715458097

| round | rotor before | rotor after | libuv before | libuv after | libxev before | libxev after | rotor after, no QoS class | libuv, user-interactive |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 220,388 | 262,397 | 258,794 | 250,237 | 215,154 | 202,426 | 228,662 | 237,452 |
| 2 | 215,606 | 231,269 | 241,553 | 249,346 | 205,226 | 208,222 | 221,215 | 248,528 |
| 3 | 237,622 | 238,326 | 260,842 | 263,270 | 208,206 | 207,057 | 236,101 | 237,113 |
| 4 | 222,340 | 227,210 | 273,984 | 249,061 | 213,295 | 207,829 | 245,495 | 245,406 |
| 5 | 248,339 | 275,184 | 271,948 | 244,366 | 238,581 | 227,159 | 219,818 | 280,389 |
| 6 | 212,422 | 199,608 | 221,473 | 255,220 | 192,153 | 184,689 | 230,297 | 278,813 |
| 7 | 247,238 | 292,061 | 247,816 | 279,107 | 212,059 | 239,411 | 277,854 | 295,717 |
| 8 | 247,001 | 229,997 | 279,936 | 245,193 | 203,818 | 210,227 | 219,542 | 241,008 |
| 9 | 244,894 | 229,829 | 263,665 | 258,144 | 224,344 | 233,805 | 241,865 | 290,957 |
| 10 | 255,630 | 286,318 | 285,347 | 290,728 | 236,249 | 241,724 | 261,527 | 256,690 |

### Job 109715458152

| round | rotor before | rotor after | libuv before | libuv after | libxev before | libxev after | rotor after, no QoS class | libuv, user-interactive |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 216,240 | 231,245 | 229,773 | 253,382 | 207,487 | 172,634 | 219,419 | 244,078 |
| 2 | 218,159 | 225,102 | 253,598 | 237,574 | 202,423 | 183,759 | 217,651 | 237,799 |
| 3 | 223,796 | 211,960 | 229,785 | 248,679 | 181,708 | 179,914 | 225,048 | 240,332 |
| 4 | 215,095 | 230,428 | 242,591 | 238,838 | 197,557 | 193,497 | 228,134 | 225,023 |
| 5 | 220,937 | 231,897 | 238,774 | 244,306 | 193,253 | 199,868 | 235,624 | 246,645 |
| 6 | 222,074 | 280,897 | 278,745 | 249,499 | 220,315 | 234,454 | 238,134 | 264,086 |
| 7 | 236,878 | 266,613 | 256,549 | 261,176 | 222,350 | 198,612 | 237,442 | 262,710 |
| 8 | 227,346 | 280,594 | 248,216 | 291,388 | 220,991 | 249,103 | 283,169 | 282,377 |
| 9 | 268,529 | 271,569 | 293,455 | 286,544 | 247,963 | 239,786 | 286,456 | 290,666 |
| 10 | 267,944 | 280,497 | 271,329 | 284,671 | 255,125 | 253,924 | 278,358 | 284,356 |
