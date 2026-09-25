# 21. Loops in several processes

Status: **proposed** on 2026-09-25, at the owner's request. Nothing here is built. A proposed record
is not a licence to build what it describes (CLAUDE.md), and cross-process posts are outside
version one's scope table (decision 2), so building them needs the owner's ruling on both.

## Context

On 2026-09-25 the owner ruled that loops talk through shared memory, and io_uring's posts moved onto
the mailbox rings the same day (decision 4, its amendment). The owner then said: "We also need to
figure out how to shard memory between rotor processes". Asked what that covers, the owner chose
both of these, after the io_uring change:

- **Shards.** Each process owns a part of the loops and the memory behind them.
- **Messages between processes.** A loop in one process posts to a loop in another through shared
  memory, as loops in one process do today.

This record takes "shard" to mean what the first point says. Its open questions ask whether that is
what the owner meant.

What exists today, and what of it can cross a process boundary:

- `core.mailbox.Mailbox` is one single-producer single-consumer ring. It is an `extern struct` of two
  atomic `u32` indices and 32 messages of 16 bytes: 4,352 bytes and no pointer. Its correctness
  argument is about loads and stores to shared memory, and a mapping two processes share is shared
  memory in the same sense. So a ring can live in such a mapping as it is.
- `core.mailbox.Entry`, one per loop, holds the loop's `sleeping` flag and `queue`, the descriptor
  that wakes it: its kqueue, its eventfd, or its io_uring ring. The flag can cross. The descriptor
  cannot: a descriptor number means something only in the process that opened it.
- `core.mailbox.Registry` is two slices, a pointer and a length each, into the memory the
  application handed it. Pointers into a mapping differ from process to process, so each process
  needs its own `Registry` value over the same bytes.
- A loop's own memory, its slot table, timers and buffers, holds pointers into that process's
  memory and names that process's kernel objects. It cannot be shared, and this record does not
  share it.
- `kqueue(2)` on macOS 26.6.2 says "The queue is not inherited by a child created with fork(2)", and
  `EVFILT_USER` is triggered through a kqueue descriptor. So on kqueue no other process can use the
  wake a loop has today.

## What it costs

Every number is a cell of `docs/costs.md` unless the text says it is recalled.

- **A message to a loop that is awake.** C19, a message by a shared ring when the receiver is
  awake: 97.0 ns on `mac`, 98.0 on `orbstack`, 36.0 on `github`. The ring does not know which
  process its two sides run in. The cache lines move between cores the same way, so the prior for a
  message between processes is C19. No cell measures it.
- **A wake of a loop that sleeps, in one process today.** C18, a ring plus `EVFILT_USER`: 18,125 ns
  on `mac`. C17, `IORING_OP_MSG_RING`: 10,981 ns on `orbstack` and 8,724 on `github`. Both are
  dominated by the sleeping thread's wake. A wake from another process adds one system call on the
  sender's side, a `write(2)` to a descriptor, of which C6 (`getppid`, 112 ns on `mac`, 124 on
  `github`) is the floor. The prior is that it costs close to C18 and C17.
- **The alternative this record argues against, a socket per message.** C16, `send` plus `recv` of
  4 KiB on a connected loopback socket: 4,417 ns on `mac` and 4,320 on `github`. Against C19 that
  is 4,417 / 97.0 = 46 times on `mac` and 4,320 / 36.0 = 120 times on `github`, before the loop's
  own work on each side. C16 moves 4 KiB, where a message is 16 bytes, so for a message it is an
  upper bound on this ratio. No cell measures a 16-byte `send` and `recv`.

## The proposal

### 1. The shared region is the registry, with a header and no pointers

The application maps one region that every process of the group maps too, and hands it to rotor. It
maps it with `memfd_create` or `shm_open` and `mmap` with `MAP_SHARED`, or with an anonymous
`MAP_SHARED` mapping made before it forks. rotor maps nothing, as today: the caller hands it every
byte it uses (CLAUDE.md, rule 1).

The region holds, in order:

1. A header: a fixed magic number, the layout version, the loop count, the shard count, and the
   shard table below. Every field is an integer.
2. The entries, one per loop, as today.
3. The rings, one per ordered pair of loops, as today.

Every place in the region is an offset computed from the loop count. Nothing in it is a pointer.

- `Registry.init(memory, loop_count, shards)` writes the header and empties every ring. One process
  calls it, before any other process attaches.
- `Registry.attach(memory, shard)` reads the header, checks the magic number, the version and the
  sizes against what this build of rotor computes, and builds this process's `Registry` value over
  the same bytes. A header that does not match is an error returned to the caller, since another
  program wrote it.

The registry of one process keeps working as it does. It is a group of one shard.

### 2. A shard is a range of loop ids, owned by one process

The shard table maps each shard to a range of loop ids, `first` and `count`, fixed at `init`. A
process attaches as one shard. Its loops and its `Remote`s claim ids in that range only, and a claim
outside it halts, because it is a programmer error. So the id space, and the rings that belong to
each id, are split between processes, and each process owns the memory of its own loops.

`Loop.Options` does not change: a loop already names its registry and its id, and the registry
value knows its shard.

### 3. The wake between processes is a descriptor both processes hold

A sender first finds the target's shard from its id. When the target is in its own shard, nothing
changes. When it is in another shard, the sender wakes it through a descriptor of its own process
that reaches the target's wait:

- **kqueue**: a pipe per loop, created at `init` when the registry has more than one shard. The loop
  registers the read end with `EVFILT_READ`. A sender writes one byte to the write end, which is
  non-blocking and has `F_SETNOSIGPIPE` set (`fcntl(2)`), so a write to a loop whose process has
  died returns an error and raises no signal. A full pipe means a wake is already pending, and the
  sender drops its own, as a wake is dropped today. The loop drains the pipe when it wakes.
- **epoll**: the loop's eventfd, which is already its wake. Another process writes to it.
- **io_uring**: an eventfd per loop, created at `init` when the registry has more than one shard,
  with a read of it kept in the ring. Another process writes to it. This takes the place of
  `MSG_RING` for a sender in another process, because a sender would otherwise need the target's
  ring descriptor and a ring of its own to submit on.

Each process keeps a table of its own: for each loop id outside its shard, the descriptor it wakes
that loop with, or none. It is process memory, not shared memory.

The descriptors must reach the other processes. rotor does not move them: that takes a Unix socket
and `SCM_RIGHTS`, or a `fork` after they exist, and both are the application's, as the mapping is.
rotor exposes the two ends:

- `Loop.wake_descriptor()` names the descriptor another process needs to wake this loop.
- `Registry.set_peer_wake(target, descriptor)` records, in this process's table, the descriptor a
  sender here uses for `target`.

A post to a loop in another shard for which this process has no descriptor still pushes the message.
The target reads it the next time it ticks. Only the wake is missing.

### 4. What a message carries between processes

A message is 16 bytes, and rotor copies them and interprets none (decision 4). In one process an
application often puts a pointer in the payload. Between processes a pointer is wrong, because each
process maps memory at its own addresses. An application passes an offset into a region both
processes map. rotor needs nothing for this, and this record says it so that nobody builds a
pointer-translating layer into rotor.

### 5. A process that dies

The rings hold no lock, so a process that dies leaves nothing locked. What it leaves:

- Its entries still publish descriptors, and senders keep pushing to its loops until their rings
  are full, then get `MailboxFull`.
- On kqueue, writes to its wake pipes fail and raise no signal, as point 3 says. On Linux an
  eventfd lasts while any process holds it, so a write to a dead loop's eventfd succeeds and wakes
  nobody.

The application learns of the death, from a `pidfd` on Linux, an `EVFILT_PROC` `NOTE_EXIT` on
macOS, or its own supervisor. A surviving process then calls `Registry.release_shard(shard)`, which
clears that shard's entries on its behalf. Posts to it are then answered `LoopNotFound`.

A new process may attach as the released shard and claim its ids. No ring needs a reset:

- A ring toward the shard had one consumer, which is dead. The new loop becomes its consumer and
  continues from `head`, as decision 4 already says for an id claimed after another loop released
  it: it is delivered what the dead loop did not read.
- A ring from the shard had one producer, which is dead. The new loop becomes its producer and
  continues from `tail`. A slot the dead process wrote without storing `tail` is not visible, and
  the new producer writes over it.

The claim is the same `.acq_rel` swap that orders an id's handover today (`mailbox.zig`). That the
dead process's last stores are visible to the claimant rests on process exit being a full barrier
for the dying process's stores. This is recalled and not read from either kernel's source.

`release_shard` on a process that is only stopped would leave two producers on one ring. rotor
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
   times the ring's cost by C16 and C19 (above). This is the cost the owner's ruling on shared
   memory removed between threads.
2. **`IORING_OP_MSG_RING` between processes.** Two system calls per message, counted between
   threads on 2026-09-25 (decision 4), and it exists on io_uring only.
3. **The region mapped at one address in every process, so that pointers work.** It fails when that
   address is taken in one of the processes, and address space layout randomisation makes that a
   matter of chance. Linux has `MAP_FIXED_NOREPLACE` to refuse instead of overwrite, and macOS has
   no flag of that name; this is recalled. Offsets work at any address.
4. **Sharing the loops' own memory too, so that a process can run another's loop after it dies.** A
   loop's tables hold pointers into its process and name its kernel objects, its kqueue or ring and
   its sockets, which die with it. What survives a death is the rings, and point 5 keeps them.
5. **A futex on the shared memory as the wake.** A loop blocks in `kevent`, `epoll_wait` or
   `io_uring_enter`, and a futex wakes a thread blocked on the futex. io_uring has a futex wait
   operation, `IORING_OP_FUTEX_WAIT`, from Linux 6.7, recalled and not read; decision 2's floor is
   6.1.
6. **One process with threads, as today.** It stays the default, and a registry of one shard is it.
   Processes give what threads cannot: a crash ends one shard, each shard has its own address space,
   one shard can restart alone, and shards can run with different privileges. They cost descriptors
   to move and a supervisor to watch them.

## How it is checked, if it is built

1. The conformance suite gains scenarios that post between two processes, on every backend: a
   message to a loop that is awake, a message and a wake to a loop that sleeps, a burst that fills a
   ring, a post with no peer descriptor, and a process that dies, has its shard released, and is
   replaced. A scenario starts its second process by running its own executable again with an
   argument.
2. The lost-wake test of `kqueue/kqueue_mailbox_test.zig` runs with its two sides in two processes.
   ThreadSanitizer cannot see a race between processes, so the race gate adds nothing here.
3. `docs/costs.md` gains two rows, measured on `mac`, `orbstack` and `github`: one message between
   processes when the receiver is awake, and one wake of a loop in another process, post to reap.
   Point 3's choice of a pipe on kqueue is checked against a socket pair then.
4. `bench/crosscore/rotor_post.zig` gains a mode that runs its two loops in two processes.
5. Mutations: the wake to another shard never sent; the shard check on a claim removed; the header
   check removed; `release_shard` clearing a live shard's entries; the new owner of a released shard
   resetting a ring it inherited.

## Open questions for review

1. **Scope.** Decision 2's table has "post one message into another loop" and says nothing of
   processes. Proposed: an amendment of decision 2 adds cross-process posts to version one, if the
   owner rules to build this.
2. **What "shard memory" means.** Proposed: each process owns a range of loop ids and its loops'
   memory, and shares only the registry. If the owner also meant one large region split among
   processes, such as a buffer pool, that region is the application's, addressed by offsets, and
   rotor needs nothing more for it.
3. **Who moves the descriptors.** Proposed: the application, with `SCM_RIGHTS` or `fork`. rotor only
   names them. rotor could open a Unix socket of its own for this, and decision 2 leaves Unix
   sockets out.
4. **A process that dies.** Proposed: a survivor releases its shard and a new process takes it over,
   as point 5 says. The simpler rule is that the whole group restarts, which gives up the main
   reason to use processes.
5. **The public surface.** `Registry.attach`, `Registry.release_shard`, `Registry.set_peer_wake` and
   `Loop.wake_descriptor` are new, and `Registry.init` takes a shard table. `Loop.Options`,
   `Loop.init` and `Loop.memory_bytes` do not change. cocuyo passes no registry, and is told before
   anything lands.
