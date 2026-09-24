# rotor

[![CI](https://github.com/c4milo/rotor/actions/workflows/ci.yml/badge.svg)](https://github.com/c4milo/rotor/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Zig 0.16.0](https://img.shields.io/badge/zig-0.16.0-f7a41d.svg)](https://ziglang.org/download/)
[![Version](https://img.shields.io/github/v/tag/c4milo/rotor?label=version)](https://github.com/c4milo/rotor/tags)

rotor is an event loop and I/O layer for Zig. It is for servers and network libraries that must
know, before they run, how much memory they use and how their I/O behaves. It runs on io_uring on
Linux, kqueue on macOS, and epoll on Linux where io_uring is not available.

## Why rotor

- **Fast.** rotor is completion-based: a program submits operations in batches, and one system
  call per tick returns the results of many. On Linux it uses the parts of io_uring that save the
  most work: one accept and one receive that each serve many completions, buffers the kernel picks
  for each receive, and descriptors and buffers registered once. A benchmark harness in this
  repository measures every speed claim, and [its results](#performance) include the rows where
  rotor is slower.
- **Deterministic.** What a loop does depends only on what the program submits and what the
  kernel answers. rotor's core reads no clock, random number or pointer value, and its statistics
  sample every Nth operation, never by time. Every operation ends with exactly one final event, so
  a program's control flow can be followed and replayed.
- **Pluggable I/O.** One API covers io_uring, kqueue and epoll. The process picks its backend once
  and reports which it chose. The API names no kernel type, so a program can put its own
  implementation behind it, such as a simulator for tests that must replay exactly. File
  operations that would block the loop can go to threads the program supplies.
- **Predictable memory.** rotor allocates nothing. A program gives each loop its memory once, at
  startup. Every table and queue in the loop has a fixed limit, and rotor never grows one.
- **Safe to run in production.** Assertions stay on in release builds. Misuse, such as calling a
  loop from a thread that does not own it, stops the program at a named check instead of
  corrupting memory.
- **Scales by sharing nothing.** Each loop belongs to one thread and takes no locks. Loops pass
  each other messages, and a thread that owns no loop can post to one.

## Status

rotor is at version 0.4.0. Everything planned for version one is built: TCP, UDP with ECN on
both kernels and segmentation offload on Linux, files, timers, deadlines and cancellation, and
messages between loops. One conformance suite, written against the public API, passes on all three
backends, and CI runs it on every push.

| system | backend | requires | tested on |
|---|---|---|---|
| Linux | io_uring | Linux 6.1 or later, with the io_uring features [listed in the guide](docs/using.md#what-the-kernel-must-have) | Linux 6.17 on x86-64 (GitHub runners), Linux 7.0 on aarch64 (a virtual machine on Apple silicon) |
| Linux, where io_uring is refused or lacks a feature rotor needs | epoll | Linux 6.1 or later | both of the above, under Docker's default seccomp profile |
| macOS | kqueue | no minimum version is set | macOS 26.6 on Apple silicon |

> [!IMPORTANT]
> **In a container, Linux runs epoll unless io_uring is allowed.** Docker's default seccomp
> profile refuses io_uring. Run with `--security-opt seccomp=unconfined`, or a profile that allows
> the io_uring system calls, to get io_uring. `rotor.backend()` says which backend a process runs;
> a program that needs io_uring checks it at startup.

> [!IMPORTANT]
> **On macOS and on epoll, file operations need a policy.** Those kernels cannot complete a file
> operation, so by default a loop refuses one with `unsupported`. Set `file_policy` at init:
> `.blocking` runs the call on the loop's thread, and `.offload` hands it to threads the program
> supplies. [The guide](docs/using.md#files) explains both.

Not in version one: TLS, DNS, Unix sockets, process spawning, Windows, and a `std.Io` adapter.
[Design record 2](docs/decisions/0002-scope.md) says why.

## Quick start

Add rotor to a project:

```bash
zig fetch --save git+https://github.com/c4milo/rotor#v0.4.0
```

In `build.zig`:

```zig
const rotor = b.dependency("rotor", .{ .target = target, .release = optimize != .Debug });
exe.root_module.addImport("rotor", rotor.module("rotor"));
```

rotor's build takes `release` instead of `optimize`. It builds Debug or ReleaseSafe only, because
it has no mode that removes its assertions.

A TCP echo server:

```zig
const std = @import("std");
const rotor = @import("rotor");

const port = 9000;
/// Connections served at once. The server closes any connection beyond this.
const connections_max = 128;
const buffer_bytes = 4096;

/// What an operation's `user_data` carries: its kind in the high 32 bits, its socket in the low.
const Kind = enum(u32) { accept, receive, send, close };

fn tag(kind: Kind, socket: rotor.Descriptor) u64 {
    return @as(u64, @intFromEnum(kind)) << 32 | @as(u32, @bitCast(socket));
}

/// The loop holds the accept and one operation per connection: a connection is receiving, sending
/// or closing, never two at once. rotor allocates nothing, so its memory is declared here.
const options: rotor.Loop.Options = .{ .operations = connections_max + 1 };
var memory: [rotor.Loop.memory_bytes(options)]u8 align(rotor.memory_alignment) = undefined;

/// One buffer per connection, the bytes it last received, and how many of them are sent back.
var buffers: [connections_max][buffer_bytes]u8 = undefined;
var received: [connections_max]u32 = undefined;
var sent: [connections_max]u32 = undefined;

pub fn main() !void {
    var loop: rotor.Loop = undefined;
    try loop.init(&memory, options);
    // The server runs until it is stopped, so it never calls `loop.deinit()`.

    const address = rotor.Address.ipv4(.{ 127, 0, 0, 1 }, port);
    const listener = try rotor.sync.listen(&address, .{ .backlog = 128, .reuse_port = false });
    // One multishot accept delivers every connection.
    try submit(&loop, rotor.Operation.accept(tag(.accept, listener), listener, true));
    std.debug.print("echo on 127.0.0.1:{d}, {t} backend\n", .{ port, rotor.backend() });

    var events: [64]rotor.Event = undefined;
    while (true) {
        const count = try loop.tick(&events, rotor.constants.ns_per_s);
        for (events[0..count]) |event| try handle(&loop, event);
    }
}

fn handle(loop: *rotor.Loop, event: rotor.Event) !void {
    const socket: rotor.Descriptor = @bitCast(@as(u32, @truncate(event.user_data)));
    switch (@as(Kind, @enumFromInt(event.user_data >> 32))) {
        .accept => {
            // An event without `more` ends the multishot accept, so arm another.
            if (!event.flags.more) try submit(loop, rotor.Operation.accept(event.user_data, socket, true));
            const accepted: rotor.Descriptor = @intCast(event.outcome() catch return);
            if (accepted >= connections_max) return rotor.sync.close_now(accepted);
            try receive(loop, accepted);
        },
        .receive => {
            // 0 bytes is the peer closing; an error ends the connection too.
            const count = event.outcome() catch 0;
            if (count == 0) return submit(loop, rotor.Operation.close(tag(.close, socket), socket));
            received[@intCast(socket)] = count;
            sent[@intCast(socket)] = 0;
            try send_rest(loop, socket);
        },
        .send => {
            const count = event.outcome() catch {
                return submit(loop, rotor.Operation.close(tag(.close, socket), socket));
            };
            sent[@intCast(socket)] += count;
            // A send may take fewer bytes than it was given: send the rest before reading again.
            if (sent[@intCast(socket)] < received[@intCast(socket)]) return send_rest(loop, socket);
            try receive(loop, socket);
        },
        .close => {},
    }
}

fn receive(loop: *rotor.Loop, socket: rotor.Descriptor) !void {
    const buffer = &buffers[@intCast(socket)];
    try submit(loop, rotor.Operation.receive(tag(.receive, socket), socket, buffer));
}

fn send_rest(loop: *rotor.Loop, socket: rotor.Descriptor) !void {
    const index: usize = @intCast(socket);
    const rest = buffers[index][sent[index]..received[index]];
    try submit(loop, rotor.Operation.send(tag(.send, socket), socket, rest));
}

/// `submit` takes as many operations as the loop has room for. This loop is sized for every
/// operation the server can have in flight, so a refusal here is a bug in that sizing.
fn submit(loop: *rotor.Loop, operation: rotor.Operation) !void {
    if (loop.submit(&.{operation}, &.{}) != 1) return error.LoopFull;
}
```

Run it, then connect with `nc 127.0.0.1 9000`: each line typed comes back. It prints the backend it
runs on:

```text
echo on 127.0.0.1:9000, kqueue backend
```

[The guide](docs/using.md) covers the rest of the API: every operation and what it promises,
deadlines and cancellation, the three ways to hand the loop buffers, datagrams, files, and loops on
several threads.

## Performance

These are summaries of runs of the harness in this repository, with each server running one event
loop on one thread. Each cell is rotor's throughput divided by the other library's: above 1.00,
rotor is faster. A cell is `undecided` when either side's runs disagreed by 10 percent or more, or
when another step of the same run measured the two differently. The Linux columns are GitHub-hosted
runners that were given different processors, and the ratios move with the processor.

TCP echo:

| connections | payload | against | macOS, kqueue, Apple M1 Pro | Linux, io_uring, AMD EPYC 9V74 | Linux, io_uring, Intel Xeon 6973P-C | Linux, io_uring, AMD EPYC 7763 |
|---:|---:|---|---:|---:|---:|---:|
| 16 | 4 KiB | libuv | 1.01 | 1.04 | 1.20 | 1.15 |
| 16 | 4 KiB | libxev | 1.24 | 1.12 | 1.33 | undecided |
| 16 | 64 KiB | libuv | 0.97 | 1.01 | 1.05 | undecided |
| 16 | 64 KiB | libxev | 0.98 | 0.92 | 1.12 | undecided |
| 64 | 4 KiB | libuv | 1.02 | 1.05 | 1.20 | 1.17 |
| 64 | 4 KiB | libxev | undecided | 1.04 | 1.27 | 1.08 |
| 64 | 64 KiB | libuv | 0.99 | 1.02 | 0.95 | 1.04 |
| 64 | 64 KiB | libxev | 1.05 | 0.91 | 0.99 | undecided |

Other workloads:

| workload | against | macOS, kqueue, Apple M1 Pro | Linux, io_uring, AMD EPYC 7763 |
|---|---|---:|---:|
| timer churn, 256 timers, fires per second | libuv | 1.22 | 1.12 |
| timer churn, 256 timers, fires per second | libxev | 1.16 | 1.04 |
| timer churn, 4,096 timers, fires per second | libuv | 2.02 | 1.96 |
| timer churn, 4,096 timers, fires per second | libxev | 1.26 | 3.58 |
| one message between loops on two cores, messages per second | libuv | 0.74, undecided | 1.12 |
| one message between loops on two cores, messages per second | libxev | 0.89, undecided | 1.11 |
| random 4 KiB file reads on a thread pool, 32 in flight | libuv | 1.00 | not measured |
| accept storm | libuv | undecided | undecided |
| accept storm | libxev | undecided | undecided |

rotor's timers keep their full rate on both machines. At 4,096 timers, libxev's fires are closer to
their deadlines than rotor's on macOS, and further from them on the EPYC 7763. On the cross-core
message, libuv's latency is lower on macOS, and the three have about the same median latency on the
EPYC 7763. [`docs/benchmarks.md`](docs/benchmarks.md) has the full tables, with latency, memory,
the machines, and the commands to take every number again.

## Documentation

| document | what it covers |
|---|---|
| [`docs/using.md`](docs/using.md) | the guide: every operation and its promises, buffers, datagrams, files, threads and limits |
| [`docs/benchmarks.md`](docs/benchmarks.md) | the full measurements, and how to take them again |
| [`docs/decisions/`](docs/decisions) | one record per design decision, with the alternatives it was chosen over |
| [`docs/costs.md`](docs/costs.md) | the measured cost of each kernel call and loop operation the decisions argue from |
| [`bench/alternatives/README.md`](bench/alternatives/README.md) | the record of every comparison experiment, including each row rotor loses and why |

<details>
<summary>The design records</summary>

| record | subject | status |
|---:|---|---|
| [1](docs/decisions/0001-interface.md) | a completion-based core | accepted |
| [2](docs/decisions/0002-scope.md) | the scope of version one | accepted |
| [3](docs/decisions/0003-speed-sources.md) | where the speed is meant to come from | accepted |
| [4](docs/decisions/0004-threading.md) | one loop per core, sharing nothing | accepted |
| [5](docs/decisions/0005-cancellation.md) | cancellation and timeouts | accepted |
| [6](docs/decisions/0006-stompy-lineage.md) | what rotor keeps from the I/O layer it grew from | accepted |
| [7](docs/decisions/0007-hot-path-ugliness.md) | where the hot path may trade clarity for speed | accepted |
| [8](docs/decisions/0008-hot-path-assertions.md) | which assertions live on the hot path | accepted |
| [9](docs/decisions/0009-sampling-and-replay.md) | sampled statistics that do not break replay | accepted |
| [10](docs/decisions/0010-no-simulator.md) | no simulator: the real kernel is the test | accepted |
| [11](docs/decisions/0011-uring-internals.md) | inside the io_uring backend | accepted |
| [12](docs/decisions/0012-kqueue-internals.md) | inside the kqueue backend | accepted |
| [13](docs/decisions/0013-when-a-loop-sleeps.md) | when a loop sleeps | proposed |
| [14](docs/decisions/0014-repeating-timers.md) | repeating timers | accepted |
| [15](docs/decisions/0015-datagrams.md) | datagrams | accepted |
| [16](docs/decisions/0016-c-abi-for-c-consumers.md) | a C ABI | proposed |
| [17](docs/decisions/0017-the-layer-that-owns-the-loop.md) | the layer that owns the loop | proposed |
| [18](docs/decisions/0018-a-caller-supplied-thread-pool.md) | a caller-supplied thread pool for file operations | accepted |
| [19](docs/decisions/0019-the-comparison-measures-one-core.md) | the comparison measures one core | accepted |
| [20](docs/decisions/0020-an-epoll-backend.md) | an epoll backend | accepted |

A proposed record describes something not yet built.

</details>

## Contributing

You need Zig 0.16.0. The Linux and race gates also need Docker. The first build fetches the lint
tooling, so it needs the network.

| command | what it does |
|---|---|
| `zig build test` | the lint, every module's tests, the conformance suite, the halt check and the format check |
| `zig build test-linux && bash tools/linux_test.sh` | the Linux tests in Docker: io_uring with `seccomp=unconfined`, epoll under the default profile |
| `zig build test-race && bash tools/race_test.sh` | the suites that start threads, under ThreadSanitizer in Docker |
| `zig build bench-echo bench-crosscore bench-alternatives` | the benchmark programs and the pinned libuv and libxev; [`docs/benchmarks.md`](docs/benchmarks.md) says how to run them |

The halt check runs each scenario in [`tools/halt/`](tools/halt) in a child process and requires it
to stop at the assertion it names, which is how an assertion is tested.
[`CLAUDE.md`](CLAUDE.md) holds the rules of the tree, for people and coding agents alike: the
style, the limits on function and file size, the commit message format, and how each test is
shown to catch the bug it covers.

| path | what it holds |
|---|---|
| [`src/rotor/`](src/rotor) | the public module: `Loop`, `Registry`, `Remote`, and the choice of backend |
| [`src/core/`](src/core) | the types every backend shares, the slot table, the timer heap and the limits |
| [`src/uring/`](src/uring), [`src/kqueue/`](src/kqueue), [`src/epoll/`](src/epoll) | the three backends |
| [`src/conformance/`](src/conformance) | the suite every backend passes |
| [`bench/`](bench) | the harness, a server per library, the cost probes and every recorded run |
| [`docs/`](docs) | the guide, the benchmarks, the design records and the table of measured costs |
| [`tools/`](tools) | the lint configuration, the halt scenarios, the io_uring probe and the Docker gates |

## License

rotor is licensed under the [Apache License 2.0](LICENSE).
