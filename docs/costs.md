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
| `mac` | development, kqueue backend | Apple M1 Pro, 128-byte cache line, 64 KiB L1d, 4 MiB L2 | 8 performance, 2 efficiency | 32 GiB | macOS 26.6.2, Darwin 25.6.0 | internal NVMe | 2026-09-19 |
| `linux` | target, io_uring backend | to name | to name | to name | to name, kernel 6.1 or later | to name, NVMe | no |

The `mac` row comes from `sysctl` and `sw_vers` on the machine this tree was started on. The
`linux` machine is not chosen. stompy builds for `znver4` and `znver5`, so a server of that family
is the expected target. A Docker container on `mac` runs Linux inside a virtual machine, so its
numbers describe the virtual machine and never go in the `linux` column.

## The table

| id | operation | prior (ns) | prior source | `mac` measured (ns) | `linux` measured (ns) |
|---|---|---|---|---|---|
| C1 | L1 cache reference | 0.5 | Abseil | | |
| C2 | L2 cache reference | 3 | Abseil | | |
| C3 | main memory reference, a last-level cache miss | 50 | Abseil | | |
| C4 | branch mispredict | 5 | Abseil | | |
| C5 | indirect call through a function pointer, predicted | 1 to 2 | recalled | | |
| C6 | smallest syscall round trip, `getppid` | 100 to 500 | recalled | | |
| C7 | `io_uring_enter`, 1 NOP submitted and its completion reaped, no wait | 300 to 1,000 | recalled | not applicable | |
| C8 | one more NOP in a batch of 32, submission side, per entry | 20 to 60 | recalled | not applicable | |
| C9 | one more completion in a reap of 32, per entry | 5 to 20 | recalled | not applicable | |
| C10 | `kevent` round trip, 1 change submitted and 1 event returned | 500 to 2,000 | recalled | | not applicable |
| C11 | one more change in a `kevent` changelist of 32, per change | 50 to 200 | recalled | | not applicable |
| C12 | 4 KiB O_DIRECT NVMe read, queue depth 1, submit to completion | 20,000 | Abseil | not applicable | |
| C13 | 4 KiB O_DIRECT NVMe read, queue depth 32, per operation | no prior | none | not applicable | |
| C14 | loopback TCP round trip, 1 byte each way, both ends on one core | 10,000 to 30,000 | recalled | | |
| C15 | loopback TCP round trip, 1 byte each way, ends on two cores | no prior | none | | |
| C16 | `send` plus `recv` of 4 KiB on a connected loopback socket, the two syscalls alone | no prior | none | | |
| C17 | one cross-core message by `IORING_OP_MSG_RING`, post to reap | no prior | none | not applicable | |
| C18 | one cross-core message by a shared ring plus an `EVFILT_USER` wake, post to reap | no prior | none | | not applicable |
| C19 | one cross-core message by a shared ring when the receiver is already awake | no prior | none | | |
| C20 | monotonic clock read | 20 | recalled | | |
| C21 | thread-local variable read and compare | 1 | recalled | | |

Rows C17 to C19 exist because the threading model is the main claim
(`docs/decisions/0004-threading.md`), and one cross-core message is the unit that model pays in.

macOS has no O_DIRECT. `F_NOCACHE` is the nearest setting, and kqueue does not report readiness for
regular files, so rows C12 and C13 have no `mac` cell
(`docs/decisions/0002-scope.md` states what the kqueue backend does with files).

## How the rows are used

A decision record writes its arithmetic over row ids, then over the numbers. For example, the
per-message syscall cost of a readiness loop that calls `recv` and `send` once each is `2 × C6`,
and the same message through a batch of 32 on io_uring costs `C7 / 32 + 2 × C8 + 2 × C9`. With
the priors that is 200 to 1,000 ns against 60 to 190 ns. The priors say the batch is worth
building. Only the measured columns can say the batch won.
