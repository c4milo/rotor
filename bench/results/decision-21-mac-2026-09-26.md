# Decision 21 on `mac`, 2026-09-26

The cost probes C18, C19, C24 and C25, three serial runs 30 seconds apart, then `rotor_post` with
its peer as a thread and as a process, three rounds alternating, in the modes `waiting` and
`spinning`, on kqueue. The binaries were built at commit `26da902` in ReleaseSafe, and a script ran
them once the 5-minute load average had stayed under 1.5 at three readings a minute apart. What it
recorded then, and the load before each run:

```text
quiet at minute 635, 2026-09-26T05:38:53Z, load { 1.02 1.31 4.50 }
Apple M1 Pro
10
34359738368
ProductName:		macOS
ProductVersion:		26.6.2
BuildVersion:		25G83
26da902 docs: record decision 21's handshake test, probes and two-process mode
```

## The probes

```text
== mac costs run 1, load { 1.02 1.31 4.50 }
rotor cost probes, for docs/costs.md

machine: Apple M1 Pro, 8 performance and 2 efficiency cores, 32 GiB memory
caches: performance core L1d 128 KiB and L2 12 MiB, efficiency core L1d 64 KiB and L2 4 MiB, line 128 bytes, page 16 KiB
os: macOS 26.6.2, Darwin 25.6.0
zig: 0.16.0, ReleaseSafe
date: 2026-09-26 (UTC)
clock: clock_gettime(CLOCK_UPTIME_RAW), smallest step seen 41 ns
placement: thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested

| id | operation | median (p99), ns |
|---|---|---|
| C18 | one cross-core message by a shared ring plus an EVFILT_USER wake, post to reap | 25042 (32667) |
  method: 5000 messages, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 2709 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; from the producer's clock read before it writes the ring to the consumer's clock read after it takes the message: ring write, the kevent that triggers, the wake from a blocking kevent, ring read; the consumer had been blocked for about 100 microseconds, a longer sleep may wake slower; threads not pinned
| C19 | one cross-core message by a shared ring when the receiver is already awake | 95.4 (101) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 92.4 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; request and reply through two rings, both threads spinning with no pause instruction; half a round trip is one message from post to reap; near thread thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested, far thread thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested. The row means two cores only when both say pinned; the median moves with the build of this probe, so read it as a range (README.md)
| C24 | one message between processes by a shared ring when the receiver is already awake | 93.1 (94.1) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 90.2 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; C19's request and reply with the far side in a process made by fork, both rings in a shared mapping, both sides spinning; half a round trip is one message from post to reap; near process thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested, far process thread not pinned, and the user-interactive QoS class was refused
| C25 | one message between processes by a shared ring plus decision 21's wake, post to reap | 25709 (34667) |
  method: 5000 messages, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 3041 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; from the near process's clock read before it writes the ring to the far process's clock read after it takes the message: ring write, the write that wakes (a pipe watched with EVFILT_READ), the wake, the read of the wake, ring read; the far process had been blocked for about 100 microseconds; near process thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested, far process thread not pinned, and the user-interactive QoS class was refused
== mac costs run 2, load { 1.19 1.33 4.38 }
rotor cost probes, for docs/costs.md

machine: Apple M1 Pro, 8 performance and 2 efficiency cores, 32 GiB memory
caches: performance core L1d 128 KiB and L2 12 MiB, efficiency core L1d 64 KiB and L2 4 MiB, line 128 bytes, page 16 KiB
os: macOS 26.6.2, Darwin 25.6.0
zig: 0.16.0, ReleaseSafe
date: 2026-09-26 (UTC)
clock: clock_gettime(CLOCK_UPTIME_RAW), smallest step seen 41 ns
placement: thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested

| id | operation | median (p99), ns |
|---|---|---|
| C18 | one cross-core message by a shared ring plus an EVFILT_USER wake, post to reap | 10875 (939000) |
  method: 5000 messages, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 1667 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; from the producer's clock read before it writes the ring to the consumer's clock read after it takes the message: ring write, the kevent that triggers, the wake from a blocking kevent, ring read; the consumer had been blocked for about 100 microseconds, a longer sleep may wake slower; threads not pinned
| C19 | one cross-core message by a shared ring when the receiver is already awake | 102 (103) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 99.6 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; request and reply through two rings, both threads spinning with no pause instruction; half a round trip is one message from post to reap; near thread thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested, far thread thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested. The row means two cores only when both say pinned; the median moves with the build of this probe, so read it as a range (README.md)
| C24 | one message between processes by a shared ring when the receiver is already awake | 97.0 (555) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 92.8 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; C19's request and reply with the far side in a process made by fork, both rings in a shared mapping, both sides spinning; half a round trip is one message from post to reap; near process thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested, far process thread not pinned, and the user-interactive QoS class was refused
| C25 | one message between processes by a shared ring plus decision 21's wake, post to reap | 15667 (37958) |
  method: 5000 messages, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 2875 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; from the near process's clock read before it writes the ring to the far process's clock read after it takes the message: ring write, the write that wakes (a pipe watched with EVFILT_READ), the wake, the read of the wake, ring read; the far process had been blocked for about 100 microseconds; near process thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested, far process thread not pinned, and the user-interactive QoS class was refused
== mac costs run 3, load { 1.22 1.32 4.27 }
rotor cost probes, for docs/costs.md

machine: Apple M1 Pro, 8 performance and 2 efficiency cores, 32 GiB memory
caches: performance core L1d 128 KiB and L2 12 MiB, efficiency core L1d 64 KiB and L2 4 MiB, line 128 bytes, page 16 KiB
os: macOS 26.6.2, Darwin 25.6.0
zig: 0.16.0, ReleaseSafe
date: 2026-09-26 (UTC)
clock: clock_gettime(CLOCK_UPTIME_RAW), smallest step seen 41 ns
placement: thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested

| id | operation | median (p99), ns |
|---|---|---|
| C18 | one cross-core message by a shared ring plus an EVFILT_USER wake, post to reap | 25084 (33000) |
  method: 5000 messages, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 2625 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; from the producer's clock read before it writes the ring to the consumer's clock read after it takes the message: ring write, the kevent that triggers, the wake from a blocking kevent, ring read; the consumer had been blocked for about 100 microseconds, a longer sleep may wake slower; threads not pinned
| C19 | one cross-core message by a shared ring when the receiver is already awake | 95.4 (99.3) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 92.8 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; request and reply through two rings, both threads spinning with no pause instruction; half a round trip is one message from post to reap; near thread thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested, far thread thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested. The row means two cores only when both say pinned; the median moves with the build of this probe, so read it as a range (README.md)
| C24 | one message between processes by a shared ring when the receiver is already awake | 93.1 (96.7) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 90.2 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; C19's request and reply with the far side in a process made by fork, both rings in a shared mapping, both sides spinning; half a round trip is one message from post to reap; near process thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested, far process thread not pinned, and the user-interactive QoS class was refused
| C25 | one message between processes by a shared ring plus decision 21's wake, post to reap | 26125 (40416) |
  method: 5000 messages, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 2583 ns; clock_gettime(CLOCK_UPTIME_RAW) with 41 ns steps; ReleaseSafe; thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested; from the near process's clock read before it writes the ring to the far process's clock read after it takes the message: ring write, the write that wakes (a pipe watched with EVFILT_READ), the wake, the read of the wake, ring read; the far process had been blocked for about 100 microseconds; near process thread not pinned (macOS on Apple silicon has no hard affinity), QoS class user-interactive requested, far process thread not pinned, and the user-interactive QoS class was refused
```

## `rotor_post`, peer thread against peer process

Each `rotor_post:` line gives the CPU time the answering loop used per round trip; the JSON line
after it is the run's result, whose `p50_ns` is one message, half a round trip. On macOS the clock
advances in 1,000 ns steps, so a message moves in steps of about 500 ns, and 0 is a round trip
shorter than one step.

```text
== mac round 1, waiting, peer thread, load { 1.05 1.24 3.85 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 4990 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":18806000,"operations":4000,"operations_per_second":212698,"p50_ns":4015,"p99_ns":9535,"p999_ns":11519,"p9999_ns":12500,"overflow":0,"peak_rss_bytes":0}
== mac round 1, waiting, peer process, load { 1.05 1.24 3.85 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 4290 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":15750000,"operations":4000,"operations_per_second":253968,"p50_ns":4015,"p99_ns":6527,"p999_ns":8511,"p9999_ns":13000,"overflow":0,"peak_rss_bytes":0}
== mac round 1, spinning, peer thread, load { 1.05 1.24 3.85 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 525 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":986000,"operations":4000,"operations_per_second":4056795,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
== mac round 1, spinning, peer process, load { 1.05 1.24 3.85 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 536 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":1005000,"operations":4000,"operations_per_second":3980099,"p50_ns":0,"p99_ns":501,"p999_ns":501,"p9999_ns":11000,"overflow":0,"peak_rss_bytes":0}
== mac round 2, waiting, peer thread, load { 1.05 1.24 3.85 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 3086 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10819000,"operations":4000,"operations_per_second":369719,"p50_ns":2511,"p99_ns":3503,"p999_ns":5503,"p9999_ns":7000,"overflow":0,"peak_rss_bytes":0}
== mac round 2, waiting, peer process, load { 1.05 1.24 3.85 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 2825 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10565000,"operations":4000,"operations_per_second":378608,"p50_ns":2511,"p99_ns":4511,"p999_ns":6015,"p9999_ns":11000,"overflow":0,"peak_rss_bytes":0}
== mac round 2, spinning, peer thread, load { 1.05 1.24 3.85 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 449 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":835000,"operations":4000,"operations_per_second":4790419,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
== mac round 2, spinning, peer process, load { 1.05 1.24 3.85 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 448 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":830000,"operations":4000,"operations_per_second":4819277,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
== mac round 3, waiting, peer thread, load { 1.05 1.24 3.85 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 2953 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10385000,"operations":4000,"operations_per_second":385170,"p50_ns":2511,"p99_ns":4015,"p999_ns":5503,"p9999_ns":6000,"overflow":0,"peak_rss_bytes":0}
== mac round 3, waiting, peer process, load { 1.05 1.24 3.85 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 2840 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":10546000,"operations":4000,"operations_per_second":379290,"p50_ns":2511,"p99_ns":4511,"p999_ns":5503,"p9999_ns":11500,"overflow":0,"peak_rss_bytes":0}
== mac round 3, spinning, peer thread, load { 1.05 1.24 3.85 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 448 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":829000,"operations":4000,"operations_per_second":4825090,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
== mac round 3, spinning, peer process, load { 1.05 1.24 3.85 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 449 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":0,"connections":1,"payload_bytes":0,"load":"even","duration_ns":840000,"operations":4000,"operations_per_second":4761904,"p50_ns":0,"p99_ns":500,"p999_ns":500,"p9999_ns":500,"overflow":0,"peak_rss_bytes":0}
```
