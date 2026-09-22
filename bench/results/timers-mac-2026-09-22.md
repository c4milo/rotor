# Timer churn on `mac`, 2026-09-22

`./zig-out/bin/timers_runner` with its defaults: 5 rounds of 3 seconds, 256 and 4,096 timers, a
1 ms period. Load average before: 5.97 6.06 5.34; after: 327.28 93.73 37.93. From 10:07:25 to
10:09:26. The load average after the run is the `std.Io.Threaded` candidate's own: at 4,096 timers
it sleeps 4,096 threads, and macOS counts them.

```text
timers_runner: std.Io.Uring runs on Linux alone, skipping it
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median p50 ns | median p99 ns | spread percent | load low /100 | load span /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
| timer-churn | rotor | this tree | 0 | 256 | 0 | even | 5 | 209223 | 164000 | 438000 | 5 | 582 | 248 | **LOAD MOVED** |
| timer-churn | libuv | 1.52.1 | 0 | 256 | 0 | even | 5 | 213746 | 183000 | 288000 | 6 | 581 | 249 | **LOAD MOVED** |
| timer-churn | libxev | 9ce8e8e | 0 | 256 | 0 | even | 5 | 220546 | 171000 | 231000 | 1 | 581 | 207 | **LOAD MOVED** |
| timer-churn | std.Io.Threaded | 0.16.0 | 0 | 256 | 0 | even | 5 | 204044 | 259000 | 486000 | 0 | 582 | 248 | **LOAD MOVED** |
| timer-churn | rotor | this tree | 0 | 4096 | 0 | even | 5 | 2382212 | 540000 | 654000 | 13 | 577 | 28434 | **RUNS DISAGREE** **LOAD MOVED** |
| timer-churn | libuv | 1.52.1 | 0 | 4096 | 0 | even | 5 | 2084026 | 917000 | 1060000 | 10 | 577 | 28434 | **RUNS DISAGREE** **LOAD MOVED** |
| timer-churn | libxev | 9ce8e8e | 0 | 4096 | 0 | even | 5 | 3231801 | 436000 | 850000 | 1 | 577 | 26207 | **LOAD MOVED** |
| timer-churn | std.Io.Threaded | 0.16.0 | 0 | 4096 | 0 | even | 5 | 446145 | 300000 | 2559000 | 9 | 595 | 32132 | **LOAD MOVED** |
```
