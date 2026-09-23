# Echo, storm, timers and one cross-core message: `github`, 2026-09-22

The `comparison` job of `.github/workflows/ci.yml`, started by hand on commit `c9f8e83`,
run 35788660457. A GitHub-hosted `ubuntu-24.04` runner, io_uring, one core, three runs per row.

**This is the first comparison over all four payload sizes, and the first with memory.** Every row's
spread came in at or under 5 percent and none was flagged, so the rows decide. `bench/baseline/echo.txt`
was taken from this run, and retaken from `echo-sized-pool-github-2026-09-22.md`.

**libuv has no timer or cross-core rows here.** Every libuv run of those workloads failed with
`Malformed`: its programs printed a result line without two fields the harness had added that day,
and the runners exited 0 anyway. `echo-sized-pool-github-2026-09-22.md` says what was fixed.

Two things it settles. rotor leads libuv and libxev at 4 KiB, is level with libuv at 8 and 16 KiB,
and trails libxev at 64 KiB by 5 to 11 percent. And rotor's provided-buffer group holds a flat
37.7 MB whatever the payload or the connection count, where libuv, libxev and rotor's own accumulate
shape all hold 3.1 to 8.7 MB scaling with connections: the pool costs more below roughly 280
connections and less above it.

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 105153 | 420624 | 149503 | 178175 | 217087 | 268287 | 37662720 | 0 | 11 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 105239 | 420967 | 148479 | 195583 | 225279 | 245759 | 4005888 | 0 | 31 | 5 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 101562 | 406264 | 155647 | 207871 | 253951 | 372735 | 3076096 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 94836 | 379350 | 167935 | 192511 | 237567 | 274431 | 3080192 | 0 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 64725 | 258907 | 246783 | 276479 | 348159 | 532479 | 14774272 | 0 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 87477 | 349920 | 180223 | 244735 | 266239 | 296959 | 37658624 | 0 | 7 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 88164 | 352665 | 179199 | 204799 | 246783 | 282623 | 4005888 | 0 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 88519 | 354085 | 178175 | 205823 | 262143 | 315391 | 3207168 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 81753 | 327024 | 194559 | 221183 | 272383 | 294911 | 3211264 | 0 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 57250 | 229003 | 280575 | 311295 | 323583 | 417791 | 11030528 | 4 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 65935 | 263750 | 239615 | 286719 | 335871 | 495615 | 37658624 | 2 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 65988 | 263968 | 238591 | 309247 | 339967 | 385023 | 4005888 | 0 | 7 | 1 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 65624 | 262510 | 239615 | 315391 | 342015 | 532479 | 3366912 | 1 | 23 | 3 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 62136 | 248558 | 253951 | 337919 | 522239 | 708607 | 3366912 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 45611 | 182453 | 350207 | 385023 | 425983 | 688127 | 11034624 | 5 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 20265 | 81072 | 782335 | 892927 | 950271 | 1173640 | 37662720 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 20581 | 82336 | 778239 | 864255 | 1044479 | 1616033 | 4096000 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 20028 | 80119 | 798719 | 884735 | 1105919 | 1541474 | 4096000 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 21355 | 85424 | 745471 | 864255 | 958463 | 1171455 | 4096000 | 2 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 17339 | 69360 | 925695 | 966655 | 1073151 | 1089535 | 14807040 | 0 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 107794 | 431231 | 593919 | 643071 | 765951 | 851967 | 37658624 | 0 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 106535 | 426168 | 598015 | 757759 | 1003519 | 1236991 | 8339456 | 0 | 3 | 1 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 103005 | 412079 | 618495 | 688127 | 933887 | 1204223 | 8339456 | 1 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 100578 | 402345 | 638975 | 684031 | 806911 | 929791 | 8339456 | 3 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 67128 | 268526 | 954367 | 991231 | 1056767 | 1327103 | 49119232 | 1 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 88396 | 353625 | 720895 | 892927 | 1105919 | 1531903 | 37662720 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 89325 | 357312 | 712703 | 905215 | 1187839 | 1474559 | 8368128 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 88713 | 354878 | 724991 | 765951 | 909311 | 983039 | 8368128 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 85781 | 343168 | 745471 | 917503 | 970751 | 1354324 | 8368128 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 58715 | 234875 | 1089535 | 1138687 | 1212415 | 1236991 | 51277824 | 0 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 66500 | 266048 | 958463 | 1163263 | 1294335 | 1858408 | 37658624 | 0 | 7 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 66467 | 265920 | 958463 | 1171455 | 1212415 | 1375966 | 8417280 | 0 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 65734 | 262976 | 970751 | 1220607 | 1269759 | 1900543 | 8417280 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 64490 | 257992 | 987135 | 1220607 | 1277951 | 1347155 | 8417280 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 47692 | 190784 | 1343487 | 1384447 | 1441791 | 1549553 | 49266688 | 1 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 20379 | 81536 | 3145727 | 3325951 | 3506175 | 3926159 | 37662720 | 0 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 20603 | 82432 | 3112959 | 3194879 | 3325951 | 3327480 | 8671232 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 19653 | 78656 | 3244031 | 4194303 | 5734399 | 6013502 | 8671232 | 1 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 22703 | 90876 | 2850815 | 3211263 | 3342335 | 3358719 | 8671232 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 17305 | 69248 | 3719167 | 3850239 | 3915775 | 3943366 | 49119232 | 1 | 3 | 0 |  |
﻿2026-09-22T22:02:44.6186206Z ##[group]Run ./zig-out/bin/echo_runner --workload storm --port-base 31000
^[[36;1m./zig-out/bin/echo_runner --workload storm --port-base 31000^[[0m
shell: /usr/bin/bash -e {0}
env:
  ZIG_VERSION: 0.16.0
##[endgroup]
echo_runner: rotor (accumulate) is not run: it echoes a whole message, and the storm's message is one byte
echo_runner: std.Io.Uring is not run: it does not compile on the pinned Zig
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| accept storm | rotor | this tree | 0 | 16 | 1 | even | 3 | 27636 | 16 | 532479 | 550683 | 550683 | 550683 | 4005888 | 3 | 11 | 1 |  |
| accept storm | libuv | v1.52.1 | 0 | 16 | 1 | even | 3 | 23047 | 16 | 524287 | 646944 | 646944 | 646944 | 2723840 | 4 | 3 | 0 |  |
| accept storm | libxev | 9ce8e8e | 0 | 16 | 1 | even | 3 | 25425 | 16 | 536575 | 582168 | 582168 | 582168 | 2727936 | 3 | 3 | 0 |  |
| accept storm | std.Io.Threaded | 0.16.0 | 0 | 16 | 1 | even | 3 | 16630 | 16 | 737279 | 919095 | 919095 | 919095 | 15249408 | 25 | 0 | 0 | **RUNS DISAGREE** |
| accept storm | rotor | this tree | 0 | 64 | 1 | even | 3 | 29303 | 64 | 2039807 | 2126868 | 2126868 | 2126868 | 4005888 | 23 | 3 | 0 | **RUNS DISAGREE** |
| accept storm | libuv | v1.52.1 | 0 | 64 | 1 | even | 3 | 25053 | 64 | 2015231 | 2374824 | 2374824 | 2374824 | 2772992 | 1 | 7 | 2 |  |
| accept storm | libxev | 9ce8e8e | 0 | 64 | 1 | even | 3 | 27918 | 64 | 2015231 | 2109872 | 2109872 | 2109872 | 2777088 | 1 | 0 | 0 |  |
| accept storm | std.Io.Threaded | 0.16.0 | 0 | 64 | 1 | even | 3 | 19113 | 64 | 3129343 | 3312686 | 3312686 | 3312686 | 49123328 | 2 | 7 | 1 |  |
﻿2026-09-22T22:03:20.8383259Z ##[group]Run ./zig-out/bin/timers_runner
^[[36;1m./zig-out/bin/timers_runner^[[0m
shell: /usr/bin/bash -e {0}
env:
  ZIG_VERSION: 0.16.0
##[endgroup]
timers_runner: std.Io.Uring is not run: it does not compile on the pinned Zig
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
timers_runner: libuv failed at 256 timers: Malformed
timers_runner: libuv (repeating) failed at 256 timers: Malformed
timers_runner: libuv failed at 256 timers: Malformed
timers_runner: libuv (repeating) failed at 256 timers: Malformed
timers_runner: libuv failed at 256 timers: Malformed
timers_runner: libuv (repeating) failed at 256 timers: Malformed
timers_runner: libuv failed at 256 timers: Malformed
timers_runner: libuv (repeating) failed at 256 timers: Malformed
timers_runner: libuv failed at 256 timers: Malformed
timers_runner: libuv (repeating) failed at 256 timers: Malformed
| timer-churn | rotor | this tree | 0 | 256 | 0 | even | 5 | 244751 | 734464 | 46365 | 65064 | 74175 | 74195 | 0 | 0 | 3 | 0 |  |
| timer-churn | rotor (repeating) | this tree | 0 | 256 | 0 | even | 5 | 255991 | 768000 | 43263 | 49423 | 73001 | 73391 | 0 | 0 | 3 | 0 |  |
timers_runner: libuv has too few runs (0)
timers_runner: libuv (repeating) has too few runs (0)
| timer-churn | libxev | 9ce8e8e | 0 | 256 | 0 | even | 5 | 246298 | 739072 | 38703 | 56580 | 80485 | 130168 | 0 | 0 | 3 | 0 |  |
| timer-churn | std.Io.Threaded | 0.16.0 | 0 | 256 | 0 | even | 5 | 234886 | 704912 | 73083 | 130879 | 217057 | 458792 | 0 | 0 | 3 | 0 |  |
timers_runner: libuv failed at 4096 timers: Malformed
timers_runner: libuv (repeating) failed at 4096 timers: Malformed
timers_runner: libuv failed at 4096 timers: Malformed
timers_runner: libuv (repeating) failed at 4096 timers: Malformed
timers_runner: libuv failed at 4096 timers: Malformed
timers_runner: libuv (repeating) failed at 4096 timers: Malformed
timers_runner: libuv failed at 4096 timers: Malformed
timers_runner: libuv (repeating) failed at 4096 timers: Malformed
timers_runner: libuv failed at 4096 timers: Malformed
timers_runner: libuv (repeating) failed at 4096 timers: Malformed
| timer-churn | rotor | this tree | 0 | 4096 | 0 | even | 5 | 2528093 | 7587621 | 672920 | 728705 | 733321 | 736857 | 0 | 2 | 3 | 0 |  |
| timer-churn | rotor (repeating) | this tree | 0 | 4096 | 0 | even | 5 | 4094748 | 12288000 | 464283 | 629315 | 632084 | 632465 | 0 | 0 | 0 | 0 |  |
timers_runner: libuv has too few runs (0)
timers_runner: libuv (repeating) has too few runs (0)
| timer-churn | libxev | 9ce8e8e | 0 | 4096 | 0 | even | 5 | 1157811 | 3474560 | 2547608 | 16573583 | 17354117 | 17466923 | 0 | 0 | 7 | 1 |  |
| timer-churn | std.Io.Threaded | 0.16.0 | 0 | 4096 | 0 | even | 5 | 533849 | 1671743 | 75578 | 208636 | 1080941 | 2031785 | 0 | 9 | 3 | 0 |  |
﻿2026-09-22T22:06:52.9675348Z ##[group]Run ./zig-out/bin/crosscore_runner
^[[36;1m./zig-out/bin/crosscore_runner^[[0m
shell: /usr/bin/bash -e {0}
env:
  ZIG_VERSION: 0.16.0
##[endgroup]
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
crosscore_runner: libuv failed: Malformed
crosscore_runner: libuv failed: Malformed
crosscore_runner: libuv failed: Malformed
crosscore_runner: libuv failed: Malformed
crosscore_runner: libuv failed: Malformed
| cross-core | rotor | this tree | 2 | 1 | 0 | even | 5 | 87174 | 40000 | 12095 | 17919 | 20607 | 45567 | 0 | 4 | 19 | 2 |  |
crosscore_runner: libuv has too few runs (0)
| cross-core | libxev | 9ce8e8e | 2 | 1 | 0 | even | 5 | 74039 | 40000 | 13503 | 18175 | 20863 | 30719 | 0 | 0 | 0 | 0 |  |
```
