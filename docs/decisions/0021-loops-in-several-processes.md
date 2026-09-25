# 21. Loops in several processes

Status: **accepted** by the owner on 2026-09-25, the day it was proposed. "Ruling" below says what
the owner decided, and the design after it follows the ruling. Nothing here is built yet. Decision 2
is amended the same day to put posts between processes in version one.

## Context

On 2026-09-25 the owner ruled that loops talk through shared memory, and io_uring's posts moved onto
the mailbox rings the same day (decision 4, its amendment). The owner then said: "We also need to
figure out how to shard memory between rotor processes", and asked for it after the io_uring change.

What exists today, and what of it can cross a process boundary:

- `core.mailbox.Mailbox` is one single-producer single-consumer ring. It is an `extern struct` of two
  atomic `u32` indices and 32 messages of 16 bytes: 4,352 bytes and no pointer. Its correctness
  argument is about loads and stores to shared memory, and a mapping two processes share is shared
  memory in the same sense. So a ring can live in such a mapping as it is.
- `core.mailbox.Entry`, one per loop, holds the loop's `sleeping` flag and `queue`, the descriptor
  that wakes it: its kqueue, its eventfd, or its io_uring ring. The flag can cross. The descriptor
  can cross only if the other process holds the same descriptor at the same number.
- `core.mailbox.Registry` is two slices, a pointer and a length each, into the memory the
  application handed it. Pointers into a mapping differ from process to process, so each process
  needs its own `Registry` value over the same bytes.
- A loop's own memory, its slot table, timers and buffers, holds pointers into that process's
  memory and names that process's kernel objects. It cannot be shared, and this record does not
  share it.
- `kqueue(2)` on macOS 26.6.2 says "The queue is not inherited by a child created with fork(2)", and
  `EVFILT_USER` is triggered through a kqueue descriptor. So on kqueue no other process can use the
  wake a loop has today.

## Ruling, 2026-09-25

The owner ruled on the four questions the proposal asked:

1. **Posts between processes are in version one.** Decision 2 is amended.
2. **The unit is the loop.** In the owner's words: "each event loop owns 1 single CPU core, and a
   dedicated and distinct memory region. Mechanical sympathy. Communication between event loops
   happens through shared memory". A process runs one loop or several. The proposal's shards, ranges
   of loop ids owned by one process, had no job left under this rule, and the design below has none.
3. **No descriptor moves between processes after they start.** The owner asked why descriptors
   came up at all, and was not sure rotor should move them. The process that creates the registry
   creates every loop's wake, and the other processes inherit them. rotor does not use `SCM_RIGHTS`.
4. **A process that dies is replaced.** A surviving process releases the dead process's loops, and a
   new process takes their ids over.

The owner also asked for a better alternative to shared memory, if there is one. None is known on
one machine: a socket per message costs 46 to 120 times the ring (below), and `MSG_RING` cost two
system calls per message between threads (decision 4).

## What it costs

Every number is a cell of `docs/costs.md` unless the text says it is recalled.

- **A message to a loop that is awake.** C19, a message by a shared ring when the receiver is
  awake: 97.0 ns on `mac`, 98.0 on `orbstack`, 36.0 on `github`. The ring does not know which
  process its two sides run in. The cache lines move between cores the same way, so the prior for a
  message between processes is C19. No cell measures it.
- **A wake of a loop that sleeps, in one process today.** C18, a ring plus `EVFILT_USER`: 18,125 ns
  on `mac`. C17, `IORING_OP_MSG_RING`: 10,981 ns on `orbstack` and 8,724 on `github`. Both are
  dominated by the sleeping thread's wake. The wake below is one `write(2)` on the sender's side,
  of which C6 (`getppid`, 112 ns on `mac`, 124 on `github`) is the floor, so the prior is that it
  costs close to C18 and C17.
- **A socket per message, which this record argues against.** C16, `send` plus `recv` of 4 KiB on a
  connected loopback socket: 4,417 ns on `mac` and 4,320 on `github`. Against C19 that is
  4,417 / 97.0 = 46 times on `mac` and 4,320 / 36.0 = 120 times on `github`, before the loop's own
  work on each side. C16 moves 4 KiB, where a message is 16 bytes, so for a message it is an upper
  bound on this ratio. No cell measures a 16-byte `send` and `recv`.

## The design

### 1. A group, and the region it shares

A group is the processes whose loops post to each other. One process creates the group: the
creator. The others are its members, and each descends from the creator, as point 3 says.

The creator maps one region with `MAP_SHARED`, from `memfd_create` or `shm_open`, or anonymous
before it forks, and hands it to rotor. rotor maps nothing, as today: the caller hands it every byte
it uses (CLAUDE.md, rule 1). The region holds, in order:

1. A header: a fixed magic number, the layout version and the loop count. Every field is an
   integer.
2. The entries, one per loop, as today.
3. The rings, one per ordered pair of loops, as today.

Every place in the region is an offset computed from the loop count. Nothing in it is a pointer.

- The creator's `init` writes the header, empties every ring and creates every loop's wake.
- A member's `attach` reads the header, checks the magic number, the version and the sizes against
  what its build of rotor computes, and builds its own `Registry` value over the same bytes. A header
  that does not match is an error returned to the caller, since another program wrote it.

A registry of one process keeps working as it does today, and creates no wake of this kind.

### 2. A loop owns one core and its own region

Each loop runs on one thread pinned to one core, and its memory is its own region, which the caller
hands it at `init` as today (decision 4, "Memory per core"). No loop's region is shared. The only
memory loops share is the group's region of point 1: the entries and the rings. Which process runs
which loops is the application's choice, and rotor does not record it.

### 3. The wake is created by the creator and inherited

A loop blocks in `kevent`, `epoll_wait` or `io_uring_enter`, and only one of its own kernel objects
can end that wait. So a sender in another process must hold an object the target waits on. Under
the ruling, the creator makes one for every loop before any member starts:

- **kqueue**: a pipe per loop. The loop registers the read end with `EVFILT_READ` at `init`. A
  sender writes one byte to the write end, which is non-blocking. Every process of the group
  inherits the read end too, so a pipe has a reader while any of them lives; the write end also has
  `F_SETNOSIGPIPE` set (`fcntl(2)`), so a write raises no signal even when none does. A full pipe
  means a wake is already pending, and the sender drops its own, as a wake is dropped today. The
  loop drains the pipe when it wakes.
- **epoll**: an eventfd per loop, which the loop uses as its wake in place of the one it creates
  today.
- **io_uring**: an eventfd per loop, with a read of it kept in the loop's ring. A sender writes to
  it. This replaces `MSG_RING` as the wake in a group, since a sender would otherwise need the
  target's ring descriptor and a ring of its own to submit on.

A member gets them by inheritance: the creator forks after it created them, or spawns the member
with them kept open at the same numbers. A descriptor inherited this way has the same number in
every process of the group, so an entry holds that number for every sender, as `queue` holds a
number today. Nothing moves after start.

In a group, every wake goes through these objects, from the loop's own process too. A sender then
never needs to know which process a target runs in.

`Entry` gains the pipe's read end, which a kqueue loop registers, inside its 128 bytes: the size of
the entry does not change.

### 4. What a message carries between processes

A message is 16 bytes, and rotor copies them and interprets none (decision 4). In one process an
application often puts a pointer in the payload. Between processes a pointer is wrong, because each
process maps memory at its own addresses. An application passes an offset into a region both
processes map. rotor needs nothing for this.

A message cannot carry the application's own descriptors either. In one process, the
`single_acceptor` shape posts an accepted socket's number to another loop (decision 4). Across
processes that number means nothing, and rotor does not move descriptors. A group accepts in each
process instead: on Linux each process binds its own listener with `SO_REUSEPORT`; on macOS the
processes accept on one listening socket they inherited from the creator.

### 5. A process that dies

The rings hold no lock, so a process that dies leaves nothing locked. What it leaves:

- Its loops' entries still publish their wakes, and senders keep pushing to its loops until their
  rings are full, then get `MailboxFull`.
- A write to the wake of one of its loops still succeeds, because the other processes of the group
  hold the pipe's read end or the eventfd, and it wakes nobody.

The application learns of the death, from a `pidfd` on Linux, an `EVFILT_PROC` `NOTE_EXIT` on
macOS, or its own supervisor, which is the creator or runs in it. A surviving process then calls
`Registry.release(id)` for each loop the dead process ran, which clears that entry on its behalf.
Posts to it are then answered `LoopNotFound`.

A new process started by the creator may then run loops with those ids. It inherits the same wakes,
because the creator still holds them. No ring needs a reset:

- A ring toward the loop had one consumer, which is dead. The new loop becomes its consumer and
  continues from `head`, as decision 4 already says for an id claimed after another loop released
  it: it is delivered what the dead loop did not read.
- A ring from the loop had one producer, which is dead. The new loop becomes its producer and
  continues from `tail`. A slot the dead process wrote without storing `tail` is not visible, and
  the new producer writes over it.

The claim is the same `.acq_rel` swap that orders an id's handover today (`mailbox.zig`). That the
dead process's last stores are visible to the claimant rests on process exit being a full barrier
for the dying process's stores. This is recalled and not read from either kernel's source.

`release` on a loop whose process is only stopped would leave two producers on one ring. rotor
cannot tell a stopped process from a dead one, so the caller must know it is dead, from an exit
notification.

### 6. What sharing a registry trusts

Every process that maps the region can write any byte of it, as every thread of a process can today.
A ring index out of range still halts the loop that reads it. So processes that share a registry
trust each other as threads of one process do. This is not a security boundary, and processes of
different trust must not share a registry.

### 7. Determinism

Unchanged (CLAUDE.md, rule 2). What a loop reads from a ring is what the other side posted, whether
that side is a thread or a process.

## Alternatives it beat

1. **A Unix socket or a pipe per message.** One system call on each side and a copy, 46 to 120
   times the ring's cost by C16 and C19 (above).
2. **`IORING_OP_MSG_RING` between processes.** Two system calls per message, counted between
   threads on 2026-09-25 (decision 4), and it exists on io_uring only.
3. **Moving wake descriptors with `SCM_RIGHTS`**, the first proposal. It needs a Unix socket and an
   exchange between every pair of processes, and each process a table of its own. The owner ruled
   against moving descriptors.
4. **Opening each loop's wake by name**, a FIFO or a Unix socket at a path. It needs no common
   creator, and costs one filesystem name per loop, created and cleaned up. Not chosen.
5. **Loops that never sleep**, so that no wake exists. It fits a loop that owns its core, and spends
   the whole core even when the loop is idle; on kqueue every poll is a system call (C10, 294 ns on
   `mac`). Not chosen. A caller may still come close with decision 13's spin budget.
6. **The region mapped at one address in every process, so that pointers work.** It fails when that
   address is taken in one of the processes, and address space layout randomisation makes that a
   matter of chance. Offsets work at any address.
7. **Sharing the loops' own memory too, so that a process can run another's loop after it dies.** A
   loop's tables hold pointers into its process and name its kernel objects, which die with it.
   What survives a death is the rings, and point 5 keeps them.
8. **A futex on the shared memory as the wake.** A loop blocks in `kevent`, `epoll_wait` or
   `io_uring_enter`, and a futex wakes a thread blocked on the futex. io_uring has a futex wait
   operation, `IORING_OP_FUTEX_WAIT`, from Linux 6.7, recalled and not read; decision 2's floor is
   6.1.

## How it is checked

1. The conformance suite gains scenarios that post between two processes, on every backend: a
   message to a loop that is awake, a message and a wake to a loop that sleeps, a burst that fills a
   ring, a header that does not match, and a process that dies, has its loops released, and is
   replaced. A scenario starts its member by forking after the registry exists.
2. The lost-wake test of `kqueue/kqueue_mailbox_test.zig` runs with its two sides in two processes.
   ThreadSanitizer cannot see a race between processes, so the race gate adds nothing here.
3. `docs/costs.md` gains two rows, measured on `mac`, `orbstack` and `github`: one message between
   processes when the receiver is awake, and one wake of a loop in another process, post to reap.
   On io_uring the eventfd wake is measured against C17, since it replaces `MSG_RING` in a group.
4. `bench/crosscore/rotor_post.zig` gains a mode that runs its two loops in two processes.
5. Mutations: the wake never sent; the header check removed; `release` leaving the entry set; the
   new loop of a released id resetting a ring it inherited; a kqueue loop that never drains its
   wake pipe.

## Open questions

1. **Where the rings a loop reads live.** The rings toward one loop are adjacent in the region
   (`receiver * loops + sender`). Under the owner's rule of a region per loop, each loop's block of
   inbound rings could sit on that loop's NUMA node, so its polls read local memory. It matters only
   on a machine with more than one socket, and no named machine has one. Proposed: build the region
   as above, and keep each loop's block of rings page-aligned so an application can place it.
2. **Members that `exec`.** rotor creates every descriptor with `FD_CLOEXEC` set. A member forked
   without `exec` inherits the wakes regardless. A member started with `exec` needs them kept open,
   which the application does in its spawn. Proposed: rotor creates the group's wakes without
   `FD_CLOEXEC`, since inheritance is what they are for, and says so where `init` is documented.
