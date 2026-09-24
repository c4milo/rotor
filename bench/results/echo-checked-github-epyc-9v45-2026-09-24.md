# Echo on a GitHub runner with an AMD EPYC 9V45, with the client check, 2026-09-24

The `comparison` job of `.github/workflows/ci.yml`, started by hand on commit `5b441cc` as run
36032363409: `echo_runner --baseline bench/baseline/echo.txt`, io_uring, one core, three runs per
row. The runner reported an AMD EPYC 9V45 96-Core Processor, 4 processors and Linux
6.17.0-1022-azure. The job held the run to that processor's section of `bench/baseline/echo.txt`.

The run includes the fix of `db9e39e`, in which each piece of a connection's stream keeps its own
buffer, and the client check of `34763cc`: a span fails when a connection ends early, and each
connection compares its first round and one round in 64 with the bytes it sent. No run failed, so
every echo the check sampled came back intact. Its 64 KiB rows became the section's 64 KiB rows.

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 161414 | 645666 | 98303 | 124415 | 261119 | 532479 | 7028736 | 2 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 152570 | 610297 | 103423 | 120831 | 149503 | 167935 | 7028736 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 142033 | 568148 | 97791 | 207871 | 224255 | 362495 | 3166208 | 7 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 149236 | 596955 | 105471 | 126463 | 160767 | 305151 | 3170304 | 3 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 103946 | 415794 | 152575 | 171007 | 180223 | 446463 | 11042816 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 156788 | 627158 | 100351 | 129023 | 147455 | 173055 | 7028736 | 5 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 150534 | 602147 | 105471 | 122879 | 149503 | 178175 | 7028736 | 3 | 7 | 1 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 137084 | 548356 | 101887 | 215039 | 290815 | 585727 | 3297280 | 4 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 147399 | 589608 | 107519 | 134143 | 372735 | 577535 | 3301376 | 3 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 102039 | 408160 | 154623 | 178175 | 194559 | 720895 | 14819328 | 4 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 147059 | 588247 | 107519 | 122367 | 133119 | 175103 | 7028736 | 4 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 138584 | 554370 | 115199 | 134143 | 247807 | 329727 | 7028736 | 3 | 3 | 1 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 123085 | 492358 | 110591 | 250879 | 540671 | 831487 | 3457024 | 5 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 132565 | 530272 | 116735 | 136191 | 167935 | 471039 | 3457024 | 2 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 94202 | 376818 | 169983 | 188415 | 280575 | 481279 | 14852096 | 2 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 58948 | 235806 | 266239 | 405503 | 421887 | 704511 | 9125888 | 3 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 58988 | 235962 | 270335 | 393215 | 415743 | 598015 | 9121792 | 5 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 57510 | 230053 | 276479 | 411647 | 522239 | 974847 | 4186112 | 2 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 57829 | 231324 | 272383 | 409599 | 536575 | 806911 | 4186112 | 0 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 47256 | 189030 | 335871 | 458751 | 712703 | 815103 | 11042816 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 160984 | 643970 | 397311 | 421887 | 454655 | 561151 | 8413184 | 0 | 7 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 150613 | 602495 | 411647 | 626687 | 1073151 | 1400831 | 8413184 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 139434 | 557806 | 454655 | 880639 | 933887 | 1122303 | 8413184 | 2 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 150887 | 603612 | 417791 | 614399 | 1196031 | 1622015 | 8413184 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 104692 | 418783 | 614399 | 663551 | 872447 | 1261567 | 48988160 | 1 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 156422 | 625709 | 409599 | 442367 | 497663 | 774143 | 8433664 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 146066 | 584324 | 436223 | 634879 | 991231 | 1335295 | 8433664 | 3 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 134841 | 539438 | 471039 | 552959 | 950271 | 1011711 | 8433664 | 5 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 147541 | 590202 | 432127 | 602111 | 655359 | 860159 | 8433664 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 101485 | 405953 | 630783 | 671743 | 716799 | 954367 | 49086464 | 2 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 144166 | 576693 | 444415 | 477183 | 565247 | 917503 | 9125888 | 1 | 0 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 135371 | 541547 | 471039 | 638975 | 700415 | 729087 | 8466432 | 1 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 126847 | 507455 | 495615 | 978943 | 1028095 | 1490943 | 8466432 | 1 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 134795 | 539236 | 473087 | 647167 | 716799 | 978943 | 8466432 | 6 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 95610 | 382450 | 671743 | 729087 | 1466367 | 1646591 | 49262592 | 4 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 62628 | 250539 | 1015807 | 1130495 | 1515519 | 1645325 | 15417344 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 62280 | 249174 | 1023999 | 1433599 | 1548287 | 1605631 | 11223040 | 2 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 61805 | 247265 | 1032191 | 1523711 | 1777663 | 2244607 | 8617984 | 2 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 61796 | 247238 | 1028095 | 1515519 | 2031615 | 2392063 | 8617984 | 2 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 49728 | 198965 | 1286143 | 1376255 | 1400831 | 1449983 | 49106944 | 0 | 3 | 0 |  |
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
| 4096 | rotor (group, the whole pool) | 476823 | 6.29 | 99.9 | 99.0 | 0.000 | 99.3 |
| 4096 | rotor (group, 2048 buffers) | 482555 | 6.21 | 99.9 | 98.7 | 0.000 | 100.0 |
| 4096 | rotor (group, 256 buffers) | 491190 | 6.11 | 100.0 | 98.7 | 0.000 | 100.0 |
| 4096 | rotor (group, 32 buffers) | 487293 | 6.16 | 100.0 | 98.0 | 0.000 | 100.0 |
| 4096 | rotor (accumulate) | 463020 | 6.48 | 100.0 | 99.3 | 0.000 | 100.0 |
| 4096 | libxev | 470952 | 6.37 | 100.0 | 99.7 | 0.000 | 100.0 |
| 65536 | rotor (group, the whole pool) | 178101 | 16.84 | 100.0 | 99.3 | 0.000 | 99.7 |
| 65536 | rotor (group, 2048 buffers) | refused by the server | | | | | |
| 65536 | rotor (group, 256 buffers) | 179698 | 16.69 | 100.0 | 99.7 | 0.000 | 100.0 |
| 65536 | rotor (group, 32 buffers) | 186642 | 16.07 | 100.0 | 99.7 | 0.000 | 100.3 |
| 65536 | rotor (accumulate) | 177790 | 16.87 | 100.0 | 99.7 | 0.000 | 100.0 |
| 65536 | libxev | 177431 | 16.88 | 99.8 | 99.7 | 0.001 | 100.0 |
```
