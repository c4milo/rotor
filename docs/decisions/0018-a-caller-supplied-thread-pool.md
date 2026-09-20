# 18. A caller-supplied thread pool for blocking file operations

Status: **accepted** on 2026-09-20. The owner ruled "let's allow a thread pool" after the
comparison below showed what the kqueue backend costs and what libxev does instead. This record
amends `0002-scope.md`'s correction "files on macOS" and adds a row to the choice that record
made. Nothing is built yet, and one thing it needs does not exist.

## Context

### What blocks, and for how long

Three operations run their system call inline on the loop thread in the kqueue backend:
`read`, `write` and `fdatasync` (`src/kqueue/kqueue_perform.zig`). They run inside `tick`, not
`submit`: `submit` queues, and `tick` calls `flush`, which performs each queued operation in turn.
So one tick holding a batch of file operations performs them one after another, and the loop makes
no `kevent` call and serves no socket until the last of them returns.

Measured on 2026-09-20 on a loaded `mac`, so the throughputs are not a measurement and the shape
is. Random 4 KiB reads, rotor's own p50:

| queue depth | p50 | against depth 1 |
|---:|---:|---:|
| 1 | 100,000 ns | 1.0 |
| 4 | 363,000 ns | 3.6 |
| 32 | 2,794,000 ns | 27.9 |

Latency rises with depth while throughput stays flat, which is one server with a queue in front of
it. At depth 32 the loop is unavailable to every connection it owns for about 2.8 ms.
`bench/competitors/README.md` holds the full table and the libuv comparison beside it.

### What libxev does, which decision 2 did not weigh

libxev's kqueue backend flags every file read that moves data as a thread-pool operation
(`src/watcher/file.zig`), and its loop holds `thread_pool: ?*ThreadPool`, **supplied by the caller
at init**. When no pool was supplied, the operation fails with `EPERM` and the completion is
queued (`src/backend/kqueue.zig`). libxev ships a `ThreadPool` and starts none of its own.

So libxev never blocks its loop, and never starts a thread either. Decision 2 listed three
choices — run inline, hand to a thread pool "as libuv does", or refuse — and rejected the second
because the loop starts no thread. A caller-supplied pool is a fourth choice: the loop still
starts no thread, and the caller decides.

### Why the current behaviour is the worst of the options

Not that it is slow. That it is **silent**. A consumer on a Mac sees its program work, and learns
the loop stalls only by benchmarking it and reasoning backwards, which is how this record's table
was produced. libxev's `EPERM` is louder and therefore kinder.

## Decision

Allow a caller-supplied offload for the operations a backend cannot do without blocking. **rotor
starts no thread, ships no thread pool, and allocates nothing.** Non-negotiable 4 stands as
written: the loop starts no thread.

### What rotor provides, and what it does not

| rotor provides | the caller provides |
|---|---|
| A way to hand one blocked operation out, and to take its result back | the threads, and whatever runs on them |
| The refusal when no offload was given | the choice to give one |
| The statistic saying how much was offloaded and how much blocked | — |

### What a loop does with a file operation, by what it was given

Proposed, and the implementation follows it until the owner rules otherwise. A kqueue loop takes
one file policy at init:

| policy | behaviour | for |
|---|---|---|
| `offload` | hands `read`, `write` and `fdatasync` to the caller's offload | a consumer that wants concurrency on macOS |
| `blocking` | today's behaviour: performs it inline, and the tick stalls | a development machine, chosen and not inherited |
| `refuse` (the default) | the operation ends with `unsupported` | everybody who did not choose |

The default is `refuse`, because the complaint this record answers is that the stall is invisible.
A caller that wants the stall says so in one word at init, and a caller that says nothing is told
rather than slowed. The io_uring backend takes the option and ignores it: the kernel does these
operations without a thread, and that is the whole point of the backend.

### The thing this needs that does not exist

An offloaded operation finishes on a thread that owns no loop, and **such a thread cannot reach a
loop today**. `submit` calls `assert_owner`, which halts a caller that is not the loop's own
thread. `0004-threading.md` describes a `Remote` for exactly this case, and
`0017-the-layer-that-owns-the-loop.md` records that no file under `src/` contains it.

So this record cannot be built before that one is answered. The kqueue backend already has most of
the machinery: `kqueue_mailbox.zig` carries a `Mailbox` with `push`, `pop_into` and the
`EVFILT_USER` wake, used today for one loop posting to another. What is missing is a sender that
is a thread rather than a loop. `0017`'s open question 5 asks whether to build `Remote` or drop
it; this record answers it: **build it**, because an offload needs it.

## Alternatives it beat

**rotor ships a thread pool and starts it, as libuv does.** Rejected: non-negotiable 4. It also
decides the consumer's threading, which rotor refuses to do everywhere else — `0004-threading.md`
enables thread-per-core without choosing it, and `post` exists so a consumer can build what it
wants.

**Keep the inline call and change nothing.** Rejected by the owner on 2026-09-20. The measurement
above is why: a 2.8 ms stall that nothing reports is not a development inconvenience, it is a
result nobody can see.

**Refuse always, decision 2's third choice.** Rejected there because it "would stop stompy's
journal from running on the machine it is developed on", and that reason still holds. The
`blocking` policy keeps that door open, with the difference that it is now opened deliberately.

**Offload on both backends, for symmetry.** Rejected: io_uring performs these operations without
a thread already, so an offload there would add a hop and remove nothing. The asymmetry is the
kernels', and hiding it would make a harness row depend on which path ran, which
`0002-scope.md` refuses for the same reason it refuses a silent fallback.

## What this changes elsewhere

- `0002-scope.md`, the correction "files on macOS": its three choices become four, and its
  consequence — "macOS is a development platform" — weakens to "macOS is a development platform
  unless the consumer supplies threads". No file number from macOS is published as a claim either
  way, because the device and the scheduler are a laptop's.
- `0004-threading.md`: `Remote` moves from described to required.
- `0017-the-layer-that-owns-the-loop.md`, open question 5: answered, build it.
- CLAUDE.md, non-negotiable 4: unchanged in force, and worth a sentence saying a caller may hand
  the loop threads that the loop itself never starts.

## How it is checked

- A conformance scenario per policy, on kqueue: `refuse` ends a file read with `unsupported`,
  `blocking` completes it, and `offload` completes it on the caller's thread. The suite runs on
  both backends, so the io_uring arm asserts that the option changes nothing there.
- A halt scenario for an offload that answers a loop it was not given.
- The reads workload gains a rotor candidate per policy, so `bench/files/reads_runner.zig` can
  say what the offload is worth against the inline call and against libuv's four threads. That
  row is the one that decides whether this was worth building.

## Open questions

1. **What is the offload's shape?** Proposed: a context pointer and two function pointers, one to
   hand work out and one the worker calls when it is done, so rotor names no thread type and no
   pool. The alternative is for rotor to define a queue the caller drains, which moves the
   wake-up problem to the caller and is worth comparing before either is built.
2. **Does an offloaded operation keep its cancellation semantics?** Decision 5 says every
   operation ends with exactly one final event. A `pread` already running on a worker cannot be
   cancelled, so a cancel must mean "end it when it returns" and not "stop it". That is what
   `0005-cancellation.md` already says for an operation the kernel owns, and it should say so for
   one a worker owns.
3. **Does the file policy belong on the loop or on the operation?** Proposed: the loop, once at
   init, because a consumer that wants both shapes can run two loops and decision 4 already says
   a loop belongs to one thread. Per-operation would let one connection stall the loop while
   another does not, which is harder to reason about and no consumer has asked for.
4. **When is this built?** Milestone 4 is unfinished and unmeasured, and this record's own gate is
   a harness row. Proposed: after milestone 4 reports, so the offload is measured against numbers
   that exist rather than against the ones it hopes to beat.
