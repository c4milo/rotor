# Cross-core message on `mac`, 2026-09-22, after the polling tick's trigger

`./zig-out/bin/crosscore_runner` with its defaults, re-taken after `kqueue_tick.zig` gained `arm_poll`
(decision 12, point 6, amended). Load average before: 5.74 5.06 4.77. The columns
are the ones `bench/harness/other_work.zig` prints: how busy the machine was in the pauses around each run,
in hundredths of one core. Then `rotor_post` alone in its three modes, which are rotor against itself.

```text
| workload | candidate | version | cores | connections | payload bytes | load | runs | median per second | median p50 ns | median p99 ns | spread percent | other work peak /100 | other work mean /100 | verdict |
|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
| cross-core | rotor | this tree | 0 | 1 | 0 | even | 5 | 384127 | 2007 | 8031 | 14 | 739 | 197 | **RUNS DISAGREE** **OTHER WORK** |
| cross-core | libuv | v1.52.1 | 0 | 1 | 0 | even | 5 | 518732 | 1500 | 6000 | 4 | 605 | 165 | **OTHER WORK** |
| cross-core | libxev | 9ce8e8e | 0 | 1 | 0 | even | 5 | 434027 | 2007 | 8031 | 8 | 995 | 180 | **OTHER WORK** |

{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":101552000,"operations":40000,"operations_per_second":393886,"p50_ns":2007,"p99_ns":7007,"p999_ns":16063,"overflow":0}
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":12845000,"operations":40000,"operations_per_second":3114052,"p50_ns":501,"p99_ns":1003,"p999_ns":1503,"overflow":0}
{"workload":"cross-core","candidate":"rotor (spin then wait, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":20956000,"operations":40000,"operations_per_second":1908761,"p50_ns":501,"p99_ns":1503,"p999_ns":2511,"overflow":0}
```
