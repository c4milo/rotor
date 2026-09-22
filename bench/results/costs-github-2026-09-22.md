# Cost probes, `github`, 2026-09-22

The `costs` job of `.github/workflows/ci.yml`, started by hand on commit `fc89a70`, run 35781510952.
One run, which is the rule for this machine: the pool hands out whichever processor it has, so three
runs would be three machines rather than three samples of one (`docs/costs.md`).

**This run got a different processor from the one that first filled the column.** It reports an Intel
Xeon Platinum 8573C where the run of earlier that day reported a 8370C at 2.80 GHz, and it sits in
`westcentralus` where that one sat in `eastus2`. Every cell of the `github` column therefore comes
from this run, replaced whole, because a column mixing the two would compare two machines.

It also carries the two rows added the same day: C22, a 64 KiB loopback send and receive pair, and
C23, one 64 KiB copy. Both exist to bound how much of a 64 KiB echo the kernel charges for
(`bench/alternatives/README.md`).

What follows is the job's output as it was printed.

```text
machine: INTEL(R) XEON(R) PLATINUM 8573C, 4 processors, 16372436 KiB
os: Linux 6.17.0-1022-azure, x86_64
zig: 0.16.0, ReleaseSafe
date: 2026-09-22 (UTC)
clock: clock_gettime(CLOCK_MONOTONIC), smallest step seen 21 ns
placement: thread not pinned: this probe pins nothing on this OS, run it under taskset
| id | operation | median (p99), ns |
|---|---|---|
| C1 | L1 cache reference | 1.67 (1.96) |
  method: 2000 samples, each a batch of 32768 loads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1.67 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; 256 nodes of 128 bytes in one random cycle, 32 KiB in all; each load's address is the value the load before it returned, so the number is one load's latency
| C2 | L2 cache reference | 5.39 (31.1) |
  method: 2000 samples, each a batch of 8192 loads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 5.36 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; 16384 nodes of 128 bytes in one random cycle, 2048 KiB in all, on 512 pages: a load misses L1 and hits L2
| C3 | main memory reference, a last-level cache miss | 120 (135) |
  method: 2000 samples, each a batch of 512 loads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 114 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; the number includes a TLB miss on nearly every load: the working set is 131072 pages of 4 KiB, and transparent huge pages were not requested and may still apply, read /sys/kernel/mm/transparent_hugepage/enabled; 4194304 nodes of 128 bytes in one random cycle, 512 MiB in all
| C4 | branch mispredict | 8.34 (10.1) |
  method: 2000 samples, each a batch of 8192 branches per variant timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; the row comes from the difference of two loops timed back to back, and its smallest per-sample value was 6.92 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; twice the per-branch gap between random outcomes (4.56 ns a branch) and constant ones (0.38 ns), since half of the random branches mispredict; the branch tests a byte loaded from L1, so the cost includes that load's latency after the flush
| C5 | indirect call through a function pointer, predicted | 1.34 (1.71) |
  method: 2000 samples, each a batch of 16384 calls per loop timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1.34 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one loop iteration: the call through the pointer, a callee that adds 1 and keeps a frame record as every ReleaseSafe function does, and the return; the same callee called directly took 1.00 ns and the median per-sample gap was 0.33 ns
| C6 | smallest syscall round trip, getppid | 124 (171) |
  method: 2000 samples, each a batch of 128 calls timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 124 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; the raw syscall instruction, no libc; every call's answer is checked
| C7 | io_uring_enter, 1 NOP submitted and its completion reaped, no wait | 300 (567) |
  method: 2000 samples, each a batch of 32 calls timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 233 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; SINGLE_ISSUER, DEFER_TASKRUN, TASKRUN_FLAG and SUBMIT_ALL, as src/uring sets them; the kernel does nothing for a NOP, so this is the ring's own cost; every call's completion is checked
| C8 | one more NOP in a batch of 32, submission side, per entry | 56.3 (71.4) |
  method: 2000 samples, each a batch of 16 calls per batch entry timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; the row comes from the difference of two loops timed back to back, and its smallest per-sample value was 38.0 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; (t32 - t1) / 31 per sample: t1 236 ns is the C7 call, t32 1981 ns submits and reaps 32 NOPs in one call; the difference carries one submission and one completion, so C9 is the part of it that is the completion
| C9 | one more completion in a reap of 32, per entry | 5.09 (7.81) |
  method: 2000 samples, each a batch of 32 completions timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 4.88 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; the 32 completions are in the ring before the timing starts, put there by an untimed submit_and_wait; the timed loop copies them out and checks each, so this is the reap alone and carries no part of the enter that C7 measures
| C12 | 4 KiB O_DIRECT NVMe read, queue depth 1, submit to completion | 189765 (959054) |
  method: 500 samples, each a batch of 16 reads timed as one and divided, after 16 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 168432 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; O_DIRECT, 4 KiB, offsets drawn by splitmix64 over a 256 MiB file this probe writes and removes; one read in flight, submitted and waited for, so this is the device's latency plus the ring's
| C13 | 4 KiB O_DIRECT NVMe read, queue depth 32, per operation | 68182 (218713) |
  method: 200 samples, each a batch of 128 reads timed as one and divided, after 8 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 15695 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; O_DIRECT, 4 KiB, offsets drawn by splitmix64 over a 256 MiB file this probe writes and removes; 32 reads in flight per call, so the device overlaps them and this is throughput in a latency's units
| C14 | loopback TCP round trip, 1 byte each way, both ends on one core | 5209 (6882) |
  method: 10000 round trips, each timed alone, after 500 that were thrown away; the p99 is of single operations; smallest sample 4981 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; send, recv, send, recv of 1 byte from the one measuring thread, blocking, TCP_NODELAY; thread pinned to one core with sched_setaffinity. One thread is one core at a time whatever the pinning says, but the kernel's own work runs where the scheduler puts it
| C15 | loopback TCP round trip, 1 byte each way, ends on two cores | 7403 (21452) |
  method: 10000 round trips, each timed alone, after 500 that were thrown away; the p99 is of single operations; smallest sample 3578 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one byte each way between two threads; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned: unpinned, the scheduler may have put both ends on one core, which is what this row is set against C14 to separate
| C16 | send plus recv of 4 KiB on a connected loopback socket, the two syscalls alone | 4320 (4594) |
  method: 10000 send and recv pairs, each timed alone, after 500 that were thrown away; the p99 is of single operations; smallest sample 2659 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one send and one recv of 4,096 bytes, both from the measuring thread; the block the recv returns had fully arrived before the clock started, so the number is two system calls and two copies, not a wait
| C17 | one cross-core message by IORING_OP_MSG_RING, post to reap | 8724 (9253) |
  method: 1000 samples, each a batch of 64 messages timed as one and divided, after 32 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 7127 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; a round trip halved: two rings on two threads, each set up as src/uring sets one up, posting MSG_RING to the other; DEFER_TASKRUN means the receiver must enter the kernel to see a message, so both sides block and this number includes waking one; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned
| C19 | one cross-core message by a shared ring when the receiver is already awake | 36.0 (38.0) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 34.3 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; request and reply through two rings, both threads spinning with no pause instruction; half a round trip is one message from post to reap; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned; the median moves with the build of this probe, so read it as a range (README.md)
| C20 | monotonic clock read | 22.4 (28.7) |
  method: 2000 samples, each a batch of 1024 reads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 22.1 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; clock_gettime(CLOCK_MONOTONIC); the same call times every probe
| C21 | thread-local variable read and compare | 1.00 (1.85) |
  method: 2000 samples, each a batch of 16384 calls per loop timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1.00 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one call of a never-inlined entry point that reads the thread-local and compares it, call and return included; the same function over a plain global took 1.00 ns and the median per-sample gap was -0.00 ns, which is what thread-local addressing adds on this OS
| C22 | send plus recv of 64 KiB on a connected loopback socket, the two syscalls alone | 11204 (21257) |
  method: 4000 send and recv pairs, each timed alone, after 200 that were thrown away; the p99 is of single operations; smallest sample 10946 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one send and one recv of 65536 bytes, both from the measuring thread; the block the recv returns had fully arrived before the clock started and the receiving end's buffer reads back as 1048576 bytes, so the number is two system calls and two copies of this size, not a wait
| C23 | copy 64 KiB from one buffer to another | 1587 (2032) |
  method: 2000 samples, each a batch of 16 copies timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1577 ns; clock_gettime(CLOCK_MONOTONIC) with 21 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; @memcpy of 65536 bytes between two buffers that stay the same, so both are warm: this is a lower bound on the copy a send or a recv of this size makes, which also touches socket buffer pages and page tables
﻿2026-09-22T20:39:01.5172884Z ##[group]Run set -euo pipefail
^[[36;1mset -euo pipefail^[[0m
^[[36;1mzig build bench-linux^[[0m
^[[36;1mfor round in 1 2 3 4 5; do^[[0m
^[[36;1m  echo "== round $round"^[[0m
^[[36;1m  ./zig-out/linux-bench/uring_nop_safe^[[0m
^[[36;1m  ./zig-out/linux-bench/uring_nop_fast^[[0m
^[[36;1mdone^[[0m
shell: /usr/bin/bash -e {0}
env:
  ZIG_VERSION: 0.16.0
== round 1
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 333 | 547 | 333 |
| 8 | 873 | 1036 | 109 |
| 32 | 2808 | 2964 | 87 |
| 64 | 5410 | 5788 | 84 |
| 128 | 10686 | 16262 | 83 |
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 313 | 354 | 313 |
| 8 | 811 | 952 | 101 |
| 32 | 2540 | 2681 | 79 |
| 64 | 4857 | 5533 | 75 |
| 128 | 9494 | 14678 | 74 |
== round 2
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 324 | 403 | 324 |
| 8 | 877 | 998 | 109 |
| 32 | 2808 | 2927 | 87 |
| 64 | 5415 | 5858 | 84 |
| 128 | 10658 | 15982 | 83 |
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 314 | 407 | 314 |
| 8 | 819 | 1097 | 102 |
| 32 | 2524 | 2674 | 78 |
| 64 | 4843 | 5010 | 75 |
| 128 | 9542 | 14111 | 74 |
== round 3
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 333 | 416 | 333 |
| 8 | 869 | 1063 | 108 |
| 32 | 2804 | 2939 | 87 |
| 64 | 5418 | 6041 | 84 |
| 128 | 10742 | 16436 | 83 |
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 315 | 367 | 315 |
| 8 | 810 | 908 | 101 |
| 32 | 2524 | 2661 | 78 |
| 64 | 4816 | 6694 | 75 |
| 128 | 9529 | 12844 | 74 |
== round 4
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 329 | 400 | 329 |
| 8 | 876 | 971 | 109 |
| 32 | 2814 | 3100 | 87 |
| 64 | 5421 | 5628 | 84 |
| 128 | 10682 | 16024 | 83 |
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 316 | 361 | 316 |
| 8 | 818 | 884 | 102 |
| 32 | 2536 | 2662 | 79 |
| 64 | 4831 | 5063 | 75 |
| 128 | 9558 | 14889 | 74 |
== round 5
uring nop, ReleaseSafe, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 328 | 422 | 328 |
| 8 | 884 | 996 | 110 |
| 32 | 2823 | 2960 | 88 |
| 64 | 5419 | 6544 | 84 |
| 128 | 10770 | 16625 | 84 |
uring nop, ReleaseFast, 20000 samples per batch size
| batch | round median ns | round p99 ns | per operation ns |
|---|---|---|---|
| 1 | 316 | 412 | 316 |
| 8 | 819 | 884 | 102 |
| 32 | 2568 | 2671 | 80 |
| 64 | 4875 | 5083 | 76 |
| 128 | 9555 | 12103 | 74 |
```
