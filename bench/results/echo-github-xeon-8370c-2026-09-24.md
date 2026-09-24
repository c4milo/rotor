# Echo on a GitHub runner with an Intel Xeon Platinum 8370C, 2026-09-24

The `comparison` job of `.github/workflows/ci.yml`, started by hand on commit `a31f1a4` as run
36028154840: `echo_runner --baseline bench/baseline/echo.txt`, io_uring, one core, three runs per
row. The runner reported an Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz, 4 processors and Linux
6.17.0-1022-azure. `bench/baseline/echo.txt` had no section for that processor, so the gate held
nothing and printed this run's ratios. They became that file's Xeon 8370C section. No row carries a
verdict.

It is the first comparison taken after the fix of `db9e39e`, in which each piece of a
connection's stream keeps its own buffer and one send goes out at a time
(`bench/alternatives/README.md`, "A third bug in rotor_echo"). It also includes `f902ffd` and
`a31f1a4`, which let a loop spin before it blocks when its caller asks; `rotor_echo` does not ask.
Its client is the one from before `34763cc`, which counted the echoed bytes and did not compare
them.

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 205664 | 822671 | 76287 | 101375 | 122367 | 149503 | 7061504 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 194636 | 778555 | 80895 | 109567 | 127487 | 150527 | 7061504 | 0 | 7 | 1 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 171809 | 687255 | 81919 | 174079 | 192511 | 234495 | 3248128 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 185160 | 740653 | 85503 | 110591 | 133119 | 157695 | 3252224 | 2 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 104536 | 418151 | 153599 | 168959 | 175103 | 234495 | 14860288 | 0 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 191027 | 764117 | 82943 | 105983 | 130047 | 148479 | 7061504 | 0 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 181885 | 727556 | 87039 | 114175 | 135167 | 158719 | 7061504 | 0 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 156584 | 626355 | 90111 | 194559 | 219135 | 242687 | 3379200 | 1 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 171391 | 685575 | 92159 | 128511 | 156671 | 176127 | 3383296 | 2 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 96504 | 386022 | 165887 | 184319 | 191487 | 350207 | 11030528 | 0 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 164736 | 658958 | 96255 | 111615 | 150527 | 184319 | 7057408 | 0 | 7 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 159741 | 638981 | 99327 | 133119 | 155647 | 176127 | 7061504 | 0 | 19 | 3 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 132552 | 530228 | 108543 | 235519 | 259071 | 290815 | 3538944 | 1 | 3 | 1 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 150827 | 603320 | 104447 | 134143 | 162815 | 185343 | 3538944 | 1 | 3 | 1 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 81402 | 325616 | 196607 | 219135 | 228351 | 325631 | 14827520 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 49517 | 198082 | 321535 | 464895 | 493567 | 528383 | 9158656 | 4 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 49485 | 197954 | 321535 | 411647 | 473087 | 520191 | 9154560 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 49069 | 196290 | 317439 | 495615 | 561151 | 622591 | 4268032 | 3 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 49463 | 197868 | 323583 | 393215 | 444415 | 614399 | 4268032 | 2 | 3 | 1 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 36763 | 147059 | 436223 | 466943 | 483327 | 733183 | 14794752 | 3 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 206829 | 827328 | 309247 | 342015 | 444415 | 505855 | 8511488 | 3 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 202207 | 808862 | 315391 | 352255 | 477183 | 516095 | 8511488 | 1 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 176489 | 706037 | 337919 | 696319 | 733183 | 782335 | 8511488 | 1 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 198176 | 792737 | 321535 | 370687 | 475135 | 548863 | 8511488 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 104590 | 418393 | 614399 | 651263 | 671743 | 925695 | 51523584 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 191576 | 766343 | 331775 | 370687 | 475135 | 552959 | 8540160 | 1 | 7 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 183582 | 734390 | 346111 | 442367 | 569343 | 606207 | 8540160 | 0 | 7 | 1 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 160325 | 641373 | 382975 | 778239 | 823295 | 872447 | 8540160 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 183627 | 734573 | 350207 | 440319 | 497663 | 561151 | 8540160 | 1 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 96407 | 385651 | 663551 | 700415 | 720895 | 897023 | 49074176 | 2 | 3 | 1 |  |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 154780 | 619133 | 413695 | 458751 | 598015 | 671743 | 9158656 | 5 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 146977 | 587972 | 434175 | 522239 | 593919 | 675839 | 8581120 | 4 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 135193 | 540844 | 438271 | 897023 | 962559 | 1056767 | 8581120 | 3 | 3 | 1 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 146884 | 587591 | 436223 | 520191 | 581631 | 778239 | 8581120 | 4 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 82119 | 328518 | 782335 | 819199 | 843775 | 1359871 | 49065984 | 3 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 50005 | 200070 | 1277951 | 1564671 | 1777663 | 1990655 | 15450112 | 5 | 7 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 48729 | 194936 | 1310719 | 1662975 | 1802239 | 1982463 | 11251712 | 3 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 50890 | 203584 | 1236991 | 1351679 | 1499135 | 2072575 | 8810496 | 3 | 3 | 1 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 49172 | 196736 | 1302527 | 1712127 | 1892351 | 2490367 | 8810496 | 3 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 35456 | 141886 | 1802239 | 2047999 | 2211839 | 2244607 | 49078272 | 4 | 0 | 0 |  |
```

The same job's CPU step agreed with the 64 KiB rows. At 16 connections rotor's group of 32
buffers spent 20.15 µs of server time per 64 KiB echo, and libxev 19.89 µs.
