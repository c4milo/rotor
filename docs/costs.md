# Costs

This document holds the latency of the low-level operations rotor's design arguments multiply and
add. Every design argument in `docs/decisions/` cites a row of it by its id. A claim that
something is fast enough shows the arithmetic over these rows.

**Status: the `mac`, `orbstack` and `github` columns were filled on 2026-09-22**, with the probes
of `bench/costs/`; "How the columns were filled" below says from which runs, and what each column
cannot carry. The `linux` column is empty, because that machine is not named.

## Rules

1. A number in a measured column comes from a probe in `bench/costs/`, run on the machine the
   column names. Nobody types a number from memory into a measured column.
2. Each measured cell holds the median, and the p99 in parentheses, in nanoseconds.
3. The prior column is a planning estimate and not evidence. It comes from the Abseil Performance
   Hints table where that table has the row, and is marked `recalled` where it comes from
   memory. A decision record may use a prior to decide what to build first. It may not use a
   prior to claim a gain.
4. When a measurement lands, every decision record that cited the prior is re-read. A record
   whose argument the measurement breaks is reopened, and the record says so.
5. A probe reports how it measured: the iteration count, the warm-up, the clock, the pinned core,
   and the compiler mode. `bench/costs/README.md` records the command for each row.

## Machines

| id | role | CPU | cores | memory | OS and kernel | storage | filled |
|---|---|---|---|---|---|---|---|
| `mac` | development, kqueue backend | Apple M1 Pro, 128-byte cache line; performance cores 128 KiB L1d and 12 MiB L2, efficiency cores 64 KiB and 4 MiB | 8 performance, 2 efficiency | 32 GiB | macOS 26.6.2, Darwin 25.6.0 | internal NVMe | 2026-09-19 |
| `orbstack` | **named measurement machine**, io_uring backend, and where the Linux gate runs | the `mac` machine's cores, through OrbStack's virtual machine; the guest reports CPU implementer `0x61`, Apple's | 10, as the guest reports them | 15.66 GiB (`MemTotal` 16,425,400 kB), plus a 16 GiB `zram0` swap | Linux 7.0.14-orbstack-00380-ga7e0a2dc9535, aarch64 | virtio: `vda` 415 MiB, `vdb` 460 GiB, `vdc` 1 GiB, each backed by a file on the `mac` machine's APFS | 2026-09-20 |
| `github` | x86-64 cross-check, io_uring backend | Intel Xeon Platinum 8370C at 2.80 GHz, as this run's `/proc/cpuinfo` named it; a later run gets whichever the pool has | 4 virtual | 15.61 GiB (`MemTotal` 16,372,436 kB) | Linux 6.17.0-1022-azure, x86_64 | an Azure cloud volume, not an NVMe | 2026-09-22 |
| `linux` | target, io_uring backend | to name | to name | to name | to name, kernel 6.1 or later | to name, NVMe | no |

The `mac` row comes from `sysctl` and `sw_vers` on the machine this tree was started on.

The `orbstack` row was read from the guest itself on 2026-09-20 — `uname -a`, `/proc/cpuinfo`,
`/proc/meminfo` and `/proc/partitions` — and not from OrbStack's documentation. It is real Linux
on the `mac` machine's own cores, and nothing is emulated. Its syscall and CPU rows are
therefore measurements and not estimates, and it is the only Linux this project has measured
anything on. Two limits, and only the second is about virtualisation:

- **It is not the `linux` row, because that row is the deployment target.** stompy builds for
  `znver4` and `znver5`, so the target is x86-64 Zen. An `io_uring_enter` on an M1 Pro does not
  predict one on a Zen 4, so a number here can guide work and can never fill that column.
- **C12 and C13 cannot be measured here.** The guest sees virtio block devices backed by a disk
  image on APFS, so an O_DIRECT read passes through the host's filesystem on its way to the
  drive. That is not the row.

What `orbstack` is good for, and what milestone 3 uses it for: any comparison of two builds or
two code paths on one machine, decision 8's assertion experiment among them. A ratio measured
here holds whatever the absolute numbers are elsewhere.

### The owner promoted it on 2026-09-20

`orbstack` is a **named machine**, and its column is filled from probes run on it, under rule 1
like any other. The project's earlier blanket statement — that a number from a virtual machine
never enters this file — is amended to what it was actually protecting against:

- A number measured on `orbstack` fills the **`orbstack`** column and nothing else. It never
  fills `linux`, because that column is the deployment target and an `io_uring_enter` on an M1
  Pro does not predict one on a Zen 4.
- **C12 and C13 stay empty here, for ever**, for the virtio reason above. An empty cell with a
  stated reason is worth more than a number measured through the wrong storage stack.
- A design argument may cite an `orbstack` cell, and must say which machine it came from. A claim
  that rotor is faster than another candidate is still made on the machine the claim names.

### The owner added `github` on 2026-09-22

A GitHub-hosted `ubuntu-24.04` runner, filled by the `costs` job of `.github/workflows/ci.yml`,
which is started by hand. It is here because **it is the only x86-64 machine this project has
measured anything on**: `mac` and `orbstack` are both Apple silicon, and the deployment target is
x86-64. An argument about the target's architecture had nothing but priors before it.

It is a named machine under three rules of its own, because it is not the same machine twice:

- **Every cell of this column comes from one run**, and `bench/results/costs-github-2026-09-22.md`
  is that run, with the CPU it reported. The probe reads `/proc/cpuinfo` for exactly this reason.
- **The column is replaced whole, never cell by cell.** GitHub hands out whichever processor its
  pool had, so a cell taken from a Xeon beside one taken from an EPYC would be a column describing
  no machine. A later run replaces all of it and names its own CPU.
- **C12 and C13 stay empty**, as they do for `orbstack` and for a different reason: the file those
  rows read sits on an Azure cloud volume, and the row names an NVMe. The probe ran and its numbers
  are in the results file; they are not this column's.

**It is not the `linux` row and cannot become it.** That row is the deployment target, and stompy
builds for `znver4` and `znver5`. A Xeon Platinum 8370C is Ice Lake, so a cell here is x86-64 and
not Zen. It is also shared, virtualised and unpinned, where the `linux` row wants a machine
somebody can keep quiet.

### Why `orbstack` cannot become the `linux` row

It was asked, and the guest answered it: **`orbstack` is `aarch64`**, on Apple silicon (CPU
implementer `0x61`). The `linux` row is the deployment target, and stompy builds for `znver4` and
`znver5` — x86-64 Zen. That is a different instruction set on different silicon, not a slower
version of the same one. A syscall cost, a cache miss and a branch mispredict all differ, and
those are what this table is for.

Two other things the guest reports are worth knowing before any number is read from it:

- **A 16 GiB `zram0` swap**, which is compressed swap held in RAM. A run that reaches memory
  pressure here behaves unlike one on a machine that swaps to a disk, or one that does not swap.
- **The disks are virtio files on APFS**, which is C12 and C13's exclusion above, and is also why
  nothing here measures a file workload.

The `linux` machine is still not chosen, and the column stays empty until one is. Nothing in this
file may be filled from a machine of another architecture, however convenient it is to reach.

## The table

| id | operation | prior (ns) | prior source | `mac` measured (ns) | `orbstack` measured (ns) | `github` measured (ns) | `linux` measured (ns) |
|---|---|---|---|---|---|---|---|
| C1 | L1 cache reference | 0.5 | Abseil | 0.93 (1.32) | 0.93 (1.44) | 1.43 (1.63) | |
| C2 | L2 cache reference | 3 | Abseil | 5.43 (8.54) | 6.78 (14.4) | 23.4 (24.7) | |
| C3 | main memory reference, a last-level cache miss | 50 | Abseil | 128 (199) | 185 (327) | 93.8 (109) | |
| C4 | branch mispredict | 5 | Abseil | 5.77 (8.34) | 5.78 (9.32) | 7.09 (8.56) | |
| C5 | indirect call through a function pointer, predicted | 1 to 2 | recalled | 1.50 (2.39) | 1.53 (2.45) | 1.15 (1.51) | |
| C6 | smallest syscall round trip, `getppid` | 100 to 500 | recalled | 112 (133) | 88.9 (160) | 98.6 (139) | |
| C7 | `io_uring_enter`, 1 NOP submitted and its completion reaped, no wait | 300 to 1,000 | recalled | not applicable | 193 (389) | 202 (251) | |
| C8 | one more NOP in a batch of 32, submission side, per entry | 20 to 60 | recalled | not applicable | 51.6 (81.1) | 54.8 (67.4) | |
| C9 | one more completion in a reap of 32, per entry | 5 to 20 | recalled | not applicable | 11.7 (14.3) | 8.06 (11.3) | |
| C10 | `kevent` round trip, 1 change submitted and 1 event returned | 500 to 2,000 | recalled | 294 (379) | not applicable | not applicable | not applicable |
| C11 | one more change in a `kevent` changelist of 32, per change | 50 to 200 | recalled | 45.7 (65.0) | not applicable | not applicable | not applicable |
| C12 | 4 KiB O_DIRECT NVMe read, queue depth 1, submit to completion | 20,000 | Abseil | not applicable | not applicable | not applicable | |
| C13 | 4 KiB O_DIRECT NVMe read, queue depth 32, per operation | no prior | none | not applicable | not applicable | not applicable | |
| C14 | loopback TCP round trip, 1 byte each way, both ends on one core | 10,000 to 30,000 | recalled | 12,791 (47,500) | 1,416 (1,708) | 5,772 (15,958) | |
| C15 | loopback TCP round trip, 1 byte each way, ends on two cores | no prior | none | 11,750 (40,875) | 9,333 (42,833) | 8,363 (20,259) | |
| C16 | `send` plus `recv` of 4 KiB on a connected loopback socket, the two syscalls alone | no prior | none | 4,417 (17,416) | 1,250 (1,500) | 4,902 (6,832) | |
| C17 | one cross-core message by `IORING_OP_MSG_RING`, post to reap | no prior | none | not applicable | 10,981 (13,519) | 8,926 (9,743) | |
| C18 | one cross-core message by a shared ring plus an `EVFILT_USER` wake, post to reap | no prior | none | 18,125 (46,750) | not applicable | not applicable | not applicable |
| C19 | one cross-core message by a shared ring when the receiver is already awake | no prior | none | 97.0 (501) | 98.0 (518) | 35.4 (49.4) | |
| C20 | monotonic clock read | 20 | recalled | 16.4 (28.3) | 18.6 (30.8) | 16.3 (26.6) | |
| C21 | thread-local variable read and compare | 1 | recalled | 1.55 (2.44) | 0.93 (1.72) | 1.43 (1.89) | |
| C22 | `send` plus `recv` of 64 KiB on a connected loopback socket, the two syscalls alone | no prior | none | | | | |
| C23 | copy 64 KiB from one buffer to another | no prior | none | | | | |

Rows C22 and C23 exist because of a question the echo comparison could not answer on 2026-09-22:
rotor leads libuv and libxev at 4 KiB and trails libxev at 64 KiB, and nothing here said how much
of a 64 KiB echo is the kernel's own work. C16 measures the same pair of calls at 4 KiB, so C22 is
its large twin, and C23 bounds the copy inside it. The two rows are the estimate that has to come
before any argument about a large payload, zero-copy send among them.

Rows C17 to C19 exist because the threading model is the main claim
(`docs/decisions/0004-threading.md`), and one cross-core message is the unit that model pays in.

macOS has no O_DIRECT. `F_NOCACHE` is the nearest setting, and kqueue does not report readiness for
regular files, so rows C12 and C13 have no `mac` cell
(`docs/decisions/0002-scope.md` states what the kqueue backend does with files).

## How the columns were filled

On 2026-09-22, on mains power, with the desktop in use and no batch job running: the `mac`
machine's load average was 4.7 to 5.1 on 10 cores before every run. Each column holds run 1 of
three serial runs, and `bench/results/` holds all three as they were printed:

- `mac`: `zig build bench-costs`, three times one minute apart
  (`bench/results/costs-mac-2026-09-22.md`).
- `orbstack`: the probes built with `zig build-exe bench/costs/main.zig -target aarch64-linux-musl
  -O ReleaseSafe` and run in the Linux gate's container, three times a few seconds apart
  (`bench/results/costs-orbstack-2026-09-22.md`, and `bench/costs/README.md` for the command).
  C12 and C13 are excluded here, as the Machines section says.

- `github`: the `costs` job of `.github/workflows/ci.yml`, started by hand, one run
  (`bench/results/costs-github-2026-09-22.md`). One run and not three: the runner is not the same
  machine twice, so a spread across runs would mix processors. What that column may carry is above.

Where the three runs disagreed by more than a few percent, the cell is one run and the range is
this: on `mac`, C14 12,417 to 13,792 ns and C18 18,125 to 25,291 ns; on `orbstack`, C7 193 to
238 ns, C8 51.6 to 64.4 ns, C9 11.7 to 14.3 ns and C15 8,896 to 13,000 ns. Every other median
agreed within 2 percent. Two things about `orbstack` explain its spread: the rows before C14 run
on whichever virtual CPU the guest chose, and a virtual CPU can be backed by an efficiency core of
the host, which the probe cannot see; and the two-thread rows pin to cores 0 and 1, which are two
virtual CPUs and not two known physical cores.

On `orbstack`, C15, C17 and C19 pinned both threads and C14 its one thread, and every method line
says so. On `mac` nothing can be pinned, and the rows that wake a thread are the ones that moved.

## What the measured rows changed

Against the priors:

- C1, C2 and C3 are about twice the prior on `mac` (0.93, 5.43 and 128 ns) and C3 is 3.7 times
  it on `orbstack` (185 ns). A miss to memory costs more than the table assumed, which strengthens
  every argument that keeps a hot structure in one line.
- C14 on `orbstack` is 1,416 ns, 7 times under the prior's floor. On `mac` it is 12,791 ns, inside
  the prior. The prior described macOS and not Linux, and every argument that divided by C14 on
  Linux understated its result by that much.
- C7 (193 ns) and C10 (294 ns) are under their priors' floors; C8 (52 ns) is at the top of its
  range; C6, C9, C11, C20 and C21 are inside theirs.
- C17, with no prior, is 10,981 ns on `orbstack`: a `MSG_RING` to a receiver that sleeps costs
  what waking a thread costs. C19, the same message to a receiver that is awake, is 98 ns on both
  machines. C15, a round trip whose far end wakes for every byte, is 9,333 ns on `orbstack` and
  11,750 ns on `mac`; C18, the kqueue wake, is 18,125 ns on `mac`. The reading of 2026-09-20, taken
  under a load average of 46, said the same in shape: the cost is the wake and not the core, by a
  factor of about 100.

`bench/uring/post.zig`, run five times on `orbstack` beside decision 8's experiment
(`bench/results/decision-8-orbstack-2026-09-22.md`), measures the same wake with rotor's own loops.
One message, in ns, across the five runs:

| how the receiving loop waits | one message, ns |
|---|---|
| blocks until the message arrives | 11,041 to 11,479 |
| never blocks, ticks without waiting | 666 to 1,354 |
| ticks without waiting for 50 µs, then blocks | 687 to 1,375 |

A bounded spin takes back almost all of the wake when the peer answers inside the window. What it
costs when the peer does not answer is not measured, which is what keeps
`docs/decisions/0013-when-a-loop-sleeps.md` proposed.

### What the x86-64 column changed

`github` is the first x86-64 reading this project has. Against the two Apple-silicon machines and
against the priors:

- **An L2 hit costs 23.4 ns there, against 5.43 on `mac` and a prior of 3.** That is the largest
  miss in the table, nearly eight times the prior, and it lands on the argument decision 8 rests
  on: "an assertion that reads memory the function would not otherwise read pays C2 or C3, 3 to 50
  ns". On the deployment architecture that is 23 to 94 ns, against a per-entry budget (C8) of 55.
  The dividing line that record draws — memory, not count — is wider on x86 than the priors made
  it, not narrower.
- **A cross-core message to a receiver that is already awake costs 35.4 ns, a third of the 97 and
  98 the two Apple machines read.** Decision 4's cheapest case is cheaper still on the target.
- **The two Linuxes disagree about loopback by four times**: C14 is 5,772 ns here and 1,416 on
  `orbstack`. A loopback number is the machine's before it is the kernel's, and no argument may
  divide by one without naming which.
- C1 is slower than Apple's in nanoseconds (1.43 against 0.93) and C3 is faster (93.8 against
  128). C6, C7, C8, C9, C20 and C21 are inside their priors and close to `orbstack`'s, which is
  the other Linux.

### Records re-read on 2026-09-22

Rule 4: every record that cited a prior was re-read against the measured cells. No argument
broke. Four records restate their arithmetic with the measured numbers, and say so in place:
decision 3 (the multishot saving against a Linux round trip), decision 4 (the handoff of
`single_acceptor`), decision 11 (the skip-success flag, now settled by C17) and decision 13 (its
table). Decision 8 gains a results section for its experiment, which `orbstack` could not decide.

## How the rows are used

A decision record writes its arithmetic over row ids, then over the numbers. For example, the
per-message syscall cost of a readiness loop that calls `recv` and `send` once each is `2 × C6`,
and the same message through a batch of 32 on io_uring costs `C7 / 32 + 2 × C8 + 2 × C9`. With
the priors that is 200 to 1,000 ns against 60 to 190 ns. The priors say the batch is worth
building. Only the measured columns can say the batch won: on `orbstack` they say 178 ns against
133 ns, a saving of 45 ns per message and not the 140 to 810 the priors allowed.
