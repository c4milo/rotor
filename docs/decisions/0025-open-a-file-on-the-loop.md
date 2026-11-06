# 25. Open a file on the loop

Status: **withdrawn** on 2026-11-05, the day it was proposed, by Camilo's choice. rotor keeps the
synchronous file calls of decision 2, which follow TigerBeetle's model: "Why it was withdrawn" says
why. Nothing of it was built. It is kept for the comparison it records, so that the question comes
back only with a need this record did not have.

As proposed, it followed Seastar's model for files: the library opens a file, sets its flags, and
never blocks its event loop doing it. It would have amended decision 2, which put a synchronous open
in version one, and added an operation kind.

## Context

rotor opens a file with `sync.open_file(path, .{ .create, .direct })`. The call runs `open(2)` on the
caller's thread, which is usually the loop's: a path lookup that misses the kernel's cache, or a
filesystem that waits on a disk or a network, holds the loop for as long as the kernel takes. Decision
2 accepted that, because the calls "run at startup and are not hot", and kept them in rotor because
"a backend that the simulator replaces must own every call that touches the disk".

Three libraries rotor is compared with do it three ways, recalled and not checked against their
current source:

| library | who opens | flags | does the event loop block |
|---|---|---|---|
| libuv | libuv, `uv_fs_open`, on its thread pool | the caller's, O_DIRECT included; libuv adds close-on-exec | no: a pool thread blocks |
| libxev | the caller; `xev.File` wraps a descriptor the program opened | none of libxev's | the caller's choice |
| Seastar | Seastar, `open_file_dma`, on a syscall thread | Seastar's: O_DIRECT always, and it reports the alignment buffers need | no: the syscall thread blocks |

On 2026-11-05 colibri asked for a read-only open (issue 11) and then withdrew it. Camilo first said
that rotor should not do file I/O directly. After the three models above were compared, he chose
Seastar's the same day.

## Decision, proposed

1. **An `open` operation.** `Operation.Kind` gains `open`, appended last so every code before it
   keeps its value:

   ```zig
   /// Result: the new descriptor.
   pub const Open = struct {
       /// The file's path, zero-terminated. It stays the loop's until the final event (decision 5,
       /// rule 3), as a `connect`'s address does.
       path: [*:0]const u8,
       /// Create the file, refusing a path that exists.
       create: bool = false,
       /// Transfers bypass the page cache: O_DIRECT on Linux, F_NOCACHE on macOS.
       direct: bool = false,
       /// Open to read alone, refused together with `create`.
       read_only: bool = false,
   };
   ```

   rotor sets the descriptor's flags itself: close-on-exec always, O_DIRECT or F_NOCACHE when
   `direct`, read and write unless `read_only`. A caller names what it wants and never an `open(2)`
   flag, as with every other operation.

2. **Each backend runs it the way it runs its other file operations:**

   | backend | how an `open` runs | where the flags are set |
   |---|---|---|
   | io_uring | `IORING_OP_OPENAT`, in the kernel's floor since Linux 5.6 | in the operation's flags |
   | epoll | decision 18's file policy: `refuse` ends it with `unsupported`, `blocking` runs `open(2)` on the loop's thread, `offload` runs it on the caller's threads | in `open(2)` |
   | kqueue | the same policies; the default is `refuse` | `open(2)`, then `fcntl(F_NOCACHE)` in the same call |

   So the loop never blocks on an open on io_uring, nor under `offload` on the other two. Under
   `blocking` it waits as `sync.open_file` waits today. On no backend is it worse than now.

3. **`sync.open_file` and `OpenOptions` go**, in the release that brings the operation. The other
   three file calls of `sync`, `file_size`, `set_file_size` and `sync_directory`, stay synchronous
   for now (open question 2).

## What it costs

- **One kind more in `Operation` and in `Slot`.** An `open` carries a pointer and three flags. They
  are expected to fit the fields a `read` uses for its buffer and offset, so the slot's 64 bytes
  and its layout would not change; that is checked when it is built, and a change to the layout
  comes back to Camilo first. Each backend's switch gains one arm, which a path that is not an open
  never takes.
- **A path the loop holds.** The caller keeps the path's bytes alive until the final event, as it
  keeps a buffer or an address today.
- **A change for callers on macOS.** kqueue refuses file operations by default, so an `open` there
  fails with `unsupported` until the caller names `blocking` or `offload`. Reading a file already
  needs that, so a program that reads files changes nothing more.
- **io_uring's own kernel workers.** From memory, `IORING_OP_OPENAT` tries the lookup without
  blocking, and hands one that must block to io_uring's kernel workers, as the kernel does with a
  buffered read. Decision 3 refused SQPOLL as a hidden thread that runs all the time. These workers
  run only for an operation that must block. The record states it, and a probe in `uring_probe`
  confirms that the operation is supported, as for every opcode rotor uses.

## Alternatives it beats

1. **libuv's model as it is today: `sync.open_file`, synchronous.** It blocks the loop on a slow
   lookup or a slow disk, and nothing can move it off the loop's thread.
2. **libxev's model: the caller opens, rotor sets nothing.** Leaves O_DIRECT, F_NOCACHE and
   close-on-exec to every caller, and the open off rotor's tests and its simulated surface
   (decision 24).
3. **The caller opens, `sync.prepare_file(descriptor, .{ .direct })` sets the flags.** Smaller, but
   the open still blocks wherever the caller runs it, and on Linux O_DIRECT set after the open is a
   second call.

## How it is checked

1. The conformance suite gains scenarios on all three backends: open a file that exists; create one
   and refuse a path that exists; refuse a path that is missing; open read-only a file of mode 0400
   and refuse a write to it; open with `direct` and read an aligned block; cancel an open that waits
   in an offload; and an open under each file policy.
2. A halt scenario: `read_only` with `create`, and an empty path.
3. Mutations of each flag rotor sets, measured as CLAUDE.md asks.
4. `rotor_reads` and the conformance scenarios that open files today move to the operation.

## Why it was withdrawn

Before ruling, Camilo asked how TigerBeetle opens files and sockets. From memory, and not checked
against its current source:

- **Files.** TigerBeetle's I/O layer opens its data file synchronously at startup, sets O_DIRECT
  itself after a check that the filesystem takes it, allocates the file's size with `fallocate`,
  takes an exclusive `flock`, and syncs the directory after a create. Every read and write after
  that is a completion on the event loop. A replica opens one file once, so a blocking open costs it
  nothing.
- **Sockets.** Its I/O layer creates a socket, sets its options, and binds and listens
  synchronously. Accept, connect, send, receive and close are completions on the loop.

rotor already has that shape for both. Its `sync` calls set a socket or a file up synchronously,
and its loop runs every transfer, as decision 2 took from stompy's layer, which is TigerBeetle's
sequence. Setting a socket up never waits on a device or a peer, and `connect`, which waits for the
peer, is a loop operation in both. A file's open can wait on a disk during its path lookup, which
matters only to a program that opens files while it serves, and rotor's callers open theirs at
startup. Camilo chose to stay with TigerBeetle's model.

Two things TigerBeetle has at startup and rotor does not, an exclusive lock on a file and a check
that O_DIRECT works on its filesystem, were noted and not asked for.

## Open questions as proposed

1. **Report the alignment, as Seastar does?** A file opened with `direct` needs buffers and offsets
   aligned to the device's logical block. Proposed: not in this record. A caller that uses `direct`
   knows its device's block today, and the question can come with a measured need.
2. **`file_size`, `set_file_size` and `sync_directory` as operations too?** Seastar runs each on its
   syscall thread. Proposed: not now. They run at startup, and each would be a kind more. A later
   record can move them with a measured need.
3. **An open relative to a directory descriptor**, as `openat(2)` takes. Proposed: not now: every
   path is relative to the working directory or absolute, as `sync.open_file`'s are.
4. **When.** Proposed: after release 0.9.0, which carries the datagram changes, so that each release
   holds one breaking change.
