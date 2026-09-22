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

Each backend re-exports what a caller reaches, so `src/rotor.zig` is untouched. Two kinds of file
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
here by definition. So a tick that registers N descriptors makes N+1 syscalls. Level-triggered
registration that is left in place turns most re-arms into no syscall at all, which is the
mitigation and the reason multishot emulation costs nothing extra.

## What it refuses

A capability with no epoll equivalent is refused and named, as kqueue refuses UDP segmentation
rather than emulating it:

- **`register_descriptors`** answers `Unsupported`. Decision 3's source 1 is an io_uring feature.
- **A registered buffer** answers `Unsupported`, for the same reason.
- **A file operation** follows decision 18: `file_policy` defaults to `refuse`, and a caller that
  wants one hands the loop a thread pool or asks for `blocking`.

A capability that is a socket option rather than a ring feature is kept, because it is the kernel's
and not io_uring's: decision 15's datagram surface, GSO, GRO and ECN included, works here.

## The gate

The same conformance suite, with `backend` bound to `epoll`, and it runs **in Docker under the
default seccomp profile**. That is the point of the backend, so it is the environment the gate
proves it in. `tools/linux_test.sh` keeps `seccomp=unconfined` for the io_uring suite; the epoll
suite must pass without it, and a run that needed the flag would be measuring nothing.

The cost gates of `src/conformance/conformance_cost.zig` run against it like any backend, with
bounds of their own: a poll that makes an `epoll_wait` is not a poll that makes a `kevent`.

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
