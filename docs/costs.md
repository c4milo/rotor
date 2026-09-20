# Costs

This document holds the latency of the low-level operations rotor's design arguments multiply and
add. Every design argument in `docs/decisions/` cites a row of it by its id. A claim that
something is fast enough shows the arithmetic over these rows.

**Status: no row is measured yet.** The measured columns are empty on purpose. Milestone 0 fills
them, before any loop code is written, with the probes of `bench/costs/`.

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
| `orbstack` | development, io_uring backend, and where the Linux gate runs | the `mac` machine's cores, through OrbStack's virtual machine | 10, as the guest sees them | 16 GiB to the guest | Linux 7.0.14-orbstack, aarch64 | a virtio disk backed by a file on the `mac` machine's APFS | no |
| `linux` | target, io_uring backend | to name | to name | to name | to name, kernel 6.1 or later | to name, NVMe | no |

The `mac` row comes from `sysctl` and `sw_vers` on the machine this tree was started on.

The `orbstack` row is real Linux on the `mac` machine's own cores: the guest reports `aarch64`
with CPU implementer `0x61`, Apple's, and nothing is emulated. Its syscall and CPU rows are
therefore measurements and not estimates, and it is the only Linux this project has measured
anything on. Two limits, and only the second is about virtualisation:

- **It is not the `linux` row, because that row is the deployment target.** stompy builds for
  `znver4` and `znver5`, so the target is x86-64 Zen. An `io_uring_enter` on an M1 Pro does not
  predict one on a Zen 4, so a number here can guide work and can never fill that column.
- **C12 and C13 cannot be measured here.** The guest sees virtio block devices backed by a disk
  image on APFS, so an O_DIRECT read passes through the host's filesystem on its way to the
  drive. That is not the row.

What `orbstack` is good for, and what milestone 3 will use it for: any comparison of two builds
or two code paths on one machine, decision 8's assertion experiment among them. A ratio measured
here holds whatever the absolute numbers are elsewhere.

The `linux` machine is not chosen.

## The table

| id | operation | prior (ns) | prior source | `mac` measured (ns) | `orbstack` measured (ns) | `linux` measured (ns) |
|---|---|---|---|---|---|---|
| C1 | L1 cache reference | 0.5 | Abseil | | | |
| C2 | L2 cache reference | 3 | Abseil | | | |
| C3 | main memory reference, a last-level cache miss | 50 | Abseil | | | |
| C4 | branch mispredict | 5 | Abseil | | | |
| C5 | indirect call through a function pointer, predicted | 1 to 2 | recalled | | | |
| C6 | smallest syscall round trip, `getppid` | 100 to 500 | recalled | | | |
| C7 | `io_uring_enter`, 1 NOP submitted and its completion reaped, no wait | 300 to 1,000 | recalled | not applicable | | |
| C8 | one more NOP in a batch of 32, submission side, per entry | 20 to 60 | recalled | not applicable | | |
| C9 | one more completion in a reap of 32, per entry | 5 to 20 | recalled | not applicable | | |
| C10 | `kevent` round trip, 1 change submitted and 1 event returned | 500 to 2,000 | recalled | | not applicable | not applicable |
| C11 | one more change in a `kevent` changelist of 32, per change | 50 to 200 | recalled | | not applicable | not applicable |
| C12 | 4 KiB O_DIRECT NVMe read, queue depth 1, submit to completion | 20,000 | Abseil | not applicable | not applicable | |
| C13 | 4 KiB O_DIRECT NVMe read, queue depth 32, per operation | no prior | none | not applicable | not applicable | |
| C14 | loopback TCP round trip, 1 byte each way, both ends on one core | 10,000 to 30,000 | recalled | | | |
| C15 | loopback TCP round trip, 1 byte each way, ends on two cores | no prior | none | | | |
| C16 | `send` plus `recv` of 4 KiB on a connected loopback socket, the two syscalls alone | no prior | none | | | |
| C17 | one cross-core message by `IORING_OP_MSG_RING`, post to reap | no prior | none | not applicable | | |
| C18 | one cross-core message by a shared ring plus an `EVFILT_USER` wake, post to reap | no prior | none | | not applicable | not applicable |
| C19 | one cross-core message by a shared ring when the receiver is already awake | no prior | none | | | |
| C20 | monotonic clock read | 20 | recalled | | | |
| C21 | thread-local variable read and compare | 1 | recalled | | | |

Rows C17 to C19 exist because the threading model is the main claim
(`docs/decisions/0004-threading.md`), and one cross-core message is the unit that model pays in.

macOS has no O_DIRECT. `F_NOCACHE` is the nearest setting, and kqueue does not report readiness for
regular files, so rows C12 and C13 have no `mac` cell
(`docs/decisions/0002-scope.md` states what the kqueue backend does with files).

## Two priors a loaded run already casts doubt on

Read on 2026-09-20 on `orbstack` while the `mac` machine carried a load average of 46, which is
why neither is in the table and neither supports a claim. A reading taken on a machine that busy
is an upper bound: load makes an operation slower, never faster. So one direction of inference is
sound, and it is the only one drawn here.

- **C14's prior is too pessimistic.** The loopback round trip read about 1,500 ns against a prior
  of 10,000 to 30,000. A loaded machine cannot make a round trip 7 times faster than it is, so
  the prior is wrong by roughly that much, and every argument that divides by C14 understates
  what it is dividing. The prior is recalled and cites no source.
- **C17 is at most about 16,000 ns, and the wake is nearly all of it.** The same run read C19,
  the same message to a receiver that is already awake, at about 100 ns. Whatever the quiet
  numbers turn out to be, the gap between a sleeping receiver and a waking one is the cost that
  matters, and `docs/decisions/0004-threading.md` does not price it.

Neither is a measurement. Both are reasons to take C14, C17 and C19 first when the machine is
quiet.

## What crossing a core costs, and what waking a thread costs

Read on 2026-09-20 on `orbstack`, with both threads pinned by `sched_setaffinity`. Not in the
table: a container's numbers describe the container. The ratios are wide enough to act on.

| row | what | ns |
|---|---|---|
| C14 | round trip, both ends on one core | 1,458 |
| C15 | round trip, ends on two cores | 13,334 to 14,813 |
| C19 | cross-core message, receiver already awake | about 100 |
| C17 | cross-core message by `MSG_RING`, receiver asleep | about 16,300 |

The first reading of C15, before the probe pinned anything, was 2,209 ns. The probe started two
threads and let the scheduler place them, and the scheduler put them on one core, so the row
measured the thing it was written to exclude. Pinning is what made it a measurement.

**The cost is the wake, not the core.** C15 and C17 agree at about 15,000 ns and share one thing:
each wakes a thread that was asleep. C19 crosses the same boundary with the receiver spinning and
costs about 100 ns, 150 times less. So a design that moves work between cores pays almost nothing
for the move and almost everything for the sleep it interrupts.

So a loop that stays awake a little after its last completion should turn a 15,000 ns handoff
into a 700 ns one. `bench/uring/post.zig` measures that, with rotor's own loops, on `orbstack`:

| how the receiving loop waits | one message, ns |
|---|---|
| blocks until the message arrives | 11,021 |
| never blocks, ticks without waiting | 687 |
| ticks without waiting for 50 µs, then blocks | 729 |

**A bounded spin takes back almost all of it**: 729 ns against 687 for a loop that never sleeps,
and against 11,021 for one that always does. Fifteen times, for 6 percent more than the loop that
burns a core outright.

What the benchmark does not measure is the case the spin is wrong for. Here the peer always
answers inside the window, so the spin always pays. A loop whose work has stopped burns the whole
budget and then sleeps anyway, which costs a core 50 µs per idle cycle and is exactly what
decision 4's shared-nothing model was meant to avoid paying for. The shape of an answer is an
adaptive budget, and what it should key on is not measured.

Decision 4 prices a cross-core message and does not price the sleep.
`docs/decisions/0013-when-a-loop-sleeps.md` is the record these numbers earned. It is proposed,
not accepted: none of these numbers is admissible, and the case a spin is wrong for is not
measured at all.

## How the rows are used

A decision record writes its arithmetic over row ids, then over the numbers. For example, the
per-message syscall cost of a readiness loop that calls `recv` and `send` once each is `2 × C6`,
and the same message through a batch of 32 on io_uring costs `C7 / 32 + 2 × C8 + 2 × C9`. With
the priors that is 200 to 1,000 ns against 60 to 190 ns. The priors say the batch is worth
building. Only the measured columns can say the batch won.
