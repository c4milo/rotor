# One cross-core message with and without the skipped poll, `mac`, 2026-09-25

`./zig-out/bin/crosscore_runner` with its defaults, from two builds of `zig build bench-crosscore
bench-alternatives`: commit `507c762`, and the same commit with the change that makes a polling
tick with nothing to ask the kernel make no `kevent` call (decision 12, point 6, its second
amendment). The rows name them `507c762` and `skip`. The runs alternate, `507c762` then `skip`, six
rounds each, so drift reaches both. Each round runs rotor, libuv and libxev five times each, and the
row is the median of those five. libuv and libxev are built from the same sources in both builds,
and the change does not reach them, so they show how far the machine moved between the two.

A script started the rounds once the 5-minute load average had stayed under 1.5 at three readings a
minute apart. What it recorded then:

```text
quiet at minute 509, 2026-09-25T07:04:07Z, load { 1.49 1.42 2.32 }
Apple M1 Pro
10
34359738368
ProductName:		macOS
ProductVersion:		26.6.2
BuildVersion:		25G83
```

The two `other work` columns are what `bench/harness/other_work.zig` read in the pauses around each
run, in hundredths of one core. A peak of 50 or more marks a row **OTHER WORK**, and every row here
has the mark: the machine was quieter than on 2026-09-22 and was not idle.

## Round 1, `507c762`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 405260 | 40000 | 2007 | 5023 | 11519 | 18559 | 0 | 8 | 142 | 35 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 545911 | 40000 | 1500 | 4500 | 9000 | 15500 | 0 | 5 | 219 | 51 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 449620 | 40000 | 2007 | 6015 | 13503 | 19583 | 0 | 5 | 176 | 43 | **OTHER WORK** |
```

## Round 1, `skip`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 480272 | 40000 | 2007 | 5023 | 9023 | 17535 | 0 | 12 | 280 | 89 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 553349 | 40000 | 1500 | 4500 | 8000 | 17000 | 0 | 4 | 299 | 49 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 468367 | 40000 | 2007 | 5503 | 10559 | 21119 | 0 | 14 | 209 | 53 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 2, `507c762`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 399644 | 40000 | 2007 | 5503 | 12031 | 21119 | 0 | 15 | 170 | 59 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 552112 | 40000 | 1500 | 4500 | 11500 | 16500 | 0 | 3 | 84 | 37 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 462818 | 40000 | 2007 | 6015 | 15039 | 23039 | 0 | 13 | 191 | 76 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 2, `skip`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 477891 | 40000 | 2007 | 5023 | 12031 | 18047 | 0 | 9 | 90 | 32 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 582614 | 40000 | 1500 | 4000 | 7000 | 17500 | 0 | 21 | 265 | 60 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 463322 | 40000 | 2007 | 5503 | 11519 | 19071 | 0 | 10 | 172 | 56 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 3, `507c762`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 399808 | 40000 | 2007 | 5503 | 9535 | 16511 | 0 | 5 | 207 | 71 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 544180 | 40000 | 1500 | 4500 | 10000 | 17500 | 0 | 9 | 149 | 49 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 468663 | 40000 | 2007 | 5023 | 10559 | 20095 | 0 | 17 | 253 | 60 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 3, `skip`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 470848 | 40000 | 2007 | 5023 | 10559 | 20095 | 0 | 8 | 434 | 78 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 552425 | 40000 | 1500 | 4500 | 8500 | 15500 | 0 | 16 | 368 | 97 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 480232 | 40000 | 2007 | 5023 | 10559 | 18559 | 0 | 15 | 177 | 45 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 4, `507c762`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 405679 | 40000 | 2007 | 5023 | 11519 | 18559 | 0 | 3 | 199 | 60 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 556173 | 40000 | 1500 | 4500 | 8000 | 15000 | 0 | 4 | 222 | 34 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 465863 | 40000 | 2007 | 5503 | 12543 | 22015 | 0 | 5 | 384 | 113 | **OTHER WORK** |
```

## Round 4, `skip`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 472589 | 40000 | 2007 | 5503 | 12031 | 18559 | 0 | 17 | 192 | 49 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 551731 | 40000 | 1500 | 5000 | 10500 | 17500 | 0 | 11 | 561 | 82 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 468773 | 40000 | 2007 | 5023 | 10559 | 18559 | 0 | 8 | 288 | 67 | **OTHER WORK** |
```

## Round 5, `507c762`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 397314 | 40000 | 2007 | 5503 | 12031 | 17535 | 0 | 1 | 196 | 69 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 573049 | 40000 | 1500 | 4500 | 7500 | 15500 | 0 | 14 | 81 | 32 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 452534 | 40000 | 2007 | 5503 | 12543 | 21119 | 0 | 6 | 322 | 76 | **OTHER WORK** |
```

## Round 5, `skip`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 474952 | 40000 | 2007 | 5023 | 11519 | 20607 | 0 | 5 | 241 | 77 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 572287 | 40000 | 1500 | 4500 | 9500 | 17500 | 0 | 11 | 303 | 62 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 459163 | 40000 | 2007 | 5023 | 10047 | 19071 | 0 | 9 | 271 | 47 | **OTHER WORK** |
```

## Round 6, `507c762`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 404028 | 40000 | 2007 | 5503 | 10559 | 17023 | 0 | 6 | 78 | 39 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 575142 | 40000 | 1500 | 4000 | 9500 | 16000 | 0 | 13 | 257 | 49 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 449241 | 40000 | 2007 | 5503 | 13055 | 21503 | 0 | 28 | 493 | 120 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 6, `skip`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 473081 | 40000 | 2007 | 5023 | 11519 | 21119 | 0 | 4 | 57 | 31 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 584316 | 40000 | 1500 | 5000 | 13000 | 22500 | 0 | 9 | 487 | 72 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 461190 | 40000 | 2007 | 5503 | 11007 | 18559 | 0 | 3 | 284 | 86 | **OTHER WORK** |
```
