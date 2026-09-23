# Echo, storm, timers, one cross-core message, CPU and kernel calls: `github` on an AMD EPYC 7763, 2026-09-22

The `comparison` job of `.github/workflows/ci.yml`, started by hand on commit `5e0fac2`, run
35815517826, from 03:44 UTC on 2026-09-23. A GitHub-hosted `ubuntu-24.04` runner: AMD EPYC 7763
64-Core Processor, 4 CPUs, Linux 6.17.0-1022-azure. io_uring, one core, three runs per echo and
storm row, five per timer and cross-core row. rotor's buffer group is sized per connection, as in
the two runs before it: `echo-sized-pool-github-2026-09-22.md` on an AMD EPYC 9V74 and
`echo-sized-pool-github-xeon-2026-09-22.md` on an Intel Xeon 6973P-C.

The baseline had no section for this processor, so the echo step gated nothing and printed this
run's ratios instead. Every step ran. It is the first run since libuv's timer and cross-core
programs were fixed, so its timer and cross-core tables are the first on io_uring with libuv rows.

## Each candidate's echo rate as thousandths of rotor's, on three processors

Above 1,000 the candidate was ahead of rotor. The EPYC 7763 column is this run. Its libxev rows at
64 KiB are not confirmed; the next section says why.

| connections | payload | candidate | EPYC 9V74 | Xeon 6973P-C | EPYC 7763 |
|---:|---:|---|---:|---:|---:|
| 16 | 4096 | rotor (accumulate) | 1002 | 961 | 943 |
| 16 | 4096 | libuv | 959 | 834 | 866 |
| 16 | 4096 | libxev | 894 | 751 | 891, runs disagree |
| 16 | 8192 | rotor (accumulate) | 1007 | 955 | 952 |
| 16 | 8192 | libuv | 1031 | 806 | 868 |
| 16 | 8192 | libxev | 926 | 755 | 892 |
| 16 | 16384 | rotor (accumulate) | 997 | 995 | 951 |
| 16 | 16384 | libuv | 989 | 812 | 880 |
| 16 | 16384 | libxev | 942 | 826 | 907 |
| 16 | 65536 | rotor (accumulate) | 1017 | 984 | 993 |
| 16 | 65536 | libuv | 990 | 954 | 963, runs disagree |
| 16 | 65536 | libxev | 1084 | 890 | 531, not confirmed |
| 64 | 4096 | rotor (accumulate) | 1003 | 1008 | 936 |
| 64 | 4096 | libuv | 954 | 830 | 851 |
| 64 | 4096 | libxev | 964 | 789 | 925 |
| 64 | 8192 | rotor (accumulate) | 999 | 970 | 939 |
| 64 | 8192 | libuv | 983 | 802 | 861 |
| 64 | 8192 | libxev | 956 | 828 | 930 |
| 64 | 16384 | rotor (accumulate) | 1004 | 978 | 950 |
| 64 | 16384 | libuv | 990 | 873 | 874 |
| 64 | 16384 | libxev | 981 | 958 | 933 |
| 64 | 65536 | rotor (accumulate) | 1003 | 1006 | 1000 |
| 64 | 65536 | libuv | 978 | 1057 | 960 |
| 64 | 65536 | libxev | 1101 | 1008 | 595, not confirmed |

`bench/baseline/echo.txt` holds this run's ratios as its EPYC 7763 section, without four rows:

- libxev at 16 connections and 4 KiB, and libuv at 16 connections and 64 KiB. Their runs
  disagreed, with spreads of 10 and 26 percent.
- libxev at 64 KiB, at 16 and at 64 connections. The next section says why.

## libxev at 64 KiB

The echo step put libxev at about half of rotor at 64 KiB. Two later steps of the same job ran
the same two server programs at 16 connections and 64 KiB with a different client, `echo_client`,
and found libxev within 6 percent of rotor:

| step | client | rotor | libxev | libxev as thousandths of rotor |
|---|---|---:|---:|---:|
| echo, median echoes per second | the runner's own | 43,718 | 23,255 | 531 |
| CPU per echo, echoes in 3 s, rotor's group of 32 buffers | `echo_client` | 134,719 | 127,595 | 947 |
| kernel calls per echo, echoes in 3 s under tracing, rotor's whole pool | `echo_client` | 76,271 | 76,661 | 1,005 |

On the two earlier processors the echo step and the CPU step agreed within 6 percent on this row.
Each cell is libxev as thousandths of rotor, at 16 connections and 64 KiB:

| processor | echo step | CPU step, rotor's group of 32 buffers |
|---|---:|---:|
| EPYC 9V74 | 1,084 | 1,031 |
| Xeon 6973P-C | 890 | 907 |
| EPYC 7763 | 531 | 947 |

The echo step's three runs of libxev agreed with each other, with a spread of 6 percent, so the
harness did not flag the row. What makes the two clients differ on this processor is not known.
Until a second run on an EPYC 7763 settles it, neither libxev row at 64 KiB is gated.

## Echo

Two rows are flagged, and both are left out of the baseline.

| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 127386 | 509552 | 122879 | 149503 | 186367 | 233471 | 3923968 | 2 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 120125 | 480514 | 131071 | 175103 | 207871 | 230399 | 3923968 | 2 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 110321 | 441303 | 129535 | 280575 | 325631 | 432127 | 3244032 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 113508 | 454044 | 137215 | 196607 | 294911 | 516095 | 3248128 | 10 | 0 | 0 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 65643 | 262578 | 243711 | 274431 | 292863 | 925695 | 14856192 | 0 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 122090 | 488373 | 127999 | 159743 | 195583 | 232447 | 3923968 | 1 | 7 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 116273 | 465108 | 136191 | 172031 | 212991 | 262143 | 3923968 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 106047 | 424208 | 130559 | 282623 | 307199 | 376831 | 3375104 | 1 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 108914 | 435668 | 144383 | 182271 | 224255 | 257023 | 3379200 | 0 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 61539 | 246165 | 261119 | 292863 | 309247 | 864255 | 11034624 | 2 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 109041 | 436173 | 144383 | 174079 | 244735 | 270335 | 3923968 | 0 | 7 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 103754 | 415028 | 152575 | 191487 | 237567 | 272383 | 3923968 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 95969 | 383895 | 144383 | 311295 | 344063 | 432127 | 3534848 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 98958 | 395842 | 158719 | 216063 | 264191 | 317439 | 3534848 | 0 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 56273 | 225103 | 286719 | 317439 | 331775 | 561151 | 11030528 | 2 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 43718 | 174880 | 360447 | 411647 | 536575 | 626687 | 6119424 | 0 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 43443 | 173780 | 362495 | 532479 | 602111 | 651263 | 4263936 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 42108 | 168450 | 374783 | 626687 | 679935 | 880639 | 4263936 | 26 | 0 | 0 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 23255 | 93028 | 692223 | 909311 | 1019903 | 1036287 | 4263936 | 6 | 3 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 28966 | 115874 | 552959 | 602111 | 626687 | 901119 | 14790656 | 2 | 23 | 4 |  |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 131810 | 527259 | 483327 | 524287 | 700415 | 794623 | 8507392 | 0 | 3 | 2 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 123468 | 493931 | 516095 | 679935 | 770047 | 831487 | 8507392 | 0 | 3 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 112214 | 448927 | 561151 | 1114111 | 1163263 | 1228799 | 8507392 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 122047 | 488223 | 522239 | 667647 | 778239 | 835583 | 8507392 | 0 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 70295 | 281208 | 913407 | 970751 | 1003519 | 1581055 | 49418240 | 1 | 3 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 123720 | 494887 | 518143 | 565247 | 688127 | 823295 | 8536064 | 0 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 116295 | 465220 | 548863 | 757759 | 811007 | 880639 | 8536064 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 106574 | 426364 | 585727 | 1171455 | 1220607 | 1286143 | 8536064 | 1 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 115115 | 460515 | 557055 | 729087 | 819199 | 860159 | 8536064 | 0 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 66275 | 265116 | 966655 | 1028095 | 1064959 | 1900543 | 49303552 | 2 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 110646 | 442617 | 577535 | 638975 | 864255 | 925695 | 8577024 | 0 | 3 | 1 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 105217 | 420927 | 610303 | 790527 | 892927 | 942079 | 8577024 | 1 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 96745 | 387050 | 643071 | 1294335 | 1335295 | 1417215 | 8577024 | 0 | 3 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 103251 | 413063 | 618495 | 827391 | 909311 | 970751 | 8577024 | 0 | 3 | 1 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 60476 | 241933 | 1064959 | 1130495 | 1171455 | 1769471 | 49188864 | 1 | 0 | 0 |  |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 43938 | 175791 | 1458175 | 1531903 | 1785855 | 2162687 | 12410880 | 1 | 3 | 0 |  |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 43968 | 175912 | 1417215 | 2031615 | 2146303 | 2326527 | 8806400 | 0 | 0 | 0 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 42209 | 168900 | 1376255 | 2850815 | 2981887 | 3440639 | 8806400 | 0 | 0 | 0 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 26182 | 104768 | 2457599 | 2867199 | 3014655 | 3150889 | 8806400 | 6 | 0 | 0 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 28475 | 113920 | 2244607 | 2326527 | 2408447 | 2441215 | 49332224 | 1 | 3 | 0 |  |

## Accept storm

Five of the eight rows disagree, so the storm decides nothing on this run.

| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| accept storm | rotor | this tree | 0 | 16 | 1 | even | 3 | 26206 | 16 | 552959 | 568551 | 568551 | 568551 | 3923968 | 35 | 71 | 12 | **RUNS DISAGREE** **OTHER WORK** |
| accept storm | libuv | v1.52.1 | 0 | 16 | 1 | even | 3 | 23315 | 16 | 522239 | 637910 | 637910 | 637910 | 2830336 | 16 | 3 | 0 | **RUNS DISAGREE** |
| accept storm | libxev | 9ce8e8e | 0 | 16 | 1 | even | 3 | 21367 | 16 | 532479 | 699585 | 699585 | 699585 | 2834432 | 28 | 0 | 0 | **RUNS DISAGREE** |
| accept storm | std.Io.Threaded | 0.16.0 | 0 | 16 | 1 | even | 3 | 16963 | 16 | 888831 | 917892 | 917892 | 917892 | 13127680 | 7 | 0 | 0 |  |
| accept storm | rotor | this tree | 0 | 64 | 1 | even | 3 | 28725 | 64 | 2080767 | 2169448 | 2169448 | 2169448 | 3928064 | 21 | 3 | 1 | **RUNS DISAGREE** |
| accept storm | libuv | v1.52.1 | 0 | 64 | 1 | even | 3 | 26915 | 64 | 1990655 | 2194074 | 2194074 | 2194074 | 2879488 | 3 | 0 | 0 |  |
| accept storm | libxev | 9ce8e8e | 0 | 64 | 1 | even | 3 | 29260 | 64 | 1990655 | 2071024 | 2071024 | 2071024 | 2883584 | 6 | 3 | 0 |  |
| accept storm | std.Io.Threaded | 0.16.0 | 0 | 64 | 1 | even | 3 | 19351 | 64 | 3194879 | 3267149 | 3267149 | 3267149 | 49348608 | 27 | 3 | 0 | **RUNS DISAGREE** |

## Timer churn

Each library in its cheapest mode. Each timer asks for 1,000 fires per second, so 256 timers ask
for 256,000 and 4,096 ask for 4,096,000.

| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| timer-churn | rotor | this tree | 0 | 256 | 0 | even | 5 | 243328 | 730112 | 52183 | 63364 | 115071 | 115081 | 0 | 0 | 23 | 2 |  |
| timer-churn | rotor (repeating) | this tree | 0 | 256 | 0 | even | 5 | 255989 | 768000 | 52007 | 67171 | 142437 | 142927 | 0 | 0 | 3 | 0 |  |
| timer-churn | libuv | 1.52.1 | 0 | 256 | 0 | even | 5 | 228710 | 686336 | 107827 | 1179076 | 1190474 | 1191611 | 0 | 0 | 3 | 0 |  |
| timer-churn | libuv (repeating) | 1.52.1 | 0 | 256 | 0 | even | 5 | 229178 | 687616 | 100544 | 1174819 | 1193724 | 1193763 | 0 | 0 | 3 | 0 |  |
| timer-churn | libxev | 9ce8e8e | 0 | 256 | 0 | even | 5 | 245749 | 737408 | 41092 | 71373 | 137753 | 159767 | 0 | 0 | 0 | 0 |  |
| timer-churn | std.Io.Threaded | 0.16.0 | 0 | 256 | 0 | even | 5 | 226975 | 681185 | 111093 | 183503 | 228198 | 281890 | 0 | 0 | 3 | 0 |  |
| timer-churn | rotor | this tree | 0 | 4096 | 0 | even | 5 | 2323617 | 6971392 | 774662 | 829014 | 836137 | 836177 | 0 | 0 | 3 | 0 |  |
| timer-churn | rotor (repeating) | this tree | 0 | 4096 | 0 | even | 5 | 4094544 | 12288000 | 597627 | 657599 | 671624 | 672045 | 0 | 0 | 3 | 0 |  |
| timer-churn | libuv | 1.52.1 | 0 | 4096 | 0 | even | 5 | 1976626 | 5931008 | 1098387 | 1308760 | 1334016 | 1337312 | 0 | 5 | 0 | 0 |  |
| timer-churn | libuv (repeating) | 1.52.1 | 0 | 4096 | 0 | even | 5 | 2085173 | 6256863 | 998690 | 1170822 | 1182345 | 1184520 | 0 | 3 | 0 | 0 |  |
| timer-churn | libxev | 9ce8e8e | 0 | 4096 | 0 | even | 5 | 1143936 | 3432960 | 2607938 | 4662387 | 5597090 | 5710972 | 0 | 0 | 3 | 0 |  |
| timer-churn | std.Io.Threaded | 0.16.0 | 0 | 4096 | 0 | even | 5 | 586898 | 1830012 | 105233 | 295328 | 872424 | 2227854 | 0 | 19 | 3 | 0 | **RUNS DISAGREE** |

## One cross-core message

Two loops on two cores send a message back and forth. rotor's message carries a 16-byte payload;
libuv's and libxev's carry none.

| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 2 | 1 | 0 | even | 5 | 68653 | 40000 | 16127 | 17791 | 24959 | 38655 | 0 | 7 | 7 | 1 |  |
| cross-core | libuv | v1.52.1 | 2 | 1 | 0 | even | 5 | 61367 | 40000 | 16330 | 16976 | 18730 | 37194 | 0 | 1 | 19 | 2 |  |
| cross-core | libxev | 9ce8e8e | 2 | 1 | 0 | even | 5 | 61981 | 40000 | 16191 | 16895 | 18687 | 27135 | 0 | 1 | 0 | 0 |  |

## CPU per echo

`bench/calls/cpu_per_echo.sh`, one run of three seconds per row at 16 connections. The rows locate
a cost and are not a comparison. The client is at 100 percent of a core in every row, as on the
two earlier processors.

| payload | server | echoes | cpu µs per echo | busy % | in the kernel % | switches per echo | client busy % |
|---:|---|---:|---:|---:|---:|---:|---:|
| 4096 | rotor (group, the whole pool) | 373150 | 8.02 | 99.8 | 98.7 | 0.001 | 99.7 |
| 4096 | rotor (group, 2048 buffers) | 386330 | 7.76 | 99.9 | 98.3 | 0.001 | 100.0 |
| 4096 | rotor (group, 256 buffers) | 378242 | 7.92 | 99.8 | 98.0 | 0.001 | 100.0 |
| 4096 | rotor (group, 32 buffers) | 387827 | 7.73 | 100.0 | 98.7 | 0.000 | 100.3 |
| 4096 | rotor (accumulate) | 365693 | 8.20 | 100.0 | 98.7 | 0.000 | 100.0 |
| 4096 | libxev | 343273 | 8.74 | 100.0 | 99.0 | 0.000 | 100.3 |
| 65536 | rotor (group, the whole pool) | 123961 | 24.21 | 100.0 | 99.7 | 0.000 | 99.3 |
| 65536 | rotor (group, 2048 buffers) | refused by the server | | | | | |
| 65536 | rotor (group, 256 buffers) | 134152 | 22.37 | 100.0 | 99.7 | 0.000 | 100.3 |
| 65536 | rotor (group, 32 buffers) | 134719 | 22.26 | 100.0 | 99.3 | 0.001 | 100.3 |
| 65536 | rotor (accumulate) | 130803 | 22.94 | 100.0 | 99.3 | 0.000 | 100.3 |
| 65536 | libxev | 127595 | 23.52 | 100.1 | 100.0 | 0.000 | 100.0 |

## Kernel calls per echo

`bench/calls/count_calls.sh`, one run of three seconds per row at 16 connections. **The libuv row
at 4 KiB lost events:** the trace buffer overran 149,280 times, so its counts are too low, and its
reads and writes per echo read 0.882, where the same row read 1.000 on the Xeon. The other rows
had no overrun.

| payload | candidate | echoes | overruns | io_uring_enter | io_uring requests | poll arms | io-wq jobs | reads | writes | epoll_ctl | epoll waits | other calls | requests by opcode |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 65536 | rotor | 76271 | 0 | 0.366 | 1.048 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | ASYNC_CANCEL 0.000, SEND 1.047, CLOSE 0.000, RECV 0.000 |
| 65536 | rotor (accumulate) | 72695 | 0 | 0.412 | 2.075 | 0.671 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | ASYNC_CANCEL 0.000, SEND 1.000, CLOSE 0.000, RECV 1.075 |
| 65536 | libuv | 82674 | 0 | 1.251 | 2.062 | 0.000 | 0.000 | 1.031 | 1.031 | 0.000 | 0.626 | 0.001 | EPOLL 2.062 |
| 65536 | libxev | 76661 | 0 | 0.931 | 2.485 | 0.929 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.001 | SEND 1.242, ACCEPT 0.000, CLOSE 0.000, RECV 1.243 |
| 4096 | rotor | 197914 | 0 | 0.510 | 1.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | ASYNC_CANCEL 0.000, SEND 1.000, CLOSE 0.000, RECV 0.000 |
| 4096 | rotor (accumulate) | 262208 | 0 | 0.815 | 2.000 | 0.974 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | ASYNC_CANCEL 0.000, SEND 1.000, CLOSE 0.000, RECV 1.000 |
| 4096 | libuv | 262506 | 149280 | 0.439 | 1.765 | 0.000 | 0.000 | 0.882 | 0.882 | 0.000 | 0.219 | 0.000 | EPOLL 1.765 |
| 4096 | libxev | 219554 | 0 | 0.652 | 2.000 | 0.806 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | SEND 1.000, ACCEPT 0.000, CLOSE 0.000, RECV 1.000 |
