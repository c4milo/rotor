# Echo on a GitHub runner with an AMD EPYC 7763, with the client check, 2026-09-24

The `comparison` job of `.github/workflows/ci.yml`, started by hand on commit `5b441cc` as run
36032373559: `echo_runner --baseline bench/baseline/echo.txt`, io_uring, one core, three runs per
row. The runner reported an AMD EPYC 7763 64-Core Processor, 4 processors and Linux
6.17.0-1022-azure. The job held the run to that processor's section of `bench/baseline/echo.txt`.

The run includes the fix of `db9e39e`, in which each piece of a connection's stream keeps its own
buffer, and the client check of `34763cc`: a span fails when a connection ends early, and each
connection compares its first round and one round in 64 with the bytes it sent. No run failed, so
every echo the check sampled came back intact. Its 64 KiB rows became the section's 64 KiB rows.

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 128358 | 513446 | 121855 | 152575 | 201727 | 241663 | 7061504 | 8 | 39 | 11 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 121211 | 484857 | 129535 | 165887 | 207871 | 237567 | 7061504 | 0 | 15 | 2 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 112251 | 449021 | 122879 | 268287 | 290815 | 393215 | 3305472 | 1 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 115062 | 460258 | 137215 | 169983 | 223231 | 258047 | 3309568 | 5 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 64461 | 257852 | 247807 | 282623 | 311295 | 1179647 | 13123584 | 1 | 43 | 7 |  |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 121588 | 486368 | 127999 | 173055 | 236543 | 321535 | 7061504 | 4 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 114341 | 457373 | 136191 | 189439 | 235519 | 282623 | 7061504 | 0 | 7 | 2 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 105473 | 421912 | 130047 | 284671 | 319487 | 382975 | 3436544 | 2 | 15 | 4 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 108256 | 433038 | 144383 | 216063 | 268287 | 348159 | 3440640 | 1 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 61531 | 246135 | 260095 | 296959 | 325631 | 434175 | 13189120 | 2 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 110639 | 442565 | 142335 | 178175 | 278527 | 454655 | 7061504 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 104713 | 418864 | 151551 | 209919 | 251903 | 491519 | 7061504 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 96560 | 386259 | 143359 | 307199 | 335871 | 407551 | 3596288 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 99997 | 400002 | 158719 | 218111 | 255999 | 307199 | 3596288 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 56086 | 224353 | 286719 | 321535 | 344063 | 503807 | 11030528 | 1 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 44561 | 178258 | 356351 | 405503 | 528383 | 647167 | 9158656 | 2 | 0 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 43871 | 175495 | 360447 | 528383 | 606207 | 667647 | 9158656 | 2 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 42587 | 170366 | 368639 | 593919 | 688127 | 917503 | 4325376 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 42862 | 171460 | 368639 | 573439 | 724991 | 802815 | 4325376 | 3 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 28053 | 112217 | 569343 | 622591 | 655359 | 2179071 | 14856192 | 3 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 131372 | 525509 | 487423 | 536575 | 712703 | 860159 | 8552448 | 1 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 122912 | 491693 | 520191 | 651263 | 778239 | 831487 | 8552448 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 111949 | 447873 | 557055 | 1114111 | 1163263 | 1245183 | 8552448 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 121170 | 484733 | 528383 | 733183 | 815103 | 901119 | 8552448 | 0 | 15 | 3 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 68112 | 272461 | 942079 | 1036287 | 1122303 | 1671167 | 49184768 | 6 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 123968 | 495912 | 516095 | 561151 | 729087 | 831487 | 8572928 | 0 | 0 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 115877 | 463550 | 552959 | 712703 | 815103 | 876543 | 8572928 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 107316 | 429332 | 573439 | 1155071 | 1212415 | 1286143 | 8572928 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 115003 | 460067 | 552959 | 679935 | 917503 | 1028095 | 8572928 | 7 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 64208 | 256847 | 999423 | 1081343 | 1130495 | 1466367 | 49102848 | 4 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 110184 | 440758 | 581631 | 638975 | 823295 | 1028095 | 9158656 | 1 | 43 | 7 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 104389 | 417609 | 610303 | 839679 | 905215 | 962559 | 8605696 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 96699 | 386874 | 630783 | 1277951 | 1343487 | 1597439 | 8605696 | 1 | 3 | 1 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 103341 | 413405 | 618495 | 851967 | 913407 | 1105919 | 8605696 | 1 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 58154 | 232643 | 1105919 | 1204223 | 1359871 | 2605055 | 49020928 | 3 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 43374 | 173533 | 1466367 | 1605631 | 2228223 | 2541593 | 15450112 | 3 | 0 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 43399 | 173634 | 1441791 | 2146303 | 2408447 | 2670591 | 11251712 | 2 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 41927 | 167768 | 1384447 | 2752511 | 2965503 | 3178495 | 8765440 | 3 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 42793 | 171218 | 1449983 | 2162687 | 2932735 | 3194879 | 8765440 | 2 | 7 | 1 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 27702 | 110829 | 2310143 | 2457599 | 2883583 | 5275647 | 49197056 | 2 | 3 | 1 |  |
```

The runner's own lines about the echo step:

```text
echo_runner: std.Io.Uring is not run: it does not compile on the pinned Zig
echo_runner: libxev is not in the baseline for this configuration
echo_runner: libuv is not in the baseline for this configuration
echo_runner: libxev is not in the baseline for this configuration
echo_runner: libxev is not in the baseline for this configuration
echo_runner: 0 row(s) fell behind the baseline
```

The same job's CPU step, which runs `echo_client` against each server for 3 seconds at 16
connections, one server at a time:

```text
| payload | server | echoes | cpu µs per echo | busy % | in the kernel % | switches per echo | client busy % |
|---:|---|---:|---:|---:|---:|---:|---:|
| 4096 | rotor (group, the whole pool) | 369320 | 8.04 | 98.9 | 98.0 | 0.006 | 99.7 |
| 4096 | rotor (group, 2048 buffers) | 382109 | 7.85 | 99.9 | 99.0 | 0.000 | 100.0 |
| 4096 | rotor (group, 256 buffers) | 379984 | 7.89 | 100.0 | 98.0 | 0.000 | 100.0 |
| 4096 | rotor (group, 32 buffers) | 379630 | 7.89 | 99.9 | 97.7 | 0.001 | 100.0 |
| 4096 | rotor (accumulate) | 356132 | 8.43 | 100.0 | 98.3 | 0.000 | 100.0 |
| 4096 | libxev | 344940 | 8.70 | 100.0 | 99.7 | 0.000 | 100.0 |
| 65536 | rotor (group, the whole pool) | 122084 | 24.59 | 100.0 | 99.7 | 0.000 | 99.7 |
| 65536 | rotor (group, 2048 buffers) | refused by the server | | | | | |
| 65536 | rotor (group, 256 buffers) | 130273 | 23.02 | 100.0 | 99.0 | 0.001 | 100.3 |
| 65536 | rotor (group, 32 buffers) | 137648 | 21.80 | 100.0 | 99.3 | 0.000 | 100.0 |
| 65536 | rotor (accumulate) | 129007 | 23.23 | 99.9 | 99.3 | 0.001 | 100.0 |
| 65536 | libxev | 124741 | 24.03 | 99.9 | 100.0 | 0.001 | 100.0 |
```
