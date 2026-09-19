# 2. Scope of version one

Status: proposed on 2026-09-19, awaiting review.

## Context

The proposal: Linux io_uring and macOS kqueue, TCP sockets, regular files with O_DIRECT, timers,
and cancellation. No TLS, no DNS, no Windows, no process spawning.

## Decision

Accept the proposal, with four additions, two exclusions it did not name, and one correction.

### In version one

| area | operations |
|---|---|
| TCP | listen, accept (single and multishot), connect, receive (single and multishot with provided buffers), send, shutdown, close |
| regular files | positional read, positional write, `fdatasync`, close; synchronous open, size, preallocate and directory sync |
| timers | arm, cancel |
| cancellation | cancel one operation by handle; cancel every operation of one descriptor (`0005-cancellation.md`) |
| cross-core | post one message into another loop (`0004-threading.md`) |
| registration | buffers and descriptors, once, before use (`0003-speed-sources.md`) |

The four additions:

1. **`fdatasync`.** The proposal lists files with O_DIRECT and no way to make a write durable.
   stompy is the first consumer and its journal calls `fdatasync` after every batch of writes.
2. **The synchronous file calls stompy's layer has**: open with O_DIRECT, file size,
   `fallocate`, directory `fsync`. They run at startup and are not hot. They are in scope
   because a backend that the simulator replaces must own every call that touches the disk.
3. **Cross-core post.** The threading model is the main claim, and its unit of cost is one
   cross-core message (C17, C18). A version one without it cannot test the claim.
4. **Registration.** Registered buffers and descriptors are where part of the speed is meant to
   come from, so they are in the first API and not added to it later.

### Not in version one

TLS, DNS, Windows and process spawning, as proposed, and also:

- **UDP and Unix sockets.** No consumer needs them yet. colibri's QUIC will want UDP, but
  colibri owns no I/O, so the need arrives with whoever embeds colibri.
- **The std.Io adapter** (`0001-interface.md`). The core's numbers come first.
- **An epoll backend.** A Linux host that refuses `io_uring_setup` gets `error.Unsupported`
  from init. That has a real cost: Docker's default seccomp profile refuses io_uring, which is
  why stompy's Linux tests run with `seccomp=unconfined`. The alternative is a third backend to
  write, simulate and benchmark, for hosts where rotor's speed sources do not exist anyway.
- **Buffered file I/O.** The brief lists O_DIRECT, and stompy uses nothing else. A buffered
  operation that has to wait can also be handed to a kernel worker thread, depending on the
  kernel and the filesystem (recalled), and that is a hidden thread by another name.

### The correction: files on macOS

macOS has no O_DIRECT, and kqueue does not report readiness for regular files: a regular file
is always ready. `EVFILT_AIO` exists on FreeBSD and not on macOS. So the kqueue backend has
three choices for a file operation:

1. Run `pread` or `pwrite` inline at submit on the loop thread, with `F_NOCACHE` set at open,
   and deliver the completion at the next tick.
2. Hand it to a thread pool, as libuv does and, as recalled, libxev does for kqueue.
3. Refuse it.

The decision is choice 1. It blocks the loop for the duration of the read, which is C12, about
20,000 ns with the prior. That is about one loopback round trip (C14) at the median, and every
connection the loop owns waits that long, and far longer when the device stalls. That is
unacceptable on a server and acceptable on a development machine. Choice 2 breaks the rule that
the loop starts no thread. Choice 3 would stop stompy's journal from running on the machine it is
developed on.

Consequence: **macOS is a development platform.** The kqueue backend exists so that every
consumer builds, tests and debugs on a Mac with real sockets and real files. The harness runs
on macOS and records its numbers, and no file-workload number from macOS is published as a
claim. Socket and timer numbers from macOS are reported as what they are: kqueue on a laptop.

### Minimum kernel

Linux 6.1. The io_uring features version one depends on, with the kernel each arrived in, as
recalled and to be verified by the init probe in milestone 2:

| feature | recalled kernel | used for |
|---|---|---|
| `IORING_FEAT_NODROP`, `IORING_FEAT_EXT_ARG` | 5.5, 5.11 | no lost completion; wait timeout as an argument (stompy requires both today) |
| `IORING_OP_MSG_RING` | 5.18 | cross-core post |
| multishot accept | 5.19 | one submission, many accepts |
| provided buffer rings | 5.19 | multishot receive |
| multishot receive | 6.0 | one submission, many receives |
| `IORING_SETUP_SINGLE_ISSUER`, `IORING_SETUP_DEFER_TASKRUN` | 6.0, 6.1 | completions run only when the loop asks |

One interaction is uncertain from memory: posting with `MSG_RING` into a ring set up with
`DEFER_TASKRUN` may need a kernel later than 6.1. The milestone 2 probe posts between two such
rings, and the floor rises if the kernel refuses the post.

Init probes every one of these and returns `error.Unsupported` naming the first that is missing.
It never falls back to a slower path without saying so: a fallback makes the harness's number
depend on which path ran.

## Alternatives it beat

**A smaller version one: sockets only.** Faster to ship, but stompy's layer is files only, so
the first consumer could not move, and `0006-stompy-lineage.md` would have nothing to stand on.

**A larger version one: add UDP and the adapter.** Each adds a simulator surface and a harness
workload. Neither changes whether the main claims hold.

**Support kernels before 6.1.** Every feature absent is a second code path and a second
harness column. The target machines are the owner's own, so the kernel is a choice.

## How it is checked

Each row of the scope table gets a simulator test in milestone 1 and a real-backend test in
milestones 2 and 3. An operation outside the table does not compile: `Operation` is a closed
union.

## Open questions for review

1. Is Linux 6.1 acceptable as the floor? The machine named in `docs/costs.md` decides.
2. Is inline blocking file I/O on macOS acceptable, given that macOS is development only?
