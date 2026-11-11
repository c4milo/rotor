# Hot-path ledger

One row per use of a technique that `docs/decisions/0007-hot-path-ugliness.md` confines to the
named hot files. A use with no row here does not land. The harness re-measures every row at each
milestone, and a row whose gain is gone is removed together with the code it justified.

The rows below are the instruction gate's counts per iteration (`bench/work`), for a program that
names no record and adds no poller, with the hint and without it. The tree is d1657ce.

| id | file and function | technique | harness workload | before | after | machine | commit | date |
|---|---|---|---|---|---|---|---|---|
| H1 | ~~`src/kqueue/kqueue.zig`, `tick_dispatched`~~ struck on 2026-11-11 (decision 33, step 3) | `@branchHint(.cold)` | work gate: post, post-operation, timer, batch, wait | 1308, 3184, 1144, 24654, 5368 | 1241, 3051, 1111, 24616, 5336 | `mac`, `/usr/bin/time -l` | d1657ce | 2026-11-06 |
| H2 | ~~`src/uring/uring.zig`, `tick_dispatched`~~ struck on 2026-11-11 (decision 33, step 3) | `@branchHint(.cold)` | work gate: post, post-operation, timer, batch | 1090, 2878, 1057, 23782 | 1046, 2794, 1031, 23757 | arm64 container on `mac`, cachegrind | d1657ce | 2026-11-06 |
| H3 | ~~`src/epoll/epoll.zig`, `tick_dispatched`~~ struck on 2026-11-11 (decision 33, step 3) | `@branchHint(.cold)` | work gate: post, post-operation, timer, batch | 1265, 3163, 1115, 23870 | 1217, 3070, 1092, 23845 | arm64 container on `mac`, cachegrind | d1657ce | 2026-11-06 |
| H4 | `src/uring/uring_submit.zig`, `flush`, its call of `send_wakes` | `@call(.always_inline, ...)` | work gate on io_uring: post, post-operation, task, record, poller | 1061, 2823, 544, 1143, 510 | 1043, 2787, 535, 1134, 501 | arm64 container on `mac`, cachegrind | this commit | 2026-11-06 |
| H5 | `src/core/stall.zig`, `Heartbeat.check_turn` | `noinline` | work gate on io_uring, then epoll: post, post-operation, task, record, poller | 1067, 2835, 559, 1156, 519; 1234, 3103, 634, 1218, 598 | 1061, 2823, 556, 1153, 516; 1228, 3091, 631, 1215, 595 | arm64 container on `mac`, cachegrind | this commit | 2026-11-06 |
| H6 | `src/uring/uring_reap.zig`, `take_reserved` | `noinline` and `@branchHint(.cold)` | work gate on io_uring: post, post-operation, timer, task, record, poller | 1099, 3007, 1103, 578, 1232, 536 | 1067, 2943, 1087, 562, 1216, 520 | arm64 container on `mac`, cachegrind | 0ce36b5 | 2026-11-08 |
| H7 | `src/epoll/epoll.zig`, `take_reserved` | `noinline` and `@branchHint(.cold)` | work gate on epoll: post, post-operation, wait, task, record, poller | 1174, 3073, 644, 610, 1246, 569 | 1142, 3009, 628, 594, 1230, 553 | arm64 container on `mac`, cachegrind | 0ce36b5 | 2026-11-08 |
| H8 | `src/kqueue/kqueue_reap.zig`, `take_reserved` | `noinline` and `@branchHint(.cold)` | work gate on kqueue: post, post-operation, task, record, poller | 1239, 3174, 631, 1312, 585 | 1202, 3112, 613, 1295, 568 | `mac`, `/usr/bin/time -l`, the median of three runs each | 0ce36b5 | 2026-11-08 |
| H9 | `src/reactor/reactor_tick.zig`, `tick_dispatched` | `@branchHint(.cold)` | work gate on io_uring: task, tasks-64, record, poller, tasks-groups-4, tasks-groups-16, call | 542, 3956, 1187, 497, 12400, 13072, 2377 | 534, 3884, 1182, 493, 12300, 12996, 2360 | arm64 container on `mac`, cachegrind | branch `d33-step-3` | 2026-11-11 |

Without the hint the compiler inlines `tick_dispatched` into `tick`, and every tick saves more
registers, also when it skips the dispatch. The counts are the same on every run, so the gain is
above the noise, which is 0.

Rows H1 to H3 were struck on 2026-11-11. Decision 33, step 3, moved `tick_dispatched` to the
reactor, and the plain tick's branch now goes to `take_kept_error`. That function was counted with
a cold hint and without it in each backend file. On arm64 Linux, all 23 rows of both backends
counted the same both ways. On `mac`, the medians of three runs differed by at most 1. So no
backend file holds the hint.

Row H9: the same hint, on the reactor's `tick_dispatched`. The row's counts are from io_uring,
where the hint gains the most. On epoll, without the hint and then with it: task 593 and 592,
tasks-64 3945 and 3942, record 1220 and 1223, poller 548 and 550, tasks-groups-4 12360 and 12358,
tasks-groups-16 13068 and 13054, call 2546 and 2543. On `mac`, the medians of three runs: task 609
and 608, tasks-64 4535 and 4534, record 1274 and 1277, poller 554 and 561, tasks-groups-4 12877
and 12879, tasks-groups-16 13585 and 13574, call 2651 and 2638. The hint loses on `record` and
`poller` on epoll and on `mac`, and gains on every other row, so it stays.

Since 2026-11-06 the gate also holds the cold path. Its `record` and `poller` workloads take
`tick_dispatched` in each iteration, so a change that makes that path slower fails the gate too.

Row H5: without `noinline` the compiler inlines the cold turn check into each backend's tick, and
each tick on arm64 Linux counts 3 instructions more. On `mac` the hint moves no row by more than
the run-to-run spread of 2 instructions: `post` counted 1247 and `poller` 588, with the hint and
without it, each the median of three runs.

Rows H6 to H8: the slow path of a drain's reserved tags, a call, a return or a wake (decision 32).
Each backend hands it to `core.inbox`'s drain as a function, from a file that decision 7 names.
The drain returns what the slow path returns, so no value of the drain lives across the call.
Without the hints the compiler inlines the slow path into the drain, and each tick counts 16 to 64
instructions more. Camilo amended decision 7 for these rows on 2026-11-08, and they were
measured again that day, on the tree of decision 32's finish.
