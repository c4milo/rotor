# Echo, storm, timers and one cross-core message: `github`, rotor's group sized per connection, 2026-09-22

The `comparison` job of `.github/workflows/ci.yml`, started by hand on commit `86a7ade`, run
35811462374, from 02:43 UTC on 2026-09-23. A GitHub-hosted `ubuntu-24.04` runner: AMD EPYC 9V74,
4 CPUs, Linux 6.17.0-1022-azure. io_uring, one core, three runs per echo and storm row, five per
timer and cross-core row.

It is the first comparison with rotor's buffer group sized to the connections: two buffers per
connection, never fewer than 32 (`bench/echo/echo_runner_setup.zig`). The run before it,
`echo-github-2026-09-22.md`, gave rotor the whole 64 MiB pool. `bench/baseline/echo.txt` was
reseeded from this run.

## Echo

Every row's spread is at or under 3 percent and none is flagged. No row fell behind the baseline
the run was held to, which was the one taken with the whole pool.

| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 136066 | 544269 | 115711 | 150527 | 176127 | 264191 | 3956736 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 136465 | 545868 | 115199 | 155647 | 251903 | 382975 | 3960832 | 1 | 3 | 1 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 130510 | 522054 | 120831 | 174079 | 193535 | 248831 | 3309568 | 1 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 121730 | 486932 | 129535 | 176127 | 189439 | 225279 | 3313664 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 83125 | 332510 | 192511 | 214015 | 222207 | 305151 | 14872576 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 112429 | 449723 | 139263 | 177151 | 204799 | 246783 | 3960832 | 1 | 7 | 2 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 113289 | 453163 | 139263 | 179199 | 196607 | 219135 | 3960832 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 115991 | 463975 | 136191 | 155647 | 197631 | 234495 | 3440640 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 104132 | 416535 | 151551 | 215039 | 229375 | 270335 | 3444736 | 2 | 3 | 1 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 72661 | 290651 | 219135 | 249855 | 258047 | 372735 | 13135872 | 3 | 7 | 2 |  |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 85764 | 343065 | 184319 | 229375 | 248831 | 272383 | 3960832 | 0 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 85554 | 342224 | 184319 | 233471 | 248831 | 280575 | 3960832 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 84836 | 339352 | 186367 | 211967 | 260095 | 344063 | 3600384 | 2 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 80874 | 323507 | 194559 | 251903 | 348159 | 577535 | 3600384 | 2 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 57645 | 230584 | 276479 | 307199 | 317439 | 544767 | 11042816 | 1 | 7 | 1 |  |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 26044 | 104192 | 614399 | 671743 | 724991 | 879195 | 6156288 | 2 | 0 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 26506 | 106032 | 602111 | 679935 | 708607 | 889971 | 4329472 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 25785 | 103153 | 622591 | 655359 | 708607 | 979825 | 4329472 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 28257 | 113040 | 565247 | 651263 | 733183 | 851967 | 4329472 | 2 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 22203 | 88816 | 724991 | 749567 | 786431 | 884735 | 14856192 | 1 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 138324 | 553313 | 458751 | 493567 | 598015 | 741375 | 8572928 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 138846 | 555392 | 460799 | 485375 | 552959 | 671743 | 8572928 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 131967 | 527914 | 485375 | 634879 | 729087 | 962559 | 8572928 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 133410 | 533691 | 479231 | 507903 | 593919 | 753663 | 8572928 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 86070 | 344296 | 745471 | 774143 | 794623 | 815103 | 49188864 | 1 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 115224 | 460924 | 552959 | 651263 | 692223 | 761855 | 8601600 | 0 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 115127 | 460536 | 557055 | 581631 | 684031 | 806911 | 8601600 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 113377 | 453541 | 561151 | 729087 | 753663 | 1138687 | 8601600 | 2 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 110166 | 440696 | 581631 | 630783 | 745471 | 903742 | 8601600 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 75317 | 301305 | 851967 | 872447 | 905215 | 987135 | 49111040 | 0 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 85975 | 343936 | 741375 | 794623 | 933887 | 1179647 | 8642560 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 86377 | 345536 | 741375 | 802815 | 946175 | 1050649 | 8642560 | 0 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 85116 | 340517 | 749567 | 942079 | 1007615 | 1564671 | 8642560 | 1 | 3 | 1 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 84427 | 337728 | 757759 | 790527 | 884735 | 942599 | 8642560 | 1 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 60432 | 241751 | 1064959 | 1089535 | 1187839 | 1646591 | 49238016 | 2 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 26362 | 105472 | 2424831 | 2572287 | 3177127 | 3374770 | 12447744 | 0 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 26453 | 105856 | 2424831 | 2523135 | 2736127 | 2933114 | 8871936 | 0 | 7 | 1 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 25808 | 103296 | 2490367 | 2588671 | 2736127 | 2817622 | 8871936 | 2 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 29035 | 116160 | 2244607 | 2490367 | 2588671 | 2746327 | 8871936 | 2 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 21930 | 87744 | 2916351 | 3129343 | 6684671 | 7140289 | 51298304 | 2 | 3 | 1 |  |

rotor's peak memory fell from 37.7 MB in every row of the earlier run to between 3.96 and 12.4 MB
here, level with the accumulate shape at 4, 8 and 16 KiB. At 64 KiB it holds 6.16 MB at 16
connections and 12.4 MB at 64, against 4.33 and 8.87 MB for libuv, libxev and the accumulate shape.
The group is 32 or 128 buffers of 64 KiB, where the others hold one buffer per connection.

| connections | payload | rotor per second | best other | its rate | its ratio to rotor |
|---:|---:|---:|---|---:|---:|
| 16 | 4096 | 136,066 | libuv | 130,510 | 0.959 |
| 16 | 8192 | 112,429 | libuv | 115,991 | 1.031 |
| 16 | 16384 | 85,764 | libuv | 84,836 | 0.989 |
| 16 | 65536 | 26,044 | libxev | 28,257 | 1.084 |
| 64 | 4096 | 138,324 | libxev | 133,410 | 0.964 |
| 64 | 8192 | 115,224 | libuv | 113,377 | 0.983 |
| 64 | 16384 | 85,975 | libuv | 85,116 | 0.990 |
| 64 | 65536 | 26,362 | libxev | 29,035 | 1.101 |

"Best other" leaves out rotor's own accumulate shape, which is within 2 percent of the group shape
in every row. rotor leads at 4 KiB, is level at 16 KiB, trails libuv by 3 percent at 8 KiB with 16
connections, and trails libxev by 8 and 10 percent at 64 KiB.

## Accept storm

rotor's row at 64 connections is flagged: its three runs disagree by 23 percent, so it decides
nothing. Both `std.Io.Threaded` rows are flagged too.

| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| accept storm | rotor | this tree | 0 | 16 | 1 | even | 3 | 33553 | 16 | 423935 | 448566 | 448566 | 448566 | 3956736 | 5 | 3 | 1 |  |
| accept storm | libuv | v1.52.1 | 0 | 16 | 1 | even | 3 | 28507 | 16 | 428031 | 522356 | 522356 | 522356 | 2871296 | 3 | 3 | 0 |  |
| accept storm | libxev | 9ce8e8e | 0 | 16 | 1 | even | 3 | 31967 | 16 | 434175 | 462045 | 462045 | 462045 | 2875392 | 4 | 3 | 1 |  |
| accept storm | std.Io.Threaded | 0.16.0 | 0 | 16 | 1 | even | 3 | 20022 | 16 | 577535 | 783433 | 783433 | 783433 | 15544320 | 25 | 3 | 0 | **RUNS DISAGREE** |
| accept storm | rotor | this tree | 0 | 64 | 1 | even | 3 | 37476 | 64 | 1589247 | 1658482 | 1658482 | 1658482 | 3956736 | 23 | 3 | 0 | **RUNS DISAGREE** |
| accept storm | libuv | v1.52.1 | 0 | 64 | 1 | even | 3 | 32055 | 64 | 1556479 | 1854433 | 1854433 | 1854433 | 2920448 | 0 | 0 | 0 |  |
| accept storm | libxev | 9ce8e8e | 0 | 64 | 1 | even | 3 | 35855 | 64 | 1572863 | 1631281 | 1631281 | 1631281 | 2924544 | 1 | 0 | 0 |  |
| accept storm | std.Io.Threaded | 0.16.0 | 0 | 64 | 1 | even | 3 | 23186 | 64 | 2654207 | 2713057 | 2713057 | 2713057 | 49348608 | 13 | 0 | 0 | **RUNS DISAGREE** |

## Timer churn

**libuv has no rows here, and none in the run before.** Every libuv run failed with `Malformed`:
its programs printed a result line without `p9999_ns` and `peak_rss_bytes`, two fields the harness
added on 2026-09-22 (`56016c4` and `355d9bb`), and the runner parsed nothing from them. The runner
printed the failures and exited 0, so the job passed. The same commit that records this file fixes
the three libuv programs and makes the timer, cross-core and file-read runners exit with an error
when an installed candidate has no row.

| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| timer-churn | rotor | this tree | 0 | 256 | 0 | even | 5 | 247066 | 741376 | 36459 | 56653 | 73514 | 75717 | 0 | 0 | 3 | 0 |  |
| timer-churn | rotor (repeating) | this tree | 0 | 256 | 0 | even | 5 | 255992 | 768000 | 34204 | 40429 | 49232 | 49532 | 0 | 0 | 3 | 0 |  |
| timer-churn | libxev | 9ce8e8e | 0 | 256 | 0 | even | 5 | 248258 | 744960 | 30500 | 43379 | 64202 | 103829 | 0 | 0 | 3 | 0 |  |
| timer-churn | std.Io.Threaded | 0.16.0 | 0 | 256 | 0 | even | 5 | 235953 | 708117 | 71030 | 122062 | 170969 | 217211 | 0 | 0 | 0 | 0 |  |
| timer-churn | rotor | this tree | 0 | 4096 | 0 | even | 5 | 2746569 | 8241152 | 519655 | 571372 | 575599 | 576220 | 0 | 1 | 3 | 0 |  |
| timer-churn | rotor (repeating) | this tree | 0 | 4096 | 0 | even | 5 | 4095040 | 12288000 | 355534 | 485024 | 487558 | 487888 | 0 | 0 | 0 | 0 |  |
| timer-churn | libxev | 9ce8e8e | 0 | 4096 | 0 | even | 5 | 1493830 | 4482944 | 1759235 | 11185026 | 12073986 | 12122328 | 0 | 0 | 3 | 0 |  |
| timer-churn | std.Io.Threaded | 0.16.0 | 0 | 4096 | 0 | even | 5 | 730123 | 2253726 | 72632 | 309023 | 991166 | 1654490 | 0 | 5 | 0 | 0 |  |

## One cross-core message

libuv has no row, for the reason above.

| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 2 | 1 | 0 | even | 5 | 113196 | 40000 | 9407 | 12671 | 17407 | 31871 | 0 | 4 | 19 | 2 |  |
| cross-core | libxev | 9ce8e8e | 2 | 1 | 0 | even | 5 | 95663 | 40000 | 10431 | 13311 | 15999 | 19455 | 0 | 0 | 0 | 0 |  |
