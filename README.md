# rotor

[![CI](https://github.com/c4milo/rotor/actions/workflows/ci.yml/badge.svg)](https://github.com/c4milo/rotor/actions/workflows/ci.yml)

rotor is an event loop and I/O layer for Zig 0.16. It is completion-based: a program submits
operations in batches, and each tick returns their results with one system call. It runs on Linux
io_uring and macOS kqueue, and on Linux epoll where the kernel refuses io_uring.

The goal is to be faster than libuv, libxev and Zig's `std.Io` on named workloads, and to show it
with a benchmark harness anyone can run again. The [results](#performance) include the rows where
rotor loses.

The latest release is `v0.3.0`.

- [What rotor promises](#what-rotor-promises)
- [Platforms](#platforms)
- [Install](#install)
- [Example](#example)
- [What a loop can do](#what-a-loop-can-do)
- [Performance](#performance)
- [Build and test](#build-and-test)
- [Repository layout](#repository-layout)
- [Design records](#design-records)
- [Not in version one](#not-in-version-one)

## What rotor promises

- **It allocates nothing.** The caller gives each loop its memory at init. Every table and queue
  inside a loop has a named limit.
- **A loop belongs to one thread.** It holds no lock and starts no thread. Another thread reaches
  it only by posting a message.
- **Every operation ends with exactly one final event.** The buffer an operation names belongs to
  the loop until that event arrives.
- **Batches come first.** One `submit` takes many operations, and one `tick` returns many events.
- **Assertions stay on in production.** The build offers Debug and ReleaseSafe only.
- **A loop's behaviour depends only on what the caller submits and what the kernel answers.**
  Nothing in the shared core reads the clock, a random number or a pointer value.

## Platforms

| host | backend | needs | tested on |
|---|---|---|---|
| Linux | io_uring | Linux 6.1 or later, with the io_uring features [listed in the guide](docs/using.md#what-the-kernel-must-have) | Linux 7.0 on aarch64, Linux 6.17 on x86-64 |
| Linux where io_uring is refused, or lacks a feature rotor needs | epoll | nothing beyond epoll | Docker's default seccomp profile, which refuses io_uring |
| macOS | kqueue | nothing beyond kqueue | macOS 26.6 on Apple M1 Pro |

A process picks its backend once, the first time it needs one: it asks the kernel for an io_uring
ring with the features rotor needs, and runs epoll if the kernel refuses or lacks one.
`rotor.backend()` says which backend runs. The API is the
same on every backend. rotor makes no speed claim for epoll: it exists so a program runs where
io_uring is refused.

On kqueue and epoll the kernel cannot complete a file operation, so a loop that touches files there
needs a `file_policy` at init: refuse, block the loop, or hand the work to threads the caller
supplies. The [guide](docs/using.md#files) explains the three.

## Install

```bash
zig fetch --save git+https://github.com/c4milo/rotor#v0.3.0
```

In `build.zig`:

```zig
const rotor = b.dependency("rotor", .{ .target = target, .release = optimize != .Debug });
exe.root_module.addImport("rotor", rotor.module("rotor"));
```

rotor's build takes `release`, not `optimize`: it builds Debug or ReleaseSafe, and has no mode
that removes its assertions.

## Example

A repeating timer that fires five times, then is cancelled:

```zig
const std = @import("std");
const rotor = @import("rotor");

pub fn main() !void {
    // The caller owns every byte the loop uses.
    const options: rotor.Loop.Options = .{ .operations = 64 };
    var memory: [rotor.Loop.memory_bytes(options)]u8 align(rotor.memory_alignment) = undefined;
    var loop: rotor.Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();

    // One repeating timer: first fire after 100 ms, then every 100 ms.
    const period_ns = 100 * rotor.constants.ns_per_ms;
    var handles: [1]rotor.Handle = undefined;
    const taken = loop.submit(&.{rotor.Operation.timer(1, period_ns, period_ns)}, &handles);
    std.debug.assert(taken == 1);

    var fired: u32 = 0;
    var events: [16]rotor.Event = undefined;
    while (true) {
        const count = try loop.tick(&events, rotor.constants.ns_per_s);
        for (events[0..count]) |event| {
            // Every operation ends with exactly one final event: the one without `more`.
            if (!event.flags.more) return; // the answer to the cancel below
            fired += 1;
            std.debug.print("{t}: fire {d}\n", .{ rotor.backend(), fired });
            if (fired == 5) loop.cancel(handles[0]);
        }
    }
}
```

On macOS it prints:

```text
kqueue: fire 1
kqueue: fire 2
kqueue: fire 3
kqueue: fire 4
kqueue: fire 5
```

On Linux the lines start with `uring`, or with `epoll` in a container that refuses io_uring.

For a full server, [`bench/echo/rotor_echo.zig`](bench/echo/rotor_echo.zig) is the TCP echo server
the comparison runs: a multishot accept, a multishot receive per connection from a provided-buffer
group, and one send per receive.

## What a loop can do

| operation | what it does |
|---|---|
| `accept` | accepts a connection; with `multishot`, every connection from one submission |
| `connect` | connects a socket to an `Address` |
| `receive` | receives into a buffer, or into a buffer the loop picks from a group; with a group, `multishot` |
| `send` | sends a buffer |
| `shutdown`, `close` | shuts down or closes a descriptor; `close` cancels the descriptor's operations first |
| `read`, `write`, `fdatasync` | file I/O at an offset |
| `timer` | fires once, or every period until cancelled |
| `post` | sends a message to another loop |
| `receive_from`, `send_to` | UDP datagrams, with segmentation offload, receive coalescing and ECN on Linux |
| `nop` | completes with no effect |

Any operation takes a deadline (`timeout_ns`), and `cancel` ends it early by its handle. A loop also
has:

- registered descriptors and registered buffers, which io_uring uses to skip per-operation work;
- provided-buffer groups, from which the kernel picks the buffer for each receive;
- a `Registry` for loops that post messages to each other, and a `Remote` for a thread that owns no
  loop;
- sampled statistics: one operation in a configurable number records its latency.

[`docs/using.md`](docs/using.md) is the guide: what each call promises, what it needs from the
caller, and every limit.

## Performance

Every number here comes from the harness in [`bench/`](bench), and each table links to the run it
came from. The harness runs each candidate on one core, runs every candidate in turn within each
round so that drift in the machine affects them alike, and reports the median of the runs. The
spread is the fastest run minus the slowest, divided by the median. A row with a spread of 10
percent or more is marked **RUNS DISAGREE** and decides nothing.

[`bench/alternatives/README.md`](bench/alternatives/README.md) explains every table, including the
rows rotor loses, and pins the version of each alternative. The tables below come from two of the
machines named in [`docs/costs.md`](docs/costs.md):

- `mac`: Apple M1 Pro, macOS 26.6.2, kqueue.
- `github`: a GitHub-hosted runner with 4 virtual x86-64 CPUs, Linux 6.17, io_uring. It is a
  shared cloud machine, and the processor differs between runs; the run below got an AMD EPYC 9V74.

No number exists yet for the Linux machine rotor is meant to be deployed on, because that machine
is not named yet.

### Echo on `mac` (kqueue)

TCP echo on one core, 2026-09-22
([run](bench/results/echo-mac-2026-09-22.md)). The run also measured `std.Io.Threaded`.

| connections | payload | candidate | messages per second | p50 µs | p99 µs | spread % |
|---:|---:|---|---:|---:|---:|---|
| 16 | 4 KiB | rotor | 159,103 | 92 | 207 | 2 |
| 16 | 4 KiB | libuv | 158,001 | 92 | 217 | 0 |
| 16 | 4 KiB | libxev | 128,484 | 118 | 238 | 0 |
| 16 | 64 KiB | rotor | 61,937 | 260 | 444 | 3 |
| 16 | 64 KiB | libuv | 63,673 | 232 | 489 | 3 |
| 16 | 64 KiB | libxev | 63,193 | 224 | 496 | 2 |
| 64 | 4 KiB | rotor | 151,102 | 381 | 844 | 2 |
| 64 | 4 KiB | libuv | 148,613 | 430 | 1,028 | 5 |
| 64 | 4 KiB | libxev | 164,166 | 319 | 782 | 12 **RUNS DISAGREE** |
| 64 | 64 KiB | rotor | 56,632 | 1,114 | 1,950 | 1 |
| 64 | 64 KiB | libuv | 57,000 | 1,122 | 2,015 | 2 |
| 64 | 64 KiB | libxev | 53,869 | 1,212 | 1,761 | 1 |

rotor and libuv are level on every row.

### Echo on `github` (io_uring)

TCP echo on one core, 2026-09-22, with rotor's buffer group sized to two buffers per connection
([run](bench/results/echo-sized-pool-github-2026-09-22.md)). The run also measured 8 KiB and 16 KiB
payloads and `std.Io.Threaded`.

| connections | payload | candidate | messages per second | p50 µs | p99 µs | spread % | peak memory MB |
|---:|---:|---|---:|---:|---:|---|---:|
| 16 | 4 KiB | rotor | 136,066 | 116 | 151 | 1 | 3.96 |
| 16 | 4 KiB | libuv | 130,510 | 121 | 174 | 1 | 3.31 |
| 16 | 4 KiB | libxev | 121,730 | 130 | 176 | 1 | 3.31 |
| 16 | 64 KiB | rotor | 26,044 | 614 | 672 | 2 | 6.16 |
| 16 | 64 KiB | libuv | 25,785 | 623 | 655 | 0 | 4.33 |
| 16 | 64 KiB | libxev | 28,257 | 565 | 651 | 2 | 4.33 |
| 64 | 4 KiB | rotor | 138,324 | 459 | 494 | 1 | 8.57 |
| 64 | 4 KiB | libuv | 131,967 | 485 | 635 | 0 | 8.57 |
| 64 | 4 KiB | libxev | 133,410 | 479 | 508 | 1 | 8.57 |
| 64 | 64 KiB | rotor | 26,362 | 2,425 | 2,572 | 0 | 12.45 |
| 64 | 64 KiB | libuv | 25,808 | 2,490 | 2,589 | 2 | 8.87 |
| 64 | 64 KiB | libxev | 29,035 | 2,245 | 2,490 | 2 | 8.87 |

rotor leads at 4 KiB and trails libxev at 64 KiB.
[`bench/alternatives/README.md`](bench/alternatives/README.md#rotor-loses-the-64-kib-row-on-io_uring-on-clean-rows)
records what is known about the 64 KiB rows.

### Timer churn on `mac`

Timers on a 1 ms period, each library in the cheapest mode it offers
([run](bench/results/timers-modes-mac-2026-09-22.md)). Lateness is how long after its deadline a
timer fired.

| timers | candidate | fires per second | p50 late µs | p99 late µs | spread % |
|---:|---|---:|---:|---:|---|
| 256 | rotor (repeating) | 255,974 | 169 | 527 | 0 |
| 256 | libxev | 220,901 | 180 | 250 | 1 |
| 256 | libuv (repeating) | 209,337 | 185 | 757 | 3 |
| 4,096 | rotor (repeating) | 4,094,231 | 793 | 1,075 | 0 |
| 4,096 | libxev | 3,252,874 | 53 | 1,051 | 2 |
| 4,096 | libuv (repeating) | 2,024,570 | 1,089 | 1,353 | 3 |

A 1 ms period asks each timer for 1,000 fires per second, and only rotor keeps that rate. libxev
fires closer to the deadline: on p99 at 256 timers, and on p50 and p99 at 4,096. A rotor timer is
scheduled from its previous deadline, so it never drops a period. The others schedule the next fire
from the clock at the moment they fire, so they fire less often and each fire is less late.

### One cross-core message on `mac`

Two loops on two cores send a message back and forth, each waiting in its tick for the other's
message ([run](bench/results/crosscore-mac-2026-09-22-after.md)). One message is half a round trip.
rotor's message carries a 16-byte payload; libuv's and libxev's carry none.

| candidate | messages per second | p50 ns | p99 ns | spread % |
|---|---:|---:|---:|---|
| rotor | 384,127 | 2,007 | 8,031 | 14 **RUNS DISAGREE** |
| libuv | 518,732 | 1,500 | 6,000 | 4 |
| libxev | 434,027 | 2,007 | 8,031 | 8 |

libuv is faster here.

### File reads and writes on `mac`

A 256 MiB file on the internal NVMe, 32 operations in flight
([run](bench/results/files-mac-2026-09-22.md)). kqueue cannot complete a file operation. `rotor`
runs the call on the loop's thread, and `rotor (registered, offload)` hands it to a pool of threads
the caller supplies.

| workload | block | candidate | operations per second | spread % |
|---|---:|---|---:|---|
| sequential read | 4 KiB | rotor (registered, offload) | 125,285 | 2 |
| sequential read | 4 KiB | libuv (thread pool) | 123,006 | 1 |
| sequential read | 4 KiB | rotor | 44,878 | 3 |
| random read | 4 KiB | rotor (registered, offload) | 48,095 | 3 |
| random read | 4 KiB | libuv (thread pool) | 48,145 | 1 |
| random read | 4 KiB | rotor | 12,452 | 0 |
| sequential write, then `fdatasync` | 4 KiB | rotor (registered, offload) | 662 | 94 **RUNS DISAGREE** |
| sequential write, then `fdatasync` | 4 KiB | libuv (thread pool) | 2,005 | 28 **RUNS DISAGREE** |
| sequential write, then `fdatasync` | 4 KiB | rotor | 5,181 | 7 |

The offload and libuv's pool are level on reads. On synced writes, one thread flushing in order is
faster than several threads waiting on the drive's flush.

## Build and test

| command | what it does |
|---|---|
| `zig build` | builds the library |
| `zig build test` | the lint, every module's tests, the conformance suite, the halt check and the format check |
| `zig build test-linux && bash tools/linux_test.sh` | the Linux tests in Docker: io_uring with `seccomp=unconfined`, epoll under the default profile |
| `zig build test-race && bash tools/race_test.sh` | the suites that start threads, under ThreadSanitizer in Docker |
| `zig build bench-echo bench-alternatives` | the echo servers, the runner, and the pinned libuv and libxev |
| `./zig-out/bin/echo_runner` | the echo comparison; `--workload storm` runs the accept storm |

One conformance suite, written against the loop's API, runs on every backend. The halt check runs
each scenario in [`tools/halt/`](tools/halt) in a child process and requires it to stop on the
assertion it names. CI runs the macOS tests, the Linux tests and the race tests on every push.

[`CLAUDE.md`](CLAUDE.md) holds the rules of the tree: the style, the limits on function and file
size, the commit format, and how a test is shown to catch the bug it covers.

## Repository layout

| path | what it holds |
|---|---|
| [`src/rotor/`](src/rotor) | the public module: `Loop`, `Registry`, `Remote`, and the choice of backend |
| [`src/core/`](src/core) | the types every backend shares, the slot table, the timer heap and the limits |
| [`src/uring/`](src/uring) | the io_uring backend |
| [`src/kqueue/`](src/kqueue) | the kqueue backend |
| [`src/epoll/`](src/epoll) | the epoll backend |
| [`src/conformance/`](src/conformance) | the suite every backend passes |
| [`bench/`](bench) | the harness, a server per candidate, the cost probes and every recorded run |
| [`docs/`](docs) | the guide, the design records, and the table of measured costs |
| [`tools/`](tools) | the lint configuration, the halt scenarios, the io_uring probe and the Docker gates |

## Design records

Each record in [`docs/decisions/`](docs/decisions) states one decision, the alternatives it was
chosen over, and the measured costs it was argued from. [`docs/costs.md`](docs/costs.md) holds those
costs.

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

## Not in version one

TLS, DNS, Unix sockets, process spawning, Windows, and a `std.Io` adapter over the loop.
[Record 2](docs/decisions/0002-scope.md) says why, and what would bring each one in.
