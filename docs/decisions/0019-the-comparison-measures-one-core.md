# 19. The comparison measures one core

Status: **accepted** on 2026-09-21. The owner ruled "no skewed load, use 1 core for accepting
connections", and separately that rotor needs a thread pool on kqueue to compare fairly with libuv
and libxev. This record covers the first half. The second half is
`0018-a-caller-supplied-thread-pool.md`, built the same day, and the section below says why it
touches the file rows and not these.

It amends `0004-threading.md` in three places. It changes no behaviour of the library.

## Context

### What decision 4 asked the harness to do

Three passages ask for skewed and multi-core rows:

- "The harness runs every workload on 1 core and on N cores, even and skewed, and measures C17, C18
  and C19 on their own." (How it is checked)
- "The harness measures every workload skewed as well as even, and reports the skewed numbers when
  they are bad. They will be: a shared queue with stealing beats shared-nothing under skew, and the
  numbers should say by how much." (When one core is hot)
- "The skewed harness runs exist to show the second case in numbers." (When this design is the wrong
  one, where the second case is "few connections, long-lived, of uneven weight")

None of it is built. `bench/harness/report.zig` declares `Load = enum { even, skewed }` and nothing
sets `.skewed`: `bench/echo/client.zig` and `bench/echo/storm.zig` both write `.load = .even`
unconditionally. `bench/echo/echo_runner.zig` takes `--cores` and defaults it to 0, so every row
taken so far is a one-core row.

### No competitor spreads TCP load across cores on kqueue

Read from the pinned trees on 2026-09-21, and recorded in `bench/competitors/README.md`.

| library | what it offers on kqueue | source |
|---|---|---|
| libuv | nothing. `uv_tcp_bind` with `UV_TCP_REUSEPORT` answers `UV_ENOTSUP` on macOS | `src/unix/core.c:2143`, `src/unix/tcp.c:170` |
| libxev | nothing. `xev.TCP.bind` sets `SO_REUSEADDR` and no more | `src/watcher/tcp.zig:88` |
| `std.Io.Threaded` | sets `SO_REUSEPORT` on every platform that defines it, macOS included | `Io/Threaded.zig:11688` |

`uv__sock_reuseport` has three branches: `SO_REUSEPORT_LB` on FreeBSD 12 and later, `SO_REUSEPORT`
on Linux, AIX 7.2.5, DragonFlyBSD 3.6 and Solaris 11.4, and `return UV_ENOTSUP` for everything else.
macOS is in the last branch, and libuv's comment gives the reason: a `SO_REUSEPORT` without load
balancing has semantics that "are completely different, therefore we shouldn't enable it, but fail
this operation". `docs/src/tcp.rst:159` repeats it in the public documentation. The flag arrived in
libuv v1.49.0.

libuv's one sanctioned route to several cores on macOS is the model Node.js uses: one loop accepts,
then passes the accepted handle to another **process** through a pipe, with `uv_write2`'s
`send_handle` (`docs/src/stream.rst:190`). That is a different program, not a loop per core in one
process.

libxev's `ThreadPool` is not a counter-example. It runs blocking file work, and a file operation
fails with `error.ThreadPoolRequired` when the caller gave the loop no pool
(`src/backend/kqueue.zig:870`). It moves no socket between loops, and no libxev example or benchmark
runs a loop per core.

`std.Io.Threaded` is the one candidate that sets the option on macOS. It sets it whenever
`reuse_address` is set, on any platform that defines `SO.REUSEPORT`. On macOS that produces the
behaviour `src/conformance/conformance_reuse_port.zig` measured as 0, 0, 0, 32 — every connection to
the last listener bound — which is the outcome libuv declines to expose.

### Three consequences

1. **On macOS there is no competitor for an N-core row.** rotor's `listener_per_core` shape is one
   libuv refuses on that kernel and libxev does not offer. A row there would set rotor's N loops
   against a competitor's one, which measures thread count.
2. **On Linux every candidate could match the shape, and none of them does today.** libuv has
   `UV_TCP_REUSEPORT`, libxev needs a raw `setsockopt` the program makes itself, and `std.Io` already
   sets it. But `bench/competitors/libuv_echo.c` and `bench/competitors/libxev_echo.zig` take no
   `--loops` and no `--cpu`, so they are single-threaded servers. The same mismatch as on macOS,
   for a different reason.
3. **The skew decision 4 names cannot be aimed.** That record wants "few connections, long-lived, of
   uneven weight", where hashing cannot balance and stealing can. `SO_REUSEPORT` gives no control
   over which loop gets the heavy connection: decision 4's own measurement is 8, 4, 10, 10 on Linux
   7.0.14 and 0, 0, 0, 32 on macOS 26.6. So a skewed row would report the kernel's split, not a
   condition the harness chose.

Decision 4 already saw part of this and said so: "a `listener_per_core` server on macOS is skewed by
construction, not by load. A harness row that says `even` there would be claiming something the
kernel does not do." That sentence and the request for `even` and `skewed` rows cannot both stand.

### Where a thread pool makes the comparison fair, and where it does not

The owner's ruling pairs one core with a thread pool. The two apply to different workloads, and it is
worth writing down which, because a pool in the wrong place would make a row less fair.

**A pool belongs to the file rows.** libuv runs every file operation on one pool per process, four
threads by default (`src/threadpool.c:39`). libxev runs file work on a pool the caller supplies and
answers `EPERM` when there is none (`src/backend/kqueue.zig:870`). rotor performed the read inline on
the loop thread, so `--depth 32` was depth 1 in fact, and
`bench/competitors/README.md` measured the gap: parity at depth 1, and libuv ahead by 3.8 times at
depth 32. `0018-a-caller-supplied-thread-pool.md` closes it, and `bench/files/reads_runner.zig`
carries a `rotor-offload` candidate.

**A pool does not belong to the echo or storm rows.** Neither competitor uses one for sockets on
kqueue: libuv's pool runs file operations and DNS, libxev's runs file work, and both serve a socket
from the loop thread. The harness connects to `127.0.0.1` by address, so no candidate resolves a
name. Giving `rotor_echo` a pool would hand rotor threads that no competitor has on that workload,
which is the mirror of the defect this record is about.

So the socket workloads are one loop against one loop, and the file workloads are one pool against
another. Neither needs a core sweep.

## Decision

**The echo comparison measures one core.** Drop the N-core sweep and the skewed rows from
milestone 4.

What stays:

- One-core rows for every workload, on both kernels, against every installed candidate. That is what
  `zig build test-bench-echo` already gates and what every row taken so far has been.
- **C17, C18 and C19 stay, measured on their own.** `bench/crosscore/` compares rotor's `post`
  against `uv_async_send` and `xev.Async` and does not need a multi-core echo row. Decision 4's main
  claim keeps its measurement.
- rotor's threading model, unchanged and still tested: shared-nothing, one loop per thread, `post`
  between loops, the ownership assertion, and `conformance_reuse_port.zig`, which measures what each
  kernel does with a shared port. Those are facts worth keeping whether or not a row sweeps cores.
- `bench/echo/rotor_echo.zig` keeps `--loops` and `--cpu`. The server can still run a loop per core;
  the runner stops sweeping it. Keeping it costs nothing and it is the only place in the tree that
  drives the shape end to end.

What goes:

- `bench/echo/echo_runner.zig`'s `--cores`, `cores_max` and `client_cpu`, and the `--cpu`/`--loops`
  arguments it passes.
- The `skewed` value of `bench/harness/report.zig`'s `Load`. No row may name a load the harness did
  not produce.
- CLAUDE.md's milestone 4 line "each on 1 core and N cores, even and skewed".

**What this costs, stated plainly.** Decision 4's claim that shared-nothing loses under skew, and by
how much, will not be measured. That record says "They will be: a shared queue with stealing beats
shared-nothing under skew, and the numbers should say by how much." After this amendment the numbers
will not say. The claim rests on the design argument and on C17 to C19, and no document may present
it as measured.

## Alternatives it beat

**Per-loop ports, with the client aiming traffic at one of them.** The only mechanism that gives a
skew the harness chooses, and the only one that behaves the same on both kernels, because it touches
no `SO_REUSEPORT`. Rejected: it is not how a `SO_REUSEPORT` deployment works, so the row would not
describe a deployment anyone runs, and no competitor can be entered against it on macOS anyway. The
row would be rotor against itself.

**Heavy-tailed connection weighting on a shared port**, reported as statistical skew. Closest to the
case decision 4 names. Rejected: the kernel picks which loop gets the heavy connection, so on macOS
every connection lands on one loop and on Linux the split varies per run. The row would measure the
kernel's choice.

**Payload skew**, some connections at 64 KiB and the rest at 4 KiB. Rejected for the same reason,
and it moves the buffer-sizing variable that `bench/competitors/README.md` already had to correct
once, when a rotor sized for 8 KiB was entered against candidates holding 64 KiB.

**Give `libuv_echo` and `libxev_echo` a `--loops` option, and keep N-core rows on Linux only.** The
strongest alternative, and it is not rejected on the merits: it would make the Linux N-core row a
real comparison, since all four candidates can run a loop per core there. Rejected on scope. It
means writing multi-loop servers for two competitors, and milestone 4 has not yet published a
one-core row. **Worth reopening** once the one-core rows exist, if the threading claim needs evidence
of its own.

**Keep the rows and label them honestly**, as rotor's N loops against a competitor's one. Rejected: a
reader compares the numbers in a table whatever the caption says, and a row that needs a caption to
avoid misleading is worse than no row.

## What this changes elsewhere

`0004-threading.md` gains one back-pointer under its status, in the shape decision 2 carries for
decision 18:

```text
Amended on 2026-09-21 by decision 19: the harness measures one core. The requests below for rows
on N cores, and for skewed rows, are withdrawn. That record says why, and what is measured
instead.
```

and one line at each of the three passages named in the Context above, marking the request withdrawn
and pointing here. The passages stay in place: the reasoning was sound and the world it assumed is
what changed.

`CLAUDE.md`, milestone 4: the workload list drops "each on 1 core and N cores, even and skewed".

`bench/competitors/README.md` already holds the kqueue finding, under "No competitor spreads TCP load
across cores on kqueue", and needs no change.

## How it is checked

- `bench/harness/report.zig` has no way to name a load the harness cannot produce. A test holds the
  `Load` enum to its values.
- `bench/echo/echo_runner.zig` takes no `--cores`, and a test holds its option list, so the sweep
  cannot return without a record.
- `bench/echo/rotor_echo.zig` still runs N loops on N cores when a person passes `--loops`, and the
  conformance suite still measures what each kernel does with a shared port. Both are capabilities,
  and neither is a row.
- Mutation: adding `skewed` back to `Load`, or `--cores` back to the runner, must be `CAUGHT`.

## Open questions

1. **Does `Load` keep one value or go entirely?** Answered as proposed: the field keeps `even` alone.
   `report.zig` says its JSON keys are "always in this order", so a published row's shape survives,
   and a later record can add a value without moving every column.
2. **Does `rotor_echo` keep `--loops`?** Answered as proposed: yes, unswept. The
   alternative is to strike it, which would leave no benchmark driving rotor's own thread-per-core
   shape at all.
3. **When does the Linux-only N-core row come back?** Proposed: when the one-core rows are published
   and the threading claim needs its own evidence. The work is the fourth alternative above, and it
   is two competitor servers, not a harness change.
