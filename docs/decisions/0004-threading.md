# 4. Threading model: one shared-nothing loop per core

Status: accepted for implementation on 2026-09-19. The owner gave the instruction to implement and
did not rule on the open questions below, so the implementation follows the proposed answer to
each until a ruling changes it. This record argues with the owner's position in two places: file
ownership and SO_REUSEPORT on macOS.

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
them. FreeBSD added `SO_REUSEPORT_LB` for that; macOS has no equivalent. This is recalled and
milestone 3 verifies it with a test that counts accepts per socket. So the API must cover both
ways on day one, and the kqueue backend forces the second way to exist.

Cost of `single_acceptor`: one message per connection, C17 or C18, against a connection's
lifetime. For a connection that carries 1,000 echo round trips at C14, the handoff is
`C17 / (1,000 × C14)`. With C17 at even 1,000 ns and C14 at 10,000 ns that is 0.01 percent. It
matters only in the accept storm, which is why the harness runs the storm both ways.

Not in version one: a BPF program attached with `SO_ATTACH_REUSEPORT_CBPF` that picks the socket
by the CPU the packet arrived on. It is the better Linux answer later.

### How cores talk

One API covers both backends: `post(target: LoopId, message: Message)`, where a `Message` is 16
bytes, a 64-bit payload and a 32-bit tag with 32 bits reserved. The receiver sees it as an
`Event` in its normal reap. Anything larger travels as an index or pointer into memory the two
sides agreed on; the loop copies 16 bytes and no more.

- **io_uring**: `IORING_OP_MSG_RING`. The post is a submission entry in the sender's own batch,
  so it adds `C8` to the sender's tick and no syscall. It arrives as a completion in the
  receiver's ring and wakes the receiver if it is waiting. No memory is shared.
- **kqueue**: kqueue has nothing like it. The answer is one single-producer single-consumer ring
  per ordered pair of loops, in memory both share, plus an `EVFILT_USER` trigger on the
  receiver's kqueue. The sender triggers only when the ring goes from empty to non-empty, so a
  burst costs one `kevent` call (C10) and not one per message.

The kqueue rings are the one place in rotor where two threads touch the same memory. They use
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

The skewed harness runs exist to show the second case in numbers.

### What another thread may do

One thing: `post`. A thread that owns a loop posts through its own loop. A thread that owns no
loop uses a `Remote`, a handle registered at init that counts against `loops_max`: on kqueue it
is the producer end of a ring pair, and on io_uring it is a small ring created for that thread,
used only to submit `MSG_RING`.

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

## How it is checked

- The harness runs every workload on 1 core and on N cores, even and skewed, and measures C17,
  C18 and C19 on their own.
- The harness asserts that the process's own threads equal the loop count, and it counts the
  kernel's io_uring worker threads per workload: zero on socket workloads, reported on file
  workloads.
- A simulator test posts between simulated loops under one seed and replays it byte for byte.
- Mutation: removing the ownership compare in `tick` must be `CAUGHT` by a test that calls
  `tick` from a second thread and expects the halt.

## Open questions for review

1. Is "reads need no owner" acceptable, or does stompy want the stricter rule as a guard?
2. Should `Remote` be in version one, or is "only loops post" enough for the first consumers?
