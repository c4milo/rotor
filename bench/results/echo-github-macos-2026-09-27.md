# Echo on GitHub's macOS runners, 2026-09-27

Four `comparison` jobs of `.github/workflows/ci.yml`, started by hand on commit `0218875` as run
36373291870, from 03:20 UTC on 2026-09-28, with `comparison_runs` set to `[1, 2, 3, 4]`. Each job
ran on its own `macos-latest` runner, image `macos-26-arm64/20260907.0351`: `echo_runner --baseline
bench/baseline/echo.txt`, kqueue, one core, three runs per row. Every runner reported an Apple M1
(Virtual) with 3 processors and Darwin 25.6.0.

**No section of `bench/baseline/echo.txt` came from them.** In 134 of the 160 echo rows the runs
disagreed, and in 132 the runner reported other work, which peaked at all 3 processors busy in the
pause before or after a run. rotor's own row disagreed in 27 of its 32. Every ratio of a
configuration is taken against rotor's median, so under the rule of 2026-09-25 a run gives no ratio
for a configuration where rotor's row disagreed. A section taken from these runs would have held 4
of the 32 rows that name a candidate other than rotor. This agrees with 2026-09-24, when these
runners' cross-core rounds spread by 9 to 96 percent.

The jobs still run every night: they build and run every candidate on kqueue, and print the table.
All four failed in their timer step, which is recorded in `.github/workflows/ci.yml`.

## rotor's rows

rotor's median echoes per second in each run, with the run's spread percent beside it. The same
configuration moved by up to 2.9 times between runners.

| connections | payload bytes | run 1 | run 2 | run 3 | run 4 |
|---:|---:|---:|---:|---:|---:|
| 16 | 4096 | 96737 (45) | 63506 (14) | 155029 (17) | 101786 (17) |
| 16 | 8192 | 111065 (65) | 67841 (20) | 126912 (59) | 80181 (42) |
| 16 | 16384 | 103581 (38) | 113433 (57) | 58912 (114) | 63546 (10) |
| 16 | 65536 | 52086 (70) | 84601 (1) | 46140 (2) | 41841 (8) |
| 64 | 4096 | 93176 (35) | 191356 (15) | 96197 (61) | 92397 (37) |
| 64 | 8192 | 101045 (16) | 173541 (3) | 95007 (43) | 95599 (52) |
| 64 | 16384 | 76322 (38) | 151844 (10) | 90032 (17) | 91483 (9) |
| 64 | 65536 | 36340 (43) | 70598 (10) | 24209 (14) | 33113 (25) |

## Each run

The echo rows each job printed.

### Run 1, job 108773890128

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 96737 | 386954 | 103423 | 724991 | 2359295 | 5308415 | 5357568 | 45 | 302 | 234 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 68568 | 274276 | 186367 | 1073151 | 3932159 | 7372799 | 5341184 | 41 | 298 | 260 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 87129 | 348535 | 159743 | 720895 | 2113535 | 5505023 | 1654784 | 66 | 303 | 244 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 64984 | 259970 | 193535 | 1081343 | 3457023 | 6881279 | 1736704 | 28 | 307 | 298 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 50871 | 203505 | 258047 | 1458175 | 4325375 | 8716287 | 4276224 | 90 | 302 | 237 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 111065 | 444282 | 90623 | 565247 | 2342911 | 7340031 | 5488640 | 65 | 301 | 244 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 69927 | 279717 | 183295 | 856063 | 2867199 | 6979583 | 5357568 | 28 | 308 | 199 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 114462 | 457874 | 85503 | 540671 | 1572863 | 4456447 | 1671168 | 102 | 300 | 279 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 98859 | 395439 | 140287 | 446463 | 753663 | 1622015 | 1736704 | 49 | 302 | 266 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 87909 | 351656 | 146431 | 618495 | 1507327 | 3063807 | 4308992 | 62 | 302 | 237 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 103581 | 414337 | 98303 | 606207 | 1449983 | 3899391 | 5734400 | 38 | 299 | 258 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 111493 | 445984 | 107007 | 522239 | 1425407 | 3866623 | 5521408 | 43 | 299 | 287 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 128111 | 512454 | 92159 | 425983 | 1368063 | 2998271 | 1916928 | 50 | 305 | 229 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 79896 | 319598 | 158719 | 663551 | 2244607 | 7241727 | 2015232 | 31 | 301 | 194 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 74928 | 299739 | 173055 | 716799 | 2179071 | 5111807 | 4292608 | 28 | 300 | 154 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 52086 | 208353 | 190463 | 1392639 | 3178495 | 6258687 | 7356416 | 70 | 302 | 194 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 46984 | 187944 | 221183 | 1138687 | 2113535 | 4161535 | 6307840 | 89 | 299 | 164 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 44547 | 178223 | 294911 | 1040383 | 1941503 | 3751935 | 2719744 | 108 | 296 | 165 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 34914 | 139667 | 278527 | 1253375 | 2899967 | 6029311 | 2785280 | 44 | 279 | 135 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 30951 | 123813 | 464895 | 1875967 | 4718591 | 16252927 | 4292608 | 88 | 228 | 115 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 93176 | 372731 | 684031 | 1736703 | 2703359 | 5570559 | 5750784 | 35 | 236 | 87 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 95621 | 382517 | 647167 | 2195455 | 4456447 | 5799935 | 5505024 | 82 | 207 | 121 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 92544 | 370213 | 655359 | 1974271 | 2801663 | 6422527 | 2490368 | 31 | 297 | 165 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 87787 | 351169 | 704511 | 1933311 | 3440639 | 5636095 | 2621440 | 38 | 299 | 204 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 66739 | 266999 | 884735 | 2867199 | 5079039 | 7734459 | 12222464 | 27 | 282 | 112 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 101045 | 404243 | 606207 | 1548287 | 2490367 | 4390911 | 6258688 | 16 | 23 | 5 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 101570 | 406310 | 540671 | 1925119 | 2818047 | 5286625 | 5783552 | 21 | 19 | 6 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 115588 | 462418 | 385023 | 2146303 | 3391487 | 5144575 | 2490368 | 34 | 138 | 53 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 64228 | 256939 | 942079 | 2621439 | 4456447 | 6782975 | 2621440 | 42 | 139 | 46 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 48267 | 193084 | 1073151 | 4653055 | 11730943 | 14942207 | 12222464 | 65 | 138 | 49 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 76322 | 305318 | 602111 | 4079615 | 7208959 | 8454143 | 7340032 | 38 | 125 | 23 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 48056 | 192244 | 1130495 | 4227071 | 7569407 | 10027007 | 6275072 | 33 | 7 | 3 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 67554 | 270297 | 901119 | 2703359 | 4554751 | 5668863 | 3538944 | 29 | 45 | 15 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 68476 | 273949 | 798719 | 2539519 | 4784127 | 6193151 | 3588096 | 69 | 32 | 9 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 49334 | 197406 | 1236991 | 3325951 | 6356991 | 10551295 | 12222464 | 9 | 123 | 46 | **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 36340 | 145432 | 1531903 | 4882431 | 7077887 | 9371647 | 13058048 | 43 | 119 | 33 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 25412 | 101686 | 2211839 | 6848511 | 13303807 | 28133459 | 9420800 | 36 | 26 | 12 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 32412 | 129679 | 1589247 | 5308415 | 7798783 | 14562042 | 6684672 | 12 | 93 | 26 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 23786 | 95204 | 2588671 | 6193151 | 9437183 | 11599871 | 6815744 | 14 | 158 | 28 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 21482 | 85974 | 2768895 | 5439487 | 7143423 | 11796479 | 12206080 | 19 | 59 | 12 | **RUNS DISAGREE** **OTHER WORK** |
```

### Run 2, job 108773890041

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 63506 | 254037 | 197631 | 913407 | 4587519 | 9437183 | 5390336 | 14 | 304 | 235 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 60339 | 241370 | 199679 | 1515519 | 3604479 | 11796479 | 5341184 | 29 | 299 | 191 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 73091 | 292368 | 194559 | 761855 | 2719743 | 12058623 | 1654784 | 8 | 304 | 300 | **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 54272 | 217098 | 246783 | 1277951 | 5406719 | 12648447 | 1736704 | 30 | 302 | 299 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 49555 | 198264 | 272383 | 1425407 | 4292607 | 9240575 | 4308992 | 7 | 303 | 247 | **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 67841 | 271381 | 205823 | 872447 | 3063807 | 8454143 | 5505024 | 20 | 301 | 198 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 57138 | 228569 | 219135 | 1122303 | 3391487 | 10944511 | 5390336 | 50 | 305 | 201 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 73782 | 295134 | 193535 | 692223 | 2375679 | 6586367 | 1654784 | 92 | 301 | 244 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 58810 | 235254 | 244735 | 749567 | 2392063 | 6127615 | 1736704 | 22 | 299 | 226 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 57968 | 231899 | 264191 | 798719 | 2572287 | 4554751 | 4308992 | 35 | 303 | 198 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 113433 | 453794 | 108031 | 466943 | 798719 | 1695743 | 5767168 | 57 | 301 | 240 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 93451 | 373820 | 125951 | 581631 | 1212415 | 4292607 | 5521408 | 28 | 295 | 170 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 100272 | 401104 | 99327 | 532479 | 1048575 | 2883583 | 1916928 | 74 | 298 | 228 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 64526 | 258116 | 185343 | 737279 | 1409023 | 2981887 | 1998848 | 54 | 288 | 190 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 79359 | 317474 | 166911 | 667647 | 2113535 | 8781823 | 4308992 | 19 | 302 | 260 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 84601 | 338413 | 182271 | 399359 | 655359 | 962559 | 7225344 | 1 | 301 | 158 | **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 77183 | 308742 | 186367 | 487423 | 610303 | 1212415 | 6307840 | 10 | 300 | 91 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 71862 | 287456 | 184319 | 548863 | 933887 | 1916927 | 2703360 | 10 | 283 | 117 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 58832 | 235340 | 262143 | 501759 | 831487 | 1703935 | 2785280 | 18 | 297 | 117 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 49177 | 196719 | 313343 | 708607 | 909311 | 2195455 | 4308992 | 9 | 300 | 123 | **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 191356 | 765497 | 278527 | 925695 | 1540095 | 2686975 | 5783552 | 15 | 213 | 84 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 193136 | 772586 | 317439 | 577535 | 872447 | 1155071 | 5537792 | 3 | 240 | 52 | **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 201244 | 804997 | 276479 | 798719 | 1253375 | 2916351 | 2490368 | 23 | 154 | 46 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 150289 | 601176 | 405503 | 876543 | 1957887 | 3731208 | 2539520 | 10 | 255 | 114 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 131170 | 524744 | 485375 | 815103 | 1114111 | 1302527 | 12222464 | 31 | 197 | 46 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 173541 | 694192 | 311295 | 974847 | 1482751 | 2179071 | 6307840 | 3 | 180 | 34 | **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 177210 | 708880 | 339967 | 712703 | 1105919 | 3276799 | 5767168 | 10 | 192 | 67 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 203123 | 812530 | 299007 | 745471 | 1028095 | 1581055 | 2490368 | 5 | 251 | 106 | **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 138010 | 552089 | 434175 | 1097727 | 1687551 | 2850815 | 2539520 | 7 | 259 | 90 | **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 102242 | 409092 | 614399 | 1589247 | 2211839 | 5144575 | 12222464 | 12 | 244 | 73 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 151844 | 607398 | 354303 | 1089535 | 2228223 | 3735551 | 7340032 | 10 | 151 | 66 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 142372 | 569601 | 385023 | 1163263 | 1482751 | 2506751 | 6307840 | 17 | 254 | 73 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 174570 | 698325 | 362495 | 536575 | 946175 | 1253375 | 3538944 | 1 | 153 | 54 | **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 111300 | 445245 | 509951 | 1187839 | 1630207 | 2637823 | 3670016 | 11 | 224 | 61 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 90009 | 360116 | 720895 | 2228223 | 3063807 | 4273875 | 12206080 | 20 | 237 | 81 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 70598 | 282423 | 880639 | 1449983 | 2883583 | 3964927 | 12402688 | 10 | 202 | 66 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 48909 | 195669 | 1122303 | 2965503 | 3915775 | 5472255 | 9453568 | 13 | 3 | 1 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 63824 | 255324 | 962559 | 1712127 | 2539519 | 3178495 | 6684672 | 2 | 65 | 17 | **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 53799 | 215233 | 1146879 | 2080767 | 2785279 | 3391487 | 6815744 | 1 | 116 | 35 | **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 32639 | 130562 | 2047999 | 3342335 | 5636095 | 5931007 | 12222464 | 6 | 228 | 43 | **OTHER WORK** |
```

### Run 3, job 108773890109

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 155029 | 620127 | 84991 | 323583 | 569343 | 2441215 | 5373952 | 17 | 306 | 280 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 132362 | 529458 | 96255 | 339967 | 634879 | 1138687 | 5341184 | 17 | 301 | 270 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 179471 | 717898 | 77311 | 215039 | 354303 | 540671 | 1654784 | 41 | 302 | 204 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 97517 | 390081 | 141311 | 325631 | 1138687 | 3309567 | 1753088 | 18 | 302 | 188 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 96834 | 387341 | 140287 | 557055 | 1417215 | 3981311 | 4308992 | 15 | 303 | 195 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 126912 | 507659 | 94207 | 452607 | 794623 | 2056191 | 5505024 | 59 | 256 | 75 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 148628 | 594523 | 94207 | 339967 | 724991 | 1761279 | 5390336 | 60 | 281 | 148 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 166106 | 664436 | 80895 | 243711 | 409599 | 643071 | 1654784 | 1 | 291 | 86 | **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 75396 | 301594 | 175103 | 679935 | 1351679 | 3653631 | 1753088 | 56 | 206 | 126 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 84709 | 338904 | 164863 | 573439 | 1171455 | 2965503 | 4292608 | 37 | 216 | 172 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 58912 | 235667 | 254975 | 737279 | 1966079 | 4358143 | 5783552 | 114 | 210 | 72 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 107738 | 430962 | 123391 | 421887 | 634879 | 1171455 | 5521408 | 79 | 258 | 46 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 65870 | 263490 | 224255 | 790527 | 1269759 | 2621439 | 1916928 | 116 | 242 | 78 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 37663 | 150667 | 382975 | 1327103 | 2703359 | 8770625 | 2015232 | 7 | 182 | 43 | **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 55055 | 220226 | 254975 | 876543 | 2195455 | 4718591 | 4292608 | 27 | 114 | 37 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 46140 | 184572 | 260095 | 1179647 | 2441215 | 3833855 | 7225344 | 2 | 114 | 29 | **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 54237 | 216961 | 222207 | 921599 | 1712127 | 3981311 | 6307840 | 12 | 17 | 2 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 38099 | 152408 | 335871 | 1400831 | 2605055 | 7045119 | 2703360 | 22 | 19 | 6 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 37615 | 150475 | 358399 | 1015807 | 1613823 | 2785279 | 2801664 | 20 | 3 | 1 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 31387 | 125557 | 483327 | 1351679 | 2342911 | 5865471 | 4308992 | 53 | 3 | 0 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 96197 | 384806 | 593919 | 2359295 | 3833855 | 4620287 | 5783552 | 61 | 186 | 56 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 107811 | 431295 | 485375 | 1933311 | 3670015 | 6291455 | 5521408 | 59 | 115 | 48 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 108272 | 433120 | 489471 | 1949695 | 3555327 | 6225919 | 2490368 | 45 | 26 | 5 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 93952 | 375852 | 569343 | 1859583 | 4489215 | 5767167 | 2555904 | 38 | 13 | 4 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 72181 | 288752 | 770047 | 2293759 | 3899391 | 8847359 | 12238848 | 42 | 15 | 4 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 95007 | 380061 | 598015 | 2211839 | 3473407 | 5570559 | 6307840 | 43 | 79 | 18 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 79169 | 316731 | 745471 | 2179071 | 4554751 | 8519679 | 5783552 | 30 | 9 | 2 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 72225 | 288940 | 798719 | 2473983 | 4227071 | 9175039 | 2490368 | 32 | 11 | 4 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 86256 | 345056 | 610303 | 2088959 | 4259839 | 5210111 | 2637824 | 42 | 3 | 1 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 78304 | 313322 | 741375 | 2408447 | 4816895 | 11862015 | 12238848 | 12 | 270 | 48 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 90032 | 360171 | 468991 | 2375679 | 4095999 | 8781823 | 7356416 | 17 | 195 | 57 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 106104 | 424474 | 481279 | 1703935 | 2719743 | 6291455 | 6307840 | 33 | 165 | 27 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 82466 | 329920 | 647167 | 2342911 | 3686399 | 6684671 | 3538944 | 8 | 67 | 14 | **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 64514 | 258077 | 958463 | 2072575 | 3850239 | 5144575 | 3686400 | 54 | 118 | 21 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 74216 | 296897 | 806911 | 2113535 | 3751935 | 11272191 | 12222464 | 31 | 117 | 34 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 24209 | 96850 | 2392063 | 6881279 | 11206655 | 13698083 | 13631488 | 14 | 70 | 13 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 25650 | 102661 | 2342911 | 5767167 | 8978431 | 9437183 | 9437184 | 6 | 9 | 4 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 26519 | 106143 | 2179071 | 5898239 | 8847359 | 14417919 | 6684672 | 5 | 7 | 2 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 23852 | 95465 | 2637823 | 5275647 | 9568255 | 10851292 | 6832128 | 24 | 129 | 23 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 22690 | 90828 | 2899967 | 4980735 | 7307263 | 13369343 | 12238848 | 7 | 55 | 21 | **OTHER WORK** |
```

### Run 4, job 108773890065

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 101786 | 407168 | 119807 | 409599 | 847871 | 2768895 | 5373952 | 17 | 300 | 96 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 83060 | 332256 | 162815 | 700415 | 1581055 | 3735551 | 5341184 | 29 | 303 | 54 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 99869 | 399485 | 133119 | 741375 | 1335295 | 2654207 | 1654784 | 32 | 302 | 134 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 65459 | 261840 | 217087 | 663551 | 1654783 | 4095999 | 1769472 | 23 | 209 | 74 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 68322 | 273294 | 186367 | 1187839 | 3768319 | 8716287 | 4276224 | 23 | 118 | 20 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 80181 | 320730 | 188415 | 536575 | 1130495 | 3227647 | 5505024 | 42 | 10 | 3 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 83666 | 334677 | 174079 | 606207 | 1146879 | 2539519 | 5390336 | 15 | 115 | 21 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 89353 | 357422 | 163839 | 507903 | 1064959 | 2392063 | 1654784 | 13 | 21 | 4 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 44395 | 177603 | 315391 | 1003519 | 3850239 | 6553599 | 1769472 | 35 | 119 | 24 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 76419 | 305684 | 198655 | 581631 | 1777663 | 6619135 | 4308992 | 5 | 171 | 31 | **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 63546 | 254195 | 220159 | 937983 | 2015231 | 5406719 | 5767168 | 10 | 121 | 23 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 74447 | 297816 | 186367 | 589823 | 1425407 | 3571711 | 5521408 | 12 | 127 | 47 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 68679 | 274867 | 207871 | 815103 | 1769471 | 2834431 | 1916928 | 26 | 101 | 19 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 52797 | 211213 | 276479 | 708607 | 1777663 | 4521983 | 2031616 | 23 | 118 | 21 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 52696 | 210793 | 249855 | 1343487 | 4653055 | 11272191 | 4308992 | 26 | 121 | 29 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 41841 | 167372 | 327679 | 983039 | 1630207 | 3473407 | 7225344 | 8 | 42 | 14 |  |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 34527 | 138117 | 430079 | 1441791 | 3211263 | 6778583 | 6307840 | 12 | 63 | 13 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 38691 | 154787 | 374783 | 1056767 | 2654207 | 3473407 | 2703360 | 26 | 117 | 22 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 29451 | 117819 | 507903 | 1368063 | 2441215 | 4882431 | 2818048 | 9 | 40 | 12 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 28789 | 115167 | 524287 | 1523711 | 3915775 | 11534335 | 4308992 | 34 | 87 | 29 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 92397 | 369611 | 593919 | 2654207 | 6291455 | 11741042 | 5767168 | 37 | 11 | 3 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 122645 | 490646 | 438271 | 1310719 | 2162687 | 4514750 | 5537792 | 24 | 128 | 24 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 133652 | 534830 | 354303 | 1531903 | 2965503 | 4620287 | 2473984 | 17 | 113 | 27 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 85022 | 340130 | 671743 | 2162687 | 3620863 | 5308415 | 2654208 | 19 | 119 | 24 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 97650 | 390635 | 614399 | 1589247 | 3522559 | 7372799 | 12206080 | 9 | 120 | 20 | **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 95599 | 382431 | 548863 | 2506751 | 4095999 | 5767167 | 6307840 | 52 | 124 | 29 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 117108 | 468463 | 436223 | 1720319 | 4227071 | 10551295 | 5783552 | 8 | 127 | 25 | **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 101315 | 405299 | 516095 | 2293759 | 4079615 | 8224767 | 2473984 | 48 | 116 | 40 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 90810 | 363257 | 626687 | 1728511 | 3358719 | 5308415 | 2572288 | 28 | 5 | 1 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 71595 | 286417 | 778239 | 2899967 | 5734399 | 26083327 | 12206080 | 22 | 17 | 7 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 91483 | 365977 | 581631 | 2007039 | 3358719 | 5505023 | 7274496 | 9 | 113 | 27 | **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 75702 | 302896 | 671743 | 3194879 | 4587519 | 8716287 | 6307840 | 36 | 110 | 22 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 78963 | 315923 | 733183 | 2244607 | 3555327 | 5453584 | 3538944 | 36 | 3 | 0 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 58759 | 235066 | 987135 | 3014655 | 4620287 | 8060927 | 3702784 | 14 | 14 | 7 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 65475 | 261907 | 933887 | 2736127 | 6553599 | 18612223 | 12206080 | 11 | 120 | 20 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 33113 | 132524 | 1564671 | 4980735 | 6782975 | 8224767 | 13647872 | 25 | 295 | 188 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 38017 | 152125 | 1482751 | 4014079 | 5242879 | 6651903 | 9453568 | 30 | 307 | 216 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 39100 | 156486 | 1417215 | 4227071 | 6389759 | 9830399 | 6684672 | 44 | 295 | 233 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 31661 | 126716 | 1810431 | 5603327 | 8978431 | 15597567 | 6733824 | 31 | 297 | 228 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 24600 | 98411 | 2555903 | 6127615 | 8781823 | 11197709 | 12222464 | 35 | 304 | 243 | **RUNS DISAGREE** **OTHER WORK** |
```
