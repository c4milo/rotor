# Decision 21 on `orbstack`, 2026-09-26

The same binaries as `bench/results/decision-21-mac-2026-09-26.md`, built for Linux at commit
`26da902`, run in the Linux gate's container right after that file's runs, in the same quiet spell:
the cost probes C17, C19, C24 and C25, three serial runs 30 seconds apart, then `rotor_post`
(`post_uring`, on io_uring) and `post_epoll` with the peer as a thread and as a process, three
rounds alternating, in `waiting` and `spinning`.

The first attempt, from the script that ran the `mac` half, found OrbStack's engine stopped and
ran nothing. The engine was started, and these runs began once the 1-minute load average was under
1.5, about a minute later. Run 1 of the probes was disturbed: its C19 read 424 ns where runs 2 and 3
read 101 and 98.6, and its C17 twice theirs. Its C24 and C25 agree with the other two runs. The load
rose during the `rotor_post` rounds, to 3.95 at the end. The engine was stopped again afterwards.

## The probes

```text
== orbstack costs run 1, load { 1.23 1.32 3.42 }
Unable to find image 'alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc' locally
docker.io/library/alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc: Pulling from library/alpine
3f26bc2dec0b: Pulling fs layer
cee42a41056b: Download complete
8b093306b817: Download complete
3f26bc2dec0b: Download complete
3f26bc2dec0b: Pull complete
Digest: sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
Status: Downloaded newer image for alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
rotor cost probes, for docs/costs.md

machine: 0x61, 10 processors, 16425400 KiB
os: Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64
zig: 0.16.0, ReleaseSafe
date: 2026-09-26 (UTC)
clock: clock_gettime(CLOCK_MONOTONIC), smallest step seen 41 ns
placement: thread not pinned: this probe pins nothing on this OS, run it under taskset

| id | operation | median (p99), ns |
|---|---|---|
| C17 | one cross-core message by IORING_OP_MSG_RING, post to reap | 20989 (31845) |
  method: 1000 samples, each a batch of 64 messages timed as one and divided, after 32 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 9536 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; a round trip halved: two rings on two threads, each set up as src/uring sets one up, posting MSG_RING to the other; DEFER_TASKRUN means the receiver must enter the kernel to see a message, so both sides block and this number includes waking one; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned
| C19 | one cross-core message by a shared ring when the receiver is already awake | 424 (511) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 95.7 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; request and reply through two rings, both threads spinning with no pause instruction; half a round trip is one message from post to reap; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned; the median moves with the build of this probe, so read it as a range (README.md)
| C24 | one message between processes by a shared ring when the receiver is already awake | 91.8 (118) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 90.8 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; C19's request and reply with the far side in a process made by fork, both rings in a shared mapping, both sides spinning; half a round trip is one message from post to reap; near process thread pinned to one core with sched_setaffinity, far process thread pinned to one core with sched_setaffinity
| C25 | one message between processes by a shared ring plus decision 21's wake, post to reap | 31500 (49375) |
  method: 5000 messages, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 2584 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; from the near process's clock read before it writes the ring to the far process's clock read after it takes the message: ring write, the write that wakes (an eventfd polled from io_uring), the wake, the read of the wake, ring read; the far process had been blocked for about 100 microseconds; near process thread pinned to one core with sched_setaffinity, far process thread pinned to one core with sched_setaffinity
== orbstack costs run 2, load { 1.29 1.33 3.33 }
rotor cost probes, for docs/costs.md

machine: 0x61, 10 processors, 16425400 KiB
os: Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64
zig: 0.16.0, ReleaseSafe
date: 2026-09-26 (UTC)
clock: clock_gettime(CLOCK_MONOTONIC), smallest step seen 41 ns
placement: thread not pinned: this probe pins nothing on this OS, run it under taskset

| id | operation | median (p99), ns |
|---|---|---|
| C17 | one cross-core message by IORING_OP_MSG_RING, post to reap | 9936 (12301) |
  method: 1000 samples, each a batch of 64 messages timed as one and divided, after 32 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 9494 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; a round trip halved: two rings on two threads, each set up as src/uring sets one up, posting MSG_RING to the other; DEFER_TASKRUN means the receiver must enter the kernel to see a message, so both sides block and this number includes waking one; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned
| C19 | one cross-core message by a shared ring when the receiver is already awake | 101 (137) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 98.3 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; request and reply through two rings, both threads spinning with no pause instruction; half a round trip is one message from post to reap; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned; the median moves with the build of this probe, so read it as a range (README.md)
| C24 | one message between processes by a shared ring when the receiver is already awake | 102 (132) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 95.4 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; C19's request and reply with the far side in a process made by fork, both rings in a shared mapping, both sides spinning; half a round trip is one message from post to reap; near process thread pinned to one core with sched_setaffinity, far process thread pinned to one core with sched_setaffinity
| C25 | one message between processes by a shared ring plus decision 21's wake, post to reap | 32500 (45375) |
  method: 5000 messages, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 3625 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; from the near process's clock read before it writes the ring to the far process's clock read after it takes the message: ring write, the write that wakes (an eventfd polled from io_uring), the wake, the read of the wake, ring read; the far process had been blocked for about 100 microseconds; near process thread pinned to one core with sched_setaffinity, far process thread pinned to one core with sched_setaffinity
== orbstack costs run 3, load { 1.76 1.45 3.31 }
rotor cost probes, for docs/costs.md

machine: 0x61, 10 processors, 16425400 KiB
os: Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64
zig: 0.16.0, ReleaseSafe
date: 2026-09-26 (UTC)
clock: clock_gettime(CLOCK_MONOTONIC), smallest step seen 41 ns
placement: thread not pinned: this probe pins nothing on this OS, run it under taskset

| id | operation | median (p99), ns |
|---|---|---|
| C17 | one cross-core message by IORING_OP_MSG_RING, post to reap | 9808 (11910) |
  method: 1000 samples, each a batch of 64 messages timed as one and divided, after 32 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 9380 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; a round trip halved: two rings on two threads, each set up as src/uring sets one up, posting MSG_RING to the other; DEFER_TASKRUN means the receiver must enter the kernel to see a message, so both sides block and this number includes waking one; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned
| C19 | one cross-core message by a shared ring when the receiver is already awake | 98.6 (141) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 96.0 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; request and reply through two rings, both threads spinning with no pause instruction; half a round trip is one message from post to reap; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned; the median moves with the build of this probe, so read it as a range (README.md)
| C24 | one message between processes by a shared ring when the receiver is already awake | 96.0 (122) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 95.0 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; C19's request and reply with the far side in a process made by fork, both rings in a shared mapping, both sides spinning; half a round trip is one message from post to reap; near process thread pinned to one core with sched_setaffinity, far process thread pinned to one core with sched_setaffinity
| C25 | one message between processes by a shared ring plus decision 21's wake, post to reap | 31417 (44000) |
  method: 5000 messages, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 2750 ns; clock_gettime(CLOCK_MONOTONIC) with 41 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; from the near process's clock read before it writes the ring to the far process's clock read after it takes the message: ring write, the write that wakes (an eventfd polled from io_uring), the wake, the read of the wake, ring read; the far process had been blocked for about 100 microseconds; near process thread pinned to one core with sched_setaffinity, far process thread pinned to one core with sched_setaffinity
```

## `rotor_post`, peer thread against peer process

Each `rotor_post:` line gives the CPU time the answering loop used per round trip; the JSON line
after it is the run's result, whose `p50_ns` is one message, half a round trip.

```text
== orbstack round 1, post_uring, waiting, peer thread, load { 2.21 1.58 3.28 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7502 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46349866,"operations":4000,"operations_per_second":86300,"p50_ns":11263,"p99_ns":23935,"p999_ns":46079,"p9999_ns":67562,"overflow":0,"peak_rss_bytes":0}
== orbstack round 1, post_uring, waiting, peer process, load { 2.21 1.58 3.28 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7172 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43006730,"operations":4000,"operations_per_second":93008,"p50_ns":11199,"p99_ns":24575,"p999_ns":40447,"p9999_ns":44521,"overflow":0,"peak_rss_bytes":0}
== orbstack round 1, post_uring, spinning, peer thread, load { 2.21 1.58 3.28 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1984 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3911704,"operations":4000,"operations_per_second":1022572,"p50_ns":939,"p99_ns":1191,"p999_ns":7711,"p9999_ns":9687,"overflow":0,"peak_rss_bytes":0}
== orbstack round 1, post_uring, spinning, peer process, load { 2.21 1.58 3.28 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2223 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4378331,"operations":4000,"operations_per_second":913590,"p50_ns":959,"p99_ns":2655,"p999_ns":9919,"p9999_ns":25875,"overflow":0,"peak_rss_bytes":0}
== orbstack round 1, post_epoll, waiting, peer thread, load { 2.21 1.58 3.28 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 6844 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":41713397,"operations":4000,"operations_per_second":95892,"p50_ns":10687,"p99_ns":18047,"p999_ns":48639,"p9999_ns":56521,"overflow":0,"peak_rss_bytes":0}
== orbstack round 1, post_epoll, waiting, peer process, load { 2.21 1.58 3.28 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 6359 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35034405,"operations":4000,"operations_per_second":114173,"p50_ns":6975,"p99_ns":19327,"p999_ns":37631,"p9999_ns":78708,"overflow":0,"peak_rss_bytes":0}
== orbstack round 1, post_epoll, spinning, peer thread, load { 2.21 1.58 3.28 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2639 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5218835,"operations":4000,"operations_per_second":766454,"p50_ns":1335,"p99_ns":1543,"p999_ns":8575,"p9999_ns":9646,"overflow":0,"peak_rss_bytes":0}
== orbstack round 1, post_epoll, spinning, peer process, load { 2.21 1.58 3.28 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2000 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3933593,"operations":4000,"operations_per_second":1016882,"p50_ns":959,"p99_ns":1023,"p999_ns":5247,"p9999_ns":16791,"overflow":0,"peak_rss_bytes":0}
== orbstack round 2, post_uring, waiting, peer thread, load { 2.21 1.58 3.28 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7509 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":48352849,"operations":4000,"operations_per_second":82725,"p50_ns":10943,"p99_ns":27263,"p999_ns":76287,"p9999_ns":422729,"overflow":0,"peak_rss_bytes":0}
== orbstack round 2, post_uring, waiting, peer process, load { 2.21 1.58 3.28 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7599 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46745009,"operations":4000,"operations_per_second":85570,"p50_ns":11263,"p99_ns":23295,"p999_ns":60927,"p9999_ns":127479,"overflow":0,"peak_rss_bytes":0}
== orbstack round 2, post_uring, spinning, peer thread, load { 2.21 1.58 3.28 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1986 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3911002,"operations":4000,"operations_per_second":1022755,"p50_ns":959,"p99_ns":1003,"p999_ns":7039,"p9999_ns":12458,"overflow":0,"peak_rss_bytes":0}
== orbstack round 2, post_uring, spinning, peer process, load { 3.95 1.95 3.40 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2474 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4884959,"operations":4000,"operations_per_second":818840,"p50_ns":1335,"p99_ns":2095,"p999_ns":9407,"p9999_ns":19062,"overflow":0,"peak_rss_bytes":0}
== orbstack round 2, post_epoll, waiting, peer thread, load { 3.95 1.95 3.40 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 6694 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":35232643,"operations":4000,"operations_per_second":113531,"p50_ns":7263,"p99_ns":18431,"p999_ns":27007,"p9999_ns":205187,"overflow":0,"peak_rss_bytes":0}
== orbstack round 2, post_epoll, waiting, peer process, load { 3.95 1.95 3.40 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7150 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44618797,"operations":4000,"operations_per_second":89648,"p50_ns":11135,"p99_ns":22271,"p999_ns":52735,"p9999_ns":67125,"overflow":0,"peak_rss_bytes":0}
== orbstack round 2, post_epoll, spinning, peer thread, load { 3.95 1.95 3.40 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2830 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5627511,"operations":4000,"operations_per_second":710793,"p50_ns":1359,"p99_ns":3087,"p999_ns":7423,"p9999_ns":21666,"overflow":0,"peak_rss_bytes":0}
== orbstack round 2, post_epoll, spinning, peer process, load { 3.95 1.95 3.40 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2485 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5004200,"operations":4000,"operations_per_second":799328,"p50_ns":1335,"p99_ns":1503,"p999_ns":12735,"p9999_ns":54229,"overflow":0,"peak_rss_bytes":0}
== orbstack round 3, post_uring, waiting, peer thread, load { 3.95 1.95 3.40 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7273 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44565450,"operations":4000,"operations_per_second":89755,"p50_ns":10879,"p99_ns":25599,"p999_ns":51455,"p9999_ns":54208,"overflow":0,"peak_rss_bytes":0}
== orbstack round 3, post_uring, waiting, peer process, load { 3.95 1.95 3.40 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7808 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":46805339,"operations":4000,"operations_per_second":85460,"p50_ns":11391,"p99_ns":23551,"p999_ns":37887,"p9999_ns":63854,"overflow":0,"peak_rss_bytes":0}
== orbstack round 3, post_uring, spinning, peer thread, load { 3.95 1.95 3.40 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2760 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5457930,"operations":4000,"operations_per_second":732878,"p50_ns":1335,"p99_ns":1439,"p999_ns":4543,"p9999_ns":14145,"overflow":0,"peak_rss_bytes":0}
== orbstack round 3, post_uring, spinning, peer process, load { 3.95 1.95 3.40 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2488 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":4912709,"operations":4000,"operations_per_second":814214,"p50_ns":1335,"p99_ns":1463,"p999_ns":7167,"p9999_ns":26062,"overflow":0,"peak_rss_bytes":0}
== orbstack round 3, post_epoll, waiting, peer thread, load { 3.95 1.95 3.40 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7049 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":43303904,"operations":4000,"operations_per_second":92370,"p50_ns":10751,"p99_ns":26367,"p999_ns":48895,"p9999_ns":76146,"overflow":0,"peak_rss_bytes":0}
== orbstack round 3, post_epoll, waiting, peer process, load { 3.95 1.95 3.40 }
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 7105 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":44126102,"operations":4000,"operations_per_second":90649,"p50_ns":10879,"p99_ns":23679,"p999_ns":87551,"p9999_ns":120229,"overflow":0,"peak_rss_bytes":0}
== orbstack round 3, post_epoll, spinning, peer thread, load { 3.95 1.95 3.40 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2805 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5563825,"operations":4000,"operations_per_second":718929,"p50_ns":1359,"p99_ns":1439,"p999_ns":7487,"p9999_ns":12771,"overflow":0,"peak_rss_bytes":0}
== orbstack round 3, post_epoll, spinning, peer process, load { 3.95 1.95 3.40 }
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2810 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5547022,"operations":4000,"operations_per_second":721107,"p50_ns":1359,"p99_ns":1463,"p999_ns":7071,"p9999_ns":12812,"overflow":0,"peak_rss_bytes":0}
```
