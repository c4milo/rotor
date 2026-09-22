# Cost probes on `github`, 2026-09-22

One run of `zig build bench-costs` on a GitHub-hosted `ubuntu-24.04` runner, started by hand with
`gh workflow run ci.yml` (the `costs` job of `.github/workflows/ci.yml`). This is the first x86-64
machine this project has measured anything on: `mac` and `orbstack` are both Apple silicon, and
`orbstack` is a virtual machine on `mac` itself.

**The runner named itself, and the next one may not be the same.** The probe reads
`/proc/cpuinfo`, so the report below carries the CPU this run landed on; GitHub gives whichever
processor its pool had. `docs/costs.md` says what that means for the column: it is replaced
whole, and never cell by cell.

The runner is shared and was not quiet, and nothing pins a thread there. Rows C12 and C13 ran and
their numbers are below, but the `github` column leaves them empty: the file they read sits on an
Azure cloud volume and the row names an NVMe.

```text
rotor cost probes, for docs/costs.md

machine: Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz, 4 processors, 16372436 KiB
os: Linux 6.17.0-1022-azure, x86_64
zig: 0.16.0, ReleaseSafe
date: 2026-09-22 (UTC)
clock: clock_gettime(CLOCK_MONOTONIC), smallest step seen 16 ns
placement: thread not pinned: this probe pins nothing on this OS, run it under taskset

| id | operation | median (p99), ns |
|---|---|---|
| C1 | L1 cache reference | 1.43 (1.63) |
  method: 2000 samples, each a batch of 32768 loads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1.43 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; 256 nodes of 128 bytes in one random cycle, 32 KiB in all; each load's address is the value the load before it returned, so the number is one load's latency
| C2 | L2 cache reference | 23.4 (24.7) |
  method: 2000 samples, each a batch of 8192 loads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 23.1 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; 16384 nodes of 128 bytes in one random cycle, 2048 KiB in all, on 512 pages: a load misses L1 and hits L2
| C3 | main memory reference, a last-level cache miss | 93.8 (109) |
  method: 2000 samples, each a batch of 512 loads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 86.3 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; the number includes a TLB miss on nearly every load: the working set is 131072 pages of 4 KiB, and transparent huge pages were not requested and may still apply, read /sys/kernel/mm/transparent_hugepage/enabled; 4194304 nodes of 128 bytes in one random cycle, 512 MiB in all
| C4 | branch mispredict | 7.09 (8.56) |
  method: 2000 samples, each a batch of 8192 branches per variant timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; the row comes from the difference of two loops timed back to back, and its smallest per-sample value was 1.08 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; twice the per-branch gap between random outcomes (3.87 ns a branch) and constant ones (0.32 ns), since half of the random branches mispredict; the branch tests a byte loaded from L1, so the cost includes that load's latency after the flush
| C5 | indirect call through a function pointer, predicted | 1.15 (1.51) |
  method: 2000 samples, each a batch of 16384 calls per loop timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1.15 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one loop iteration: the call through the pointer, a callee that adds 1 and keeps a frame record as every ReleaseSafe function does, and the return; the same callee called directly took 0.86 ns and the median per-sample gap was 0.29 ns
| C6 | smallest syscall round trip, getppid | 98.6 (139) |
  method: 2000 samples, each a batch of 128 calls timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 97.0 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; the raw syscall instruction, no libc; every call's answer is checked
| C7 | io_uring_enter, 1 NOP submitted and its completion reaped, no wait | 202 (251) |
  method: 2000 samples, each a batch of 32 calls timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 197 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; SINGLE_ISSUER, DEFER_TASKRUN, TASKRUN_FLAG and SUBMIT_ALL, as src/uring sets them; the kernel does nothing for a NOP, so this is the ring's own cost; every call's completion is checked
| C8 | one more NOP in a batch of 32, submission side, per entry | 54.8 (67.4) |
  method: 2000 samples, each a batch of 16 calls per batch entry timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; the row comes from the difference of two loops timed back to back, and its smallest per-sample value was 41.0 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; (t32 - t1) / 31 per sample: t1 203 ns is the C7 call, t32 1903 ns submits and reaps 32 NOPs in one call; the difference carries one submission and one completion, so C9 is the part of it that is the completion
| C9 | one more completion in a reap of 32, per entry | 8.06 (11.3) |
  method: 2000 samples, each a batch of 32 completions timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 5.19 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; the 32 completions are in the ring before the timing starts, put there by an untimed submit_and_wait; the timed loop copies them out and checks each, so this is the reap alone and carries no part of the enter that C7 measures
| C12 | 4 KiB O_DIRECT NVMe read, queue depth 1, submit to completion | 114079 (191718) |
  method: 500 samples, each a batch of 16 reads timed as one and divided, after 16 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 99210 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; O_DIRECT, 4 KiB, offsets drawn by splitmix64 over a 256 MiB file this probe writes and removes; one read in flight, submitted and waited for, so this is the device's latency plus the ring's
| C13 | 4 KiB O_DIRECT NVMe read, queue depth 32, per operation | 11937 (410345) |
  method: 200 samples, each a batch of 128 reads timed as one and divided, after 8 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 10630 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; O_DIRECT, 4 KiB, offsets drawn by splitmix64 over a 256 MiB file this probe writes and removes; 32 reads in flight per call, so the device overlaps them and this is throughput in a latency's units
| C14 | loopback TCP round trip, 1 byte each way, both ends on one core | 5772 (15958) |
  method: 10000 round trips, each timed alone, after 500 that were thrown away; the p99 is of single operations; smallest sample 5676 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; send, recv, send, recv of 1 byte from the one measuring thread, blocking, TCP_NODELAY; thread pinned to one core with sched_setaffinity. One thread is one core at a time whatever the pinning says, but the kernel's own work runs where the scheduler puts it
| C15 | loopback TCP round trip, 1 byte each way, ends on two cores | 8363 (20259) |
  method: 10000 round trips, each timed alone, after 500 that were thrown away; the p99 is of single operations; smallest sample 4010 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one byte each way between two threads; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned: unpinned, the scheduler may have put both ends on one core, which is what this row is set against C14 to separate
| C16 | send plus recv of 4 KiB on a connected loopback socket, the two syscalls alone | 4902 (6832) |
  method: 10000 send and recv pairs, each timed alone, after 500 that were thrown away; the p99 is of single operations; smallest sample 2873 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one send and one recv of 4,096 bytes, both from the measuring thread; the block the recv returns had fully arrived before the clock started, so the number is two system calls and two copies, not a wait
| C17 | one cross-core message by IORING_OP_MSG_RING, post to reap | 8926 (9743) |
  method: 1000 samples, each a batch of 64 messages timed as one and divided, after 32 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 7472 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; a round trip halved: two rings on two threads, each set up as src/uring sets one up, posting MSG_RING to the other; DEFER_TASKRUN means the receiver must enter the kernel to see a message, so both sides block and this number includes waking one; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned
| C19 | one cross-core message by a shared ring when the receiver is already awake | 35.4 (49.4) |
  method: 2000 samples, each a batch of 128 messages, two to a round trip timed as one and divided, after 200 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 34.0 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; request and reply through two rings, both threads spinning with no pause instruction; half a round trip is one message from post to reap; near thread thread pinned to one core with sched_setaffinity, far thread thread pinned to one core with sched_setaffinity. The row means two cores only when both say pinned; the median moves with the build of this probe, so read it as a range (README.md)
| C20 | monotonic clock read | 16.3 (26.6) |
  method: 2000 samples, each a batch of 1024 reads timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 16.3 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; clock_gettime(CLOCK_MONOTONIC); the same call times every probe
| C21 | thread-local variable read and compare | 1.43 (1.89) |
  method: 2000 samples, each a batch of 16384 calls per loop timed as one and divided, after 64 warm-up batches; the p99 is of batch means, not of single operations; smallest sample 1.43 ns; clock_gettime(CLOCK_MONOTONIC) with 16 ns steps; ReleaseSafe; thread not pinned: this probe pins nothing on this OS, run it under taskset; one call of a never-inlined entry point that reads the thread-local and compares it, call and return included; the same function over a plain global took 1.43 ns and the median per-sample gap was -0.00 ns, which is what thread-local addressing adds on this OS
```
