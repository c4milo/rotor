# Decision 21 on `github`, 2026-09-25

The CI job `costs` of `.github/workflows/ci.yml`, started by hand on commit `26da902`, run
36177323493, on a GitHub-hosted `ubuntu-24.04` runner that reported an AMD EPYC 7763. Two of its
steps: every cost probe, which includes rows C24 and C25 for the first time on this architecture,
and `rotor_post` with its peer as a thread and as a process, three rounds alternating, on io_uring
(`rotor_post`) and on epoll (`post_epoll`), in the modes `waiting` and `spinning`. Each `rotor_post:`
line gives the CPU time the answering loop used per round trip; the JSON line after it is the
run's result, whose `p50_ns` is one message, half a round trip. Decision 21 reads them.

The `github` column of `docs/costs.md` describes an Intel Xeon Platinum 8573C and is replaced whole
or not at all, so this run did not change it.

## The probes

```text
rotor cost probes, for docs/costs.md

machine: AMD EPYC 7763 64-Core Processor, 4 processors, 16373452 KiB
os: Linux 6.17.0-1022-azure, x86_64
zig: 0.16.0, ReleaseSafe
date: 2026-09-25 (UTC)
clock: clock_gettime(CLOCK_MONOTONIC), smallest step seen 20 ns
placement: thread not pinned: this probe pins nothing on this OS, run it under taskset

| id | operation | median (p99), ns |
|---|---|---|
| C1 | L1 cache reference | 1.24 (1.52) |
  method: 2000 samples, each a batch of 32768 loads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1.23 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; 256 nodes of 128 bytes in one random cycle, 32 KiB in all; each load's address is the value the load before it returned, so the number is one load's latency
| C2 | L2 cache reference | 12.6 (15.1) |
  method: 2000 samples, each a batch of 8192 loads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 12.1 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; 16384 nodes of 128 bytes in one random cycle, 2048 KiB in all, on 512 pages: a load misses L1 and hits L2
| C3 | main memory reference, a last-level cache miss | 103 (128) |
  method: 2000 samples, each a batch of 512 loads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 99.6 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; the number includes a TLB miss on nearly every load: the working set is 131072 pages of 4 KiB, and transparent huge pages were not requested and may still apply, read /sys/kernel/mm/transparent_hugepage/enabled; 4194304 nodes of 128 bytes in one random cycle, 512 MiB in all
| C4 | branch mispredict | 7.02 (9.48) |
  method: 2000 samples, each a batch of 8192 branches per variant timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; the row comes from the difference of two loops timed back to back, and its smallest per-sample value was 4.46 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; twice the per-branch gap between random outcomes (3.82 ns a branch) and constant ones (0.31 ns), since half of the random branches mispredict; the branch tests a byte loaded from L1, so the cost includes that load's latency after the flush
| C5 | indirect call through a function pointer, predicted | 1.54 (2.07) |
  method: 2000 samples, each a batch of 16384 calls per loop timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1.54 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one loop iteration: the call through the pointer, a callee that adds 1 and keeps a frame record as every ReleaseSafe function does, and the return; the same callee called directly took 1.54 ns and the median per-sample gap was 0.00 ns
| C6 | smallest syscall round trip, getppid | 169 (234) |
  method: 2000 samples, each a batch of 128 calls timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 169 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; the raw syscall instruction, no libc; every call's answer is checked
| C7 | io_uring_enter, 1 NOP submitted and its completion reaped, no wait | 414 (674) |
  method: 2000 samples, each a batch of 32 calls timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 410 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; SINGLE_ISSUER, DEFER_TASKRUN, TASKRUN_FLAG and SUBMIT_ALL, as src/uring sets them; the kernel does nothing for a NOP, so this is the ring's own cost; every call's completion is checked
| C8 | one more NOP in a batch of 32, submission side, per entry | 82.7 (105) |
  method: 2000 samples, each a batch of 16 calls per batch entry timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; the row comes from the difference of two loops timed back to back, and its smallest per-sample value was 45.2 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; (t32 - t1) / 31 per sample: t1 415 ns is the C7 call, t32 2980 ns submits and reaps 32 NOPs in one call; the difference carries one submission and one completion, so C9 is the part of it that is the completion
| C9 | one more completion in a reap of 32, per entry | 6.25 (12.2) |
  method: 2000 samples, each a batch of 32 completions timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 5.94 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; the 32 completions are in the ring before the timing starts, put there by an untimed submit_and_wait; the timed loop copies them out and checks each, so this is the reap alone and carries no part of the enter that C7 measures
| C12 | 4 KiB O_DIRECT NVMe read, queue depth 1, submit to completion | 117481 (278438) |
  method: 500 samples, each a batch of 16 reads timed as one and divided, after 16 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 106147 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; O_DIRECT, 4 KiB, offsets drawn by splitmix64 over a 256 MiB file this probe writes and removes; one read in flight, submitted and waited for, so this is the device's latency plus the ring's
| C13 | 4 KiB O_DIRECT NVMe read, queue depth 32, per operation | 14088 (386571) |
  method: 200 samples, each a batch of 128 reads timed as one and divided, after 8 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 11554 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; O_DIRECT, 4 KiB, offsets drawn by splitmix64 over a 256 MiB file this probe writes and removes; 32 reads in flight per call, so the device overlaps them and this is throughput in a latency's units
| C14 | loopback TCP round trip, 1 byte each way, both ends on one core | 12172 (22101) |
  method: 10000 round trips, each timed alone, after 500 that were thrown away; the p99 is of single operations; smallest sample 12092 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; send, recv, send, recv of 1 byte from the one measuring thread, blocking, TCP_NODELAY; thread pinned to one core with sched_setaffinity. One thread is one core at a time whatever the pinning says, but the kernel's own work runs where the scheduler puts it
| C15 | loopback TCP round trip, 1 byte each way, ends on two cores | 10830 (29895) |
  method: 10000 round trips, each timed alone, after 500 that were thrown away; the p99 is of single operations; smallest sample 7885 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one byte each way between two threads; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned: unpinned, the scheduler may have put both ends on one core, which is what this row is set against C14 to separate
| C16 | send plus recv of 4 KiB on a connected loopback socket, the two syscalls alone | 9979 (13365) |
  method: 10000 send and recv pairs, each timed alone, after 500 that were thrown away; the p99 is of single operations; smallest sample 6041 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one send and one recv of 4,096 bytes, both from the measuring thread; the block the recv returns had fully arrived before the clock started, so the number is two system calls and two copies, not a wait
| C17 | one cross-core message by IORING_OP_MSG_RING, post to reap | 14734 (16017) |
  method: 1000 samples, each a batch of 64 messages timed as one and divided, after 32 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 10404 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; a round trip halved: two rings on two threads, each set up as src/uring sets one up, posting MSG_RING to the other; DEFER_TASKRUN means the receiver must enter the kernel to see a message, so both sides block and this number includes waking one; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned
| C19 | one cross-core message by a shared ring when the receiver is already awake | 42.0 (44.4) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 40.0 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; request and reply through two rings, both threads spinning with no pause instruction; half a round trip is one message from post to reap; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned; the median moves with the build of this probe, so read it as a range (README.md)
| C20 | monotonic clock read | 27.2 (42.0) |
  method: 2000 samples, each a batch of 1024 reads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 27.1 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; clock_gettime(CLOCK_MONOTONIC); the same call times every probe
| C21 | thread-local variable read and compare | 1.85 (2.35) |
  method: 2000 samples, each a batch of 16384 calls per loop timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1.85 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one call of a never-inlined entry point that reads the thread-local and compares it, call and return included; the same function over a plain global took 1.54 ns and the median per-sample gap was 0.31 ns, which is what thread-local addressing adds on this OS
| C22 | send plus recv of 64 KiB on a connected loopback socket, the two syscalls alone | 21149 (34294) |
  method: 4000 send and recv pairs, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 19868 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one send and one recv of 65536 bytes, both from the measuring thread; the block the recv returns had fully arrived before the clock started and the receiving end's buffer reads back as 1048576 bytes, so the number is two system calls and two copies of this size, not a wait
| C23 | copy 64 KiB from one buffer to another | 1300 (1822) |
  method: 2000 samples, each a batch of 16 copies timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1291 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; @memcpy of 65536 bytes between two buffers that stay the same, so both are warm: this is a lower bound on the copy a send or a recv of this size makes, which also touches socket buffer pages and page tables
| C24 | one message between processes by a shared ring when the receiver is already awake | 41.6 (44.1) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 39.2 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; C19's request and reply with the far side in a process made by fork, both rings in a shared mapping, both sides spinning; half a round trip is one message from post to reap; near process thread pinned to one core with sched_setaffinity, far process thread pinned to one core with sched_setaffinity
| C25 | one message between processes by a shared ring plus decision 21's wake, post to reap | 14534 (17560) |
  method: 5000 messages, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 6489 ns; clock_gettime(CLOCK_MONOTONIC) with 20 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; from the near process's clock read before it writes the ring to the far process's clock read after it takes the message: ring write, the write that wakes (an eventfd polled from io_uring), the wake, the read of the wake, ring read; the far process had been blocked for about 100 microseconds; near process thread pinned to one core with sched_setaffinity, far process thread pinned to one core with sched_setaffinity
```

## `rotor_post`, peer thread against peer process

```text
== round 1, ./zig-out/bin/rotor_post, waiting, peer thread
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14430 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59101571,"operations":4000,"operations_per_second":67680,"p50_ns":16639,"p99_ns":19327,"p999_ns":25983,"p9999_ns":27812,"overflow":0,"peak_rss_bytes":0}
== round 1, ./zig-out/bin/rotor_post, waiting, peer process
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16670 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":64380293,"operations":4000,"operations_per_second":62130,"p50_ns":17151,"p99_ns":18559,"p999_ns":26495,"p9999_ns":32074,"overflow":0,"peak_rss_bytes":0}
== round 1, ./zig-out/bin/rotor_post, spinning, peer thread
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1937 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":6773031,"operations":4000,"operations_per_second":590577,"p50_ns":903,"p99_ns":971,"p999_ns":12543,"p9999_ns":1519791,"overflow":0,"peak_rss_bytes":0}
== round 1, ./zig-out/bin/rotor_post, spinning, peer process
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1930 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":7797923,"operations":4000,"operations_per_second":512957,"p50_ns":907,"p99_ns":963,"p999_ns":19967,"p9999_ns":1516805,"overflow":0,"peak_rss_bytes":0}
== round 1, ./zig-out/linux-bench/post_epoll, waiting, peer thread
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14864 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":112216494,"operations":4000,"operations_per_second":35645,"p50_ns":11455,"p99_ns":868351,"p999_ns":2293759,"p9999_ns":2896466,"overflow":0,"peak_rss_bytes":0}
== round 1, ./zig-out/linux-bench/post_epoll, waiting, peer process
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16222 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":59349434,"operations":4000,"operations_per_second":67397,"p50_ns":14399,"p99_ns":19711,"p999_ns":29823,"p9999_ns":41121,"overflow":0,"peak_rss_bytes":0}
== round 1, ./zig-out/linux-bench/post_epoll, spinning, peer thread
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2685 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5300289,"operations":4000,"operations_per_second":754675,"p50_ns":1215,"p99_ns":1623,"p999_ns":16895,"p9999_ns":24315,"overflow":0,"peak_rss_bytes":0}
== round 1, ./zig-out/linux-bench/post_epoll, spinning, peer process
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2745 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5392259,"operations":4000,"operations_per_second":741804,"p50_ns":1215,"p99_ns":1623,"p999_ns":11263,"p9999_ns":29890,"overflow":0,"peak_rss_bytes":0}
== round 2, ./zig-out/bin/rotor_post, waiting, peer thread
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13489 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":55919984,"operations":4000,"operations_per_second":71530,"p50_ns":12095,"p99_ns":19199,"p999_ns":28415,"p9999_ns":41041,"overflow":0,"peak_rss_bytes":0}
== round 2, ./zig-out/bin/rotor_post, waiting, peer process
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 16368 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":63254622,"operations":4000,"operations_per_second":63236,"p50_ns":17151,"p99_ns":18431,"p999_ns":23935,"p9999_ns":30376,"overflow":0,"peak_rss_bytes":0}
== round 2, ./zig-out/bin/rotor_post, spinning, peer thread
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1945 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3798711,"operations":4000,"operations_per_second":1052988,"p50_ns":915,"p99_ns":975,"p999_ns":10495,"p9999_ns":25603,"overflow":0,"peak_rss_bytes":0}
== round 2, ./zig-out/bin/rotor_post, spinning, peer process
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1909 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3727320,"operations":4000,"operations_per_second":1073157,"p50_ns":903,"p99_ns":967,"p999_ns":7359,"p9999_ns":9978,"overflow":0,"peak_rss_bytes":0}
== round 2, ./zig-out/linux-bench/post_epoll, waiting, peer thread
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13199 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56410812,"operations":4000,"operations_per_second":70908,"p50_ns":12607,"p99_ns":19967,"p999_ns":24959,"p9999_ns":27210,"overflow":0,"peak_rss_bytes":0}
== round 2, ./zig-out/linux-bench/post_epoll, waiting, peer process
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14915 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":60059073,"operations":4000,"operations_per_second":66601,"p50_ns":16511,"p99_ns":19583,"p999_ns":26367,"p9999_ns":30872,"overflow":0,"peak_rss_bytes":0}
== round 2, ./zig-out/linux-bench/post_epoll, spinning, peer thread
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2691 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5304479,"operations":4000,"operations_per_second":754079,"p50_ns":1215,"p99_ns":1623,"p999_ns":13439,"p9999_ns":16726,"overflow":0,"peak_rss_bytes":0}
== round 2, ./zig-out/linux-bench/post_epoll, spinning, peer process
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2689 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5281481,"operations":4000,"operations_per_second":757363,"p50_ns":1215,"p99_ns":1623,"p999_ns":9407,"p9999_ns":23994,"overflow":0,"peak_rss_bytes":0}
== round 3, ./zig-out/bin/rotor_post, waiting, peer thread
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 14131 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57599318,"operations":4000,"operations_per_second":69445,"p50_ns":12671,"p99_ns":19583,"p999_ns":24319,"p9999_ns":27641,"overflow":0,"peak_rss_bytes":0}
== round 3, ./zig-out/bin/rotor_post, waiting, peer process
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 12964 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":56489139,"operations":4000,"operations_per_second":70810,"p50_ns":12287,"p99_ns":20223,"p999_ns":25855,"p9999_ns":253019,"overflow":0,"peak_rss_bytes":0}
== round 3, ./zig-out/bin/rotor_post, spinning, peer thread
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1926 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3762520,"operations":4000,"operations_per_second":1063117,"p50_ns":903,"p99_ns":959,"p999_ns":8255,"p9999_ns":22481,"overflow":0,"peak_rss_bytes":0}
== round 3, ./zig-out/bin/rotor_post, spinning, peer process
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 1902 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":3716269,"operations":4000,"operations_per_second":1076348,"p50_ns":907,"p99_ns":967,"p999_ns":8095,"p9999_ns":8576,"overflow":0,"peak_rss_bytes":0}
== round 3, ./zig-out/linux-bench/post_epoll, waiting, peer thread
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 15383 ns
{"workload":"cross-core","candidate":"rotor","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57955070,"operations":4000,"operations_per_second":69018,"p50_ns":12607,"p99_ns":18815,"p999_ns":23167,"p9999_ns":24821,"overflow":0,"peak_rss_bytes":0}
== round 3, ./zig-out/linux-bench/post_epoll, waiting, peer process
rotor_post: mode waiting, gap 0 us, peer CPU per round trip 13924 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":57493616,"operations":4000,"operations_per_second":69572,"p50_ns":12479,"p99_ns":19583,"p999_ns":25471,"p9999_ns":27010,"overflow":0,"peak_rss_bytes":0}
== round 3, ./zig-out/linux-bench/post_epoll, spinning, peer thread
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2716 ns
{"workload":"cross-core","candidate":"rotor (spinning, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5349320,"operations":4000,"operations_per_second":747758,"p50_ns":1215,"p99_ns":1623,"p999_ns":13631,"p9999_ns":29845,"overflow":0,"peak_rss_bytes":0}
== round 3, ./zig-out/linux-bench/post_epoll, spinning, peer process
rotor_post: mode spinning, gap 0 us, peer CPU per round trip 2684 ns
{"workload":"cross-core","candidate":"rotor (peer in another process, not a comparison)","version":"this tree","cores":2,"connections":1,"payload_bytes":0,"load":"even","duration_ns":5271454,"operations":4000,"operations_per_second":758803,"p50_ns":1215,"p99_ns":1615,"p999_ns":10111,"p9999_ns":15809,"overflow":0,"peak_rss_bytes":0}
```
