# Using rotor

This is the guide for a program or a library that drives a rotor loop. It says what the loop
promises, what it needs from the caller, and where the limits are. The decision records in
`docs/decisions/` say why; this file says what.

rotor is one Zig module. It allocates nothing: the caller hands every loop its memory at init, and
every table and queue inside it is bounded by a named limit. A loop belongs to one thread. Every
operation ends with exactly one final event. Those three rules shape everything below.

## Getting the module

```bash
zig fetch --save git+https://github.com/c4milo/rotor#v0.4.0
```

In `build.zig`:

```zig
const rotor = b.dependency("rotor", .{ .target = target, .release = optimize != .Debug });
exe.root_module.addImport("rotor", rotor.module("rotor"));
```

rotor's build declares `release` and no `optimize` option, so a dependency that passes `.optimize`
prints `invalid option: -Doptimize` on every build.

Then `const rotor = @import("rotor");`. The module picks the backend for the host it runs on. On
macOS it is kqueue. On Linux it is io_uring, **and epoll where the kernel refuses io_uring**, as
Docker's default seccomp profile does and as `io_uring_disabled` does: the first thing that needs
the answer asks the kernel for a ring, and the answer holds for the life of the process.
`rotor.backend()` says which one runs (`.uring`, `.epoll` or `.kqueue`), so the fallback is never
silent. Every backend carries the same surface, so the program is the same whichever runs. rotor
builds in Debug and ReleaseSafe; its assertions stay on in production, and it offers no mode that
removes them.

epoll has none of io_uring's speed sources, and rotor makes no speed claim for it: it exists so a
program runs where io_uring does not. A program that must have io_uring checks `backend()` at
start and refuses to go on without it.

What the module exports: `Loop`, `Registry`, `Remote`, the helpers `sync` and `buffers`, `backend`
and `Backend`, the flags `files_block`, `post_bounded` and `supported`, `offload_memory_bytes`,
`memory_alignment`, and the
types a caller builds operations from and reads events with (`Operation`, `Event`, `Handle`,
`Address`, `Message`, `LoopId`, `Descriptor`, `Code`, `Error`, `Delivery`, and the namespaces
`constants`, `datagram`, `offload`, `statistics`).

There is one API, and it is this one. `Loop`, `Registry` and `Remote` are types of this module that
carry exactly the surface named in `src/core/surface.zig` and forward to the host's backend; the
backend's other public functions serve its own files, the benchmarks and the conformance suite,
which live in rotor's tree, and a dependent package cannot name a backend at all: the build
registers this module alone. A program that needs what the backends keep for themselves is a program
inside this tree.

## A loop

```zig
const options: rotor.Loop.Options = .{ .operations = 1024 };
var memory: [rotor.Loop.memory_bytes(options)]u8 align(rotor.memory_alignment) = undefined;
var loop: rotor.Loop = undefined;
try loop.init(&memory, options);
defer loop.deinit();
```

- `operations` is the most operations the loop holds in flight at once, and what sizes its
  tables: at most `constants.operations_max`, 2^20.
- `entries` sizes the io_uring submission ring. Left at 0 it is `operations` rounded up to a
  power of two, capped at 32,768; kqueue takes it and sizes nothing by it.
- `memory_bytes` is a function of the options, and `init` asserts the block is large enough and
  aligned to `memory_alignment`. The memory is the loop's until `deinit`.
- `init` must run on the thread that will own the loop. Every other call on the loop asserts that
  it comes from that thread, and a call from another thread halts the process: it is a programmer
  error, not a condition the loop reports.
- `init` fails with `Unsupported` when the host's kernel lacks what the backend needs (below), and
  with `SystemResources` when a descriptor or memory limit refuses the ring, the epoll instance or
  the kqueue. A kernel that refuses io_uring does not fail `init` on Linux: the process runs epoll.
- `deinit` requires an empty loop: nothing in flight. `cancel_all` then `drain` gets there.

The other options: `id` and `registry` for a loop that posts to others (below), `sampling` for the
statistics, `spin_budget_ns` for a loop that polls before it sleeps, and `file_policy`, `offload`
and `offload_memory` for files on macOS and on epoll (below).

`spin_budget_ns` is 0 by default, and then a tick that is given a wait blocks at once, as it always
has. With a budget, at most `rotor.constants.spin_budget_ns_max`, a tick given a longer wait first
ticks without waiting for up to that long, and blocks for the rest of the wait only if nothing came
(decision 13). The window runs from the loop's last event, so a loop whose work has stopped spends
its budget once and then sleeps. A message another loop posts inside the budget arrives without the
kernel waking this one. In that record's measurement on io_uring, loops with a 50 µs budget, each
message 20 µs after the last, made a round trip in 2.7 to 4.2 µs against 18 to 32 µs for loops
that waited (`bench/results/decision-13-spin-budget-github-2026-09-24.md`). The cost is the CPU:
each message that comes after the budget costs the budget in polling, which at one message every
100 µs was about half a core (`bench/results/decision-13-idle-github-2026-09-24.md`). A tick given no wait, or a wait no longer than the budget, never polls, and nor
does one whose next timer is due inside the budget.

## Submit and tick

```zig
var handles: [2]rotor.Handle = undefined;
const taken = loop.submit(&.{
    rotor.Operation.receive(1, socket, &buffer),
    rotor.Operation.timer(2, rotor.constants.ns_per_s, 0),
}, &handles);
var events: [64]rotor.Event = undefined;
const count = try loop.tick(&events, rotor.constants.ns_per_ms);
```

`Operation` has one constructor per kind (`accept`, `connect`, `receive`, `receive_group`, `send`,
`shutdown`, `close`, `read`, `write`, `fdatasync`, `timer`, `post`, `receive_from`, `send_to`),
each building the common shape in one call. Set `timeout_ns` or `descriptor_registered` on the
result when either is wanted, and write the struct out for a receive into a registered buffer.

- `submit` takes a batch of operations, at most `constants.batch_max` (4,096), and returns how
  many it took. It takes fewer when the table has no room for the rest; the caller submits those
  again later. `handles` is either empty or one per operation, and receives the handle of each
  operation taken, which is what `cancel` takes.
- `tick` makes the loop's one system call, delivers events into `events` and returns how many. With
  `wait_ns` of 0 it polls and returns at once; otherwise it blocks until an event is ready, a
  message arrives, or the wait passes, at most `constants.wait_ns_max`, 10 seconds. A longer wait
  halts, as does an `events` that is empty or longer than `batch_max`, on every backend and whether
  or not the tick would have waited. A tick that already holds events to return does not wait. `tick` fails only when the kernel refuses the call
  after `interrupt_retries_max` signals, or answers something rotor has no meaning for.
- `now_ns` returns the monotonic clock in nanoseconds as the last `tick` read it, at its start or
  after its wait. Timers expire against that reading. It is 0 until the first tick, and reading it
  makes no system call. A caller that keeps timeouts of its own can read the time here instead of
  reading a clock itself. A timer submitted now fires no earlier than `now_ns` plus its `after_ns`,
  because the next tick arms it at that tick's own reading.
- Batch first. One `submit` of many operations and one `tick` returning many events is the shape
  rotor is built for; one operation per call works and costs a system call each.

An `Event` is 16 bytes:

- `user_data`: the value the caller put in the `Operation`. rotor never reads it. For a message
  posted by another loop, the message's payload.
- `result`: not negative is a byte count, a new descriptor, or 0; negative is `-@intFromEnum(Code)`,
  and `event.outcome()` turns it into `Error!u32`. For a message, the tag.
- `flags.more`: more events of this operation follow and its slot stays claimed. An event without
  `more` is the operation's final event. `flags.message`: another loop posted this; it belongs to
  no operation. `flags.buffer` and `flags.buffer_id`: which provided buffer holds this receive's
  bytes.

The rules every caller relies on (decision 5):

1. Every operation ends with exactly one final event, and its slot is freed by that event and by
   nothing else. A multishot operation delivers events flagged `more` until its final one.
2. `cancel(handle)` is a request. The answer is the operation's final event: `Canceled` when
   nothing was transferred, or the bytes that moved.
3. From `submit` to the final event, the buffer an operation names belongs to the loop: do not read,
   write, reuse or free it. This covers the `Address` a `connect` names and the `Outbound` a
   `send_to` names. Provided buffers change hands differently (below).
4. `timeout_ns` on an operation is a deadline the loop enforces by cancelling it; the final event
   then says `Timeout`.
5. Timers live in the loop and cost no descriptor. `timer{ .after_ns, .repeat_ns }`: one event, or
   one per period flagged `more` until cancelled, scheduled from the previous deadline and never
   from the clock.
6. `close` cancels every operation on that descriptor first, then closes it. Its final event says
   the descriptor is gone.
7. `deinit` requires an empty loop.

## The operations

Every `Operation` has `user_data`, an optional `timeout_ns`, `descriptor_registered` (below), and a
`kind`:

| kind | what it names | result |
|---|---|---|
| `accept` | a listener, `multishot` | the accepted socket, one event per connection when multishot |
| `connect` | a socket and an `*const Address` | 0 |
| `receive` | a socket and a target: a buffer, or a provided-buffer group; `multishot` with a group | bytes received, 0 at end of stream, which ends a multishot receive |
| `send` | a socket and a buffer | bytes sent; a short send is a result under the buffer's length |
| `shutdown` | a socket and `how` | 0 |
| `close` | a descriptor of the process | 0 |
| `read`, `write` | a file, a buffer and an offset | bytes moved |
| `fdatasync` | a file | 0 |
| `timer` | `after_ns`, optional `repeat_ns` | 0 per fire |
| `post` | a target `LoopId` and a `Message` | 0, or `mailbox_full`, `loop_not_found` |
| `nop` | nothing | 0 |
| `receive_from` | a socket and a datagram group | bytes, one event per datagram, until cancelled |
| `send_to` | a socket, a buffer and an `*const Outbound` | every byte of the buffer, or none |

Descriptors come from `rotor.sync`, which makes the calls a loop does not: `open_socket`,
`listen(&address, .{ .backlog, .reuse_port })`, `open_datagram(family, bind_to, .{})`,
`local_address`, `set_no_delay`, `set_option`, `set_buffer_bytes`, `close_now`, and for files
`open_file`, `file_size`, `set_file_size`, `sync_directory`. `Address` is rotor's own type,
IPv4 or IPv6 with a port and a scope id; no kernel type is part of the surface.

### Socket buffer sizes

`sync.set_buffer_bytes(descriptor, .receive, bytes)` asks the kernel for that much buffer on the
socket and **returns the size it actually set**, because the answer is rarely the request: Linux
stores twice what it is asked for and caps it at `net.core.rmem_max` for a caller without
`CAP_NET_ADMIN`, and macOS does neither. `.send` sizes the other one. `sync.socket_buffer_bytes_max`
is the largest request, which is what `setsockopt` carries.

A datagram receiver under load is what it is for. A UDP socket whose receive buffer is too small
drops what arrives while the loop is elsewhere, and no operation reports that: the datagram is gone
before rotor sees it. A resolver or a QUIC stack sizes the buffer at start-up and reads back what it
got.

## Buffers

Three ways to hand the loop memory for bytes:

- A plain `Buffer` or `ConstBuffer` in the operation. Simplest; rule 3 applies.
- Registered buffers: `register_buffers(&loop, buffers)` once, before use, at most
  `registered_buffers_max` (1,024). An operation then names one by index in `Buffer.registered`,
  and io_uring skips pinning its pages per operation. kqueue accepts the same calls and gains
  nothing from them.
- A provided-buffer group: `provide_buffers(&loop, group_id, memory, count, buffer_bytes)`, with
  `memory` one block of `buffers.group_bytes(count, buffer_bytes)` bytes aligned to
  `buffers.group_alignment`; the loop keeps its bookkeeping at the front and the buffers after it.
  `count` is a power of two. `Operation.receive_group` lets the kernel pick a buffer; the event
  carries `flags.buffer` and `buffer_id`, and `loop.provided_buffer(group_id, buffer_id)` is its
  bytes. The buffer is the caller's from that event until `loop.give_back_buffer(group_id,
  buffer_id)`, whether or not the receive has ended. A group that runs out ends a multishot
  receive with `buffers_exhausted`: give buffers back and submit it again. The end of the stream
  ends it too, with a final event of 0 that names no buffer. At most
  `buffer_groups_max` groups (16) of `buffers_per_group_max` (32,768).

  **Check the alignment you got, do not assume it.** io_uring requires the 64 KiB of
  `buffers.group_alignment` and rotor asserts it, so a misaligned group halts with a named assertion
  rather than arriving as an errno. Declaring `align(buffers.group_alignment)` on a static is enough
  on Linux, and on macOS such a static came back 16 KiB aligned on 2026-09-22, so a caller that must
  build on both aligns forward inside a larger block:

  ```zig
  var backing: [bytes + buffers.group_alignment]u8 align(buffers.group_alignment) = undefined;
  const start = std.mem.alignForward(usize, @intFromPtr(&backing), buffers.group_alignment);
  const memory: []align(buffers.group_alignment) u8 =
      @as([*]align(buffers.group_alignment) u8, @ptrFromInt(start))[0..bytes];
  ```

  The kqueue backend needs only the alignment of its own free list, so under-aligned memory works
  there and fails on Linux. That asymmetry is why the assertion on the io_uring side is worth having:
  it is where a caller who trusted the declaration finds out.

  **Size a group to the buffers in flight, not to the memory you can spare.** On io_uring the kernel
  takes buffers from the head of the group's ring and `give_back_buffer` returns them at the tail,
  so a group of `count` buffers is used in order and every receive lands in the buffer returned
  longest ago. A large group is therefore a large working set, and every receive writes into memory
  that is cold in cache and TLB. A 64 MiB group of 64 KiB buffers cost 22 µs of kernel time per
  echo on the `orbstack` machine, and 32 buffers cost 7.5
  (`bench/results/cpu-orbstack-2026-09-22.md`). A connection holds a buffer from its receive's event
  until the caller gives it back, so two per connection is enough for an echo, and a group that
  runs out ends the receive with `buffers_exhausted` rather than losing bytes. On kqueue and epoll
  the loop reuses the buffer returned last, so the size costs only memory there.

Registered descriptors work the same way: `register_descriptors(&loop, descriptors)` once, at
most `registered_descriptors_max` (1,024), and an operation with `descriptor_registered = true`
names an index instead of a descriptor. A `close` always names a descriptor of the process.

## Datagrams

A datagram group is a provided-buffer group with room in front of every buffer for the peer
address and the control messages: `provide_datagram_buffers(&loop, group_id, memory, count,
buffer_bytes, .{})`, from one block as above. One loop serves one datagram shape. `receive_from`
receives into it, one event per datagram, and `loop.datagram(group_id, event)` is the only reader
of such a buffer: it returns a `Delivery` with the peer, the local address when the socket was asked
for it, the ECN
codepoint, the segment size when the kernel coalesced several datagrams into one, and the bytes.
`send_to` takes an `Outbound`: the destination, the source address, the codepoint, and whether to
cut the buffer into segments. GSO, GRO and ECN are Linux; macOS answers a segmented send with
`unsupported` (decision 15).

## Files

io_uring performs `read`, `write` and `fdatasync` without a thread. kqueue and epoll report
readiness and never complete a file operation, so on macOS, and on Linux where the process runs
epoll, the loop needs to be told what to do. `rotor.files_block` is true on both, because on Linux
a process may run either backend; a caller that sets a policy there is right on both:

- `file_policy = .refuse`, the default: a file operation ends with `unsupported`. Nobody is quietly
  slowed.
- `.blocking`: the loop performs it inline, and the tick stalls for its duration.
- `.offload`: the loop hands it to the caller's threads. `offload` is an `Offload`: a context, a
  `submit` function the loop calls with a `Work` the worker runs, and the number of workers, at
  most `offload_workers_max` (64). `offload_memory` is `rotor.offload_memory_bytes(workers)`
  bytes of the caller's, because the caller's threads write it. `bench/files/reads_pool.zig` is a
  pool that does this.

`offload` is required under `.offload` and must be null under the other two policies. io_uring
checks the options as kqueue and epoll do, so options that halt on one backend halt on all of them,
and then ignores them. A loop that never touches a file needs none of this.

A caller that hands a loop an offload stops the offload's threads before the loop's `deinit`, and
not before the loop is drained: a worker still inside `Work.run` reads the loop after its result is
visible (decision 18).

## Threads

A loop belongs to one thread, holds no lock and starts no thread. The one thing another thread
may do to it is post a message:

- Loops that post to each other share a `Registry`: `Registry.memory_bytes(loops)` bytes of the
  application's memory, `registry.init(&memory, loops)` once, and each loop gets an `id` below
  `loops` and the `registry` in its options. `post{ .target, .message }` from one loop arrives in
  the target's next tick as an event with `flags.message`, `user_data` the payload and `result`
  the tag (at most `message_tag_max`). The sender's own final event says 0, `mailbox_full` or
  `loop_not_found`. On kqueue and epoll the mailbox between two loops holds `mailbox_messages`
  (256); on io_uring a full target overflows into kernel memory. `rotor.post_bounded` is true on
  Linux, because a process there may run either.
- A thread that owns no loop holds a `Remote`: `remote.init(&registry, id)` on that thread, taking
  one id of the registry, and `remote.post(target, message)` returns `Remote.PostError` where a
  loop's post produces an event: `MailboxFull`, `LoopNotFound`, and on io_uring `SystemResources`,
  `Unanswered` (the kernel took the message and had not answered within a second; it may still
  land) and `Unexpected`. A `Remote` belongs to one thread as a loop does.
- The offload's workers answer through rings of their own, not through a `Remote`.

At most `loops_max` (256) loops and remotes share one registry.

## A library that shares a loop

A library such as a resolver takes a `*Loop` from the application and owns no socket, thread or
loop of its own. What that needs:

- The application owns the loop, calls `tick`, and hands the library the events that are its. An
  event carries `user_data` and nothing else that names its owner, so the two agree on a
  convention: a range of `user_data`, or a bit in it, that the library's operations use.
- The library submits on the loop's thread only. A caller on another thread reaches it through a
  `Remote` and a message whose tag the library defines.
- The library's operations in flight count against the loop's `operations`, and its buffers
  against the loop's groups. The application sizes the loop for both.
- `timeout_ns` on a `receive_from` and a `timer` per retry are what a query needs; `cancel` with
  the handle ends either early.

## Statistics

`loop.statistics()` is sampled: one operation in `sample_mask + 1` records its latency into
power-of-two buckets, per kind, and nothing else is counted (decision 9). Nothing logs on the
loop's path.

## Limits

Every limit is a named constant in `rotor.constants`, or in a backend's own `constants.zig`:

| limit | value |
|---|---|
| operations in flight per loop | `operations_max`, 2^20 |
| operations per `submit`, events per `tick` | `batch_max`, 4,096 |
| a tick's wait | `wait_ns_max`, 10 s |
| a deadline or a timer | `timeout_ns_max`, one day |
| one transfer | `transfer_bytes_max`, 2,147,479,552 bytes |
| loops and remotes per registry | `loops_max`, 256 |
| offload workers | `offload_workers_max`, 64 |
| registered descriptors, registered buffers | 1,024 each |
| provided-buffer groups, buffers per group | 16, 32,768 |
| a message's tag | `message_tag_max`, 0x7fff_f000 |
| messages queued from one loop to another (kqueue) | `mailbox_messages`, 256 |
| registrations in, readiness out, per tick (kqueue) | `changes_max`, `readiness_max`, 256 |

## What the kernel must have

- Linux 6.1 or later, with io_uring: `IORING_FEAT_NODROP`, `IORING_FEAT_EXT_ARG`, `MSG_RING`,
  multishot accept and receive, provided buffer rings, `SINGLE_ISSUER` and `DEFER_TASKRUN`. A
  kernel that lacks one of these, or refuses io_uring itself as Docker's default seccomp profile
  does, gets the epoll backend instead (above): the process asks for a ring with the same flags,
  features and opcodes a loop needs. `tools/uring_probe.zig` names the first thing a kernel lacks.
- macOS with kqueue. Files need a policy (above). A loop that polls carries its own wake trigger
  in the `kevent` call, because a poll that finds nothing ready parks the thread for about 12 µs
  on macOS 26 otherwise (decision 12, point 6).

## Not in version one

TLS (chapulin fills that interface for colibri), DNS (cocuyo), Unix sockets, process spawning,
Windows and the `std.Io` adapter. Decision 2 says why, and what would bring each in. The epoll
backend was on this list until decision 20 brought it in.

## Where the numbers are

`docs/costs.md` holds the measured costs of the operations the design arguments cite, for the
`mac`, `orbstack` and `github` machines. `docs/benchmarks.md` holds the current comparison against
libuv and libxev and the commands that take it, `bench/alternatives/README.md` records every
experiment behind it, the losing rows included, and `bench/results/` holds every run as printed. The Linux machine rotor is meant to be deployed on is not named yet, so no claim is made
for it.
