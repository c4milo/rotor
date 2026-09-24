# Echo on a GitHub runner with an AMD EPYC 9V74, with the client check, 2026-09-24

The `comparison` job of `.github/workflows/ci.yml`, started by hand on commit `5b441cc` as run
36032383576: `echo_runner --baseline bench/baseline/echo.txt`, io_uring, one core, three runs per
row. The runner reported an AMD EPYC 9V74 80-Core Processor, 4 processors and Linux
6.17.0-1022-azure. The job held the run to that processor's section of `bench/baseline/echo.txt`.

The run includes the fix of `db9e39e`, in which each piece of a connection's stream keeps its own
buffer, and the client check of `34763cc`: a span fails when a connection ends early, and each
connection compares its first round and one round in 64 with the bytes it sent. No run failed, so
every echo the check sampled came back intact. Its rows became the whole section, first its
64 KiB rows and then the rest.

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 163377 | 653520 | 96767 | 110591 | 135167 | 154623 | 7028736 | 0 | 7 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 154606 | 618438 | 102399 | 131071 | 156671 | 175103 | 7028736 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 129898 | 519613 | 114687 | 236543 | 254975 | 284671 | 3166208 | 1 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 146786 | 587167 | 108031 | 142335 | 163839 | 200703 | 3170304 | 1 | 27 | 4 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 94293 | 377181 | 169983 | 187391 | 194559 | 274431 | 14888960 | 1 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 155079 | 620326 | 101887 | 120319 | 140287 | 162815 | 7028736 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 148702 | 594823 | 106495 | 134143 | 154623 | 179199 | 7028736 | 1 | 7 | 1 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 124228 | 496930 | 118783 | 244735 | 260095 | 301055 | 3297280 | 1 | 7 | 1 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 139789 | 559167 | 112639 | 145407 | 167935 | 187391 | 3301376 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 89543 | 358185 | 178175 | 196607 | 209919 | 516095 | 11042816 | 0 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 137806 | 551230 | 114687 | 133119 | 165887 | 189439 | 7028736 | 4 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 134553 | 538229 | 117759 | 149503 | 179199 | 200703 | 7028736 | 2 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 113494 | 453996 | 132095 | 274431 | 288767 | 309247 | 3457024 | 1 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 128411 | 513655 | 123391 | 144383 | 179199 | 206847 | 3457024 | 2 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 81285 | 325148 | 195583 | 218111 | 229375 | 317439 | 13090816 | 1 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 51249 | 205006 | 309247 | 446463 | 481279 | 507903 | 9125888 | 0 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 52472 | 209898 | 303103 | 440319 | 475135 | 505855 | 9125888 | 0 | 7 | 1 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 48804 | 195235 | 321535 | 487423 | 540671 | 598015 | 4186112 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 51831 | 207341 | 305151 | 448511 | 614399 | 651263 | 4186112 | 0 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 36499 | 145999 | 440319 | 464895 | 485375 | 618495 | 13135872 | 0 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 164149 | 656634 | 389119 | 413695 | 471039 | 565247 | 8413184 | 1 | 7 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 156607 | 626476 | 407551 | 544767 | 667647 | 884735 | 8413184 | 0 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 132691 | 530835 | 481279 | 511999 | 606207 | 929791 | 8413184 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 155017 | 620135 | 411647 | 573439 | 614399 | 651263 | 8413184 | 0 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 95311 | 381278 | 675839 | 696319 | 704511 | 1028095 | 49229824 | 1 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 151550 | 606208 | 421887 | 446463 | 548863 | 647167 | 8433664 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 147224 | 588948 | 434175 | 479231 | 634879 | 655359 | 8433664 | 0 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 126491 | 506038 | 505855 | 561151 | 651263 | 974847 | 8433664 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 145557 | 582280 | 438271 | 610303 | 651263 | 671743 | 8433664 | 0 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 90822 | 363297 | 708607 | 729087 | 745471 | 794623 | 49364992 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 137794 | 551208 | 462847 | 499711 | 585727 | 610303 | 9125888 | 0 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 131811 | 527291 | 485375 | 557055 | 704511 | 741375 | 8466432 | 0 | 39 | 7 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 114753 | 459084 | 557055 | 593919 | 720895 | 1019903 | 8466432 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 130880 | 523581 | 489471 | 630783 | 716799 | 745471 | 8466432 | 0 | 3 | 1 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 82352 | 329433 | 778239 | 806911 | 827391 | 1179647 | 49233920 | 0 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 51947 | 207821 | 1220607 | 1744895 | 1875967 | 1998847 | 15417344 | 0 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 54707 | 218892 | 1163263 | 1302527 | 1777663 | 1933311 | 11223040 | 0 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 47729 | 190929 | 1343487 | 1449983 | 1613823 | 2277375 | 8617984 | 4 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 54216 | 216930 | 1171455 | 1318911 | 2326527 | 2441215 | 8617984 | 0 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 35730 | 142973 | 1794047 | 1875967 | 1925119 | 1990655 | 49152000 | 0 | 3 | 1 |  |
```

The runner's own lines about the echo step:

```text
echo_runner: std.Io.Uring is not run: it does not compile on the pinned Zig
echo_runner: 0 row(s) fell behind the baseline
```

The same job's CPU step, which runs `echo_client` against each server for 3 seconds at 16
connections, one server at a time:

```text
| payload | server | echoes | cpu µs per echo | busy % | in the kernel % | switches per echo | client busy % |
|---:|---|---:|---:|---:|---:|---:|---:|
| 4096 | rotor (group, the whole pool) | 481436 | 6.22 | 99.8 | 99.0 | 0.002 | 100.0 |
| 4096 | rotor (group, 2048 buffers) | 490728 | 6.11 | 100.0 | 98.3 | 0.000 | 100.0 |
| 4096 | rotor (group, 256 buffers) | 491989 | 6.10 | 100.0 | 98.7 | 0.000 | 100.0 |
| 4096 | rotor (group, 32 buffers) | 494128 | 6.07 | 100.0 | 98.3 | 0.000 | 100.3 |
| 4096 | rotor (accumulate) | 462237 | 6.49 | 100.0 | 97.7 | 0.000 | 100.3 |
| 4096 | libxev | 441677 | 6.79 | 100.0 | 99.7 | 0.000 | 100.0 |
| 65536 | rotor (group, the whole pool) | 141342 | 21.23 | 100.0 | 99.7 | 0.000 | 98.3 |
| 65536 | rotor (group, 2048 buffers) | refused by the server | | | | | |
| 65536 | rotor (group, 256 buffers) | 152096 | 19.73 | 100.0 | 99.7 | 0.000 | 100.0 |
| 65536 | rotor (group, 32 buffers) | 154669 | 19.40 | 100.0 | 99.3 | 0.001 | 100.3 |
| 65536 | rotor (accumulate) | 156806 | 19.14 | 100.0 | 99.7 | 0.000 | 100.3 |
| 65536 | libxev | 156082 | 19.23 | 100.0 | 99.7 | 0.000 | 100.0 |
```
