# One cross-core message with and without the wait timer, `mac`, 2026-09-27

`./zig-out/bin/crosscore_runner` with its defaults, from two builds of `zig build bench-crosscore
bench-alternatives`: commit `aebc1b2`, and the same commit with the change that bounds a tick's
wait with an `EVFILT_TIMER` and not a timeout (decision 12, point 7), pushed as `64fd5e8`. The rows
name them `aebc1b2` and `wait timer`. The runs alternate, `aebc1b2` then `wait timer`, six rounds
each, so drift reaches both. Each round runs rotor, libuv and libxev five times each, and the row is
the median of those five. libuv and libxev are built from the same sources in both builds, and the
change does not reach them, so they show how far the machine moved between the two.

A script started the rounds once the 5-minute load average had stayed under 1.5 at three readings a
minute apart, which took 12 hours. What it recorded then:

```text
quiet at minute 722, 2026-09-27T09:11:02Z, load { 0.97 1.32 3.17 }
Apple M1 Pro
10
34359738368
ProductName:		macOS
ProductVersion:		26.6.2
BuildVersion:		25G83
```

The two `other work` columns are what `bench/harness/other_work.zig` read in the pauses around each
run, in hundredths of one core. A peak of 50 or more marks a row **OTHER WORK**, and every row here
has the mark: the machine was about as quiet as on 2026-09-25 and was not idle. In 16 of the 36 round
rows the runs disagreed by 10 percent or more.

## Round 1, `aebc1b2`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 481811 | 40000 | 2007 | 4511 | 8031 | 15039 | 0 | 11 | 115 | 32 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 552906 | 40000 | 1500 | 4000 | 10500 | 23500 | 0 | 9 | 298 | 48 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 481191 | 40000 | 2007 | 5023 | 10047 | 22015 | 0 | 11 | 119 | 47 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 1, `wait timer`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 530884 | 40000 | 1503 | 4511 | 8511 | 17535 | 0 | 17 | 127 | 29 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 586381 | 40000 | 1500 | 4000 | 7000 | 17500 | 0 | 19 | 230 | 71 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 454313 | 40000 | 2007 | 5503 | 9023 | 20607 | 0 | 8 | 158 | 53 | **OTHER WORK** |
```

## Round 2, `aebc1b2`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 480538 | 40000 | 2007 | 4511 | 11519 | 18047 | 0 | 10 | 184 | 49 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 575150 | 40000 | 1500 | 4000 | 7000 | 14500 | 0 | 17 | 98 | 31 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 466967 | 40000 | 2007 | 5023 | 13055 | 23039 | 0 | 14 | 238 | 55 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 2, `wait timer`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 505331 | 40000 | 1503 | 5023 | 7519 | 23039 | 0 | 6 | 130 | 40 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 560522 | 40000 | 1500 | 4000 | 7500 | 21500 | 0 | 3 | 65 | 32 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 470084 | 40000 | 2007 | 5023 | 10559 | 22015 | 0 | 15 | 151 | 48 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 3, `aebc1b2`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 489703 | 40000 | 2007 | 4511 | 10047 | 18047 | 0 | 6 | 222 | 48 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 560561 | 40000 | 1500 | 4500 | 8000 | 20000 | 0 | 7 | 209 | 53 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 454974 | 40000 | 2007 | 5023 | 9023 | 20095 | 0 | 10 | 124 | 34 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 3, `wait timer`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 510191 | 40000 | 1503 | 4511 | 10559 | 24063 | 0 | 5 | 343 | 64 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 554561 | 40000 | 1500 | 4000 | 9000 | 17500 | 0 | 5 | 54 | 21 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 459374 | 40000 | 2007 | 5023 | 11007 | 19583 | 0 | 8 | 176 | 34 | **OTHER WORK** |
```

## Round 4, `aebc1b2`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 498827 | 40000 | 1503 | 4511 | 9535 | 21119 | 0 | 12 | 359 | 72 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 573822 | 40000 | 1500 | 4000 | 7000 | 17500 | 0 | 3 | 99 | 37 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 455181 | 40000 | 2007 | 5023 | 8511 | 15551 | 0 | 14 | 326 | 60 | **RUNS DISAGREE** **OTHER WORK** |
```

## Round 4, `wait timer`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 504935 | 40000 | 1503 | 5023 | 8511 | 16063 | 0 | 9 | 563 | 74 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 567681 | 40000 | 1500 | 4000 | 8500 | 18000 | 0 | 4 | 170 | 43 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 468093 | 40000 | 2007 | 5023 | 9023 | 20607 | 0 | 6 | 340 | 57 | **OTHER WORK** |
```

## Round 5, `aebc1b2`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 479145 | 40000 | 2007 | 5023 | 8511 | 21119 | 0 | 17 | 163 | 43 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 569751 | 40000 | 1500 | 4000 | 8000 | 17000 | 0 | 12 | 238 | 43 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 461760 | 40000 | 2007 | 5023 | 8511 | 22527 | 0 | 4 | 61 | 25 | **OTHER WORK** |
```

## Round 5, `wait timer`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 503030 | 40000 | 1503 | 4511 | 7007 | 15551 | 0 | 8 | 165 | 44 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 599763 | 40000 | 1500 | 3500 | 6000 | 15500 | 0 | 16 | 157 | 36 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 457372 | 40000 | 2007 | 5503 | 12031 | 21503 | 0 | 8 | 157 | 40 | **OTHER WORK** |
```

## Round 6, `aebc1b2`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 474141 | 40000 | 2007 | 5023 | 10559 | 21503 | 0 | 3 | 155 | 60 | **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 547900 | 40000 | 1500 | 4500 | 10000 | 22000 | 0 | 4 | 207 | 49 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 461323 | 40000 | 2007 | 5023 | 9535 | 22015 | 0 | 7 | 272 | 54 | **OTHER WORK** |
```

## Round 6, `wait timer`

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median operations | median p50 ns | median p99 ns | median p999 ns | median p9999 ns | median peak rss bytes | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 506868 | 40000 | 1503 | 4511 | 9535 | 22527 | 0 | 11 | 61 | 21 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 552318 | 40000 | 1500 | 4000 | 7000 | 15500 | 0 | 4 | 140 | 47 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 468225 | 40000 | 2007 | 5023 | 8511 | 20607 | 0 | 17 | 63 | 34 | **RUNS DISAGREE** **OTHER WORK** |
```

The script ended at:

```text
done at 2026-09-27T09:12:55Z, load { 1.84 1.42 2.98 }
```
