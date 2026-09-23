# 20. An epoll backend

Status: **accepted** on 2026-09-22, by the owner, who ruled for it after a consumer could not run
rotor at all in its continuous integration.

## Why this reverses decision 2

Decision 2 puts an epoll backend in "Not in version one" and gives the reason:

> **An epoll backend.** A Linux host that refuses `io_uring_setup` gets `error.Unsupported`
> from init. That has a real cost: Docker's default seccomp profile refuses io_uring, which is
> why stompy's Linux tests run with `seccomp=unconfined`. The alternative is a third backend to
> write, simulate and benchmark, for hosts where rotor's speed sources do not exist anyway.

That is a refusal and not a trigger, unlike the UDP row decision 15 fired. So this record reverses
it, and owes an account of what changed. Three things did.

**The cost the row named arrived.** cocuyo reported on 2026-09-22 that its tests could not run
rotor. The row had already named the mechanism: Docker's default seccomp profile refuses
`io_uring_setup` with EPERM. Every environment rotor now cannot enter is one that row predicted.

**The row's own estimate of the work was wrong in two ways.** It says "a third backend to write,
simulate and benchmark". There is nothing to simulate: decision 10 dropped the simulator, and one
conformance suite runs against every backend. And it is not a third design. epoll is a readiness
interface, which is kqueue's shape: `src/kqueue/` already performs every transfer itself when
readiness arrives, and already emulates multishot and provided buffer groups in user space because
kqueue has neither. This backend follows decision 12 and not decision 11.

**What the row got right stands, and is not softened here.** epoll gets none of decision 3's speed
sources: no registered descriptors, no provided buffer rings, no multishot, no batched submission
for socket I/O, no one syscall per tick. rotor on epoll is shaped like libuv on epoll. **No speed
claim is made for this backend, now or later**, and the comparison does not gain a row for it. It
exists so that rotor runs where io_uring does not.

## What it is for

One sentence: a consumer can run rotor in a container it does not control.

The environments this reaches, each verified or named:

| environment | io_uring | why |
|---|---|---|
| Docker, default seccomp | refused | the profile denies `io_uring_setup`, EPERM |
| Docker, `seccomp=unconfined` | works | what rotor's own Linux gate passes |
| GitHub-hosted `ubuntu-24.04`, no container | works | measured 2026-09-22: rows C7 and C17 of `docs/costs.md` |
| a kernel with `io_uring_disabled` at 2 | refused | the 6.6 sysctl, set by some hardened builds |
| gVisor and similar sandboxes | refused, recalled and not verified here | they implement a subset of syscalls |

The third row matters because it corrects a misreading. GitHub's runners do **not** disable
io_uring; a container on them does. `.github/workflows/ci.yml` prints both facts so no one has to
guess again.

## The shape

epoll reports readiness, so this backend is decision 12's design with three organs replaced.

| what | kqueue | epoll |
|---|---|---|
| readiness call | `kevent`, changelist rides in the wait | `epoll_wait`, changes need their own calls |
| registration | one changelist entry, batched up to 256 | one `epoll_ctl` per change, not batched |
| cross-thread wake | `EVFILT_USER` with `NOTE_TRIGGER` | `eventfd`, one write |
| timers | the loop's own heap, decision 5 rule 5 | the same heap, unchanged |
| a transfer | performed inline when ready | the same |
| multishot | emulated: the filter is kept | the same, by not clearing the registration |
| provided buffers | emulated in user space | the same, `core` holds the group |
| files | not reported ready, decision 18 offload | the same, and for the same reason |

Everything in the right column that says "the same" is code this backend takes from `core` or
mirrors from `src/kqueue/`, which is why the estimate in decision 2 was too high.

**What became `core`'s rather than being copied**, on 2026-09-22 as the build reached each one. A
file moved when it names no kernel type, because both readiness backends then need the same code and
two copies drift:

| file | was | why it moved |
|---|---|---|
| `core/waiters.zig` | `src/kqueue/kqueue_waiters.zig` | open addressing over the caller's memory, no kernel type |
| `core/mailbox.zig` | `src/kqueue/kqueue_mailbox.zig` | neither kernel has `msg_ring`, so both cross in user space |
| `core/errno.zig` | `src/kqueue/kqueue_errno.zig` | both backends make their own calls; the map matches by name |
| `core.offload.init_rings` | `kqueue_offload.zig` | the same rings out of the same caller memory |

Each backend re-exports what a caller reaches, so the public module was untouched by the move. Two kinds of file
stayed put: one whose calls take a `*Loop`, because `core` would have to be generic over it
(`epoll_buffers.zig` is `kqueue_buffers.zig` copied for that reason), and one that names the target's
own kernel types (the sync helpers, the address helpers, `perform`). The threaded mailbox tests also
stayed in `src/kqueue/`: they need a deadline, and `core` reads no clock.

Moving `core.offload.init_rings` found a gap rather than just saving lines. Nothing had ever handed
it memory that was 64-byte aligned and not 128-byte aligned, so the skip forward it exists for had
never run, and aligning the rings to 64 passed every test. It has a test now.

**The one real loss against kqueue is registration.** kqueue carries up to 256 changes in the call
that waits; epoll needs one `epoll_ctl` per change and has no way to batch without io_uring, which
is the thing that is missing. libuv batches them through an io_uring ring when one exists
(`docs/decisions/0003-speed-sources.md` cites `src/unix/linux.c:651`), and that route is closed
here by definition. So a tick that registers N descriptors makes N+1 syscalls.

This record first said that registrations left in place turn most re-arms into no syscall at all.
The build showed that was wrong, and why. The loop cannot keep a record of what it registered: a
descriptor the caller closes with `sync.close_now` leaves the epoll instance with it, and its number
can come back as another socket, so a record in user space would be wrong exactly when it matters.
So the kernel is asked each time, and the rules the backend settled on are these
(`epoll_queue.zig`, `epoll_reap.zig`, `epoll_cancel.zig`):

- **An operation that waits costs one `epoll_ctl` or more**: a modify, and an add when the kernel
  answers that it holds nothing. Measured on `orbstack` on 2026-09-22
  (`bench/results/calls-orbstack-2026-09-22.md`), per echo at 64 KiB: a receive that is re-armed per
  message waited 0.505 times and cost 0.652 `epoll_ctl`, more than one per wait, because bytes that
  arrive while nobody receives are taken out by the reap and the next receive then adds its
  registration again. A multishot receive keeps its registration and cost none. At 4 KiB the
  re-armed receive waited 0.115 times and cost 0.208.
- **The read direction stays registered after a receive or an accept completes**, because the next
  one on that descriptor is the common case and finds it there.
- **The write direction is taken out as soon as nobody waits on it.** A socket is writable almost
  all the time, so a write registration left in place ends the very next wait, for nobody.
- **A cancel, and a multishot operation that ends, take their direction out at once**, as kqueue
  removes the filter a multishot operation kept.
- **A direction the kernel reports with nobody waiting is taken out by the reap**, or a
  level-triggered registration would report it on every wait.

The conformance suite decided the third and fourth rules: each was first written the other way,
and a scenario in which a tick must take its whole wait failed until it was changed.

## What it emulates, and what it refuses

This record first said that `register_descriptors` and registered buffers answer `Unsupported`.
That was wrong, and it contradicted this record's own gate: kqueue emulates both so that one program
runs on every backend, and the conformance suite requires them of every backend. So epoll does what
kqueue does:

- **`register_descriptors`** keeps a table of the caller's descriptors and swaps an index for its
  descriptor at the flush (`epoll_descriptors.zig`). Nothing is gained, and nothing is claimed.
- **A registered buffer** is recorded and nothing else: epoll pins no pages.
- **A file operation** follows decision 18: `file_policy` defaults to `refuse`, and a caller that
  wants one hands the loop a thread pool or asks for `blocking`.

A capability that is a socket option rather than a ring feature is kept, because it is the kernel's
and not io_uring's: decision 15's datagram surface, GSO, GRO and ECN included, works here, and a
segmented send is carried where kqueue answers `unsupported`.

## The gate

The same conformance suite, with `backend` bound to `epoll`, and it runs **in Docker under the
default seccomp profile**. That is the point of the backend, so it is the environment the gate
proves it in. `tools/linux_test.sh` keeps `seccomp=unconfined` for the io_uring suite; the epoll
suite must pass without it, and a run that needed the flag would be measuring nothing.

The cost gates of `src/conformance/conformance_cost.zig` run against it like any backend. They pass
with the bounds every backend has; none needed one of its own.

The gate passed on 2026-09-22, on OrbStack's Linux 7.0.14:

| run | executable | passed | skipped | failed |
|---|---|---:|---:|---:|
| `tools/linux_test.sh`, default seccomp | `epoll` | 51 | 1 | 0 |
| `tools/linux_test.sh`, default seccomp | `conformance-epoll` | 53 | 1 | 0 |
| `tools/race_test.sh`, ThreadSanitizer | `conformance-epoll` | 50 | 4 | 0 |

The skipped scenario in the Linux gate is the io_uring backend's own. The race gate skips more
because it runs the Debug executable with the sanitizer, where the cost gates do not apply.

## What building it found

Four things outside this backend, each fixed or recorded where it belongs:

- **kqueue left its poll trigger set.** A tick whose events were already full still added the
  trigger, which the kernel applied and could not deliver, so it ended the next waiting tick at
  once. The multishot accept scenario caught it once its late connection came from a second loop
  (`kqueue_tick.zig`).
- **Decision 18's teardown order had a second half.** A worker still inside `run` reads the loop
  after its result is visible, so a caller stops its offload before `deinit`. ThreadSanitizer found
  it in this suite, the first conformance suite whose loops use the mailbox rings under it.
- **SIGPIPE cannot end a Zig test.** `std.Io.Threaded` installs a handler that does nothing for it,
  so a missing `MSG_NOSIGNAL` passed unseen. The scenario for a closed peer counts the signal now,
  and it holds on every backend.
- **A Linux system call on a Mac runs some other call.** macOS reads the call number from another
  register, so `zig build halt-check` cannot prove an epoll assertion whose path, once the assertion
  is deleted, reaches one (`tools/halt/epoll_scenarios.zig`). Since 2026-09-22 the Linux gate runs
  a halt check of its own for such scenarios (`tools/halt/epoll_linux_scenarios.zig`).

## Open questions

Each has a proposed answer, and the implementation follows it until the owner rules otherwise.

1. **`epoll_wait` or `epoll_pwait2`?** The first takes a timeout in milliseconds, which is coarser
   than every deadline rotor accepts; the second takes a `timespec` and arrived in Linux 5.11, below
   decision 2's floor of 6.1. *Proposed: `epoll_pwait2`, and `Unsupported` at init on a kernel
   without it, matching how `uring_ring.zig` refuses a kernel missing a flag it needs.*
2. **Level or edge triggered?** *Proposed: level triggered. Edge triggering requires draining until
   EAGAIN, which turns one transfer into several syscalls and makes a short read indistinguishable
   from an empty socket. Level triggering costs a re-arm that level triggering does not need.*
3. **Does `post` between two epoll loops share the mailbox rings?** *Proposed: yes, unchanged from
   decision 4. The rings are `core`'s and the wake is the only backend-specific part, so an eventfd
   write replaces the `EVFILT_USER` trigger and nothing else moves.*
4. **Does the comparison gain an epoll row?** *Proposed: no. There is no speed claim to make, and a
   row invites one. A person who wants the number runs the harness by hand.*
5. **How does a caller get this backend?** Two shapes were put to the owner: a build option that
   makes the public module wrap `epoll` on Linux, and a fallback at `init` that tries io_uring and
   runs epoll when the kernel refuses it. **The owner ruled on 2026-09-22: the fallback at init.**
   One binary runs everywhere, as libuv does; the price is a branch per call on Linux and both
   backends linked. What was built (`src/rotor/rotor_loop.zig`):
   - **The choice is made once per process, not per loop.** The sockets `sync` opens before any
     loop exists must suit the backend: uring's block, because the ring does the waiting, and
     epoll's must not. So the first thing that needs the answer asks the kernel, with a ring of one
     entry made the way a loop makes one (`uring.refused`), and one atomic keeps the answer. It is
     the one value rotor keeps outside the memory a caller hands it.
   - **Refused means `PermissionDenied` or `Unsupported`**: seccomp, `io_uring_disabled`, a kernel
     without io_uring or without what the backend requires. A process short of descriptors or
     memory is short of them on either backend, so that is reported and not fallen back from.
   - **It is reported.** `rotor.backend()` answers `.uring`, `.epoll` or `.kqueue`, which keeps
     `uring_ring.zig`'s promise never to fall back to a slower path without saying so.
   - **The flags answer for either backend.** `files_block` and `post_bounded` are true on Linux,
     because a process may run epoll; a caller that sets a file policy and handles `mailbox_full`
     is right on both.
   - **The public module imports `epoll`**, the one edge of the module graph the ruling adds, and
     moved to `src/rotor/` because it is two files now.

   The Linux gate runs the public module's tests twice, with io_uring and under the default seccomp
   profile, so each branch is tested where it is chosen. No build option to pin one backend was
   built: nothing asked for it yet, and the benchmarks use the backends directly.
