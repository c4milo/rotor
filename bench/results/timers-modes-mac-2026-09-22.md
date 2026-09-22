# Timer churn on `mac`, 2026-09-22, every candidate in its own best mode

`./zig-out/bin/timers_runner --only 'rotor,rotor (repeating),libuv,libuv (repeating),libxev'`, five
rounds of three seconds at 256 and 4,096 timers with a 1 ms period. `std.Io.Threaded` is left out
of this run: at 4,096 timers it sleeps 4,096 threads and took the machine's one-minute load average
to 267, which poisons the pauses `bench/harness/other_work.zig` reads for whichever candidate runs
next. Its row is in `timers-mac-2026-09-22.md`.

Load average before the run: 4.78 23.25 26.34 (still decaying from that earlier run); after: 3.74
14.54 22.11. From 13:45:52 to 13:48:48 local time. rotor reads the clock once per fire here, as
libuv's and libxev's callbacks do, so the lateness column means one thing across candidates.

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median p50 ns | median p99 ns | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
| timer-churn | rotor | this tree | 0 | 256 | 0 | even | 5 | 207301 | 206000 | 1139000 | 4 | 259 | 179 | **OTHER WORK** |
| timer-churn | rotor (repeating) | this tree | 0 | 256 | 0 | even | 5 | 255974 | 169000 | 527000 | 0 | 275 | 210 | **OTHER WORK** |
| timer-churn | libuv | 1.52.1 | 0 | 256 | 0 | even | 5 | 207544 | 206000 | 1394000 | 4 | 247 | 189 | **OTHER WORK** |
| timer-churn | libuv (repeating) | 1.52.1 | 0 | 256 | 0 | even | 5 | 209337 | 185000 | 757000 | 3 | 242 | 133 | **OTHER WORK** |
| timer-churn | libxev | 9ce8e8e | 0 | 256 | 0 | even | 5 | 220901 | 180000 | 250000 | 1 | 211 | 180 | **OTHER WORK** |
| timer-churn | rotor | this tree | 0 | 4096 | 0 | even | 5 | 2016061 | 1259000 | 1487000 | 3 | 233 | 190 | **OTHER WORK** |
| timer-churn | rotor (repeating) | this tree | 0 | 4096 | 0 | even | 5 | 4094231 | 793000 | 1075000 | 0 | 301 | 209 | **OTHER WORK** |
| timer-churn | libuv | 1.52.1 | 0 | 4096 | 0 | even | 5 | 1905599 | 1400000 | 1705000 | 5 | 244 | 195 | **OTHER WORK** |
| timer-churn | libuv (repeating) | 1.52.1 | 0 | 4096 | 0 | even | 5 | 2024570 | 1089000 | 1353000 | 3 | 247 | 192 | **OTHER WORK** |
| timer-churn | libxev | 9ce8e8e | 0 | 4096 | 0 | even | 5 | 3252874 | 53000 | 1051000 | 2 | 254 | 194 | **OTHER WORK** |
```
