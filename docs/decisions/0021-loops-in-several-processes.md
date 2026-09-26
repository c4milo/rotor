# 21. Loops in several processes

Status: **accepted** by the owner on 2026-09-25, the day it was proposed, and **built** the same
day. "Ruling" below says what the owner decided, and the design after it follows the ruling.
"Built" at the end says what was built, where it differs from the design, and how it is checked.
Decision 2 is amended the same day to put posts between processes in version one.

## Context

On 2026-09-25 the owner ruled that loops talk through shared memory, and io_uring's posts moved onto
the mailbox rings the same day (decision 4, its amendment). The owner then said: "We also need to
figure out how to shard memory between rotor processes", and asked for it after the io_uring change.

What exists today, and what of it can cross a process boundary:

- `core.mailbox.Mailbox` is one single-producer single-consumer ring. It is an `extern struct` of two
  atomic `u32` indices, each on its own 128-byte line, and 256 messages of 16 bytes: 4,352 bytes
  and no pointer. Its correctness
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
- **io_uring**: an eventfd per loop, with a poll of it kept in the loop's ring. A sender writes to
  it with `write(2)`. This replaces `MSG_RING` as the wake in a group, since a sender would
  otherwise need the target's ring descriptor and a ring of its own to submit on.

A member gets them by inheritance: the creator forks after it created them, or spawns the member
with them kept open at the same numbers. A descriptor inherited this way has the same number in
every process of the group, so an entry holds that number for every sender, as `queue` holds a
number today. Nothing moves after start.

In a group, every wake goes through these objects, from the loop's own process too. A sender then
never needs to know which process a target runs in.

The wakes sit in a table of their own after the header, one `Wake` of two descriptors per loop, so
`Entry` does not change.

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

## Built, 2026-09-25

What was built, module by module:

- `core`: `mailbox_registry.zig`, split from `mailbox.zig`, holds the header, the wake table,
  `init_group`, `attach` and `release`. `Registry.memory_bytes` grows by the 128-byte header and the
  wake table in whole 128-byte lines: 256 bytes more for up to 16 loops.
- `kqueue`: `kqueue_group.zig` makes the pipes. A loop of a group registers its pipe's read end with
  `EVFILT_READ` at `init` and publishes the write end; the reap reads what was written; a loop's
  flush and a `Remote` write one byte.
- `linux_shared`: `linux_shared_group.zig` makes the eventfds, non-blocking and without
  close-on-exec.
- `epoll`: a loop of a group waits on the group's eventfd in place of one of its own
  (`Queue.init_group`), and leaves it open at `deinit`. Senders write to it as they did.
- `uring`: `uring_group.zig`. A loop of a group keeps an `IORING_OP_POLL_ADD` of its eventfd in its
  ring, reads the count when it completes, and queues it again at the next flush; a tick does not
  block while it is not in the ring. A sender writes with `write(2)`.
- The public module: `Registry.init_group`, `attach`, `release` and `close_wakes`, with
  `Registry.GroupError` and `Registry.AttachError`. `Loop.Options` did not change.

Where it differs from the design: the first build on io_uring kept a read of the eventfd in the
loop's ring and queued a sender's write in the sender's ring. The first conformance scenario below
failed on io_uring in Docker: the child submitted its write, exited at once, and the parent slept
out its whole wait. Under `strace` the same scenario passed. The explanation that fits is that the
kernel gave the write to a worker thread and the child's exit cancelled it; it is not measured. A
`write(2)` has happened when it returns, and a poll takes no worker, so the build uses those.

How it is checked, point by point of "How it is checked":

1. `src/conformance/conformance_group.zig` runs four scenarios on every backend, each with a child
   made by `fork` after the registry and before the parent's loop, so the child holds none of that
   loop's own descriptors: a post that wakes a loop that sleeps, after which the loop sleeps again;
   a message to a loop that sleeps in the other process and its answer back; a loop whose process
   died, released and taken over by a new process that reads what was left for it; and a post from
   a `Remote` in the other process. They pass on kqueue natively, and on io_uring and epoll in the
   Linux gate, with and without a spin budget, and under ThreadSanitizer in the race gate. They do
   not use `exec`.
2. `conformance_group.zig` also runs the lost-wake test across processes, on every backend: a
   child's loop posts 4,000 rounds of one to eight messages at moments drawn from a seed, each
   after the parent's loop took the round before, a quarter of them only once that loop says it
   sleeps; a tick of the parent's loop that lasts a second is a lost wake. With the check after
   `begin_sleep` deleted from `core/inbox.zig` it failed on kqueue with and without a spin budget,
   and no other scenario did: CAUGHT. It was added on 2026-09-25, after the rest.
3. The probes of rows C24 and C25 exist (`bench/costs/probes/probes_cross_process.zig`), and their
   cells wait for a quiet run.
4. `rotor_post --peer process` runs the peer loop in a forked process on a group's registry, and the
   CI job `costs` runs it beside `--peer thread` on io_uring and on epoll.
5. Mutations:

| mutation | caught by | result |
|---|---|---|
| `attach` skips the magic number, the version or the group check | `test-core` | CAUGHT, each |
| `init_group` writes the header of a registry of one process | `test-core` | CAUGHT |
| `release` leaves the entry set | `test-core` | CAUGHT |
| each of the five new assertions of `init_group`, `attach` and `release` deleted | `zig build halt-check` | CAUGHT, each DID NOT HALT |
| a kqueue loop never registers its wake pipe | `test-conformance-kqueue` | CAUGHT |
| a kqueue loop's post or `Remote` wakes a group's loop through `EVFILT_USER` | `test-conformance-kqueue` | CAUGHT, each |
| the kqueue reap leaves the wake pipe full | `test-conformance-kqueue` | CAUGHT |
| a kqueue loop of a group publishes its kqueue | `test-conformance-kqueue` | CAUGHT |
| the pipes close on exec | `test-kqueue` | CAUGHT |
| an epoll loop of a group waits on an eventfd of its own | `conformance-epoll`, Linux gate | CAUGHT |
| an epoll loop's end closes its group's eventfd | `epoll`, Linux gate | CAUGHT |
| an io_uring loop never queues the poll of its eventfd | `conformance-uring`, Linux gate | CAUGHT |
| an io_uring loop leaves its eventfd's count | `conformance-uring`, Linux gate | CAUGHT |
| an io_uring loop's post or `Remote` wakes a group's loop with `MSG_RING` | `conformance-uring`, Linux gate | CAUGHT, each |
| an io_uring loop of a group publishes its ring | `conformance-uring`, Linux gate | CAUGHT |
| the eventfds close on exec | `linux-shared`, Linux gate | CAUGHT |
| the public `release` does nothing | `test-rotor` | CAUGHT |

### Measured on `github`, 2026-09-25

The CI job `costs`, started by hand on commit `26da902`, run 36177323493, on an AMD EPYC 7763
(`bench/results/decision-21-github-2026-09-25.md`). The probes, one run, median and p99 in ns:

| row | what | median (p99) |
|---|---|---:|
| C19 | a message between two threads, the receiver awake | 42.0 (44.4) |
| C24 | a message between two processes, the receiver awake | 41.6 (44.1) |
| C17 | a message by `MSG_RING` to a thread that sleeps, round trip halved | 14,734 (16,017) |
| C25 | a message plus the group's wake to a process that sleeps, post to reap | 14,534 (17,560) |

`rotor_post` with its peer as a thread and as a process, three rounds alternating: one message,
the median and the range of the three rounds' medians, in ns.

| backend | mode | peer thread | peer process |
|---|---|---:|---:|
| io_uring | spinning | 903 (903 to 915) | 907 (903 to 907) |
| epoll | spinning | 1,215 (1,215 to 1,215) | 1,215 (1,215 to 1,215) |
| io_uring | waiting | 12,671 (12,095 to 16,639) | 17,151 (12,287 to 17,151) |
| epoll | waiting | 12,607 (11,455 to 12,607) | 14,399 (12,479 to 16,511) |

What the runs say:

- **A process boundary costs a message nothing when the receiver is awake.** C24 reads as C19, and
  rotor's own loops that spin post in the same time with the peer in a thread or a process, on
  io_uring and on epoll. The ring is the same memory either way, which is what the prior said.
- **A wake between processes costs what a wake between threads costs.** C25, the group's eventfd
  polled from io_uring, reads as C17, `MSG_RING`, within 2 percent. The two are measured differently:
  C17 is a round trip halved with both sides asleep, and C25 one message to a process that had slept
  for 100 µs.
- **With a peer that sleeps, three rounds cannot tell a thread from a process.** The ranges overlap
  on both backends and each spreads by 4 to 5 µs.

These cells do not enter `docs/costs.md`: its `github` column describes a Xeon Platinum 8573C and is
replaced whole or not at all.

### Measured on `mac` and `orbstack`, 2026-09-26

The same probes and `rotor_post` rounds, from binaries built at `26da902`, run once the machine's
5-minute load average had stayed under 1.5 (`bench/results/decision-21-mac-2026-09-26.md` and
`bench/results/decision-21-orbstack-2026-09-26.md`). The probes, run 2 and run 3 of three, median
and p99 in ns. Run 1 on `mac` agrees with run 3; run 1 on `orbstack` was taken a minute after
OrbStack's engine started, and its C19 and C17 were disturbed.

| row | `mac`, run 2 | `mac`, run 3 | `orbstack`, run 2 | `orbstack`, run 3 |
|---|---:|---:|---:|---:|
| C19, between threads, awake | 102 (103) | 95.4 (99.3) | 101 (137) | 98.6 (141) |
| C24, between processes, awake | 97.0 (555) | 93.1 (96.7) | 102 (132) | 96.0 (122) |
| C18, `EVFILT_USER` wake between threads | 10,875 (939,000) | 25,084 (33,000) | not applicable | not applicable |
| C17, `MSG_RING` wake between threads | not applicable | not applicable | 9,936 (12,301) | 9,808 (11,910) |
| C25, the group's wake between processes | 15,667 (37,958) | 26,125 (40,416) | 32,500 (45,375) | 31,417 (44,000) |

`rotor_post`, one message, the median and the range of three rounds' medians, in ns:

| backend | mode | peer thread | peer process |
|---|---|---:|---:|
| kqueue, `mac` | waiting | 2,511 (2,511 to 4,015) | 2,511 (2,511 to 4,015) |
| kqueue, `mac` | spinning | 0 (0 to 0) | 0 (0 to 0) |
| io_uring, `orbstack` | waiting | 10,943 (10,879 to 11,263) | 11,263 (11,199 to 11,391) |
| io_uring, `orbstack` | spinning | 959 (939 to 1,335) | 1,335 (959 to 1,335) |
| epoll, `orbstack` | waiting | 10,687 (7,263 to 10,751) | 10,879 (6,975 to 11,135) |
| epoll, `orbstack` | spinning | 1,359 (1,335 to 1,359) | 1,335 (959 to 1,359) |

On `mac` the clock advances in 1,000 ns steps, so a message moves in steps of about 500 ns and 0 is
a round trip shorter than one step.

What the runs say:

- **A process boundary costs a message nothing on any machine measured.** C24 reads as C19 on
  `mac`, `orbstack` and `github`, and rotor's own loops post in the same time with a peer thread or a
  peer process on all three backends, awake or asleep, within the rounds' spread.
- **On `mac` the group's wake costs what `EVFILT_USER` costs.** C25 read as C18 in the two runs
  where C18 was not disturbed, 26,125 against 25,084 ns in run 3.
- **On `orbstack` C25 reads three times C17, and the method explains it.** C25 wakes a process that
  slept 100 µs; C17 is a round trip between two rings that each went to sleep a moment before.
  `rotor_post`, which measures both peers alike, found them level there too. A C17 taken the way C25
  is would compare the two wakes directly; it does not exist yet.
- **The spinning rounds on `orbstack` are bimodal**, near 950 or near 1,335 ns, for a thread and a
  process alike: which host cores the two virtual CPUs land on, most likely, which the guest cannot
  see.

