# Using rotor

This is the guide for a program or a library that runs on rotor. It says what rotor promises, what
it needs from the caller, and where the limits are. The decision records in `docs/decisions/` say
why. This file says what.

rotor is one Zig module. It allocates nothing: the caller gives each loop its memory at init, and a
named limit bounds each table and each queue. A loop belongs to one thread. Each operation ends with
exactly one final event. These three rules shape the rest of this guide.

The guide has two parts:

- **[A loop](#a-loop).** The plain `rotor.Loop`: operations and their events, buffers, datagrams,
  files, messages between loops, statistics and stalls. Its 28 names are the core's surface
  (decisions 1 and 33).
- **[A reactor](#a-reactor).** `rotor.Reactor(rotor.Loop)`: a loop with records that have
  callbacks, pollers, tasks, scheduling groups, cross-core calls, and a view that several libraries
  share (decisions 26 to 33). Its last section is for the author of a twin (decision 10).

A program that needs nothing of the second part makes a `rotor.Loop`, and its binary holds no code
of the reactor. Zig compiles only what a program names.

The code here runs. Each Zig block is part of a program under [`examples/`](../examples), or of the
consumer project in [`examples/consumer/`](../examples/consumer), line for line.
[`examples/guide.zig`](../examples/guide.zig) runs the code of both parts in order. `zig build test`
builds and runs each program, and the Linux gate runs each one with io_uring and with epoll.

This guide describes the tree on `main`. Release v0.10.0 does not have the split of decision 33.
Release v0.11.0 will carry it.

## Getting the module

```bash
zig fetch --save git+https://github.com/c4milo/rotor#v0.10.0
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

A program that cannot take whichever backend the kernel allows names one itself:
`rotor.require_backend(.epoll)`, or `.uring` or `.kqueue` (decision 23). It is the first call the
program makes on the module, because `sync`, a `Registry`, a `Loop` and `backend()` each make the
choice when none is made, and the choice holds for the life of the process. The call answers
`RequireError`: `OtherBackendChosen` when the process already runs another backend, and
`Unsupported` when this host cannot run the one asked for, which covers `.uring` on a kernel that
refuses a ring. It never falls back, and an error stores nothing. Requiring the backend the process
already runs succeeds.

What the module exports:

| for | names |
|---|---|
| a loop | `Loop`, `Registry`, `Remote`, `Offload`, `Statistics`, `Heartbeat` |
| a reactor | `Reactor`, `SharedLoop`, `Completion`, `Poller`, `Task`, `SchedulingGroup`, `NamedSchedulingGroup`, `SchedulingGroupName`, `named_scheduling_group` |
| cross-core calls | `Service`, `CallRecord`, `Answer`, `CallResult`, `CallOptions`, `CallError`, `CallLink`, `CallStation` |
| operations and events | `Operation`, `Event`, `Handle`, `Address`, `Message`, `LoopId`, `Descriptor`, `Code`, `Error`, `Delivery`, `WaitLimit`, `BufferGroup` |
| the backend | `backend`, `require_backend`, `Backend`, `RequireError`, and the flags `files_block`, `post_bounded` and `supported` |
| helpers | `sync`, `buffers`, `memory_alignment`, and the namespaces `constants`, `datagram`, `offload` and `statistics` |

`Loop` declares its six error sets: `InitError`, `TickError`, `DrainError`, `RegisterError`,
`ProvideError` and `PostError`. A reactor declares its own (A reactor, below).

There is one API, and it is this one. `Loop`, `Registry` and `Remote` are types of this module that
carry exactly the surface named in `src/core/surface.zig` and forward to the host's backend.
`Reactor(Loop)` holds a `Loop` and the reactor's state of the module `reactor`. A backend's other
public functions serve its own files, the benchmarks and the conformance suite, which live in
rotor's tree. A dependent package cannot name a backend at all: the build registers this module
alone. A program that needs what the backends keep for themselves is a program inside this tree.

## A loop

### Start and end a loop

```zig
const options: rotor.Loop.Options = .{ .operations = 1024 };
var memory: [rotor.Loop.memory_bytes(&options)]u8 align(rotor.memory_alignment) = undefined;
var loop: rotor.Loop = undefined;
try loop.init(&memory, &options);
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
- `deinit` requires an empty loop: nothing in flight. `cancel_all` asks each operation in flight
  to end. Then `drain` ticks until nothing is in flight. It fails with `StillInFlight` after
  `drain_rounds_max` (1,024) ticks.
- `in_flight()` returns how many operations are in flight. `assert_empty()` halts while an
  operation is in flight, and inside a tick.

The other options: `id` and `registry` for a loop that posts to others (below), `sampling` and
`stall_turn_ns` for the statistics, `spin_budget_ns` for a loop that polls before it sleeps, and
`file_policy`, `offload` and `offload_memory` for files on macOS and on epoll (below).

`spin_budget_ns` is 0 by default, and then a tick that is given a wait blocks at once, as it always
has. With a budget, at most `rotor.constants.spin_budget_ns_max`, a tick given a longer wait first
ticks without waiting for up to that long, and blocks for the rest of the wait only if nothing came
(decision 13). The window runs from the loop's last event, so a loop whose work has stopped spends
its budget once and then sleeps. A message another loop posts inside the budget arrives without the
kernel waking this one. In that record's measurement on io_uring, loops with a 50 µs budget, each
message 20 µs after the last, made a round trip in 2.7 to 4.2 µs against 18 to 32 µs for loops that
waited (`bench/results/decision-13-spin-budget-github-2026-09-24.md`). The cost is the CPU: each
message that comes after the budget costs the budget in polling, which at one message every 100 µs
was about half a core (`bench/results/decision-13-idle-github-2026-09-24.md`). A tick given no wait,
or a wait no longer than the budget, never polls, and nor does one whose next timer is due inside
the budget.

On macOS a budget costs time as well as CPU. A message that comes after the budget arrives about
11 µs later than it would with no budget: 12.5 to 14.5 µs against 1.0 to 3.5 µs, measured on an
M1 Pro on 2026-09-25 (`bench/results/decision-13-idle-kqueue-mac-2026-09-25.md`). The loop that
spun is slower to wake when the message comes. Why is not known. A macOS caller should set a budget
only when most messages come inside it.

### Submit and tick

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
`shutdown`, `close`, `read`, `write`, `fdatasync`, `fsync`, `timer`, `post`, `receive_from`,
`send_to`), each building the common shape in one call. Set `timeout_ns` or `descriptor_registered`
on the result when either is wanted, and write the struct out for a receive into a registered
buffer.

- `submit` takes a batch of operations, at most `constants.batch_max` (4,096), and returns how
  many it took. It takes fewer when the table has no room for the rest; the caller submits those
  again later. `handles` is either empty or one per operation, and receives the handle of each
  operation taken, which is what `cancel` takes.
- `tick` makes the loop's one system call, delivers events into `events` and returns how many. With
  `wait_ns` of 0 it polls and returns at once; otherwise it blocks until an event is ready, a
  message arrives, or the wait passes, at most `constants.wait_ns_max`, 10 seconds. A longer wait
  halts, as does an `events` that is empty or longer than `batch_max`, on every backend and whether
  or not the tick would have waited. A tick that already holds events to return does not wait.
  `tick` fails only when the kernel refuses the call after `interrupt_retries_max` signals, or
  answers something rotor has no meaning for.
- `now_ns` returns the monotonic clock in nanoseconds as the last `tick` read it, at its start or
  after its wait. Timers expire against that reading. It is 0 until the first tick, and reading it
  makes no system call. A caller that keeps timeouts of its own can read the time here instead of
  reading a clock itself. A timer submitted now runs its `after_ns` from `now_ns`, as libuv's and
  libxev's timers run from the loop's cached time: it is due at `now_ns` plus its `after_ns`, and
  fires no earlier. A caller that works long after a tick before it arms a timer gets a timer that
  is due that much sooner after the call. A timer submitted before the first tick runs from that
  tick's reading. An operation's deadline (`timeout_ns`) still runs from the tick that hands the
  operation to the kernel.
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
- `flags.dispatched`: the operation named a reactor's record (Records, below). A plain loop calls no
  record. It gives such an event to the caller of `tick`, with the bit set, as any other event.

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
   the descriptor is gone. A file operation out on an offload's worker cannot be cancelled, so the
   close waits for its result (Files, below).
7. `deinit` requires an empty loop.

### The operations

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
| `fdatasync` | a file: its data, and the metadata a later read needs, such as its size | 0 |
| `fsync` | a file: its data and all of its metadata, such as its times and permissions | 0 |
| `timer` | `after_ns`, optional `repeat_ns` | 0 per fire |
| `post` | a target `LoopId` and a `Message` | 0, or `mailbox_full`, `loop_not_found` |
| `nop` | nothing | 0 |
| `receive_from` | a socket and a datagram group | bytes, one event per datagram, until cancelled |
| `send_to` | a socket, a buffer and an `*const Outbound` | every byte of the buffer, or none |

Descriptors come from `rotor.sync`, which makes the calls a loop does not: `open_socket`,
`listen(&address, .{ .backlog, .reuse_port })`, `open_datagram(family, bind_to, .{})`,
`local_address`, `set_no_delay`, `set_buffer_bytes`, `close_now`, and for files
`open_file`, `file_size`, `set_file_size`, `sync_directory`. `Address` is rotor's own type,
IPv4 or IPv6 with a port and a scope id; no kernel type is part of the surface.

#### Socket buffer sizes

`sync.set_buffer_bytes(descriptor, .receive, bytes)` asks the kernel for that much buffer on the
socket and **returns the size it actually set**, because the answer is rarely the request: Linux
stores twice what it is asked for and caps it at `net.core.rmem_max` for a caller without
`CAP_NET_ADMIN`, and macOS does neither. `.send` sizes the other one. `sync.socket_buffer_bytes_max`
is the largest request, which is what `setsockopt` carries.

A datagram receiver under load is what it is for. A UDP socket whose receive buffer is too small
drops what arrives while the loop is elsewhere, and no operation reports that: the datagram is gone
before rotor sees it. A resolver or a QUIC stack sizes the buffer at start-up and reads back what it
got.

### Buffers

Three ways to hand the loop memory for bytes:

- A plain `Buffer` or `ConstBuffer` in the operation. Simplest; rule 3 applies.
- Registered buffers: `register_buffers(&loop, buffers)` once, before use, at most
  `registered_buffers_max` (1,024). An operation then names one by index in `Buffer.registered`,
  and io_uring skips pinning its pages per operation. kqueue accepts the same calls and gains
  nothing from them.
- A provided-buffer group. First `const group = try loop.reserve_buffer_group()`, once: it
  returns the lowest group id that no caller holds, as a `rotor.BufferGroup`, which is yours until
  the loop's `deinit` (decision 29). Each call that names a group takes that type, so a literal id
  fails to compile, and two libraries on one loop cannot take the same group. It returns
  `error.BufferGroupsFull` when every id is reserved. Then
  `provide_buffers(&loop, group, memory, count, buffer_bytes)`, with
  `memory` one block of `buffers.group_bytes(count, buffer_bytes)` bytes aligned to
  `buffers.group_alignment`; the loop keeps its bookkeeping at the front and the buffers after it.
  `count` is a power of two. A provide with a group that no caller reserved halts.
  `Operation.receive_group` lets the kernel pick a buffer; the event
  carries `flags.buffer` and `buffer_id`, and `loop.provided_buffer(group, buffer_id)` is its
  bytes. The buffer is the caller's from that event until `loop.give_back_buffer(group,
  buffer_id)`, whether or not the receive has ended. A group that runs out ends a multishot
  receive with `buffers_exhausted`: give buffers back and submit it again. The end of the stream
  ends it too, with a final event of 0 that names no buffer. At most
  `buffer_groups_max` groups (16) of `buffers_per_group_max` (32,768).

  `loop.release_buffers(group)` takes a group back: its memory is yours again, and you may
  provide the group again. The id stays reserved: no call gives it back. Call it after the final
  event of every receive from the group. It halts while an operation still names the group. A
  buffer you hold at the release is plain memory, and its `give_back_buffer` halts. A library that
  stops and starts on a loop that lives on releases its group at the stop, and so uses one id and
  not one for each start.

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
  there and fails on Linux. That asymmetry is why the assertion on the io_uring side is worth
  having: it is where a caller who trusted the declaration finds out.

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

### Datagrams

A datagram group is a provided-buffer group with room in front of every buffer for the peer address
and the control messages: `provide_datagram_buffers(&loop, group, memory, count, buffer_bytes,
.{})`, with a group that `reserve_buffer_group` gave and one block as above. One loop serves one
datagram shape: the first datagram group fixes it, and a later group with different options halts,
because the loop reads every datagram at the offset that shape gives. `receive_from` receives into
it, one event per datagram, and `loop.datagram(group, event)` is the only reader of such a buffer:
it returns a `Delivery` with the peer, the local address when the socket was asked for it, the ECN
codepoint, and the bytes. `send_to` takes an `Outbound`: the destination, the source address, the
codepoint, and whether to cut the buffer into segments. GSO, GRO and ECN are Linux; macOS answers a
segmented send with `unsupported` (decision 15).

On Linux a socket coalesces by default (`DatagramOptions.coalesce`): the kernel takes several
datagrams from one peer in one receive. The loop splits them again, and each datagram comes as an
event of its own, so nothing in your code changes. Give back every event's buffer, as for any
datagram: several events of one coalesced datagram name the same buffer, and it goes back to the
group at the last. Coalescing needs buffers that hold 65,535 bytes of payload: a `buffer_bytes` of
at least `datagram.prefix_bytes(.{}) + constants.coalesced_bytes_max`, rounded up to a multiple of
8, as every datagram group's buffer size must be. A receive on a group with smaller buffers turns
coalescing off for its socket, so no datagram is cut short. Set `.coalesce = false` to turn it off
yourself. One segmented send carries at most 65,507 bytes over IPv4, in at most `segments_max` (64)
segments.

A multishot receive can end with a success. On io_uring the kernel can end it after 32 datagrams,
and the last datagram is then the final event. Submit the receive again when an event without
`more` carries bytes.

### Files

io_uring performs `read`, `write`, `fdatasync` and `fsync` without a thread. kqueue and epoll report
readiness and never complete a file operation, so on macOS, and on Linux where the process runs
epoll, the loop needs to be told what to do. `rotor.files_block` is true on both, because on Linux
a process may run either backend; a caller that sets a policy there is right on both:

- `file_policy = .refuse`, the default: a file operation ends with `unsupported`. Nobody is quietly
  slowed.
- `.blocking`: the loop performs it inline, and the tick stalls for its duration.
- `.offload`: the loop hands it to the caller's threads. `offload` is an `Offload`: a context, a
  `submit` function the loop calls with a `Work` the worker runs, and the number of workers, at
  most `offload_workers_max` (64). `offload_memory` is `rotor.Offload.memory_bytes(workers)`
  bytes of the caller's, because the caller's threads write it. `examples/offload.zig` is a
  bounded pool that does this, and `bench/files/reads_pool.zig` is the one the benchmarks use.

A loop has at most `offload_in_flight_max` (256) file operations out on its workers at a time.
An operation is out from the hand-out until the loop takes its result. A further file operation
stays queued, and a later tick hands it out when a result comes back. The loop does not refuse it,
and it gets its final event as every operation does. So an offload never holds more than 256 of one
loop's works at once (decision 18, amendment of 2026-11-06).

A queued file operation is the loop's alone, and the loop ends it as it ends any queued operation:

- Its deadline runs from the tick that queues it, as any operation's runs from the tick that hands
  it over, so `timeout_ns` ends it with `timeout` while it waits for room.
- A `cancel` ends it with `canceled` at the next tick, wherever it is in the queue.
- A `close` of its descriptor ends it with `canceled`, and the caller gets that event before the
  close's event.

An operation out on a worker is the worker's until its result comes back, and a `close` cannot end
it. So the close waits. The loop keeps the close, and the descriptor stays open, until each
operation out on the descriptor has its result. Then the loop closes the descriptor. The worker's
call always runs on the file it named, and you get its event before the close's event (decision 18,
ruling (d) of 2026-11-06).

- The close's deadline runs from the tick that keeps it. A `cancel`, or the deadline, ends a close
  that waits with `canceled` or `timeout`. The descriptor then stays open, because the close did not
  happen: close it again, or close it with `sync.close_now`.
- Submit nothing on a descriptor after its `close`. A file operation that goes out while the close
  waits makes the close wait for it too.
- Close a descriptor once. With or without an offload, a second `close` halts when the descriptor
  is closed, or closes a file that took its number.

`offload` is required under `.offload` and must be null under the other two policies. io_uring
checks the options as kqueue and epoll do, so options that halt on one backend halt on all of them,
and then ignores them. A loop that never touches a file needs none of this.

A caller that hands a loop an offload stops the offload's threads before the loop's `deinit`, and
not before the loop is drained: a worker still inside `Work.run` reads the loop after its result is
visible (decision 18). `examples/offload.zig` does the three steps in that order.

A file call that blocks under `.blocking` holds the loop for its whole length, and every other
operation and callback of the loop waits for it. The stall count sees it when its tick does not
block, and a watch sees it either way (Stalls, below). The offload moves the call to the caller's
threads, so the loop goes on.

### The stored limit

A plain loop has one stored limit, which bounds the wait of each tick. Only the program writes it,
with `wait_until` (decision 33):

```zig
const deadline_ns = loop.now_ns() + rotor.constants.ns_per_ms;
loop.wait_until(.at(deadline_ns));
_ = try loop.tick(events, rotor.constants.ns_per_s);
```

- `.at(t)`: a tick that would block waits until `t` on the loop's clock, at the latest. A timer
  before `t` still ends the wait first.
- `.now`: each tick waits 0 ns.
- `.none`, the value at init: the limit bounds nothing, and each tick waits what its caller gives.
- The limit stays across ticks until the program writes it again.
- The tick compares the limit with its own clock stamp, as it compares the nearest timer (decision
  29, item 2).

A program with several deadlines of its own, such as those of a QUIC stack, writes the least of them
before each tick. A deadline that moves then needs no timer, and no cancel of the old timer.
`wait_until` makes the owner check, as each call of the program does. A reactor refuses it at
compile time, because its pollers bound its wait (Pollers, below).

### Threads

A loop belongs to one thread, holds no lock and starts no thread. The one thing another thread
may do to it is post a message:

- Loops that post to each other share a `Registry`: `Registry.memory_bytes(loops)` bytes of the
  application's memory, `registry.init(&memory, loops)` once, and each loop gets an `id` below
  `loops` and the `registry` in its options. `post{ .target, .message }` from one loop arrives in
  the target's next tick as an event with `flags.message`, `user_data` the payload and `result`
  the tag (at most `message_tag_max`). The sender's own final event says 0, `mailbox_full` or
  `loop_not_found`. On every backend the mailbox between two loops holds `mailbox_messages`
  (256), of which a post sees `mailbox_posts_max` (224): the rest wait for the returns of
  cross-core calls (decision 32). `rotor.post_bounded` is true. A loop that sleeps is woken by the
  post that finds it asleep: on io_uring with an `IORING_OP_MSG_RING` that carries no message.
  Between two loops that are awake a message costs no system call on any backend.
- `rotor.Message.wake`, whose tag is `message_tag_wake`, is the one message that makes no event.
  A plain loop drops it. On a reactor with a poller added, the next tick calls the pollers before it
  blocks (decision 29, and Pollers, below).
- A loop can also send one message with `loop.post(target, message)`, which takes no operation:
  the message is in the target's mailbox when it returns, there is no final event, and it returns
  `Loop.PostError`, `MailboxFull` or `LoopNotFound`. It costs the sender about half the work of a
  post operation, because no tick has to hand an event over. A target that sleeps is woken at once
  on kqueue and epoll, and by the sender's next tick on io_uring. A sender that calls `deinit`
  before that tick sends the wake in `deinit`. A wake the kernel refuses is no error: the message
  is in the mailbox, and the target reads it when its wait ends. `loop.dropped_wakes()` says how
  many wakes the loop dropped since `init`, on every backend: in `post`, in a tick that sends the
  wakes of post operations, and in `deinit`. It is still readable after `deinit`, until the next
  `init`. A target that stopped refuses its wake, so a normal shutdown can leave the count above 0.
  On io_uring it is a lower bound, as a remote's is. A burst to one loop is cheaper as post
  operations in one submit, whose tick wakes the target once.
- A thread that owns no loop holds a `Remote`: `remote.init(&registry, id)` on that thread, taking
  one id of the registry, and `remote.post(target, message)` returns `Remote.PostError` where a
  loop's post produces an event: `MailboxFull` or `LoopNotFound`. `SystemResources`, `Unanswered`
  and `Unexpected` are still in the set and no backend returns them since 2026-09-25. A wake the
  kernel refuses is no error: the message is in the mailbox, and the target reads it when its wait
  ends. `remote.dropped_wakes()` says how many wakes the remote dropped since `init`, and it is
  still readable after `deinit`. On io_uring it is a lower bound: an answer the kernel posts after
  the remote's last enter is not read. A `Remote` belongs to one thread as a loop does.
- The offload's workers answer through rings of their own, not through a `Remote`.
- The registry keeps the descriptor that wakes each loop until `registry.deinit()`, so a
  sender that read it never wakes a descriptor that a later open got. The first loop of each id
  makes it. Call `deinit` once every loop and remote of the registry ended and every thread
  that posts to them stopped: an id still held halts it. Until then each id a loop held keeps one
  descriptor open, and a kqueue or io_uring loop holds two more while it runs (decision 4,
  amendment of 2026-11-06).

At most `loops_max` (256) loops and remotes share one registry.

### Loops in several processes

Loops that run in different processes can post to each other in the same way (decision 21). They
share a registry that lives in memory every process maps, and each loop keeps its own memory, as a
loop in one process does.

1. One process, the creator, maps `Registry.memory_bytes(loops)` bytes with `MAP_SHARED`
   (`memfd_create`, `shm_open`, or an anonymous mapping made before it forks) and calls
   `registry.init_group(memory, loops)`. It makes one wake per loop: a pipe on macOS, an eventfd on
   Linux. It returns `Registry.GroupError` when the process has no descriptor left for one.
2. The creator then starts the other processes: with `fork`, or by spawning them with the wakes
   kept open at the same numbers. rotor makes the wakes without close-on-exec for this. No
   descriptor moves between processes after they start.
3. Each other process maps the same memory and calls `registry.attach(memory)`, which answers
   `Registry.AttachError` when the memory holds no group this build of rotor laid out.
4. Every process runs loops and remotes with ids of that registry, as in one process. Which process
   runs which ids is the application's choice.

A message is 16 bytes and rotor reads none of them, so between processes a payload that points at
memory must be an offset into memory both processes map: a pointer means something in one process
only. A message cannot carry a socket to another process either; each process accepts its own
connections. A cross-core call carries an address, so a reactor of a group makes no call and serves
no service: each halts there.

When a process dies, the application learns it (a `pidfd` on Linux, `EVFILT_PROC` on macOS, or its
supervisor), and a surviving process calls `registry.release(id)` for each loop the dead one ran.
Posts to those ids are then refused as `loop_not_found`. A new process started by the creator may
then run loops with those ids, and is handed what was posted to the dead loop and not read.
`release` is only for a process known to be dead: one that is only stopped would come back to find
a second loop on its rings. Each process calls `registry.deinit()` when it is done with the
group.

A macOS process holds two descriptors per loop of the group. The default limit a macOS process
starts with was 256 descriptors on an M1 Pro with macOS 26.6.2 (`launchctl limit maxfiles`,
2026-09-25), so a group of more than about 100 loops needs a higher limit.

Processes that share a registry trust each other as threads of one process do: each can write any
byte of it.

### A host that owns the wait

Some programs cannot block inside `tick`, because other things must wake them too: a worker that
runs inside another program's wait, for example. Such a host sleeps in a wait of its own and ticks
the loop when the loop has something to deliver (decision 23).

- **On Linux the host requires epoll first**: `rotor.require_backend(.epoll)`, before anything else
  of the module. An io_uring loop has nothing a host can wait on: the kernel posts a completion
  only when the loop's own thread enters the ring, so nothing wakes that thread while it sleeps
  elsewhere. On macOS there is nothing to require.
- **`loop.wait_descriptor()` is what the host waits on**: the loop's kqueue, or its epoll instance.
  It answers null on io_uring. The host adds it to its own wait for read readiness. rotor's tests
  wait with a second epoll instance on Linux and a second kqueue on macOS.
- **The host's cycle** (decision 29): tick with a wait of 0. Call `loop.wait_limit()` as the last
  call before the sleep, and tick again on `.now`. Then sleep in the host's own wait, with the
  descriptor among what it waits on: on `.at(t)` for `t -| loop.now_ns()` at most, and on `.none`
  for as long as the host's own wait allows. `wait_limit` reads no clock and changes nothing. It
  answers `.now` while an operation waits to be submitted, a result waits to be handed over, a ring
  holds a message or a worker's result, or the last tick kept a kernel error. Otherwise it answers
  the least of the nearest timer and the stored limit, and `.now` when that is due. It halts inside
  a tick. The host runs the same ticks after it submits or cancels, before it waits, because an
  operation reaches the kernel in a tick.
- **Every tick gets a wait of 0.** A tick that blocks arms the loop's wait timer, which makes the
  descriptor readable later for no operation.
- **The host does nothing else to the descriptor.** It does not read it, close it, or change what
  it holds, and it stops waiting on it before `deinit`.
- **The host sets `stall_turn_ns = null`, and watches no heartbeat.** Its sleep is between two
  ticks, so it reads as one long turn, and every sleep would count as a stall (decision 28).

What the descriptor does not report, so that the host wakes for it by its own means:

- **A timer, a stored limit or an operation's deadline that comes due.** A tick finds those by
  reading the clock. The host bounds its own wait by what `wait_limit` answers.
- **A message or a wake another loop or a `Remote` posts, and an offload worker's result.** Only a
  loop that blocks in `tick` asks to be woken for those.

There is one more limit. While an operation of the loop waits on a descriptor, the wait descriptor
is not readable after a tick that delivers nothing. While none waits, a tick with a wait of 0 asks
the kernel nothing, so readiness the kernel holds for no operation stays, and the host's wait ends
at once each time until an operation waits again. On epoll that is bytes that arrive on a socket
whose last receive has completed. On kqueue it is bytes that arrive on a socket whose receive was
cancelled or ended by its timeout. A host that keeps an operation waiting, such as a receive on
its socket, meets neither. Decision 23 has the measurements under its open questions.

A host that ticks a reactor reads `wait_limit` on the reactor (A reactor, "A host that owns the
wait", below).

### Statistics

`loop.statistics()` holds two kinds of count. Latencies are sampled: one operation in
`sample_mask + 1` records its latency into power-of-two buckets, per kind (decision 9). Stalls are
exact (decision 9, rule 7, and decision 28). Nothing logs on the loop's path. A program reads the
statistics between ticks, and exports them.

### Stalls

A callback or a part of the program that runs long holds the loop, and every other operation of the
loop waits. rotor gives a count to see such a stall after it ends, and a heartbeat to see one while
it lasts (decision 28). The stall count, the stamp and the heartbeat are the loop's, so a plain loop
has them too. Only a reactor calls a callback, and it names each callback on the heartbeat.

A **stamp** is a value of the clock that a tick reads: one at its start, and one after a wait that
blocked. A **turn** runs from one stamp to the next tick's first stamp. It holds the callbacks of
the last tick, the program's own code between the two ticks, and the pollers of the next tick. A
kernel wait is never in a turn: the stamp after a wait starts a new one. A turn at or above
`Options.stall_turn_ns` is a **stall**. The default is `constants.stall_turn_ns_default`, 10 ms;
null counts no stall. The loop counts each stall in three fields of `statistics()`:

- `stalls`, the count;
- `stall_ns_max`, the longest;
- `last_stall`, a `statistics.Stall`: when the turn ended, how long it was, the callbacks the
  reactor called in it, and their name when it called one.

| `last_stall` | what held the loop |
|---|---|
| `callbacks == 1`, `name` set | that callback |
| `callbacks > 1`, `name` null | several callbacks together. A watch names the one that runs while the turn is open |
| `callbacks == 0` | the program's own code between ticks, or the loop's own work in a tick that did not block, such as a file call under `file_policy = .blocking`. A plain loop calls no callback, so each of its stalls is in this row |

The loop's own work in a tick that then blocks is in no turn that the count sees. That work comes
after the first stamp and before the wait, and the stamp after the wait starts a new turn. So a
file call under `.blocking` in such a tick is not a stall. A watch sees it while it runs, with a
null name.

A test that runs a reactor shared by libraries sets `stall_turn_ns` and checks at its end that
`statistics().stalls` is 0; on a failure, `last_stall` names the callback. The check compares
times, so a busy machine can fail it: raise a threshold that proves flaky deliberately, with the
number beside it.

A callback that never returns never ends its turn, so the count never sees it. A thread of the
program's own sees it, through the loop's **heartbeat**. rotor starts no thread. The program calls
`heartbeat()` on the loop's thread, and hands the heartbeat to its watch thread. The example runs a
task, so it makes a reactor and calls `reactor.heartbeat()`:

```zig
var watcher: Watcher = .{ .heartbeat = reactor.heartbeat(), .io = init.io };
const thread = try std.Thread.spawn(.{}, Watcher.run, .{&watcher});
```

The watch thread calls `watch` on it once, `check` once in each period it chooses, and `end` before
the loop's `deinit`, which halts while a watch reads the heartbeat:

```zig
var watch = watcher.heartbeat.watch();
defer watch.end();
for (0..checks_max) |_| {
    watcher.io.sleep(.fromMilliseconds(period_ms), .awake) catch return;
    const stuck = watch.check() orelse continue;
    if (stuck.checks < checks_limit) continue;
```

`check` reads no clock. It returns null when the loop moved since the last check, when the loop
sleeps in a kernel wait, and on the first check of a turn. Otherwise it returns a `Heartbeat.Stuck`:
the name of the callback that runs now, or null for code outside a callback, the stamp that
started the turn, and `checks`, the checks in a row after the first that saw the turn open. A turn
of `n` periods or more is reported with `checks` of `n - 1` or more, so a program's limit is a count
of checks. A name is static data, so the program may read it after a library frees its record.
`examples/stall_watch.zig` is the whole program.

Three ways prevent a stall:

- **Work split into slices.** A long task reads `task_budget_left()`, does at most that many
  slices plus one, charges what it did past its cost, and schedules itself again (Tasks, below).
- **Another loop.** CPU work that cannot be split goes to a loop on another thread, through `post`.
- **The offload.** A file call that blocks goes to the program's threads (Files, above).

### The loop's names

`rotor.Loop` declares these 28 names and its six error sets, and nothing else. The 28 names are the
core's surface, `loop_declarations` in `src/core/surface.zig`.

| names | what they are for | section |
|---|---|---|
| `Options`, `memory_bytes`, `init`, `deinit` | the loop's options, its memory, its start and its end | Start and end a loop |
| `cancel_all`, `drain`, `assert_empty`, `in_flight` | the end of the loop's work | Start and end a loop |
| `submit`, `cancel`, `tick`, `now_ns` | operations and their events | Submit and tick |
| `register_buffers`, `register_descriptors`, `reserve_buffer_group`, `provide_buffers`, `provided_buffer`, `give_back_buffer`, `release_buffers` | buffers and descriptors | Buffers |
| `provide_datagram_buffers`, `datagram` | datagrams | Datagrams |
| `wait_until` | the stored limit | The stored limit |
| `post`, `dropped_wakes` | messages to other loops | Threads |
| `wait_limit`, `wait_descriptor` | a host that sleeps in a wait of its own | A host that owns the wait |
| `statistics`, `heartbeat` | counts and stalls | Statistics, Stalls |

## A reactor

A reactor is a loop with the pieces that call the program's code from inside a tick: records with
callbacks and pollers (decision 26), and tasks (decision 27). It adds scheduling groups for the
tasks (decision 30), cross-core calls (decision 32), and a view that several libraries share
(decision 28). Decision 33 put these pieces in the module `reactor`, apart from the loop.

### Make a reactor

A program that wants a reactor makes a `rotor.Reactor(rotor.Loop)` in place of a `rotor.Loop`:

```zig
const Reactor = rotor.Reactor(rotor.Loop);
const options: Reactor.Options = .{ .loop = .{ .operations = 64 } };
var memory: [Reactor.memory_bytes(&options)]u8 align(rotor.memory_alignment) = undefined;
var reactor: Reactor = undefined;
try reactor.init(&memory, &options);
defer reactor.deinit();
```

- `Reactor.Options` has two fields. `loop` holds the loop's options, and has no default.
  `named_groups` holds the program's named groups. Its default is the root file's
  `rotor_scheduling_groups` (Scheduling groups, below).
- `Reactor.memory_bytes` is the loop's bytes, then 536 B for the reactor's scheduling groups.
- `init` starts the loop on the memory, then the reactor's state. Call it on the thread that will
  own the reactor. The reactor stays at its address until `deinit`, as a loop does.
- `deinit` halts while a poller is added, a task is queued or a service is served. Then it ends the
  loop, which halts while an operation, a record or a call is still counted.

The reactor holds its loop by value, and its own state beside it. Each of the loop's 28 names is a
name of the reactor too, and does what the loop's call does. Eight of them also do the reactor's
part: `memory_bytes`, `init`, `deinit`, `submit`, `tick`, `drain`, `assert_empty` and `wait_limit`.
The reactor's `submit`, for example, counts the operations that name a record. One of the 28 names
fails to compile: `wait_until`. A reactor bounds its wait with its pollers, and only the reactor's
own code writes its stored limit (Pollers, below). The reactor adds 16 names of its own:

| names | section |
|---|---|
| `add_poller`, `remove_poller` | Pollers |
| `schedule`, `schedule_in`, `is_scheduled`, `tasks_queued`, `task_budget_left`, `charge_task`, `discard_tasks` | Tasks |
| `reserve_scheduling_group`, `set_scheduling_group_shares` | Scheduling groups |
| `shared` | The view |
| `call`, `answer`, `serve`, `stop_serving` | Cross-core calls |

`rotor.Reactor(rotor.Loop)` declares the loop's six error sets, and `DrainError` also holds
`TasksStillQueued`. It declares four more: `AddPollerError`, `ScheduleError`,
`ReserveSchedulingGroupError` and `CallError`.

No call of a reactor gives out its loop. A call on the loop inside would skip the reactor's part of
that call. So code that takes a `*rotor.Loop` does not run on a reactor. A function that serves both takes
the type of its loop as a comptime parameter.

### A library on a reactor

A library such as a resolver takes the reactor's view from the program, and owns no socket, thread
or loop of its own. Several libraries can share one reactor (decision 26). Only the program calls
`tick`. A library submits, returns, and finishes its work in records, pollers and tasks (decision
27).

The library of this example sends one request, with a deadline for the whole exchange. A timer
stands in for the request's I/O:

```zig
const Exchange = struct {
    shared: *rotor.SharedLoop,
    group: rotor.SchedulingGroup,
    request: rotor.Completion = .init(Exchange, "request", on_request),
    deadline: rotor.Poller = .init(Exchange, "deadline", on_deadline),
    done: rotor.Task = .init(Exchange, "done", on_done),
    handle: [1]rotor.Handle = .{.none},
    deadline_ns: u64 = 0,
    outcome: Outcome = .waiting,
    finished: bool = false,

    const Outcome = enum { waiting, replied, expired };

    fn start(exchange: *Exchange, reply_ns: u64, timeout_ns: u64) !void {
        exchange.deadline_ns = exchange.shared.now_ns() + timeout_ns;
        try exchange.shared.add_poller(&exchange.deadline);
        const request = rotor.Completion.mark(&exchange.request, rotor.Operation.timer(0, reply_ns, 0));
        if (exchange.shared.submit(&.{request}, &exchange.handle) != 1) return error.NotTaken;
    }

    fn on_request(exchange: *Exchange, event: rotor.Event) void {
        _ = event.outcome() catch return;
        exchange.end(.replied);
    }

    fn on_deadline(exchange: *Exchange) rotor.WaitLimit {
        if (exchange.outcome != .waiting) return .none;
        if (exchange.shared.now_ns() < exchange.deadline_ns) return .at(exchange.deadline_ns);
        exchange.shared.cancel(exchange.handle[0]);
        exchange.end(.expired);
        return .none;
    }

    fn end(exchange: *Exchange, outcome: Outcome) void {
        if (exchange.outcome != .waiting) return;
        exchange.outcome = outcome;
        // The group holds no other task, so it has room.
        exchange.shared.schedule_in(exchange.group, &exchange.done) catch unreachable;
    }

    fn on_done(exchange: *Exchange) void {
        exchange.shared.remove_poller(&exchange.deadline);
        exchange.finished = true;
    }
};
```

The program reserves the library's scheduling group, gives the library the view, and ticks:

```zig
const group = try reactor.reserve_scheduling_group(200);
var exchange: Exchange = .{ .shared = reactor.shared(), .group = group };
try exchange.start(rotor.constants.ns_per_ms, rotor.constants.ns_per_s);
_ = try reactor.tick(&events, rotor.constants.ns_per_s);
```

The sections below say what each piece does.

### Records

A record is a `rotor.Completion` in the library's own struct. The reactor calls it for each event of
the operation that names it (decision 26).

- `rotor.Completion.init(Exchange, "request", on_request)` declares a record. The handler takes
  `*Exchange` and the `rotor.Event`. `init` names the record after its type and its field, with the
  type's full path. A stall or a watch reports that name.
- `rotor.Completion.mark(&record, operation)` returns the operation with the record's address in
  `user_data` and the `dispatched` bit set. The record must stay valid until the final event.
- The reactor calls the record for each event of that operation: each event flagged `more`, and the
  final event. It does not give these events to the caller of `tick`.
- An event of an operation that names no record, and a message from another loop, go to the caller
  of `tick`, as on a plain loop.
- A record written by hand points to a `Completion.Call` that is a container-level `const` with a
  literal name. Another thread may read the name after the library frees the record.

### Pollers

A poller is work that is not one operation, such as a batch of sends to flush, or a deadline.

- `rotor.Poller.init` declares one. `add_poller` adds it, and the reactor calls it once in each tick,
  before the tick waits.
- It returns a `rotor.WaitLimit` (decision 29): `.now` when the tick must not block, for example
  because work is left; `.at(ns)` for a deadline on the loop's clock, `now_ns`; and `.none`
  otherwise.
- The reactor stores the least limit of its pollers in the loop's stored limit. The tick bounds its
  wait at that limit, as it bounds it at the nearest timer. So a deadline that moves needs no timer.
- While a poller is added, a record or a task that ran in a tick, or a wake that a tick took, makes
  the stored limit `.now`. The next tick then calls the pollers before it waits.
- `remove_poller` removes one. When it removes the last, the stored limit goes back to `.none`.
- At most `pollers_max` (8) pollers. One more returns `error.PollersFull`.

A library that another thread wakes keeps a flag, a `std.atomic.Value(bool)`, in its own struct,
and reads it in its poller with acquire order. The other thread stores the flag with release
order, then posts `rotor.Message.wake` through its `Remote` or its own loop. The wake reaches no
callback. A reactor that sleeps wakes, and its next tick calls the poller. `MailboxFull` on a wake
is safe to drop: the ring holds messages, so the reactor does not sleep until it reads them.

### Tasks

A task is work that continues later, such as the caller's callback after an exchange ends.

- `rotor.Task.init(Exchange, "done", on_done)` declares one. A library queues it in its scheduling
  group with `shared.schedule_in(group, &task)`, and the reactor calls it once.
- A task that the program queued between ticks runs in the next tick, after the records. A task that
  a poller or a record queued runs in the same tick, after the records. A task that a task queued
  runs in the next tick.
- One tick runs at most `tasks_per_tick_max` (64) tasks, and does not block while a task is queued.
- A task is queued on one reactor at a time, and `is_scheduled` says whether it is. Each group holds
  at most `tasks_queued_max` (65,536) tasks. One more returns `error.TasksFull`, and the other groups
  can still schedule.
- `tasks_queued()` returns the tasks queued in every group.

A long task splits its work. Its cost pays for its first slices: 1 for `Task.init`, `cost` for
`Task.init_cost`. It reads `task_budget_left()`, and does at most that budget plus one slices, or
its cost when that is more. When it did more slices than its cost, it calls `charge_task` with the
slices less its cost. Then it schedules itself again if work is left. Keep the total of one run, its
cost and its charges together, at or under `task_charge_max` (64) units: that rule is the caller's.
The reactor checks only that each charge is below `task_charge_max`. While any named group holds a
task, the reactor serves groups, and a run far over the total can take its group's deficit below the
floor. The reactor then halts.

### Scheduling groups

The program owns the scheduling groups (decision 30). A group is a task queue with shares, and the
reactor serves the groups by deficit round robin in cost units. A task costs 1 unit, or the cost
that `Task.init_cost` states, plus what it adds with `charge_task`.

- Shares are in hundredths of a unit, from 1 to `scheduling_shares_max` (1,000). The default of 100
  gives a group one unit at each visit. So two groups at 100 and 300 are served units 1 to 3.
- The program reserves a group with `reactor.reserve_scheduling_group(shares)`, sets shares with
  `reactor.set_scheduling_group_shares`, and gives each library its group at init.
- `.default` is the group of `reactor.schedule`, and a library names it as `.default` in
  `schedule_in`. A program that uses no group other than `.default` runs decision 27's queue, in the
  order of the calls.

A group that a cross-core call names must be the same group on every reactor, so it has a name. The
program declares its named groups once, in its root source file:
`pub const rotor_scheduling_groups = .{ .quic = 400, .dns = 100 };`. Every reactor reserves them at
init as ids 1 to n, in that order, at those shares, and `reserve_scheduling_group` then returns
n + 1. `rotor.named_scheduling_group(.quic)` returns the `NamedSchedulingGroup`, which the program
gives to a library that makes cross-core calls. The library calls its `group()` for its own
`schedule_in`. A name that the root does not declare fails to compile. Shares belong to each
reactor: `set_scheduling_group_shares` changes them on the reactor that makes the call.

Records and pollers are in no group. A record or a poller does a small, fixed amount of work, and
puts the rest in a task in its library's group. A stall of one task names its group
(`Stall.group`).

### The view

The program calls `reactor.shared()` and gives each library the `*rotor.SharedLoop` it returns,
which the library keeps (decision 28). Its address is the reactor's, and each call on it is the
reactor's call of the same name:

- the library's calls: `submit`, `cancel`, `post`, `now_ns`, `schedule_in`, `charge_task`,
  `is_scheduled`, `task_budget_left`, `add_poller`, `remove_poller`, `reserve_buffer_group`, the
  buffer group calls, `call`, `answer`, `serve` and `stop_serving`;
- the calls that fail to compile, with a message that states the rule: `tick`, `drain`, `deinit`,
  `cancel_all` and `discard_tasks` (decision 28); `schedule`, `reserve_scheduling_group` and
  `set_scheduling_group_shares` (decision 30); and `wait_until` (decision 33).

A library that casts the view back to a `*Reactor` and ticks inside a callback still halts. A
callback, a poller or a task may submit, cancel, give buffers back and schedule a task. A callback or
a task may add or remove a poller; a poller may not. Any of them that calls `tick` or `deinit` halts.

- A library reserves its buffer group with `shared.reserve_buffer_group()` once, at init, and keeps
  the `BufferGroup` until the reactor's `deinit`.
- The library submits on the reactor's thread only. A caller on another thread reaches it through a
  `Remote` and a message whose tag the library defines.
- The library's operations in flight count against the loop's `operations`, and its buffers
  against the loop's groups. The program sizes the loop for both.
- `timeout_ns` on a `receive_from` and a `timer` per retry are what a query needs. `cancel` with the
  handle ends either early.

### Cross-core calls

A cross-core call sends a request from one reactor to another reactor of the process, runs a
handler there, and brings the reply back (decision 32). The caller owns the record of the call, and
the ring between the two loops carries its address. What that needs:

- The program declares each kind of call once, as a static:
  `var append: Append = .init;` with `const Append = rotor.Service(Journal, Request, Reply,
  Journal.append);`. `rotor.Service` is the host reactor's, `rotor.Reactor(rotor.Loop).Service`.
  The handler takes the context and a `*rotor.CallRecord(Request, Reply)`, and returns
  `rotor.Answer(Reply)`: `.{ .now = reply }`, or `.later`, after which the handler's own code calls
  `call.answer(shared, &reply)` once, on the target's thread.
- Each reactor that serves the call calls `append.serve(shared, &journal)` before its first tick,
  and `append.stop_serving(shared)` before its `deinit`, which halts while a station serves.
- The caller keeps a record in its own struct:
  `append_call: rotor.CallRecord(Request, Reply) = .init(Writer, "append_call", on_appended)`.
  `on_appended` takes the struct and a `rotor.CallResult(Reply)`, and switches on it: `replied`
  with a pointer to the reply, `expired` or `target_stopped`. It runs exactly once for each `send`
  that returns success, and it may send the same record again.
- `append.send(shared, target, &writer.append_call, &request, .{ .group = group })` sends. The
  group is a `NamedSchedulingGroup`, from `rotor.named_scheduling_group(.journal)` or `.default`,
  and it has no default. The handler runs in that group on the target, and `on_appended` runs in
  it on the caller. A `deadline_ns` on the loop clock ends a call that reaches the target late
  with `expired`, and the handler does not run.
- `send` returns `CallsFull` when 32 calls to that target (`calls_per_pair_max`) have not yet run
  their `finish`, `MailboxFull` when the ring holds the posts' share, and `LoopNotFound`. Then
  nothing was sent, and `finish` does not run. The program must not touch the request or the
  reply while `call.is_out()` is true.
- `send` returns `LoopNotFound` for a target that runs no loop, and for a plain loop, which takes no
  calls (decision 33, open question 12). That plain loop gets no message.
- A call that reaches a reactor that never served the service halts that reactor. A call that
  reaches a reactor that stopped serving ends with `target_stopped`, and so does a call to a later
  reactor of that id that does not serve.
- A call to the caller's own reactor takes no ring. Its tasks run in later task runs, never inside
  `send`.
- A post sees `mailbox_posts_max` (224) slots of a ring, so a return always finds a slot.
- A thread with no loop holds a `Remote`, which has no call. A reactor whose registry is a decision
  21 group's makes no call and serves no service: each halts there.

To stop reactors that call each other, every reactor stops its calls and posts first, through a flag
of the program and a barrier. Then each reactor ticks until no reactor has a call out or a task
queued. Then each reactor calls `stop_serving` for each service, and then `cancel_all`, `drain` and
`deinit`. A call that a reactor pushes after its target's last tick stays in the ring, and its
caller's `drain` returns `StillInFlight`.

### Drain and end a reactor

- `cancel_all` asks each operation in flight to end, the operations of every library included.
- `drain` ticks the reactor, so each record and each task runs. It stops when nothing is in flight,
  no task is queued, and no call is out or held.
- `drain` fails with `StillInFlight` while an operation or a call stays, and with `TasksStillQueued`
  when only tasks are left, such as a task that schedules itself again in each run.
- After `TasksStillQueued`, `discard_tasks()` unlinks the queued tasks of every group without a call,
  and returns how many. The kernel then holds nothing.
- Remove every poller, and let every task run, before `deinit`, which halts on either.

### A host that owns the wait, with a reactor

A host that sleeps in a wait of its own ticks the reactor as it ticks a loop (A loop, "A host that
owns the wait"). It reads `wait_limit` on the reactor:

- The reactor answers `.now` while a task is queued. Otherwise it answers what its loop answers.
- The loop's stored limit holds the least limit of the pollers, which the last tick stored. While a
  poller is added, a poller that returned `.now`, a wake that the last tick took, and a record or a
  task that the last tick called each give `.now`.
- `wait_descriptor` is the loop's. `SharedLoop` declares neither `wait_limit` nor
  `wait_descriptor`.
- The descriptor does not report a poller's limit that comes due. The host bounds its own wait by
  what `wait_limit` answers.

### A twin of the loop

This section is for the author of a twin. A twin is a type of the program's own that carries the
loop's surface, for a test that must replay exactly (decision 10). `rotor.Reactor(Twin)` gives a
twin the reactor, from the same code as the host's reactor. [`examples/twin.zig`](../examples/twin.zig)
is a whole twin, and it runs one record and one task on its reactor.

```zig
const Reactor = rotor.Reactor(Twin);
```

A twin declares the loop's 28 names (The loop's names, above). A twin that drives a reactor also
declares the 8 names of the port of decision 33. The port is what the reactor needs from a loop, and
what a program must not call. `rotor.Loop` does not declare it, and each backend's loop does. Each
type in the port is a Zig type, a type that `rotor` exports, or a type of the twin's own. So a twin
in a dependent package can write each signature. The port of the example twin:

```zig
const Take = fn (context: *anyopaque, sender: rotor.LoopId, message: rotor.Message) void;

const PushError = error{ LoopNotFound, CallsFull, MailboxFull };

pub fn tick_backend(twin: *Twin, events: []rotor.Event, wait_ns: u64) TickError!u32 {
    twin.assert_owner();
    assert(events.len != 0);
    twin.clock_ns += twin.wait_bound(wait_ns);
    const written = twin.end_due(events);
    twin.counts.ticks += 1;
    twin.counts.events += written;
    return written;
}
pub fn take_kept_error(twin: *Twin) TickError!void {
    twin.assert_owner();
}
pub fn outstanding(twin: *Twin) *u32 {
    return &twin.outstanding_word;
}
pub fn stored_limit(twin: *Twin) *rotor.WaitLimit {
    return &twin.limit;
}
pub fn heartbeat_line(twin: *Twin) *Line {
    return &twin.line;
}
pub fn attach_reserved(twin: *Twin, context: *anyopaque, take: *const Take) void {
    twin.assert_owner();
    assert(twin.hook == null);
    twin.hook = .{ .context = context, .take = take };
}
pub fn push_reserved(twin: *Twin, target: rotor.LoopId, message: rotor.Message) PushError!*u32 {
    _ = .{ twin, target, message };
    return error.LoopNotFound;
}
pub fn assert_owner(twin: *const Twin) void {
    assert(twin.owner == std.Thread.getCurrentId());
}
```

| name | what the reactor does with it |
|---|---|
| `tick_backend` | It calls the twin's tick, which does not check for a kept error. The reactor takes its error set for a tick from the return type of this function |
| `take_kept_error` | It takes an error that an earlier tick kept, once. That call lowers `outstanding`. A twin that keeps no error returns at once |
| `outstanding` | It raises the word for each record in flight, each queued task and each call, and lowers it at each end. While the word is above 0, the reactor's tick takes its slow path |
| `stored_limit` | It writes the least limit of its pollers there. The twin's tick bounds its wait at that limit. On a reactor, only the reactor's code writes it |
| `heartbeat_line` | It names each callback on the line that this function returns, before the callback runs |
| `attach_reserved` | The reactor's `init` stores its hook there once. The twin's drain gives the hook each wake, call and return from another loop |
| `push_reserved` | It pushes a call or a return into the ring to `target`. The function wakes `target`, and returns the count of calls out of that ring |
| `assert_owner` | It halts the program when a thread other than the twin's own makes a call |

The check of names, below, cannot see what the reactor needs of each signature:

- `init` returns an error union. The reactor's `init` returns what the twin's returns.
- `tick_backend` returns `E!u32`, where `E` is the twin's own error set for a tick.
  `take_kept_error` returns an error union whose errors are in `E`.
- `heartbeat_line` returns a single pointer to a type that declares the 6 calls of the line.
- `attach_reserved` takes a pointer to a function of the type `Take` above.
- `push_reserved` returns an error union whose errors are in `rotor.CallError`: `LoopNotFound`,
  `CallsFull` and `MailboxFull`.
- `Options` may declare `id`, a `rotor.LoopId`. The reactor copies it, and takes 0 when it is
  absent.

`heartbeat_line` returns a pointer to a line. The line declares the 6 calls that the reactor makes on
it:

```zig
const Line = struct {
    names: [names_max][]const u8 = undefined,
    count: u32 = 0,
    poller_name: ?*const [:0]const u8 = null,

    const names_max = 8;

    pub fn enter(line: *Line, name: *const [:0]const u8) void {
        if (line.count == names_max) return;
        line.names[line.count] = name.*;
        line.count += 1;
    }
    pub fn leave(_: *Line, _: u64) void {}
    pub fn leave_polling(_: *Line, _: u32) void {}
    pub fn leave_tasks(_: *Line, _: u64) void {}
    pub fn leave_group_tasks(_: *Line, _: u64, _: u8) void {}
    pub fn name_poller(line: *Line, name: ?*const [:0]const u8) void {
        line.poller_name = name;
    }
};
```

| call | when the reactor makes it |
|---|---|
| `enter(name)` | before each callback: a record, a poller or a task |
| `leave(called)` | after the records of a tick |
| `leave_polling(polled)` | after the pollers of a tick |
| `leave_tasks(ran)` | after a run of tasks of `.default` |
| `leave_group_tasks(ran, group)` | after a run of the scheduling groups |
| `name_poller(name)` | at each `add_poller` and `remove_poller`: the name of the first poller, or null |

A twin's line can store nothing. Its heartbeat then names no callback, which a twin for replay does
not need.

`rotor.Reactor(Twin)` checks the twin at compile time, before it makes anything. It collects each
name of the surface, of the port and of the line that the twin lacks, and stops the build with one
error that names them all. A twin with no `stored_limit` stops the build with this message:

```text
rotor.Reactor(twin.Twin): the type lacks 1 declaration that the reactor needs:
  stored_limit: a pointer to the stored limit, which only the reactor writes
A program passes rotor.Loop. A twin of decision 10 declares each name (decision 33, "The port").
```

The check sees names, not signatures. A wrong signature fails where the reactor calls it, and the
error names a line under `src/reactor/`.

- A twin carries no `shared` and no `SharedLoop`: the reactor makes them. A twin's program writes
  `rotor.Reactor(Twin).SharedLoop`, `rotor.Reactor(Twin).Service` and
  `rotor.Reactor(Twin).CallRecord`.
- The exports that name no view, such as `rotor.Completion` and `rotor.Task`, are the same for a
  twin's program.
- The port is API for the author of a twin. A change to it is a breaking change, and the release
  names it.

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
| a turn that counts as a stall, by default | `stall_turn_ns_default`, 10 ms |
| file operations out on the offload per loop; more stay queued | `offload_in_flight_max`, 256 |
| registered descriptors, registered buffers | 1,024 each |
| provided-buffer groups, buffers per group | 16, 32,768 |
| a message's tag | `message_tag_max`, 0x7fff_efff |
| messages a post sees of one ring | `mailbox_posts_max`, 224 |
| the tag of `Message.wake` | `message_tag_wake`, 0x7fff_f000 |
| ticks of one `drain` | `drain_rounds_max`, 1,024 |
| messages queued from one loop to another (kqueue) | `mailbox_messages`, 256 |
| registrations in, readiness out, per tick (kqueue) | `changes_max`, `readiness_max`, 256 |
| pollers per reactor | `pollers_max`, 8 |
| tasks that one tick runs | `tasks_per_tick_max`, 64 |
| tasks queued in one scheduling group | `tasks_queued_max`, 65,536 |
| scheduling group ids per reactor, `.default` included | `scheduling_groups_max`, 16 |
| the shares of one scheduling group | `scheduling_shares_max`, 1,000 |
| the units of one task's run | `task_charge_max`, 64 |
| cross-core calls of one pair of loops out at once | `calls_per_pair_max`, 32 |
| services one reactor serves or calls itself through | `services_max`, 16 |

## What the kernel must have

- Linux 6.17 or later, with io_uring: `IORING_FEAT_NODROP`, `IORING_FEAT_EXT_ARG`, `MSG_RING`,
  multishot accept and receive, provided buffer rings, `SINGLE_ISSUER` and `DEFER_TASKRUN`. A
  kernel that lacks one of these, or refuses io_uring itself as Docker's default seccomp profile
  does, gets the epoll backend instead (above): the process asks for a ring with the same flags,
  features and opcodes a loop needs. `tools/uring_probe.zig` names the first thing a kernel lacks.
- macOS with kqueue. Files need a policy (above). A loop that polls carries its own wake trigger
  in the `kevent` call, because a poll that finds nothing ready parks the thread for about 12 µs
  on macOS 26 otherwise (decision 12, point 6).

## Not in version one

TLS (chapulin fills that interface for colibri), DNS (cocuyo), Unix sockets, process spawning,
Windows and the `std.Io` adapter. Loops in several processes are in version one, but rotor starts
no process: the application does. Decision 2 says why, and what would bring each in. The epoll
backend was on this list until decision 20 brought it in.

## Where the numbers are

`docs/costs.md` holds the measured costs of the operations the design arguments cite, for the `mac`,
`orbstack` and `github` machines. `docs/benchmarks.md` holds the current comparison against libuv
and libxev and the commands that take it, `bench/alternatives/README.md` records every experiment
behind it, the losing rows included, and `bench/results/` holds every run as printed. The Linux
machine rotor is meant to be deployed on is not named yet, so no claim is made for it.
