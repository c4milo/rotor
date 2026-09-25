# 4. Threading model: one shared-nothing loop per core

Status: accepted for implementation on 2026-09-19. The owner gave the instruction to implement and
did not rule on the open questions below, so the implementation follows the proposed answer to
each until a ruling changes it. This record argues with the owner's position in two places: file
ownership and SO_REUSEPORT on macOS.

Amended on 2026-09-25 by the owner's ruling: loops talk through shared memory on io_uring too.
A post on every backend goes through the mailbox ring the sender has to the target, and
`IORING_OP_MSG_RING` only wakes a target that sleeps. The ruling reopened the alternative "Shared
rings for both backends", which this record had rejected, on the evidence recorded under it. "How
cores talk" and "What another thread may do" below say what changed.

Amended on 2026-09-21 by decision 19: the harness measures one core. The requests below for rows on
N cores, and for skewed rows, are withdrawn. That record says why, and what is measured instead.

Amended on 2026-09-19 by decision 10: the replay argument for shared-nothing now concerns a
consumer's own simulator, which can reproduce one queue's order and cannot reproduce a race
between threads. The simulator test under "How it is checked" is replaced by a test that posts
between two loops on two real threads.

## Context

The position under review: the loop is shared-nothing and single-threaded by construction. It
holds no lock, starts no thread, and never moves work between cores on its own. Thread per core
is what the application builds by running one pinned loop per core with explicit channels
between them, as Seastar and glommio do, and as libuv with its hidden pool does not.

## Decision

Accept the position. A `Loop` is owned by the one thread that initialised it. The sections below
settle each point the brief lists.

The reason that carries the most weight is replay. A work-stealing scheduler makes completion
order depend on how threads race. One core's queue has one order, and the simulator can
reproduce it from a seed (`0009-sampling-and-replay.md`). `std.Io.Uring` and `std.Io.Kqueue` in
Zig 0.16.0 both move ready fibers between threads, so neither can offer replay.

### Where connections come from

Both ways ship in version one, and the application picks one per listener.

- **`listener_per_core`**: every loop binds its own listening socket with SO_REUSEPORT. The
  kernel picks a socket by a hash of the connection's addresses. No message crosses a core.
- **`single_acceptor`**: one loop accepts and posts each accepted descriptor to a loop it
  chooses, as one cross-core message (C17 or C18). A descriptor is an integer valid in the whole
  process, so the message carries it as is.

`listener_per_core` is the default on Linux. Its weakness is the one the brief names: a hash
spreads connections evenly and not load. With few long-lived connections of unequal weight, one
core can end up with most of the work.

`single_acceptor` is the only choice on macOS, which the brief did not account for. On macOS,
SO_REUSEPORT lets several sockets bind one port and does not spread incoming connections across
them. FreeBSD added `SO_REUSEPORT_LB` for that; macOS has no equivalent.

### A worked `listener_per_core`, and what rotor does not decide

`bench/echo/rotor_echo.zig --loops N` is the first one in this tree, added 2026-09-20. A consumer
reading this record had the shape named and nothing to copy.

**rotor starts none of it.** The server spawns the threads, pins them, binds a listener each and
hands each loop its own memory. The library offers the parts and enforces the invariants:

- `sync.listen` takes `reuse_port` as an option and chooses nothing.
- `Tables.assert_owner` halts a loop touched from a thread that is not its own.
- `Loop.init`'s comment says it must run on the owning thread, after that thread is pinned.
- `post` and the registry are the only way a loop reaches another.

A `Thread.spawn` under `src/` would be the library making the application's call, and would break
the fourth non-negotiable. There is none: every spawn in the tree is in `bench/` or in the
conformance suite.

The conformance suite measures what each kernel then does with the shape, and the two disagree
exactly as this record says (`conformance_reuse_port.zig`, 2026-09-20):

| kernel | 32 connections over 4 listeners |
|---|---|
| Linux 7.0.14 | 8, 4, 10, 10 — spread |
| macOS 26.6 | 0, 0, 0, 32 — all to the last bound |

So a `listener_per_core` server on macOS is skewed by construction, not by load. A harness row
that says `even` there would be claiming something the kernel does not do.

**Measured on 2026-09-20**, and no longer recalled.
`src/conformance/conformance_reuse_port.zig` opens four listeners on one port, connects 32
sockets one at a time, and counts what each listener accepted. It is a count and not a time, so a
busy machine cannot corrupt it, and it runs in the conformance suite on whichever kernel the
build gives it.

| kernel | listeners that took any | fewest | most |
|---|---|---|---|
| macOS 26.6.2 (kqueue) | 1 of 4 | 0 | 32 |
| Linux 7.0.14 (io_uring) | 4 of 4 | 6 | 9 |

macOS gave every one of the 32 connections to the listener bound last. Linux spread them 8, 9, 9,
6 about a mean of 8. So the recalled claim holds on both sides: the API must cover both ways on
day one, and the kqueue backend forces `single_acceptor` to exist.

What the count does not say is how Linux spreads: even over 32 connections of one client is what
a 4-tuple hash gives, and it says nothing about whether the listener chosen is the one whose core
will serve it. That is the question `docs/decisions/0013-when-a-loop-sleeps.md` weighs against
the cost of a wake.

Cost of `single_acceptor`: one message per connection, C17 or C18, against a connection's
lifetime. For a connection that carries 1,000 echo round trips at C14, the handoff is
`C17 / (1,000 × C14)`. With C17 at even 1,000 ns and C14 at 10,000 ns that is 0.01 percent. It
matters only in the accept storm, which is why the harness runs the storm both ways.

Measured on 2026-09-22 (`docs/costs.md`): on `orbstack` C17 is 10,981 ns and C14 is 1,416 ns, so
the handoff is 0.78 percent of such a connection there; on `mac` C18 is 18,125 ns against C14 at
12,791 ns, 0.14 percent. The conclusion stands.

The first reading of C18 by the probe on `mac`, taken on 2026-09-19 while the machine was busy and
therefore not entered in `docs/costs.md`, was about 25,000 ns: 25 times the figure above. At that
cost the handoff is 0.25 percent of such a connection, so the conclusion stands, and the storm is
where the difference will show.

Not in version one: a BPF program attached with `SO_ATTACH_REUSEPORT_CBPF` that picks the socket
by the CPU the packet arrived on. It is the better Linux answer later.

### How cores talk

One API covers both backends: `post(target: LoopId, message: Message)`, where a `Message` is 16
bytes, a 64-bit payload and a 32-bit tag with 32 bits reserved. The receiver sees it as an
`Event` in its normal reap. Anything larger travels as an index or pointer into memory the two
sides agreed on; the loop copies 16 bytes and no more.

- **io_uring**, since 2026-09-25: the same rings as kqueue and epoll, and the same sleep flag.
  The wake is an `IORING_OP_MSG_RING` that carries no message, sent only when the ring's loop said
  it sleeps: a submission entry in the sender's batch, whose completion ends the target's wait.
  Between two loops that are awake a message costs no system call, where it cost two before.
  Until that day the message itself rode the `MSG_RING`: a submission entry in the sender's own
  batch that arrived as a completion in the receiver's ring, with no memory shared, and a
  `DEFER_TASKRUN` receiver had to enter the kernel to see it.
- **kqueue**: kqueue has nothing like it. The answer is one single-producer single-consumer ring
  per ordered pair of loops, in memory both share, plus an `EVFILT_USER` trigger on the
  receiver's kqueue. The sender triggers only when the ring goes from empty to non-empty, so a
  burst costs one `kevent` call (C10) and not one per message.

The rings are the one place in rotor where two threads touch the same memory, on every backend
since 2026-09-25 (`src/core/mailbox.zig`). They use
two atomic indices and no lock, and the two indices sit on separate cache lines, 128 bytes apart
on Apple silicon, so the producer and the consumer never write one line. The memory is
`loops_max × loops_max × ring_bytes`, a named product, handed in at init.

`IORING_SETUP_ATTACH_WQ` shares one pool of kernel worker threads among rings. rotor does not
use it, because version one is built to need those workers rarely. A socket operation that
cannot complete at once waits on the kernel's internal poll and not on a worker. An O_DIRECT
read or write is issued to the device queue from the submitting thread when the filesystem can
do that without blocking; when it cannot, the kernel hands the operation to a worker. This
paragraph is recalled and not read from the kernel source, and milestone 2 verifies it.

Init caps the workers with `IORING_REGISTER_IOWQ_MAX_WORKERS` at a named limit, so a hidden pool
cannot grow without bound. The harness counts the worker threads each workload caused and
reports the count. On a socket workload the count must be zero, and a worker there is a bug to
find. On a file workload it is a cost to report, with the filesystem named beside it, and not a
load to spread across rings.

### When one core is hot

The loop accepts the imbalance. It never migrates anything on its own, because a loop that
moves work is a scheduler, and a scheduler's order is what replay cannot reproduce.

The application has two remedies, and rotor supplies the mechanism for the first:

1. **Explicit migration.** A connection with no operation in flight can move: the owner cancels
   its multishot receive, waits for the final event (`0005-cancellation.md`), and posts the
   descriptor to another loop. rotor asserts that no operation is in flight for a descriptor
   that is posted away. Deciding when to migrate is the application's policy.
2. **A better sharding key.** That is wholly the application's.

The harness measures every workload skewed as well as even, and reports the skewed numbers when
they are bad. They will be: a shared queue with stealing beats shared-nothing under skew, and
the numbers should say by how much.

**Withdrawn on 2026-09-21 by decision 19.** Neither libuv nor libxev spreads TCP load across cores on kqueue,
so there is nothing to compare a skewed row against, and `SO_REUSEPORT` cannot aim the skew at a
chosen loop on either kernel. This claim is argued and not measured, and no document may present it
as measured.

### Memory per core

rotor allocates nothing. `init` takes the loop's memory as a slice and carves its tables from
it; the sizes are comptime functions of the named limits, so the caller can compute them. The
brief's "one arena per core" is then the application's: it maps one region per core and hands
each loop its own.

NUMA placement follows from first touch. `init` must run on the thread that will own the loop,
after that thread is pinned, so the pages it touches first land on its node. `init` records the
calling thread, and that record is what the ownership assertion below compares against. rotor
does not call `mbind`; an application that wants explicit binding does it before `init`.

### Files

The brief says per-core rings with O_DIRECT mean a file needs one owning core. That is stronger
than the kernel requires, and this record proposes less.

What is per ring is the registration: a registered descriptor index belongs to one ring. The
file does not. Each loop can open the same path and register its own descriptor, and the kernel
serves O_DIRECT reads of one file from many rings without any coordination in user space. So:

- **Reads need no owner.** Every loop that reads a file opens it. No message crosses a core.
- **Writes need an order, and the order is the application's invariant.** stompy's journal has
  one writer by design. rotor does not enforce a single writer, because it cannot know which
  writes conflict.

Forcing every read through one owning core would add C17 twice to every read from elsewhere and
make one core the limit for one file's read rate.

### When this design is the wrong one

- A genuinely shared mutable structure that every request touches, such as one in-memory index
  with cross-key transactions. Sharding it costs a message per access, and a lock-based design
  on shared memory wins.
- Few connections, long-lived, of uneven weight: a handful of replication streams, for example.
  Hashing cannot balance five connections over sixteen cores, and stealing can.
- Work that is CPU-bound and not I/O-bound. A loop that computes for a millisecond stalls every
  connection it owns. That work belongs on threads the application starts, with results posted
  back.

The skewed harness runs exist to show the second case in numbers. **Withdrawn on 2026-09-21 by
decision 19:** there are no skewed runs, so the second case is argued and not measured.

### What another thread may do

One thing: `post`. A thread that owns a loop posts through its own loop. A thread that owns no
loop uses a `Remote`, a handle registered at init that counts against `loops_max`: on every
backend it is the producer end of its mailbox rings. On io_uring it also carries a small ring
created for that thread, used only to submit the `MSG_RING` that wakes a target that sleeps.

**`Remote` was built on 2026-09-22**, after `0017-the-layer-that-owns-the-loop.md` found it
described here and absent from `src/`. It is `src/kqueue/kqueue_remote.zig` and
`src/uring/uring_remote.zig`, with what they share in `src/core/remote.zig`, and `src/rotor/rotor.zig`
exports it. What it settled that this paragraph did not say:

- A `Remote` claims a registry slot with a sentinel, `descriptor_remote`, distinct from the empty
  slot. Claiming one twice halts, and a `post` aimed at a remote's slot is answered
  `loop_not_found` by the check every backend already made on a negative descriptor.
- `Remote.post` returns `core.remote.PostError` where a loop's `post` produces an event, because a
  remote has nowhere to deliver an event. The errors a loop's post can also report keep the names
  `event.error_of` gives them: `MailboxFull`, `LoopNotFound`, `SystemResources`, `Unexpected`,
  and `Unanswered`, which a loop can never report. Since 2026-09-25 every backend answers only the
  first two. The other three stay in the set by the owner's ruling of that day, so the surface did
  not change.
- On io_uring, since 2026-09-25, `post` pushes the message into the ring and, when the target
  sleeps, submits a wake from the remote's own ring without waiting for its answer. A wake the
  kernel refuses is dropped, as kqueue and epoll drop theirs: the message is in the ring, and the
  target reads it when it next ticks. Until that day the post submitted the message as a
  `MSG_RING` and waited up to `remote_wait_ns` for the kernel's answer, and a post whose answer
  had not come was `Unanswered`.
- The remote's ring holds `constants.remote_entries` entries, one: it submits one wake at a time
  in an enter of its own, and drops the answers to earlier wakes before the next.
- A `Remote` belongs to one thread. `init` records the thread's identity, the address of the
  thread-local marker `core/tables.zig` keeps for a loop, and `post` and `deinit` halt on any
  other thread.
- A registry claim on kqueue is `.acq_rel`, not `.release`: the claimant of a released id becomes
  the producer of that id's rings, and the claim is the one edge that carries the previous holder's
  last stores to it (`kqueue_mailbox.zig`, the ordering argument). The application decides when an
  id may be claimed again, and a message left in a ring by a previous holder is delivered to the
  next loop that claims the receiving id.
- Whether `MailboxFull` can happen at all is the backend's, and `post_bounded`, exported from
  `src/rotor/rotor.zig`, says. Since 2026-09-25 it is yes on every backend, whose mailbox holds
  `mailbox_messages`. Until then io_uring refused a post only when the kernel was out of memory,
  because `IORING_FEAT_NODROP` kept an overflowing completion in a kernel list.

**The offload built on 2026-09-21 is not `Remote` and does not replace it.**
`0018-a-caller-supplied-thread-pool.md` lets a worker thread hand back the result of one file
operation, through a function pointer and a ring of its own, and nothing else: it carries no message
a caller chose, it is reached through no registered handle, and it counts against nothing in
`loops_max`. A thread that owns no loop ends an operation the loop gave it through the offload,
and posts a message of its own through a `Remote`.

Everything else is the owner's alone. What the loop does when another thread calls it:

- The loop holds a thread-local variable that `init` sets to the loop's address. Every public
  entry point compares it: one thread-local read and one compare, C21, about 1 ns.
- In Debug builds, every entry point asserts. In ReleaseSafe, `tick` and `submit` assert, once
  per batch each (`0008-hot-path-assertions.md`).
- A failed assertion halts the process. It does not return an error: a call from the wrong
  thread is a programmer error, and by the time it is seen the tables may already be torn.

## Alternatives it beat

**A shared loop with a lock, as libuv's pool queue is.** The uncontended lock costs about 15 ns
per operation by the Abseil table, which is comparable to the whole per-entry submission cost
C8, and the contended case has no bound.

**Work stealing inside rotor.** It wins under skew and loses replay. An application that needs
stealing can build it over `post`; rotor cannot remove it once it is inside.

**Shared rings for both backends,** dropping `MSG_RING` for symmetry. It would put shared
memory in the Linux backend for no gain: `MSG_RING` rides in a batch the sender already
submits.

*Evidence against that reason, 2026-09-25. It is not a ruling: the alternative stays rejected
until the owner reopens it.* `bench/calls/count_post.sh` counted the system calls of one message
in `rotor_post`'s ping-pong, on `orbstack`
(`bench/results/calls-crosscore-uring-epoll-orbstack-2026-09-25.md`):

| how the receiving loop waits | io_uring, calls per message | epoll, calls per message |
|---|---|---|
| it blocks | 2.10, all `io_uring_enter` | 3.15: an eventfd write, an `epoll_pwait2`, an eventfd read |
| it polls without blocking | 2.10 | 0.002 |
| it polls for its 50 µs spin budget (decision 13) | 2.10 | 0.002 |

- Between two loops that are awake, `MSG_RING` costs two system calls per message, and epoll's
  shared rings cost none. The sender enters the kernel to submit its post. The receiver enters to
  take it: with `DEFER_TASKRUN`, which `src/uring` sets, a message becomes a completion only when
  the receiving ring's own thread enters the kernel, as the C17 probe's notes say.
- In time, on `github`, a round trip between two loops that poll took 2.6 to 4.2 µs on io_uring
  and 1.6 to 2.4 µs on epoll, on the same runners (decision 13, its epoll section). C19, the
  shared ring alone, is 36 ns there.
- When the receiver sleeps, io_uring is the cheaper, at 2.1 calls against 3.15.

So "no gain" holds for a post to a loop that must be woken, and does not hold for a post to a
loop that is awake, which decision 13's spin budget makes common for a caller that asks for it.
"Rides in a batch the sender already submits" holds for a loop whose tick has other work to enter
for; in the measured ping-pong each message paid for its entries alone. What the evidence points
to is a post that goes through a shared ring when the target is awake, as on kqueue and epoll,
with `MSG_RING` left to wake a target that sleeps.

*Adopted on 2026-09-25.* The owner ruled that loops talk across threads through shared memory
(the amendment at the top of this record). What was built:

- A post on io_uring goes through `core.remote.post`, which every backend now calls, into the
  mailbox ring. A target that said it sleeps is noted and woken once per flush, with an
  `IORING_OP_MSG_RING` that carries no message and whose completion both reaps drop
  (`uring/constants.zig`, `user_data_wake`). A wake that finds no room in the submission ring
  stays noted, and the tick does not block while one is.
- The io_uring tick takes the sleep handshake of `core.inbox`: it drains the mailboxes, says it
  sleeps and reads them once more before it blocks, and says it is awake again before an error
  can leave the tick.
- `uring.Registry` is `core.mailbox.Registry`. A `Remote` on io_uring pushes into the ring and
  keeps its one-entry ring for wakes alone.

Counted afterwards, on `orbstack`, with `bench/calls/count_post.sh`:

| how the receiving loop waits | io_uring before, calls per message | io_uring after | epoll |
|---|---|---|---|
| it blocks | 2.10 | 2.10 | 3.15 |
| it polls without blocking | 2.10 | 0.002 | 0.002 |
| it polls for its 50 µs spin budget | 2.10 | 0.002 | 0.002 |

Between loops that are awake a message now costs io_uring what it costs epoll. Waking a loop that
sleeps still costs 2.1 calls, one fewer than epoll.

The time, on `github`: a round trip of `rotor_post` in µs, the median and the range of three
rounds, with no gap between messages. "Before" is the last run on a runner of the same processor,
from `dcc95fb` or `57dbc22`; "after" is `1ccbd4e`, with epoll on the same runner
(`bench/results/crosscore-uring-shared-rings-github-2026-09-25.md`):

| processor | receiving loop | io_uring before | io_uring after | epoll, same runner as after |
|---|---|---|---|---|
| Intel Xeon Platinum 8573C | polls | 2.5 (2.5 to 2.5) | 1.7 (1.7 to 1.7) | 2.3 (2.3 to 2.4) |
| Intel Xeon Platinum 8573C | blocks | 15.9 (15.3 to 23.0) | 18.2 (17.9 to 26.5) | 18.4 (14.8 to 19.7) |
| AMD EPYC 7763 | polls | 4.2 (4.2 to 4.2) | 1.8 (1.8 to 1.8) | 2.4 (2.4 to 2.4) |
| AMD EPYC 7763 | blocks | 33.0 (23.2 to 33.3) | 25.5 (23.2 to 33.3) | 28.4 (24.8 to 34.8) |
| AMD EPYC 9V74 | polls | 3.9 (3.9 to 4.0) | 1.5 (1.5 to 1.5) | 2.0 (2.0 to 2.0) |
| AMD EPYC 9V74 | blocks | 17.5 (16.9 to 21.6) | 20.7 (19.1 to 20.7) | 21.9 (19.5 to 21.9) |

- Between two loops that poll, a round trip on io_uring fell from 2.5 to 4.2 µs to 1.5 to 1.8 µs,
  and is now shorter than epoll's on the same runner, by 0.5 to 0.6 µs.
- To a loop that blocks, the round trip rose on two processors and fell on the third, by 2.3 to
  7.5 µs, between runners of one processor, and the rounds of one runner spread by up to 10 µs.
  The wake still costs 2.1 calls, so this change is not measured to have moved that round trip.

## How it is checked

- The harness runs every workload on 1 core and measures C17, C18 and C19 on their own. **Amended on
  2026-09-21 by decision 19:** the N-core and skewed rows are withdrawn; C17 to C19 are unaffected,
  because `bench/crosscore/` measures them without an echo row.
- The harness asserts that the process's own threads equal the loop count, and it counts the
  kernel's io_uring worker threads per workload: zero on socket workloads, reported on file
  workloads.
- A simulator test posts between simulated loops under one seed and replays it byte for byte.
- Mutation: removing the ownership compare in `tick` must be `CAUGHT` by a test that calls
  `tick` from a second thread and expects the halt. **Met on 2026-09-22 on every backend:**
  kqueue's scenario runs in `zig build halt-check`, and uring's and epoll's run in the Linux gate,
  because on a Mac a Linux system call runs some other call. On kqueue and epoll the offload's
  `drain` had to stop checking the owner, because its check halted the same tick.
- The same mutation for every other entry point that checks the owner. `submit`, `tick` and a
  remote's `post` had a scenario; `cancel`, `cancel_all`, `deinit`, `register_buffers`,
  `register_descriptors`, `provide_buffers`, `give_back_buffer` and a remote's `deinit` had none,
  so deleting any of their checks went unnoticed. **Met on 2026-09-23 on every backend.** Each
  scenario is in `tools/halt/`, in the Linux gate's files where the path after the check makes a
  Linux system call.

## Open questions for review

1. Is "reads need no owner" acceptable, or does stompy want the stricter rule as a guard?
2. Should `Remote` be in version one, or is "only loops post" enough for the first consumers?
