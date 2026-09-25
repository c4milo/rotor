# Cost probes

These probes measure the rows of `docs/costs.md`. Every design argument in `docs/decisions/`
multiplies and adds those rows, so each probe says what it measures, how, and what it cannot show.

Nobody types a number into `docs/costs.md` from memory (`docs/costs.md`, rule 1). A measured cell
comes from a run of these probes on the machine the column names. Make that run serially, on a
quiet machine, on mains power, and copy the cells by hand.

## Commands

```bash
zig build bench-costs                          # every row this target has
zig build bench-costs -- --row C6              # one row
zig build bench-costs -- --row C1 --row C3     # --row may repeat
zig build test-bench-programs                  # the probes' own unit tests, with the others
```

`build/bench.zig` always builds the probes ReleaseSafe, the mode rotor ships in. `zig build test`
compiles the probes and lints them, and `zig build test-bench-programs` runs their unit tests.

Exit status: 0 when every row printed a number, 1 when a row failed, 2 on a usage error.

Each row has one command, `zig build bench-costs -- --row <id>`:

| row | file | what the command runs |
|---|---|---|
| C1 | `probes/probes_memory.zig` | pointer chase over 32 KiB |
| C2 | `probes/probes_memory.zig` | pointer chase over 2 MiB |
| C3 | `probes/probes_memory.zig` | pointer chase over 512 MiB |
| C4 | `probes/probes_cpu.zig` | one branch loop over constant bits, then over random bits |
| C5 | `probes/probes_cpu.zig` | a direct call loop, then the same callee through a pointer |
| C6 | `probes/probes_syscall.zig` | `getppid` |
| C10 | `probes/probes_kqueue.zig` | `kevent` with 1 change in and 1 event out; macOS only |
| C11 | `probes/probes_kqueue.zig` | the C10 call, then with 31 more changes; macOS only |
| C14 | `probes/probes_socket.zig` | 1 byte each way on loopback TCP, one thread |
| C15 | `probes/probes_socket.zig` | 1 byte each way on loopback TCP, the echo on a second thread |
| C16 | `probes/probes_socket.zig` | `send` and `recv` of 4 KiB with the data already there |
| C18 | `probes/probes_cross_core.zig` | ring message to a thread blocked in `kevent`; macOS only |
| C19 | `probes/probes_cross_core.zig` | ring message to a thread that spins on the ring |
| C20 | `probes/probes_syscall.zig` | the monotonic clock |
| C21 | `probes/probes_cpu.zig` | a thread-local read and compare inside a never-inlined function |
| C22 | `probes/probes_socket.zig` | `send` and `recv` of 64 KiB with the data already there |
| C23 | `probes/probes_memory.zig` | `@memcpy` of 64 KiB between two warm buffers |
| C24 | `probes/probes_cross_process.zig` | C19 with the far side in a process made by `fork` |
| C25 | `probes/probes_cross_process.zig` | a ring message plus decision 21's wake to a process blocked in its wait |

Rows C7, C8, C9, C12, C13 and C17 need Linux and io_uring: C7 to C9 are in
`probes/probes_linux.zig`, C12 and C13 in `probes/probes_linux_file.zig`, and C17 in
`probes/probes_linux_message.zig`. `probes/probes.zig` selects them when the target is Linux.

### `orbstack`

The probes are built for the Linux gate's target and run in its container, without a cpuset:

```bash
zig build-exe -target aarch64-linux-musl -O ReleaseSafe --dep harness -Mroot=bench/costs/main.zig \
  -target aarch64-linux-musl -O ReleaseSafe -Mharness=bench/harness/harness.zig -femit-bin=/tmp/costs
docker run --rm --security-opt seccomp=unconfined -v /tmp:/t:ro \
  alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc \
  sh -c 'cp /t/costs /tmp/c && chmod +x /tmp/c && /tmp/c'
```

The seccomp option is what the Linux gate uses, because Docker's default profile refuses
`io_uring_setup`. A `--cpuset-cpus` that leaves out cores 0 and 1 makes every pin below fail, and
the report then says so on each row; with the pins refused, C19's two spinning threads can share a
core, and the row then takes minutes.

## Output

The report prints the machine, the OS, the Zig version, the date, the clock with the smallest step
it was seen to make, and what was done about pinning. Then, per row:

- One Markdown table line: `| C6 | smallest syscall round trip, getppid | median (p99) |`. The
  cell is what goes into `docs/costs.md`: the median, and the p99 in parentheses, in nanoseconds.
- One line of method: the sample count, the batch, the warm-up, what the p99 is a p99 of, the
  smallest sample, the clock and its step, the compiler mode, the thread placement, and what the
  number includes.

A row whose median is under 0.15 ns prints `FAILED: measured nothing`. That is less than one cycle
of a 6 GHz core, so the optimizer deleted the work. A row whose own checks fail prints `FAILED`
and the error. A failed row has no number.

## Method

`measure.zig` owns the method, and every probe uses it.

1. Before any timing, `Environment.init` maps every large array once: 512 MiB for the memory rows
   and the sample buffers.
2. `settle` raises the thread's QoS class and spins for 300 ms, so the first row does not start on
   a slow core.
3. A probe runs `warmup` timed batches and throws them away, then keeps `samples` timed batches
   of `batch` operations. A sample is the elapsed time divided by the batch.
4. The row is the median of the samples. The p99 is the nearest rank: the smallest sample with at
   least 99 percent of the samples at or under it.

**What the p99 means.** The clock steps in units of 41.67 ns on Apple silicon, and one read costs
as much as a dozen L1 loads or more. An operation shorter than that cannot be timed alone. Rows
C1 to C6, C10, C11, C19, C20 and C21 time a batch and divide, so their p99 is the p99 of batch
means. A batch mean hides one slow operation among its thousands. Rows C14, C15, C16 and C18 time
every operation alone, so their p99 is the p99 of single operations.

**Pairs.** C4 and C11 are differences of two loops. C5 and C21 are read beside a baseline.
`sample_pairs` times both loops back to back inside every sample, so drift in clock rate or in
load lands on both, and it summarises the per-sample difference. C4 and C11 report the
difference. C5 and C21 report the absolute time of the loop the row names and give the baseline
in the method line, because their difference can be zero on some machines and a zero cell would
fail as a probe that measured nothing.

**The clock** is `clock_gettime(CLOCK_UPTIME_RAW)` on macOS and `clock_gettime(CLOCK_MONOTONIC)`
elsewhere: the clock `std.Io` reads, and the one C20 measures. `CLOCK_MONOTONIC` on macOS steps
in whole microseconds, so the probes do not use it there.

**Pinning.** macOS on Apple silicon has no hard CPU affinity. Every thread of the probes asks for
the user-interactive QoS class, which keeps it on performance cores when one is free, and the
report says that the thread was not pinned. On Linux the rows that name a core pin with
`sched_setaffinity`: C14 pins its thread to core 0, and C15, C17 and C19 pin their near thread to
core 0 and their far thread to core 1. A spawned thread inherits its parent's affinity, so a
two-thread row that pinned only one thread would run both on one core; each of those rows pins
both and reports both placements. The rows before C14 are not pinned. A row that could not pin
says so in its method line.

## What each probe measures, and what it cannot

### C1, C2, C3: one load

The loop is `current = current.next` through 128-byte nodes linked in one random cycle. Each
load's address is the value the load before it returned, so loads cannot overlap and no prefetcher
can predict the next address. A node is one cache line on Apple silicon. The working set decides
which level answers: 32 KiB fits every L1d of an M1 Pro, 2 MiB misses L1 and fits every L2, and
512 MiB is more than 40 times the largest L2. `sysctl` reports no L3 on that machine.

- The probe asserts that the links form one cycle through every node, and that the chase ended on
  the node that a separate walk over the indices predicts. A shorter cycle or a skipped load would
  shrink the working set without a word.
- The `next` field is a plain pointer. An index scaled by 8 measured one cycle more per load on
  an M1 Pro: that cycle is the addressing mode, not the cache.
- The timed loop is a function that is never inlined. Inlined, the compiler folded the read of the
  start pointer into the loop, and one load instruction then read a just-stored stack slot once
  per batch. On an M1 Pro that loop ran for milliseconds at 3 cycles per load and then for
  milliseconds at 4, and the median landed on either. The cause was not measured.
- **C3 includes a TLB miss on nearly every load.** 512 MiB is 32,768 pages of 16 KiB, far more
  than a TLB holds. macOS gives a process no larger page on Apple silicon, so this probe cannot
  measure the cache miss without the page-table walk. On Linux the probe requests no huge pages,
  and transparent huge pages may still apply: read
  `/sys/kernel/mm/transparent_hugepage/enabled` and record it beside the number.
- The hardware names of `docs/costs.md` say 64 KiB L1d and 4 MiB L2 for `mac`. Those are the
  efficiency cores. The performance cores, where the probes run, have 128 KiB and 12 MiB. Both
  working sets fit both.

### C4: branch mispredict

One loop with one conditional branch per byte runs over a megabyte of zeros and then over a
megabyte of random bits. It is the same machine code both times. The row is the per-branch
difference divided by 0.5, because independent fair bits mispredict half the time on any
predictor.

- The probe cannot count mispredicts. macOS gives the performance counters to root alone. The 0.5
  is arithmetic, not a measurement.
- Each arm reads a value through a volatile pointer. The compiler may not run a volatile load the
  program would not have run, so it cannot compute both arms and select one. Check it with
  `objdump -d`: `run_branches` must hold a `cbnz` or `cbz` on the loaded byte (`jne` or `je` on
  x86-64), and no `csel` or `cmov`. If the compiler ever removes the branch, the row fails as a
  probe that measured nothing.
- The branch tests a byte loaded from L1. After a flush that load starts over, so the row
  includes its latency. A branch on a value that is already in a register costs less; a branch on
  a value that misses the cache costs more.
- The random bits are long enough that a window of them repeats only every 128 batches, so a
  predictor with a long history cannot learn them.

### C5: indirect call, predicted

Two loops call the same callee, which adds 1 to its argument. The first calls it directly with
inlining forbidden. The second calls it through a pointer read from a volatile location, so the
compiler cannot know the target. The target never changes, so the predictor is right. The row is
the second loop's time per iteration; the method line gives the first loop's time and the median
per-sample gap.

- The number includes the callee, its frame record (every ReleaseSafe function keeps one), and the
  return. It is one iteration of a minimal loop, not the cost of the `blr` instruction alone.
- A loop this short depends on how the core's front end handles it. Two call loops of the same
  shape measured 3 and 5 cycles a call in one build on an M1 Pro. Read the row as "between 1 and
  2 ns".
- Check with `objdump -d`: the direct loop must hold `bl` to `add_one`, the other `blr`.

### C6: smallest system call

`getppid` reads one field in the kernel. A process can get a new parent at any time, so no libc
may cache the answer. On Linux the probes link no libc and the call is the raw `syscall`
instruction. On macOS it is libSystem's stub around `svc #0x80`, the only supported path. A raw
`svc` measured within 3 percent of the stub in a development run. Every call's answer is checked.

### C10, C11: kevent

- C10 is one `kevent` call that submits one change and returns one event. The change triggers an
  EVFILT_USER filter on the same kqueue (NOTE_TRIGGER), and the same call reports it. EV_CLEAR
  resets the filter, so every call does the same work. Every call's event is checked.
- C11 is `(t32 - t1) / 31`. `t1` is the C10 call. `t32` is the same call with 31 more changes
  behind the trigger. Both return the one user event, so the 31 changes are the only difference.
  Each of them re-arms EVFILT_READ with EV_ADD and EV_ENABLE on an idle loopback TCP socket whose
  filter already exists.
- C11 cannot show the first EV_ADD of a descriptor, which allocates the filter, or EV_DELETE. A
  change on an EVFILT_USER filter that does nothing measured about a quarter less than the socket
  re-arm in a development run.
- Both calls pass a zero timeout, so a probe that goes wrong gets 0 events and fails. It cannot
  block.

### C14, C15, C16: loopback TCP

One connected pair on 127.0.0.1, TCP_NODELAY on both ends, blocking calls, every operation timed
alone.

- C14: the measuring thread sends a byte on one socket, receives it on the other, sends it back
  and receives it. The row is the four calls together.
- C15: a second thread owns the far end and echoes. The measuring thread sends a byte and blocks
  until the echo arrives.
- C16: `send` and then `recv` of 4 KiB. Before the clock starts, an untimed
  `recv(MSG_PEEK | MSG_WAITALL)` blocks until one whole block sits in the far end's buffer. The
  pair always has one block in flight, so the timed `recv` returns the block sent one sample
  earlier and never waits. The row is two system calls and two copies. In a development run on
  macOS the `send` took about four fifths of the row, and its samples fell into two groups about
  2 microseconds apart. The probe does not show why.
- No thread is pinned. "One core" and "two cores" in the row names are what the scheduler chose.
- On macOS, as recalled from the XNU sources and not verified here, `send` does not deliver a
  loopback segment: the kernel queues it for an input thread of its own. Every leg of C14 then
  wakes a thread, which would explain why C14 and C15 measure alike. It also means the timed
  `recv` of C16 can find the socket locked by that thread.

### C22: send and recv of 64 KiB

C16's large twin, and the same design: a whole block already sits in the receiving end's buffer
before the clock starts, so the timed pair never waits for data. Two things differ. It asks both
ends for 512 KiB of kernel buffer and refuses to report a number unless the receiving end reads
back as at least two blocks, because one block waits while the timed `send` adds another and a
smaller buffer would make the row a measure of waiting for room. It also takes 4,000 samples where
C16 takes 10,000, since each one moves sixteen times the bytes.

### C23: one copy of 64 KiB

`@memcpy` between two buffers carved from the arena, both reused every time, so the copy runs warm.
The row is a lower bound on the copy a `send` or a `recv` of that size makes: the kernel's copy also
touches socket buffer pages and page tables this probe never goes near.

The length is read through a volatile pointer every iteration, so the compiler cannot prove two
copies move the same bytes and fold them into one. It did exactly that at first, reporting 62.5 ns
for 64 KiB on the `mac` machine, which is over a terabyte a second. The probe now also refuses a
median under 131 ns, which is 500 GB/s and faster than the memory can be, so a folded copy fails
the row instead of filling it.

### C18, C19: one cross-core message

The ring is single-producer single-consumer: two atomic indices, no lock, each index on a
128-byte line of its own, 16-byte messages. `push` reads the consumer's index to refuse a full
ring. A thread reads its own index with a plain load, because no other thread writes it.

- C18: the consumer blocks in `kevent` with a 5-second timeout. The producer reads the clock,
  writes the message, and triggers the consumer's EVFILT_USER filter. The consumer wakes, takes
  the message, and reads the clock. The message carries the producer's reading, so the sample is
  post to reap, and each message is timed alone. It includes the producer's `kevent` call.
- The producer spins for 100 microseconds after the consumer says it is about to block. If the
  scheduler held the consumer back, that sample is a message to a thread that was still awake,
  and the smallest sample shows such cases. Gaps from 50 to 1,000 microseconds gave the same
  median in development runs. A thread that slept for seconds may wake slower; the probe does not
  show that.
- C19: the consumer spins on the ring. One message takes about as long as two steps of the clock,
  so the probe times a batch of round trips: request and reply through two rings, both threads
  spinning. A round trip is two messages, so a sample is the batch time over twice the round
  trips. The spin has no pause instruction; a loop that pauses reaps later.
- **C19 moves with the build.** On an M1 Pro its median held within 2 percent from run to run of
  one binary, and moved between 60 and 100 ns across binaries whose only differences were
  elsewhere in the file. The cause was not measured. Read the row as that range.
- A push that cached the consumer's index, and read it again only when the ring looked full,
  measured the same as the plain push.
- No thread is pinned, so the scheduler chose the two cores. On an M1 Pro they may share a
  cluster's L2 or not.

### C20: monotonic clock read

The row reads the clock that times every probe. On macOS that call is `mach_absolute_time` plus a
conversion to a timespec, so the method line also gives `mach_absolute_time` alone, in ticks.

### C21: thread-local read and compare

A never-inlined function reads a thread-local and compares it with its argument, as the entry
points of `docs/decisions/0004-threading.md` do. The row is one call, the call and the return
included. The method line gives the same function over a plain global, and the median per-sample
gap, which is what thread-local addressing adds.

- On macOS every access to a thread-local calls the `tlv_get_addr` thunk through a pointer. On
  Linux with a static executable it is one load off the thread pointer.
- Inlined into the timing loop, the compiler would resolve the thread-local's address once per
  batch. A caller that enters the library pays it on every call, so the function is never inlined.
- The read is volatile, so the function has an effect and the compiler cannot merge or hoist its
  calls. Every compare is counted, and the probe fails unless all of them matched.

## Known limits

- **No pinning on macOS.** A QoS class is a request. Under load the scheduler can still move a
  thread between performance cores or onto an efficiency core. The L1 row shows it: before the
  probes spun for 300 ms at start-up, the first row of a development run took about 1.5 times as
  long per load as the rows after it.
- **Loaded machine.** Another build on the machine lowers the clock rate the cores reach, fills
  the shared L2, and widens every p99. Fill `docs/costs.md` from a serial run on a quiet machine.
- **Laptop power state.** Battery power, low power mode and a hot chassis all lower the clock
  rate. Run on mains power, with low power mode off, and let the machine cool first.
- **TLB effects.** C3 includes them and cannot separate them on macOS. C1 and C2 use 2 and 128
  pages. In a development run a 1 MiB working set measured the same as the 2 MiB one, so the TLB
  does not show at that size.
- **Clock step.** 41.67 ns on Apple silicon. A row timed alone is quantised to it, which is under
  2 percent of the shortest such row.
- **Short loops depend on code layout.** C5, C21 and C19 move by a cycle or more with the build.
  Their method lines and the sections above say how to read them.
- **Linux.** The probes compile for `x86_64-linux` and `aarch64-linux`. They filled the
  `orbstack` column of `docs/costs.md` on 2026-09-22 (`bench/results/`), pinned as above. A virtual
  machine's numbers never go in the `linux` column (`docs/costs.md`, Machines), and no physical
  Linux machine has run the probes.

## Layout

| file | holds |
|---|---|
| `main.zig` | arguments, the run over the probe list, the report |
| `measure.zig` | the clock, thread placement, plans, sampling, the median and the p99 |
| `machine.zig` | the machine, the OS, the Zig version and the date, printed above the table |
| `sys.zig` | the socket calls, spelled once for macOS and for Linux without libc |
| `probes/probes.zig` | the probe list, selected by OS and sorted by row |
| `probes/probes_*.zig` | the probes, one file per kind of row |
