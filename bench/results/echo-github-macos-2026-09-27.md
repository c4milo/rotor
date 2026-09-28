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

## With Spotlight indexing off, 2026-09-28

The run above listed nothing about its other work, so the next run printed the processes using the
most CPU. Spotlight's `mds_stores`, `mds` and `mdworker_shared` used about one processor of three.
Run 36376749918, from 04:13 UTC on 2026-09-28, then turned indexing off with `sudo mdutil -a -i
off` before it built anything, and waited for those processes to go quiet. Four `comparison` jobs
ran on their own `macos-latest` runners, on a branch commit whose echo servers and client were the
same as above.

Spotlight's processes went from 206, 83, 99 and 45 percent of a processor to 0, 0, 0 and 3.
The runs still disagreed in 138 of 160 echo rows, and 96 rows reported other work, against
134 and 132 before. rotor's own runs spread by up to 151 percent, and by 32 percent in a row whose
runner saw 3 hundredths of a processor of other work. So the noise is not from a process these
runners show, and the step that turned indexing off was not kept.

rotor's median echoes per second in each run, then its spread percent and the peak other work, in
hundredths of a processor:

| connections | payload bytes | run 1 | run 2 | run 3 | run 4 |
|---:|---:|---:|---:|---:|---:|
| 16 | 4096 | 71467 (27, 250) | 94865 (97, 305) | 97224 (73, 181) | 100828 (27, 126) |
| 16 | 8192 | 95076 (21, 197) | 148992 (27, 93) | 161383 (1, 111) | 82365 (49, 229) |
| 16 | 16384 | 75186 (36, 14) | 131413 (5, 94) | 82985 (86, 60) | 99466 (67, 11) |
| 16 | 65536 | 36419 (61, 114) | 78227 (7, 103) | 71375 (46, 14) | 53244 (59, 115) |
| 64 | 4096 | 126067 (4, 148) | 93639 (151, 109) | 191016 (18, 137) | 82568 (31, 25) |
| 64 | 8192 | 117093 (39, 22) | 131831 (42, 5) | 151957 (32, 3) | 195950 (28, 17) |
| 64 | 16384 | 69110 (60, 36) | 93430 (46, 121) | 84091 (114, 19) | 168178 (2, 87) |
| 64 | 65536 | 37025 (34, 127) | 26857 (26, 10) | 30317 (33, 68) | 65039 (29, 95) |

The echo rows each job printed follow.

### Run 1, job 108784054147

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 71467 | 285883 | 167935 | 856063 | 2752511 | 6717439 | 5373952 | 27 | 250 | 51 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 81511 | 326060 | 190463 | 466943 | 1019903 | 2572287 | 5324800 | 58 | 302 | 127 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 86271 | 345106 | 168959 | 614399 | 1343487 | 3538943 | 1638400 | 42 | 288 | 164 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 52810 | 211247 | 248831 | 729087 | 1531903 | 3145727 | 1769472 | 40 | 259 | 100 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 85874 | 343513 | 178175 | 569343 | 1294335 | 4194303 | 4308992 | 25 | 38 | 16 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 95076 | 380319 | 154623 | 393215 | 671743 | 1138687 | 5472256 | 21 | 197 | 42 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 63956 | 255834 | 231423 | 663551 | 1540095 | 3915775 | 5373952 | 35 | 13 | 3 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 84823 | 339302 | 169983 | 544767 | 868351 | 1761279 | 1638400 | 81 | 239 | 71 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 73374 | 293515 | 189439 | 565247 | 1196031 | 2588671 | 1769472 | 34 | 141 | 49 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 77867 | 311482 | 190463 | 638975 | 1867775 | 6127615 | 4308992 | 36 | 11 | 2 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 75186 | 300760 | 208895 | 499711 | 815103 | 2637823 | 5767168 | 36 | 14 | 3 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 59157 | 236644 | 262143 | 569343 | 1019903 | 4194303 | 5521408 | 43 | 109 | 51 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 66759 | 267047 | 225279 | 679935 | 1236991 | 3129343 | 1900544 | 40 | 119 | 45 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 58556 | 234238 | 253951 | 708607 | 1392639 | 4161535 | 2097152 | 31 | 120 | 36 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 53504 | 214026 | 274431 | 937983 | 3096575 | 6094847 | 4308992 | 27 | 36 | 10 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 36419 | 145699 | 434175 | 966655 | 1482751 | 2277375 | 7127040 | 61 | 114 | 45 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 31481 | 125940 | 477183 | 942079 | 1605631 | 2621439 | 6291456 | 42 | 115 | 33 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 36107 | 144451 | 436223 | 1204223 | 2179071 | 3571711 | 2686976 | 47 | 72 | 21 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 33790 | 135170 | 448511 | 1011711 | 1474559 | 2588671 | 2801664 | 31 | 111 | 22 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 36959 | 147847 | 421887 | 1064959 | 1703935 | 3358719 | 4292608 | 16 | 66 | 14 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 126067 | 504306 | 452607 | 1449983 | 2539519 | 3735551 | 5750784 | 4 | 148 | 30 | **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 154130 | 616536 | 344063 | 1003519 | 1359871 | 2490367 | 5521408 | 30 | 3 | 0 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 91236 | 365014 | 651263 | 2146303 | 2949119 | 6160383 | 2473984 | 23 | 81 | 15 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 79532 | 318162 | 778239 | 1957887 | 3801087 | 6127615 | 2654208 | 108 | 120 | 40 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 82993 | 332003 | 745471 | 1581055 | 2588671 | 5439487 | 12222464 | 2 | 116 | 40 | **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 117093 | 468398 | 458751 | 1957887 | 3751935 | 5013503 | 6291456 | 39 | 22 | 6 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 127682 | 510833 | 430079 | 1236991 | 2457599 | 3276799 | 5767168 | 43 | 9 | 3 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 116352 | 465437 | 473087 | 1638399 | 3260415 | 9568255 | 2457600 | 59 | 17 | 9 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 97349 | 389448 | 518143 | 2162687 | 3768319 | 4915199 | 2637824 | 37 | 121 | 43 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 84968 | 339958 | 724991 | 1679359 | 3407871 | 5111807 | 12222464 | 31 | 126 | 25 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 69110 | 276484 | 892927 | 2457599 | 4063231 | 5079039 | 7323648 | 60 | 36 | 7 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 73949 | 295823 | 839679 | 1802239 | 2703359 | 4990875 | 6307840 | 59 | 98 | 22 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 69174 | 276704 | 872447 | 2473983 | 3178495 | 3637247 | 3522560 | 39 | 115 | 22 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 50026 | 200134 | 1187839 | 2818047 | 3964927 | 5286000 | 3702784 | 6 | 15 | 4 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 57142 | 228577 | 1105919 | 2523135 | 5210111 | 9043967 | 12222464 | 5 | 10 | 2 |  |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 37025 | 148117 | 1335295 | 5144575 | 8716287 | 9961471 | 13615104 | 34 | 127 | 23 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 33202 | 132830 | 1818623 | 4194303 | 5373951 | 6586367 | 9437184 | 16 | 8 | 1 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 31154 | 124698 | 1908735 | 4685823 | 5996543 | 6979583 | 6668288 | 40 | 123 | 26 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 23335 | 93368 | 2703359 | 5832703 | 8028159 | 9502719 | 6832128 | 6 | 22 | 7 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 22776 | 91127 | 2850815 | 4390911 | 7012351 | 8159231 | 12222464 | 18 | 10 | 4 | **RUNS DISAGREE** |
```

### Run 2, job 108784054123

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 94865 | 379477 | 152575 | 528383 | 1187839 | 3473407 | 5390336 | 97 | 305 | 119 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 116496 | 465994 | 98303 | 438271 | 684031 | 1630207 | 5341184 | 53 | 254 | 98 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 129769 | 519085 | 80895 | 370687 | 835583 | 2523135 | 1638400 | 24 | 203 | 86 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 85251 | 341020 | 173055 | 464895 | 995327 | 2424831 | 1753088 | 34 | 307 | 123 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 90078 | 360324 | 149503 | 610303 | 1335295 | 4521983 | 4308992 | 63 | 198 | 68 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 148992 | 595982 | 95231 | 229375 | 358399 | 585727 | 5472256 | 27 | 93 | 17 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 142426 | 569718 | 95231 | 346111 | 888831 | 4390911 | 5390336 | 72 | 89 | 35 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 170530 | 682134 | 81919 | 252927 | 569343 | 1302527 | 1638400 | 27 | 104 | 21 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 94666 | 378680 | 164863 | 268287 | 428031 | 663551 | 1753088 | 6 | 103 | 27 | **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 89930 | 359726 | 150527 | 565247 | 1507327 | 4095999 | 4308992 | 6 | 209 | 42 | **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 131413 | 525663 | 107007 | 278527 | 442367 | 802815 | 5750784 | 5 | 94 | 25 | **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 129896 | 519597 | 107519 | 286719 | 421887 | 638975 | 5521408 | 15 | 57 | 19 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 148043 | 592180 | 98303 | 258047 | 409599 | 643071 | 1900544 | 3 | 8 | 2 |  |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 85234 | 340951 | 182271 | 313343 | 448511 | 737279 | 2015232 | 5 | 8 | 2 |  |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 99679 | 398720 | 154623 | 342015 | 509951 | 819199 | 4308992 | 16 | 126 | 22 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 78227 | 312925 | 185343 | 460799 | 651263 | 1335295 | 7094272 | 7 | 103 | 20 | **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 66746 | 266993 | 196607 | 606207 | 897023 | 1286143 | 6307840 | 32 | 5 | 2 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 64532 | 258141 | 188415 | 659455 | 995327 | 1802239 | 2686976 | 24 | 142 | 24 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 53824 | 215311 | 272383 | 733183 | 1269759 | 3784703 | 2801664 | 17 | 195 | 34 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 50663 | 202661 | 315391 | 798719 | 2088959 | 5177343 | 4308992 | 26 | 208 | 37 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 93639 | 374578 | 651263 | 1892351 | 3817471 | 5046271 | 5750784 | 151 | 109 | 40 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 100064 | 400304 | 602111 | 1490943 | 3571711 | 5373951 | 5537792 | 40 | 107 | 35 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 106047 | 424253 | 548863 | 1933311 | 3801087 | 4849663 | 2473984 | 22 | 3 | 0 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 75049 | 300235 | 798719 | 1851391 | 3342335 | 5275647 | 2637824 | 71 | 32 | 13 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 105054 | 420306 | 565247 | 1531903 | 3997695 | 10878975 | 12206080 | 37 | 116 | 20 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 131831 | 527362 | 370687 | 1687551 | 2998271 | 3928583 | 6275072 | 42 | 5 | 1 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 94645 | 378607 | 618495 | 1810431 | 3244031 | 5242879 | 5783552 | 27 | 5 | 1 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 126830 | 507385 | 329727 | 1818623 | 3309567 | 6422527 | 2473984 | 70 | 9 | 2 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 85947 | 343853 | 598015 | 1957887 | 4063231 | 7962623 | 2637824 | 29 | 118 | 43 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 76519 | 306105 | 786431 | 3194879 | 6422527 | 9175039 | 12222464 | 26 | 118 | 45 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 93430 | 373809 | 569343 | 2179071 | 3424255 | 4620287 | 7356416 | 46 | 121 | 23 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 69190 | 276797 | 901119 | 1933311 | 3391487 | 4161535 | 6307840 | 103 | 28 | 6 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 68754 | 275067 | 888831 | 2277375 | 3702783 | 7405567 | 3506176 | 100 | 34 | 6 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 50907 | 203668 | 1122303 | 3506175 | 6324223 | 10175625 | 3604480 | 10 | 12 | 3 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 55813 | 223268 | 1081343 | 2736127 | 4325375 | 9043967 | 12206080 | 45 | 2 | 0 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 26857 | 107496 | 2228223 | 5505023 | 8060927 | 11823167 | 13647872 | 26 | 10 | 3 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 27818 | 111323 | 2179071 | 5079039 | 10420223 | 13905875 | 9453568 | 32 | 120 | 37 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 30894 | 123613 | 1884159 | 5275647 | 7372799 | 8454143 | 6668288 | 57 | 122 | 51 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 27674 | 110750 | 2056191 | 5472255 | 7962623 | 12124159 | 6832128 | 93 | 13 | 3 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 25494 | 102023 | 2441215 | 5177343 | 7995391 | 10813439 | 12206080 | 38 | 11 | 6 | **RUNS DISAGREE** |
```

### Run 3, job 108784054080

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 97224 | 388900 | 147455 | 448511 | 876543 | 2129919 | 5373952 | 73 | 181 | 70 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 103175 | 412720 | 106495 | 446463 | 983039 | 2211839 | 5341184 | 63 | 142 | 86 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 86035 | 344158 | 168959 | 630783 | 1114111 | 1900543 | 1654784 | 95 | 38 | 10 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 94683 | 378744 | 152575 | 444415 | 761855 | 1474559 | 1753088 | 26 | 12 | 6 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 88019 | 352084 | 148479 | 692223 | 3162111 | 8978431 | 4308992 | 62 | 147 | 46 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 161383 | 645544 | 86015 | 220159 | 393215 | 598015 | 5505024 | 1 | 111 | 38 | **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 162352 | 649429 | 92671 | 204799 | 339967 | 514047 | 5390336 | 10 | 5 | 0 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 171760 | 687047 | 81407 | 272383 | 491519 | 835583 | 1654784 | 21 | 57 | 20 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 103097 | 412389 | 151551 | 233471 | 360447 | 565247 | 1753088 | 5 | 109 | 36 | **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 123617 | 494479 | 124927 | 311295 | 729087 | 1269759 | 4308992 | 6 | 177 | 36 | **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 82985 | 331960 | 168959 | 497663 | 868351 | 2179071 | 5734400 | 86 | 60 | 20 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 57260 | 229047 | 264191 | 716799 | 1335295 | 2080767 | 5521408 | 157 | 7 | 3 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 57421 | 229694 | 242687 | 651263 | 1073151 | 1597439 | 1916928 | 68 | 5 | 2 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 53630 | 214523 | 266239 | 835583 | 1384447 | 5242879 | 2015232 | 37 | 27 | 8 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 66119 | 264492 | 214015 | 643071 | 1728511 | 3653631 | 4308992 | 17 | 121 | 26 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 71375 | 285510 | 190463 | 630783 | 888831 | 2703359 | 7028736 | 46 | 14 | 2 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 64856 | 259449 | 194559 | 557055 | 1028095 | 2293759 | 6291456 | 7 | 13 | 7 |  |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 76701 | 306816 | 183295 | 630783 | 950271 | 1712127 | 2703360 | 12 | 90 | 18 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 52451 | 209820 | 274431 | 647167 | 974847 | 1409023 | 2801664 | 9 | 123 | 41 | **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 50599 | 202404 | 301055 | 720895 | 1531903 | 3162111 | 4308992 | 19 | 4 | 2 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 191016 | 764132 | 301055 | 819199 | 1277951 | 2023423 | 5734400 | 18 | 137 | 27 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 166430 | 665767 | 333823 | 860159 | 1499135 | 2375679 | 5537792 | 5 | 94 | 25 | **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 164698 | 658852 | 305151 | 1433599 | 2359295 | 6782975 | 2473984 | 21 | 13 | 5 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 129079 | 516360 | 430079 | 1155071 | 1605631 | 1851391 | 2637824 | 21 | 7 | 2 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 95496 | 381988 | 610303 | 1499135 | 2146303 | 2899967 | 12222464 | 29 | 72 | 21 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 151957 | 607845 | 335871 | 1032191 | 1720319 | 2523135 | 6258688 | 32 | 3 | 0 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 177875 | 711537 | 342015 | 655359 | 901119 | 1236991 | 5767168 | 4 | 16 | 5 |  |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 173571 | 694325 | 319487 | 933887 | 1712127 | 2539519 | 2490368 | 49 | 5 | 1 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 137595 | 550418 | 428031 | 1196031 | 1523711 | 2490367 | 2637824 | 61 | 117 | 21 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 104580 | 418347 | 610303 | 1122303 | 2039807 | 9830399 | 12222464 | 51 | 114 | 41 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 84091 | 336394 | 561151 | 2818047 | 6094847 | 10551295 | 7356416 | 114 | 19 | 9 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 88532 | 354174 | 585727 | 2342911 | 5079039 | 7372799 | 6307840 | 28 | 24 | 8 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 116013 | 464104 | 389119 | 2342911 | 4358143 | 9175039 | 3522560 | 39 | 18 | 7 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 90604 | 362450 | 610303 | 1843199 | 2834431 | 4685823 | 3604480 | 28 | 75 | 16 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 77687 | 310777 | 741375 | 2260991 | 3555327 | 7550375 | 12222464 | 29 | 122 | 22 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 30317 | 121335 | 1900543 | 5865471 | 10485759 | 14677000 | 13631488 | 33 | 68 | 12 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 44499 | 178038 | 1114111 | 4259839 | 6160383 | 8519679 | 9453568 | 30 | 27 | 7 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 40050 | 160230 | 1236991 | 4653055 | 8355839 | 17442959 | 6684672 | 7 | 14 | 5 |  |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 38843 | 155436 | 1359871 | 4489215 | 7667711 | 11075583 | 6832128 | 16 | 19 | 10 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 27257 | 109104 | 2277375 | 5373951 | 8650751 | 10944511 | 12222464 | 15 | 110 | 24 | **RUNS DISAGREE** **OTHER WORK** |
```

### Run 4, job 108784054186

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
| echo | rotor | this tree | 0 | 16 | 4096 | even | 3 | 100828 | 403360 | 125439 | 589823 | 1236991 | 2670591 | 5357568 | 27 | 126 | 59 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 4096 | even | 3 | 86012 | 344087 | 158719 | 716799 | 1605631 | 6029311 | 5324800 | 62 | 300 | 152 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 4096 | even | 3 | 65038 | 260159 | 193535 | 1187839 | 3031039 | 13893631 | 1638400 | 24 | 292 | 127 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 4096 | even | 3 | 60499 | 242004 | 239615 | 757759 | 2785279 | 6586367 | 1736704 | 49 | 270 | 85 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 4096 | even | 3 | 102250 | 409007 | 135167 | 557055 | 1835007 | 7077887 | 4292608 | 59 | 254 | 98 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 8192 | even | 3 | 82365 | 329470 | 184319 | 847871 | 2490367 | 5636095 | 5505024 | 49 | 229 | 69 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 8192 | even | 3 | 82399 | 329627 | 180223 | 544767 | 1597439 | 6062079 | 5373952 | 63 | 155 | 36 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 8192 | even | 3 | 71167 | 284799 | 184319 | 745471 | 1482751 | 2293759 | 1638400 | 165 | 301 | 100 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 8192 | even | 3 | 57542 | 230180 | 264191 | 729087 | 1785855 | 2752511 | 1736704 | 81 | 266 | 73 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 8192 | even | 3 | 73388 | 293559 | 188415 | 610303 | 1810431 | 6127615 | 4292608 | 16 | 235 | 83 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 16384 | even | 3 | 99466 | 397882 | 130559 | 503807 | 1433599 | 3833855 | 5734400 | 67 | 11 | 4 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 16384 | even | 3 | 51326 | 205325 | 268287 | 1007615 | 2637823 | 7569407 | 5505024 | 69 | 134 | 32 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 16384 | even | 3 | 93231 | 372941 | 107007 | 626687 | 1228799 | 2342911 | 1900544 | 63 | 125 | 52 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 16384 | even | 3 | 45262 | 181051 | 311295 | 1146879 | 2588671 | 4456447 | 1998848 | 37 | 8 | 1 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 16384 | even | 3 | 63171 | 252699 | 224255 | 774143 | 2015231 | 5341183 | 4292608 | 30 | 114 | 26 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 16 | 65536 | even | 3 | 53244 | 212991 | 234495 | 798719 | 1163263 | 2162687 | 7127040 | 59 | 115 | 40 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 16 | 65536 | even | 3 | 49813 | 199272 | 248831 | 950271 | 1875967 | 4390911 | 6291456 | 45 | 112 | 27 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 16 | 65536 | even | 3 | 63097 | 252419 | 208895 | 770047 | 1441791 | 3194879 | 2686976 | 49 | 86 | 16 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 16 | 65536 | even | 3 | 41754 | 167025 | 307199 | 1015807 | 1712127 | 3096575 | 2785280 | 58 | 154 | 57 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 16 | 65536 | even | 3 | 40737 | 162963 | 344063 | 1196031 | 2752511 | 4079615 | 4292608 | 67 | 126 | 55 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 4096 | even | 3 | 82568 | 330301 | 671743 | 2244607 | 5439487 | 8978431 | 5767168 | 31 | 25 | 5 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 4096 | even | 3 | 90990 | 363988 | 634879 | 2211839 | 4423679 | 9306111 | 5521408 | 54 | 193 | 35 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libuv | v1.52.1 | 0 | 64 | 4096 | even | 3 | 141121 | 564568 | 296959 | 1449983 | 2277375 | 5636095 | 2473984 | 33 | 28 | 5 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 4096 | even | 3 | 119127 | 476556 | 430079 | 1392639 | 2670591 | 4095999 | 2539520 | 17 | 97 | 19 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 4096 | even | 3 | 86186 | 344763 | 618495 | 2162687 | 3817471 | 7438335 | 12206080 | 8 | 115 | 23 | **OTHER WORK** |
| echo | rotor | this tree | 0 | 64 | 8192 | even | 3 | 195950 | 783888 | 307199 | 790527 | 1212415 | 2047999 | 6193152 | 28 | 17 | 4 | **RUNS DISAGREE** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 8192 | even | 3 | 167668 | 670711 | 335871 | 806911 | 1892351 | 3014655 | 5767168 | 49 | 12 | 4 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 8192 | even | 3 | 170184 | 680774 | 303103 | 1032191 | 1761279 | 2686975 | 2457600 | 26 | 121 | 22 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 8192 | even | 3 | 138527 | 554153 | 421887 | 1155071 | 1761279 | 2883583 | 2621440 | 41 | 13 | 4 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 8192 | even | 3 | 116234 | 464972 | 544767 | 1015807 | 2408447 | 3604479 | 12222464 | 18 | 23 | 5 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 64 | 16384 | even | 3 | 168178 | 672748 | 335871 | 987135 | 1425407 | 2162687 | 7323648 | 2 | 87 | 17 | **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 16384 | even | 3 | 165213 | 660894 | 370687 | 610303 | 909311 | 1351679 | 6307840 | 12 | 16 | 6 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 16384 | even | 3 | 136930 | 547962 | 370687 | 1458175 | 2490367 | 4784127 | 3506176 | 47 | 29 | 7 | **RUNS DISAGREE** |
| echo | libxev | 9ce8e8e | 0 | 64 | 16384 | even | 3 | 124558 | 498274 | 464895 | 1163263 | 1777663 | 2326527 | 3670016 | 20 | 114 | 20 | **RUNS DISAGREE** **OTHER WORK** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 16384 | even | 3 | 103615 | 414520 | 651263 | 1261567 | 2457599 | 5636095 | 12206080 | 20 | 15 | 6 | **RUNS DISAGREE** |
| echo | rotor | this tree | 0 | 64 | 65536 | even | 3 | 65039 | 260180 | 802815 | 2523135 | 3440639 | 10289151 | 12795904 | 29 | 95 | 18 | **RUNS DISAGREE** **OTHER WORK** |
| echo | rotor (accumulate) | this tree | 0 | 64 | 65536 | even | 3 | 62248 | 249035 | 823295 | 2572287 | 3309567 | 3883007 | 9420800 | 20 | 31 | 11 | **RUNS DISAGREE** |
| echo | libuv | v1.52.1 | 0 | 64 | 65536 | even | 3 | 73534 | 294180 | 843775 | 1687551 | 2572287 | 3178495 | 6651904 | 15 | 116 | 31 | **RUNS DISAGREE** **OTHER WORK** |
| echo | libxev | 9ce8e8e | 0 | 64 | 65536 | even | 3 | 52698 | 210829 | 1023999 | 2539519 | 3293183 | 4227071 | 6815744 | 19 | 9 | 1 | **RUNS DISAGREE** |
| echo | std.Io.Threaded | 0.16.0 | 0 | 64 | 65536 | even | 3 | 40196 | 160800 | 1712127 | 2588671 | 3293183 | 5472255 | 12206080 | 6 | 15 | 6 |  |
```
