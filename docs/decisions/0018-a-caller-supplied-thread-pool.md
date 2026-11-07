# 18. A caller-supplied thread pool for blocking file operations

Status: **accepted** on 2026-09-20, and **built on 2026-09-21** except the harness row. Camilo
ruled "let's allow a thread pool" after the comparison below showed what the kqueue backend costs
and what libxev does instead. This record amends `0002-scope.md`'s correction "files on macOS" and
adds a row to the choice that record made.

**Amended on 2026-11-06** by Camilo's ruling R1 (a): a loop has at most `offload_in_flight_max`
operations out on its workers, and keeps a further file operation queued. Three more rulings of
that day make the loop end a held operation as it ends a queued one: at a close of its descriptor,
at its deadline, and at a cancel. "Amendment of 2026-11-06" below sets them out.

What is built: the three policies, the hand-off, the cancel of an offloaded operation, the
conformance scenarios and the halt scenarios. What is not: the harness row, because measurement is
deferred (`0003-speed-sources.md`'s rule, and Camilo's ruling of 2026-09-20). **No number is
claimed for the offload.** Camilo brought the work forward on 2026-09-21, ahead of open
question 4's proposed answer, which is recorded there.

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
`bench/alternatives/README.md` holds the full table and the libuv comparison beside it.

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

Proposed, and the implementation follows it until Camilo rules otherwise. A kqueue loop takes
one file policy at init:

| policy | behaviour | for |
|---|---|---|
| `offload` | hands `read`, `write`, `fdatasync` and `fsync` to the caller's offload | a consumer that wants concurrency on macOS |
| `blocking` | today's behaviour: performs it inline, and the tick stalls | a development machine, chosen and not inherited |
| `refuse` (the default) | the operation ends with `unsupported` | everybody who did not choose |

The default is `refuse`, because the complaint this record answers is that the stall is invisible.
A caller that wants the stall says so in one word at init, and a caller that says nothing is told
rather than slowed. The io_uring backend takes the option and ignores it: the kernel does these
operations without a thread, and that is the whole point of the backend. **Amended on 2026-09-23:**
it checks the option first, as the other backends do ("How it is checked").

### The thing this needs, and what was built instead of `Remote`

An offloaded operation finishes on a thread that owns no loop, and **such a thread could not reach a
loop**. `submit` calls `assert_owner`, which halts a caller that is not the loop's own thread.
`0004-threading.md` describes a `Remote` for exactly this case, and
`0017-the-layer-that-owns-the-loop.md` records that no file under `src/` contains it. This record's
first draft concluded from that: build `Remote`, because an offload needs it.

**It did not need `Remote`, and this record's own open question 1 is why.** That question proposes
the offload's shape as "a context pointer and two function pointers, one to hand work out and one
the worker calls when it is done". The second of those *is* the sender this needed, and it is
narrower than `Remote` in three ways: it carries one operation's result rather than any message, it
is reached through a function pointer rather than a registered handle, and it counts against nothing
in `loops_max`. So what was built on 2026-09-21 is what this record already described, and
`Remote` — a handle any thread may post anything through — was owed to
`0017-the-layer-that-owns-the-loop.md`'s DNS worker, and was built on 2026-09-22
(`0004-threading.md`, "What another thread may do").

The kqueue backend had most of the machinery: `kqueue_mailbox.zig`'s `Mailbox`, with `push`,
`pop_into` and the `EVFILT_USER` wake, used for one loop posting to another. What was added:

- `src/core/offload.zig`: `FilePolicy`, `Work` and `Offload`, so both backends take the same options.
- `src/kqueue/kqueue_offload.zig`: one ring per worker, the hand-out, the worker's `run`, and the
  drain that finishes the slots on the loop thread.
- `core.constants.offload_workers_max`, which bounds the rings at 64.

**One ring per worker, not one queue shared between them.** `Mailbox` is single-producer, and its
memory-ordering argument depends on that; a ring each keeps it true and adds no new concurrency
primitive. libxev instead shares one Vyukov MPSC queue between its pool threads
(`src/queue_mpsc.zig`), whose own source carries a TODO saying the atomics are unaudited. The cost
of the choice is memory: a ring is 4,352 bytes, so 64 workers is about 279 KiB, and the caller owns
that memory because the caller's threads write it.

**A caller must keep its offload running until the loop is drained, and stop it before `deinit`.**
An operation out on a worker can only be ended by that worker, so a caller that stops its threads
first leaves an operation that never ends, and `drain` reports `StillInFlight` rather than hanging.
The second half was added on 2026-09-22: a worker's `run` pushes its result and then reads the loop
once more, to learn whether it must wake a loop that sleeps. So a worker can still be inside `run`
after the loop has taken its result and been drained. A loop torn down then has its wake descriptor
read by that worker, and possibly written to after it was closed and its number reused.
ThreadSanitizer reported it in the race gate the first time the epoll suite ran there, from a
scenario that deinitialised the loop before it stopped its pool; kqueue's `run` has the same shape.

## Amendment of 2026-11-06: a bound on the operations out

### The defect

A worker pushes each result to its own ring of `mailbox_messages` (256), and `Work.run` asserts
that the push succeeded. A dropped result would leave an operation with no final event (decision 5,
rule 1). Until this amendment, a loop handed out every file operation of a flush at once.

So a loop with more than 256 file operations out on one worker filled that ring when the loop was
busy, for example in a long callback, while they finished. The 257th push failed, and the process
halted. Load and timing reached the halt, and the caller made no mistake. A robustness audit for
stompy, which runs one loop per core, found it as F1.

### The ruling

Camilo chose answer (a) of R1 on 2026-11-06. The other answers were an assertion at init that
`operations <= mailbox_messages` under `.offload`, and a documented bound only.

- `core.constants.offload_in_flight_max` names the limit, and it is `mailbox_messages`. A comptime
  assert holds it at or below `mailbox_messages`.
- A loop counts the operations it handed out whose result it has not taken off a ring. The count
  rises in the backend's `hand_out` and falls in `core.offload.drain`.
- At the limit, `hand_out` keeps the operation `queued` on a held list. The operation is not
  refused, and it still gets exactly one final event.
- Each flush first hands out the held operations, oldest first, while there is room. So a file
  operation queued later never passes a held one.
- `core.offload.InFlight`, in `src/core/offload_in_flight.zig`, holds the count and the held list
  for both kqueue and epoll. Each loop keeps it in its `Inbox`.

### Why the push assertion is now an invariant

Every result in a ring belongs to an operation that is out, and at most 256 are out. So a ring
never holds more results than it has room for, and only a defect in rotor's count can fail the push.

A worker must also see each ring's `head` no older than it was at the hand-out of each work it ran.
The caller's `submit` must make the `Work` fields visible to the worker. So it orders every store
the loop made before the hand-out, the pops of `head` among them, before the worker's loads.

### The held operations: rulings (a), (b) and (c)

A review of the first build found that a `close` did not end a held write on its descriptor. So the
write went out after the close, to a closed descriptor or to a file that took its number. Camilo
ruled on 2026-11-06 that a held operation is the loop's alone, and the loop ends it as it ends a
queued one.

- **(a) A close ends the held operations on its descriptor.** A backend's `close` first calls
  `end_waiters`, then `InFlight.end_descriptor`, and then closes the descriptor. Each held operation
  on the descriptor ends with `canceled`. The finished list keeps the order, so the caller sees
  these events before the close's event, as decision 5, rule 6 requires.
- **(b) A held operation's deadline runs from its submit.** The flush that holds the operation arms
  its deadline, as a flush that hands an operation out does. The later hand-out keeps that deadline.
  So a caller's `timeout_ns` ends a held operation with `timeout` while it waits for room. The
  expiry marks the operation, and the next flush ends it, as for a queued operation.
- **(c) A cancel ends a held operation wherever it sits.** A backend's `cancel` sets
  `InFlight.canceled` when it marks a queued operation while some are held. The next flush then
  visits each held operation once, ends each one that is marked, and keeps the others in order. A
  flush with no such cancel does not walk the list. Before this ruling, a cancelled operation behind
  one that waited for room ended only when that one went out.

An operation out on a worker is not ended by a `close`. The worker owns it until its result comes
back, and a `pread` or a `pwrite` that runs cannot be stopped. The descriptor can close before the
worker's call starts, or while it runs. The call then fails with `EBADF`, or it reads or writes the
file that took the number. Its event can come after the close's event. So rule 6 does not hold for
such an operation. That was so before this amendment, and the amendment does not change it.
`docs/using.md` tells a caller to take the final event of each such operation before a `close`.

### What it costs and what it changes

- `InFlight` is 20 bytes, and a comptime assert holds it there: the count, the held list and the
  flag of ruling (c). It adds 20 bytes to the `Inbox` of every loop, io_uring's included.
- A flush walks the held list only after a cancel that reached a queued operation while some were
  held. A cancel of an operation on the pending list can cause that walk, which then ends nothing.
  A `close` walks the list when it holds an operation. Each walk visits each held operation once.
- A loop may sleep with operations held. The flush holds one only when 256 are out, so a worker
  owes the loop a result, and that worker's push wakes it. `Inbox.settle_to_sleep` asserts this.
- The caller's `submit` never has to queue more than 256 works for one loop at a time.

### How it is checked

- `src/conformance/conformance_offload_limit.zig` submits 300 reads with one worker that holds. One
  tick hands out exactly 256. The worker then answers all 256 while the loop does not tick, which
  fills the ring. Every read then gets exactly one event, and the pool ran 300. It runs on kqueue
  on macOS and on epoll in the Linux gate and the race gate.
- `src/conformance/conformance_offload_held.zig` fills the offload with 256 reads on a worker that
  holds, and then holds one more operation. A `close` ends a held write on its descriptor with
  `canceled` before its own event. A held read with a deadline of 1 ms ends with `timeout`. A cancel
  of a held read behind another held read ends it with `canceled`, and the first read still goes
  out. Each operation gets exactly one final event. It runs where the limit scenario runs.
- `src/kqueue/kqueue_offload_held_test.zig` tests the same paths through kqueue's own flush, cancel
  and close, with a pool that runs no work.
- `src/core/offload_in_flight.zig` tests the count, the held list, the order, a cancel behind a held
  operation, a deadline, and a close.
- Halt scenarios: a push into a full ring in `tools/halt/kqueue_scenarios.zig` and in
  `tools/halt/epoll_linux_scenarios.zig`. In `tools/halt/core_scenarios_offload.zig`: a hand-out
  past the limit, more results taken than handed out, a sleep with an operation held and none out, a
  hold with room, a cancel noted for an unmarked slot, a hand-out of a marked held operation, a
  negative descriptor, and a held operation that is not queued.

## Alternatives it beat

**rotor ships a thread pool and starts it, as libuv does.** Rejected: non-negotiable 4. It also
decides the consumer's threading, which rotor refuses to do everywhere else — `0004-threading.md`
enables thread-per-core without choosing it, and `post` exists so a consumer can build what it
wants.

**Keep the inline call and change nothing.** Rejected by Camilo on 2026-09-20. The measurement
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
  unless the consumer supplies threads". **Withdrawn on 2026-09-22**: that record now says macOS is
  a production platform, so a macOS file number is a claim, and the offload measured level with
  libuv's own pool (`bench/alternatives/README.md`).
- `0004-threading.md`: `Remote` moves from described to required.
- `0017-the-layer-that-owns-the-loop.md`, open question 5: answered, build it.
- CLAUDE.md, non-negotiable 4: unchanged in force, and worth a sentence saying a caller may hand
  the loop threads that the loop itself never starts.

## How it is checked

Done on 2026-09-21, except the last:

- **A conformance scenario per policy**, on kqueue: `refuse` ends a file read with `unsupported`,
  `blocking` completes it, and `offload` completes it on the caller's thread. The suite runs on both
  backends, so the io_uring arm asserts that the option changes nothing there. Seven scenarios in
  `src/conformance/conformance_offload.zig`, which also cover the cancel, the same-tick delivery,
  and that a socket operation's cancel is untouched by the policy.
- **Halt scenarios** in `tools/halt/kqueue_scenarios.zig`: answering as a worker the loop holds no
  ring for, the `offload` policy with no offload, an offload with no worker, and one with more
  workers than the limit. **Amended on 2026-09-22:** the worker scenario halts on the bounds check
  of the ring lookup in `run`, which comes before the system call. An `assert` of the worker index
  stood there first, and no halt scenario could prove it, because the bounds check halted as well.
  The scenario cannot show that the lookup comes first either, so a comment in `run` says so.
- **Amended on 2026-09-23: every backend checks the options at init**, io_uring included, through
  `core.offload.assert_options`. Under the public module one binary runs io_uring or epoll by what
  the kernel allows, and the same options halted on epoll and passed on io_uring. An offload named
  under another policy, which the options refuse, passed on every backend. io_uring still ignores
  the options once they are checked. The three scenarios of the options above run on every backend
  now, beside two more: an offload under another policy, and, on io_uring alone, too little ring
  memory, because kqueue and epoll halt on that twice and neither halt can prove the other.
- **The race gate cannot see any of this, and that is recorded where it bites.** The offload exists
  on kqueue alone, so its conformance scenarios run on macOS, where ThreadSanitizer cannot be built.
  So the ordering is tested twice: once through the real path on macOS
  (`src/kqueue/kqueue_offload_test.zig`, Darwin only), and once against a bare `Mailbox` and a bare
  flag in the same file, which compiles for Linux and which `zig build test-race` judges.
- The reads workload gains a rotor candidate per policy, so `bench/files/reads_runner.zig` can say
  what the offload is worth against the inline call and against libuv's four threads. That row is
  the one that decides whether this was worth building, and **it is not taken**: measurement is
  deferred.

## Open questions

1. **What is the offload's shape?** Proposed: a context pointer and two function pointers, one to
   hand work out and one the worker calls when it is done, so rotor names no thread type and no
   pool. The alternative is for rotor to define a queue the caller drains, which moves the
   wake-up problem to the caller and is worth comparing before either is built.
   **Answered on 2026-09-27: the caller's context and functions, as proposed.** The loop hands work
   out through the caller's function, and a worker hands its result back through a ring the loop
   drains, so rotor names no thread type and no pool. It measured level with libuv's pool on the
   file rows (`bench/alternatives/README.md`).
2. **Does an offloaded operation keep its cancellation semantics?** **Built to the proposed answer
   on 2026-09-21.** Decision 5 says every operation ends with exactly one final event. A `pread`
   already running on a worker cannot be cancelled, so a cancel means "end it when it returns" and
   not "stop it": `kqueue_cancel.zig` records the cancel and leaves the operation to the worker,
   whose result is what the event carries. That is what `0005-cancellation.md` already says for an
   operation the kernel owns. A conformance scenario holds a worker, cancels, releases it, and
   requires exactly one event.
   **Answered on 2026-09-27: yes, as built.** A cancel means "end it when it returns", as decision 5
   says for an operation the kernel owns.
3. **Does the file policy belong on the loop or on the operation?** Proposed: the loop, once at
   init, because a consumer that wants both shapes can run two loops and decision 4 already says
   a loop belongs to one thread. Per-operation would let one connection stall the loop while
   another does not, which is harder to reason about and no consumer has asked for.
   **Answered on 2026-09-27: the loop, as proposed.**
4. **When is this built?** **Overtaken by Camilo on 2026-09-21**, who brought it forward: the
   comparison's file rows set a rotor with no pool against a libuv with four threads, which measures
   the pool and not the loops, and milestone 4's own rule is that a comparison matches what each
   candidate holds. The proposed answer was: after milestone 4 reports, so the offload is measured
   against numbers that exist rather than against the ones it hopes to beat. That ordering still
   holds for the *number*: none is claimed here.
