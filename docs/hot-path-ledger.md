# Hot-path ledger

One row per use of a technique that `docs/decisions/0007-hot-path-ugliness.md` confines to the
named hot files. A use with no row here does not land. The harness re-measures every row at each
milestone, and a row whose gain is gone is removed together with the code it justified.

The rows below are the instruction gate's counts per iteration (`bench/work`), for a program that
names no record and adds no poller, with the hint and without it. The tree is d1657ce.

| id | file and function | technique | harness workload | before | after | machine | commit | date |
|---|---|---|---|---|---|---|---|---|
| H1 | `src/kqueue/kqueue.zig`, `tick_dispatched` | `@branchHint(.cold)` | work gate: post, post-operation, timer, batch, wait | 1308, 3184, 1144, 24654, 5368 | 1241, 3051, 1111, 24616, 5336 | `mac`, `/usr/bin/time -l` | d1657ce | 2026-11-06 |
| H2 | `src/uring/uring.zig`, `tick_dispatched` | `@branchHint(.cold)` | work gate: post, post-operation, timer, batch | 1090, 2878, 1057, 23782 | 1046, 2794, 1031, 23757 | arm64 container on `mac`, cachegrind | d1657ce | 2026-11-06 |
| H3 | `src/epoll/epoll.zig`, `tick_dispatched` | `@branchHint(.cold)` | work gate: post, post-operation, timer, batch | 1265, 3163, 1115, 23870 | 1217, 3070, 1092, 23845 | arm64 container on `mac`, cachegrind | d1657ce | 2026-11-06 |
| H4 | `src/uring/uring_submit.zig`, `flush`, its call of `send_wakes` | `@call(.always_inline, ...)` | work gate on io_uring: post, post-operation, task, record, poller | 1061, 2823, 544, 1143, 510 | 1043, 2787, 535, 1134, 501 | arm64 container on `mac`, cachegrind | this commit | 2026-11-06 |
| H5 | `src/core/stall.zig`, `Heartbeat.check_turn` | `noinline` | work gate on io_uring, then epoll: post, post-operation, task, record, poller | 1067, 2835, 559, 1156, 519; 1234, 3103, 634, 1218, 598 | 1061, 2823, 556, 1153, 516; 1228, 3091, 631, 1215, 595 | arm64 container on `mac`, cachegrind | this commit | 2026-11-06 |
| H6 | `src/uring/uring_reap.zig`, `take_reserved` | `noinline` and `@branchHint(.cold)` | work gate on io_uring: post, post-operation, timer, task, record, poller | 1111, 3037, 1109, 587, 1241, 544 | 1091, 2997, 1099, 577, 1231, 534 | arm64 container on `mac`, cachegrind | this commit | 2026-11-07 |
| H7 | `src/epoll/epoll.zig`, `take_reserved` | `noinline` and `@branchHint(.cold)` | work gate on epoll: post, post-operation, wait, task, record, poller | 1192, 3103, 650, 619, 1255, 577 | 1172, 3064, 640, 609, 1245, 567 | arm64 container on `mac`, cachegrind | this commit | 2026-11-07 |
| H8 | `src/kqueue/kqueue_reap.zig`, `take_reserved` | `noinline` and `@branchHint(.cold)` | work gate on kqueue: post, post-operation, task, record, poller | 1229 and 1238, 3156 and 3167, 625 and 630, 1304 and 1315, 579 and 581 | 1226, 3151, 624, 1303, 574 | `mac`, `/usr/bin/time -l`, a load average of about 30 | this commit | 2026-11-07 |

Without the hint the compiler inlines `tick_dispatched` into `tick`, and every tick saves more
registers, also when it skips the dispatch. The counts are the same on every run, so the gain is
above the noise, which is 0.

Since 2026-11-06 the gate also holds the cold path. Its `record` and `poller` workloads take
`tick_dispatched` in each iteration, so a change that makes that path slower fails the gate too.

Row H5: without `noinline` the compiler inlines the cold turn check into each backend's tick, and
each tick on arm64 Linux counts 3 instructions more. On `mac` the hint moves no row by more than
the run-to-run spread of 2 instructions: `post` counted 1247 and `poller` 588, with the hint and
without it, each the median of three runs.

Rows H6 to H8: the slow path of a drain's reserved tags, a call, a return or a wake (decision 32).
`core.inbox` hands it to the drain as a function, and each backend hands it its own, from a file
that decision 7 names. Without the hint the compiler inlines it into the drain, and each tick
counts more instructions. On `mac` the gain is near the run-to-run spread: row H8 gives the two
runs with no hint, and the median of three runs with it.
