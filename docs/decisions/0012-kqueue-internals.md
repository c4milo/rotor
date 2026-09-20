# 12. Inside the kqueue backend

Status: accepted on 2026-09-19, by the author of the backend before writing it. Each point is a
choice the code will embody, with the alternative it beat. kqueue reports readiness and io_uring
reports completion, so this backend does what the kernel does for `uring`: it performs the
operation when the descriptor is ready. The caller sees one behaviour, which the conformance
suite checks on both (decision 10). macOS is a development platform (decision 2), so where speed
and sameness pull apart, sameness wins here.

## 1. An operation is tried first, and waits for readiness only when it would block

`flush` performs the system call at once: `accept`, `recv`, `send`, `connect`. Only `EAGAIN`, or
`EINPROGRESS` for a connect, registers a one-shot filter, `EVFILT_READ` or `EVFILT_WRITE`, with
the handle as the filter's user data. When the filter fires, the reap performs the call again.

A send is almost always ready, so registering first would cost a `kevent` change and a wake for
nothing. The price is one wasted call for a receive on an idle socket. libuv and libxev make the
same choice.

An operation that completes in `flush` ends on the loop's finished list, like a timer, and its
event is handed over by the same tick. Decision 5's rule still holds: never from inside
`submit` or `cancel`.

Consequence, stated plainly: "one system call per tick" (decision 3, source 4) does not hold on
kqueue and is not claimed for it. Every transfer is its own call. One `kevent` call per tick
carries the registrations in and the readiness out.

## 2. One table maps a descriptor to the operations waiting on it

kqueue knows one registration per descriptor and filter, and its user data is one word. Two
receives waiting on one socket, or a cancel, or a close, all need to find the operations that
wait on a descriptor. The loop keeps an open-addressing table from descriptor to two list heads,
read and write, linked through `Slot.next`, in memory the caller handed in, with room for two
entries per slot of the slot table.

It is touched when an operation has to wait, when one is cancelled, and at close: never on the
path of an operation that completes at once. The `uring` backend refused this table
(decision 11, point 5) because it would have cost a cache line on every operation. Here it
costs one only where a `kevent` change is being paid for anyway.

With it, `close` keeps decision 5's rule 6 in full: every operation waiting on the descriptor
gets its `canceled` event first, then the close gets its own.

## 3. Multishot operations keep their filter

A multishot accept or receive registers its filter without `EV_ONESHOT`. kqueue is
level-triggered, so readiness the loop did not get to is reported again at the next tick, and a
tick takes no more readiness events than it has room for events. No queue is needed and none can
overflow.

## 4. Provided buffers are picked by the loop

io_uring picks a buffer from a group itself. Here the loop does: a group is the caller's memory
cut into equal buffers, with a stack of free buffer ids. A receive from a group pops an id,
receives into that buffer, and names it in the event. `give_back_buffer` pushes the id. An empty
stack ends a multishot receive with `buffers_exhausted`, as on io_uring. `register_buffers`
records nothing and changes nothing: there is no page pinning to save.

## 5. Files block the loop, and a sync is a full sync

A file operation runs inline in `flush`: `pread`, `pwrite`, and for `fdatasync`,
`fcntl(F_FULLFSYNC)`. Decision 2 accepted the blocking. `F_FULLFSYNC` is what makes the promise
of `fdatasync` true on macOS: a plain `fsync` leaves the bytes in the drive's cache. `open_file`
with `direct` sets `F_NOCACHE`, the nearest macOS has to O_DIRECT, and `set_file_size`
preallocates with `F_PREALLOCATE` and then sets the length.

Observed on Darwin 25.6 while writing the calls:

- `F_PREALLOCATE` reserves from the physical end of the file, and APFS keeps blocks past the end
  of the file after a close. So `set_file_size` reserves only the bytes the file lacks. Asking
  for the full size each time would leak blocks.
- `sync_directory` is a plain `fsync`. devfs and autofs refuse `F_FULLFSYNC` on a directory
  descriptor, and APFS accepts it, so the directory entry is less durable than the file's data.
  No test on this host can tell a dropped directory `fsync` from a made one.

## 6. A post is a ring in shared memory plus a wake

Decision 4 settled the shape. The details:

- The registry holds one single-producer single-consumer ring of messages per ordered pair of
  loops, in memory the application hands it, sized for the loops it will run and not for
  `loops_max`: `loops × loops × ring_bytes`.
- The producer's index and the consumer's index sit on separate 128-byte lines, so the two
  threads never write one line.
- A post writes the message and, when the ring was empty, triggers an `EVFILT_USER` event on the
  receiver's kqueue. That is one `kevent` call for a burst, made in the sender's tick.
- The post's own final event is 0, or `mailbox_full` when the ring has no room, or
  `loop_not_found`. It is produced by the sender's `flush` with no wait.
- The receiver drains every ring that names it at each tick, after the `kevent` call, straight
  into the caller's events. A ring that still holds messages when the events run out is drained
  at the next tick, which does not wait while any ring is non-empty.

These rings are the one place in rotor where two threads touch the same memory. They are tested
with two real threads under load, not only by the conformance suite's single message.

## 7. Timers, deadlines, cancellation

As in `uring`, from `core`: the heap orders every deadline, the nearest one bounds the `kevent`
wait, and a passed deadline is a cancel the loop issues (decision 11, point 1). A cancel of an
operation that waits for readiness unlinks it from its descriptor's list and ends it at once
with `canceled`. The filter is left to fire: it is one-shot, and the reap finds no operation
waiting and does nothing.

## 8. Accepted sockets

macOS has no `accept4`. The backend sets `O_NONBLOCK` and `FD_CLOEXEC` on an accepted socket
with two `fcntl` calls, and `SO_NOSIGPIPE` with a `setsockopt`, because macOS has no
`MSG_NOSIGNAL` either. That is three system calls per accepted connection that Linux does not
pay, and the accept-storm numbers on macOS will show it.

Observed on Darwin 25.6: an accepted socket inherits `O_NONBLOCK` and `SO_NOSIGPIPE` from its
listener, and does not inherit `FD_CLOEXEC`. With a listener from `sync.listen`, two of the three
calls change nothing. The backend still makes all three, because the caller may hand it a
listener it opened some other way. Dropping the two calls for a listener the loop can prove it
prepared is a measured optimisation for later, not a default.

## 9. Registered descriptors are a table in the loop

kqueue has nothing to register a descriptor with. The loop copies the list
`register_descriptors` was handed into a table of its own, 4 KiB for
`registered_descriptors_max` entries, inside the `Loop`. The flush swaps the index an operation
names for the descriptor registered there, and clears the flag, before anything else reads the
slot. So the table of waiters, the cancel and the close all see a descriptor, as before.

`register_descriptors` refuses a descriptor that is not open with `DescriptorInvalid`, which it
finds with `fcntl(F_GETFD)`, because io_uring refuses one. Nothing is gained on this backend and
nothing is claimed: the table exists so that one program runs on both.

## Not in this backend

- One loop per core by SO_REUSEPORT: decision 4 recalled that macOS does not spread connections
  across such sockets, and the conformance suite's count of accepts per socket will say.
- Any claim about file workloads (decision 2).
