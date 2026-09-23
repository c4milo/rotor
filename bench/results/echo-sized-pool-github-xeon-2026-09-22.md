# Echo, CPU and kernel calls: `github` on an Intel Xeon 6973P-C, 2026-09-22

The `comparison` job of `.github/workflows/ci.yml`, started by hand on commit `ba273fd`, run
35813656107, from 03:16 UTC on 2026-09-23. A GitHub-hosted `ubuntu-24.04` runner: Intel Xeon
6973P-C, 4 CPUs, Linux 6.17.0-1022-azure. io_uring, one core, three runs per echo row. rotor's
buffer group is sized per connection, as in `echo-sized-pool-github-2026-09-22.md`, which is the
same comparison on an AMD EPYC 9V74 one run earlier.

**The echo step failed its baseline, and the failure is the processor.** The baseline had been
taken on the EPYC. On this processor libuv reached 1,057 thousandths of rotor at 64 connections and
64 KiB, against 978 there, past the margin of 50. No commit between the two runs touched rotor's
echo server or libuv's. The ratios below moved by up to 225 thousandths between the two processors,
most of them toward rotor. The baseline now keeps one section per processor
(`bench/harness/baseline.zig`), and this run's rows are its Xeon section.

The storm, timer and cross-core steps did not run, because the job stopped at the failed step.
They now run whatever the echo gate decides.

## Each candidate's echo rate as thousandths of rotor's, on the two processors

Above 1,000 the candidate was ahead of rotor.

| connections | payload | candidate | EPYC 9V74 | Xeon 6973P-C |
|---:|---:|---|---:|---:|
| 16 | 4096 | rotor (accumulate) | 1002 | 961 |
| 16 | 4096 | libuv | 959 | 834 |
| 16 | 4096 | libxev | 894 | 751 |
| 16 | 8192 | rotor (accumulate) | 1007 | 955 |
| 16 | 8192 | libuv | 1031 | 806 |
| 16 | 8192 | libxev | 926 | 755 |
| 16 | 16384 | rotor (accumulate) | 997 | 995 |
| 16 | 16384 | libuv | 989 | 812 |
| 16 | 16384 | libxev | 942 | 826 |
| 16 | 65536 | rotor (accumulate) | 1017 | 984 |
| 16 | 65536 | libuv | 990 | 954 |
| 16 | 65536 | libxev | 1084 | 890 |
| 64 | 4096 | rotor (accumulate) | 1003 | 1008 |
| 64 | 4096 | libuv | 954 | 830 |
| 64 | 4096 | libxev | 964 | 789 |
| 64 | 8192 | rotor (accumulate) | 999 | 970 |
| 64 | 8192 | libuv | 983 | 802 |
| 64 | 8192 | libxev | 956 | 828 |
| 64 | 16384 | rotor (accumulate) | 1004 | 978 |
| 64 | 16384 | libuv | 990 | 873 |
| 64 | 16384 | libxev | 981 | 958 |
| 64 | 65536 | rotor (accumulate) | 1003 | 1006 |
| 64 | 65536 | libuv | 978 | 1057 |
| 64 | 65536 | libxev | 1101 | 1008 |

## Echo

Every row's spread is under 10 percent and none is flagged.

| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 231410 | 925651 | 68095 | 93183 | 115199 | 146431 | 3993600 | 2 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 222513 | 890071 | 70655 | 99327 | 121855 | 150527 | 3993600 | 0 | 7 | 2 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 193095 | 772396 | 75263 | 161791 | 178175 | 194559 | 3108864 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 173880 | 695525 | 92671 | 112639 | 127487 | 152575 | 3112960 | 0 | 23 | 3 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 130307 | 521235 | 122879 | 145407 | 164863 | 235519 | 13127680 | 1 | 7 | 1 |  |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 220869 | 883482 | 72191 | 89599 | 105471 | 145407 | 3993600 | 1 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 211135 | 844560 | 74239 | 106495 | 127999 | 156671 | 3997696 | 1 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 178169 | 712695 | 81919 | 176127 | 193535 | 217087 | 3239936 | 2 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 166772 | 667091 | 96255 | 115711 | 132095 | 173055 | 3244032 | 0 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 119563 | 478259 | 133119 | 161791 | 186367 | 230399 | 14721024 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 185519 | 742087 | 84479 | 107007 | 125951 | 156671 | 3993600 | 0 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 184596 | 738400 | 84991 | 113663 | 135167 | 164863 | 3993600 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 150788 | 603173 | 96767 | 208895 | 239615 | 286719 | 3399680 | 6 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 153369 | 613483 | 104447 | 139263 | 168959 | 193535 | 3399680 | 1 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 97395 | 389591 | 162815 | 203775 | 262143 | 321535 | 11038720 | 1 | 11 | 2 |  |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 65718 | 262885 | 240639 | 284671 | 329727 | 366591 | 6090752 | 0 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 64673 | 258702 | 243711 | 327679 | 389119 | 442367 | 4128768 | 2 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 62755 | 251033 | 248831 | 399359 | 479231 | 528383 | 4128768 | 1 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 58491 | 233979 | 274431 | 321535 | 405503 | 501759 | 4128768 | 1 | 3 | 1 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 41069 | 164287 | 382975 | 458751 | 495615 | 557055 | 14782464 | 5 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 239611 | 958464 | 266239 | 319487 | 385023 | 421887 | 8372224 | 1 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 241672 | 966744 | 264191 | 327679 | 389119 | 430079 | 8372224 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 199081 | 796396 | 319487 | 401407 | 655359 | 761855 | 8372224 | 2 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 189242 | 756989 | 339967 | 403455 | 450559 | 565247 | 8372224 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 123892 | 495575 | 514047 | 618495 | 737279 | 770047 | 49258496 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 222661 | 890664 | 284671 | 344063 | 407551 | 511999 | 8400896 | 3 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 216191 | 864791 | 292863 | 350207 | 421887 | 489471 | 8400896 | 0 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 178745 | 715052 | 352255 | 667647 | 745471 | 856063 | 8400896 | 3 | 3 | 1 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 184367 | 737507 | 346111 | 413695 | 491519 | 577535 | 8400896 | 0 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 109722 | 438899 | 585727 | 626687 | 675839 | 729087 | 49311744 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 186836 | 747373 | 339967 | 395263 | 434175 | 475135 | 8445952 | 0 | 0 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 182748 | 731017 | 346111 | 425983 | 483327 | 536575 | 8445952 | 3 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 163188 | 652813 | 370687 | 700415 | 778239 | 884735 | 8445952 | 6 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 179143 | 716637 | 356351 | 440319 | 468991 | 505855 | 8445952 | 1 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 88652 | 354657 | 720895 | 843775 | 921599 | 1003519 | 49410048 | 4 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 57665 | 230711 | 1105919 | 1400831 | 1523711 | 1695743 | 12484608 | 2 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 58035 | 232188 | 1097727 | 1343487 | 1499135 | 1785855 | 8675328 | 1 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 60983 | 243964 | 1040383 | 1236991 | 1335295 | 1564671 | 8675328 | 8 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 58140 | 232607 | 1097727 | 1384447 | 1531903 | 1916927 | 8675328 | 2 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 42641 | 170620 | 1507327 | 1638399 | 1687551 | 1821159 | 49201152 | 1 | 3 | 0 |  |

## CPU per echo

`bench/calls/cpu_per_echo.sh`, one run of three seconds per row at 16 connections. The rows locate
a cost and are not a comparison. As on the EPYC, a whole-pool group costs the server about what 32
buffers do, and the client is at 100 percent of a core in every row.

| payload | server | echoes | cpu µs per echo | busy % | in the kernel % | switches per echo | client busy % |
|---:|---|---:|---:|---:|---:|---:|---:|
| 4096 | rotor (group, the whole pool) | 703887 | 4.23 | 99.2 | 98.3 | 0.002 | 99.0 |
| 4096 | rotor (group, 2048 buffers) | 695762 | 4.29 | 99.6 | 98.3 | 0.004 | 100.0 |
| 4096 | rotor (group, 256 buffers) | 682697 | 4.37 | 99.5 | 98.7 | 0.002 | 100.3 |
| 4096 | rotor (group, 32 buffers) | 701616 | 4.27 | 99.9 | 98.3 | 0.001 | 100.0 |
| 4096 | rotor (accumulate) | 660921 | 4.52 | 99.6 | 98.0 | 0.002 | 99.7 |
| 4096 | libxev | 520135 | 5.52 | 95.8 | 98.6 | 0.054 | 100.0 |
| 65536 | rotor (group, the whole pool) | 190602 | 15.71 | 99.8 | 99.3 | 0.002 | 99.3 |
| 65536 | rotor (group, 2048 buffers) | refused by the server | | | | | |
| 65536 | rotor (group, 256 buffers) | 194495 | 15.39 | 99.8 | 99.7 | 0.002 | 99.3 |
| 65536 | rotor (group, 32 buffers) | 197874 | 14.98 | 98.8 | 99.7 | 0.015 | 100.0 |
| 65536 | rotor (accumulate) | 194809 | 15.39 | 99.9 | 99.3 | 0.001 | 99.7 |
| 65536 | libxev | 179558 | 16.35 | 97.9 | 99.3 | 0.039 | 100.0 |

## Kernel calls per echo

`bench/calls/count_calls.sh`, one run of three seconds per row at 16 connections, with no trace
buffer overrun. It is the first count on x86-64: the earlier one on this runner read zero,
because the script could not write its client's output as root.

| payload | candidate | echoes | overruns | io_uring_enter | io_uring requests | poll arms | io-wq jobs | reads | writes | epoll_ctl | epoll waits | other calls | requests by opcode |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 65536 | rotor | 136458 | 0 | 0.279 | 1.020 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | ASYNC_CANCEL 0.000, SEND 1.020, CLOSE 0.000, RECV 0.000 |
| 65536 | rotor (accumulate) | 124657 | 0 | 0.162 | 2.006 | 0.322 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | ASYNC_CANCEL 0.000, SEND 1.000, CLOSE 0.000, RECV 1.005 |
| 65536 | libuv | 129803 | 0 | 0.184 | 2.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.092 | 0.001 | EPOLL 2.000 |
| 65536 | libxev | 114832 | 0 | 0.212 | 2.068 | 0.286 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | SEND 1.034, ACCEPT 0.000, CLOSE 0.000, RECV 1.034 |
| 4096 | rotor | 436798 | 0 | 0.222 | 1.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | ASYNC_CANCEL 0.000, SEND 1.000, CLOSE 0.000, RECV 0.000 |
| 4096 | rotor (accumulate) | 472140 | 0 | 0.186 | 2.000 | 0.834 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | ASYNC_CANCEL 0.000, SEND 1.000, CLOSE 0.000, RECV 1.000 |
| 4096 | libuv | 403299 | 0 | 0.131 | 2.000 | 0.000 | 0.000 | 1.000 | 1.000 | 0.000 | 0.066 | 0.000 | EPOLL 2.000 |
| 4096 | libxev | 389188 | 0 | 0.509 | 2.000 | 0.839 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | SEND 1.000, ACCEPT 0.000, CLOSE 0.000, RECV 1.000 |
