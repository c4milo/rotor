# Echo on a GitHub runner with an Intel Xeon 6973P-C, with the client check, 2026-09-24

The `comparison` job of `.github/workflows/ci.yml`, started by hand on commit `b50e91a` as run
36034661578: `echo_runner --baseline bench/baseline/echo.txt`, io_uring, one core, three runs per
row. The runner reported an Intel(R) Xeon(R) 6973P-C, 4 processors and Linux 6.17.0-1022-azure. The
job held the run to that processor's section of `bench/baseline/echo.txt`.

The run includes the fix of `db9e39e`, in which each piece of a connection's stream keeps its own
buffer, and the client check of `34763cc`: a span fails when a connection ends early, and each
connection compares its first round and one round in 64 with the bytes it sent. No run failed, so
every echo the check sampled came back intact. Its 64 KiB rows became the section's 64 KiB rows.

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 224041 | 896178 | 70143 | 94719 | 114687 | 146431 | 7061504 | 4 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 217432 | 869744 | 72191 | 101887 | 117759 | 154623 | 7061504 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 184516 | 738083 | 78847 | 168959 | 191487 | 228351 | 3301376 | 1 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 163317 | 653276 | 97279 | 120831 | 140287 | 174079 | 3305472 | 2 | 3 | 1 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 120749 | 483001 | 132095 | 155647 | 180223 | 581631 | 14856192 | 3 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 207694 | 830789 | 75775 | 99327 | 126463 | 162815 | 7057408 | 0 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 199816 | 799280 | 78847 | 112127 | 127999 | 161791 | 7061504 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 168479 | 673935 | 86527 | 184319 | 204799 | 226303 | 3432448 | 2 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 154180 | 616724 | 103935 | 127999 | 145407 | 166911 | 3436544 | 1 | 3 | 1 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 109562 | 438260 | 146431 | 169983 | 184319 | 581631 | 13127680 | 0 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 175571 | 702294 | 90111 | 111103 | 137215 | 175103 | 7061504 | 2 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 176160 | 704654 | 89599 | 114175 | 141311 | 175103 | 7061504 | 2 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 139713 | 558875 | 107007 | 223231 | 244735 | 268287 | 3592192 | 1 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 150065 | 600273 | 105983 | 136191 | 155647 | 190463 | 3592192 | 3 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 90913 | 363661 | 175103 | 203775 | 225279 | 569343 | 11034624 | 1 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 60475 | 241906 | 259071 | 376831 | 417791 | 444415 | 9154560 | 2 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 61536 | 246155 | 257023 | 339967 | 403455 | 436223 | 9158656 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 60334 | 241349 | 258047 | 425983 | 481279 | 557055 | 4321280 | 1 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 57436 | 229751 | 276479 | 382975 | 428031 | 528383 | 4321280 | 2 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 38961 | 155850 | 403455 | 495615 | 518143 | 618495 | 11034624 | 6 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 228323 | 913316 | 278527 | 329727 | 411647 | 518143 | 8548352 | 1 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 228899 | 915640 | 276479 | 339967 | 409599 | 491519 | 8548352 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 190209 | 760907 | 333823 | 401407 | 679935 | 720895 | 8548352 | 1 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 180033 | 720153 | 358399 | 411647 | 438271 | 622591 | 8548352 | 1 | 7 | 1 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 118759 | 475045 | 540671 | 610303 | 638975 | 774143 | 51281920 | 2 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 215458 | 861857 | 294911 | 350207 | 421887 | 505855 | 8568832 | 3 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 213435 | 853779 | 296959 | 360447 | 430079 | 475135 | 8568832 | 2 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 175115 | 700526 | 358399 | 700415 | 753663 | 798719 | 8568832 | 2 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 176381 | 705555 | 362495 | 425983 | 468991 | 622591 | 8568832 | 6 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 106536 | 426176 | 602111 | 679935 | 720895 | 925695 | 49352704 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 181568 | 726308 | 350207 | 405503 | 491519 | 557055 | 9158656 | 0 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 174690 | 698817 | 368639 | 458751 | 507903 | 581631 | 8601600 | 2 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 147873 | 591579 | 421887 | 827391 | 901119 | 995327 | 8601600 | 1 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 170963 | 683921 | 370687 | 464895 | 548863 | 610303 | 8601600 | 2 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 82336 | 329382 | 778239 | 839679 | 872447 | 974847 | 49270784 | 3 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 54302 | 217259 | 1163263 | 1523711 | 1687551 | 1908735 | 15450112 | 1 | 0 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 54696 | 218843 | 1163263 | 1458175 | 1654783 | 1835007 | 11251712 | 2 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 58384 | 233585 | 1089535 | 1261567 | 1540095 | 1662975 | 8761344 | 4 | 3 | 1 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 55770 | 223139 | 1146879 | 1409023 | 1548287 | 2211839 | 8761344 | 1 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 39975 | 159927 | 1597439 | 1736703 | 1810431 | 1998847 | 51376128 | 0 | 0 | 0 |  |
```

The runner's own lines about the echo step:

```text
echo_runner: std.Io.Uring is not run: it does not compile on the pinned Zig
echo_runner: **libxev GAINED ON ROTOR** past the baseline
echo_runner: 1 row(s) fell behind the baseline
```

The same job's CPU step, which runs `echo_client` against each server for 3 seconds at 16
connections, one server at a time:

```text
| payload | server | echoes | cpu µs per echo | busy % | in the kernel % | switches per echo | client busy % |
|---:|---|---:|---:|---:|---:|---:|---:|
| 4096 | rotor (group, the whole pool) | 665379 | 4.51 | 100.0 | 98.3 | 0.000 | 99.7 |
| 4096 | rotor (group, 2048 buffers) | 656731 | 4.54 | 99.3 | 97.3 | 0.004 | 100.0 |
| 4096 | rotor (group, 256 buffers) | 674983 | 4.44 | 99.8 | 97.3 | 0.001 | 100.0 |
| 4096 | rotor (group, 32 buffers) | 686334 | 4.36 | 99.8 | 98.0 | 0.001 | 99.7 |
| 4096 | rotor (accumulate) | 662317 | 4.53 | 100.0 | 97.3 | 0.000 | 99.7 |
| 4096 | libxev | 508375 | 5.63 | 95.4 | 98.9 | 0.053 | 99.7 |
| 65536 | rotor (group, the whole pool) | 177961 | 16.85 | 100.0 | 99.3 | 0.001 | 96.7 |
| 65536 | rotor (group, 2048 buffers) | refused by the server | | | | | |
| 65536 | rotor (group, 256 buffers) | 182424 | 16.44 | 100.0 | 99.3 | 0.001 | 99.7 |
| 65536 | rotor (group, 32 buffers) | 185515 | 16.15 | 99.9 | 99.3 | 0.001 | 100.3 |
| 65536 | rotor (accumulate) | 187914 | 15.96 | 100.0 | 99.0 | 0.001 | 100.0 |
| 65536 | libxev | 176383 | 16.87 | 99.2 | 99.7 | 0.013 | 100.0 |
```
