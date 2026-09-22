# Cross-core message on `mac`, 2026-09-22

`./zig-out/bin/crosscore_runner` with its defaults: 5 rounds of 20,000 messages after 2,000 of
warm-up. Load average before: 327.28 93.73 37.93; after: 301.55 92.28 37.74. From 10:09:26 to
10:09:29, right after the timer run, whose last candidate had left a one-minute load average of 327
that was still decaying; that process had exited, and nothing else ran.

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median p50 ns | median p99 ns | spread percent | load low /100 | load span /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 154795 | 6015 | 16511 | 5 | 30154 | 2573 | **LOAD MOVED** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 619348 | 1500 | 5500 | 15 | 30154 | 2573 | **RUNS DISAGREE** **LOAD MOVED** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 481064 | 2007 | 7007 | 16 | 30154 | 2573 | **RUNS DISAGREE** **LOAD MOVED** |
```
