# Alternatives

This directory holds what the harness measures rotor against: the pinned version of each
alternative, one echo server written on each, and one probe that prints the size of each
alternative's per-operation structure. It also records how every libuv and libxev cell of the table
in `docs/decisions/0003-speed-sources.md` was settled. The rule is the project's: a claim is
measured or read from a source, never recalled.

Everything here was done on 2026-09-19 on the `mac` machine of `docs/costs.md`, with Zig 0.16.0.

## How to read a row

Every row carries three things beside its medians, and a row cannot be quoted without them.

- **spread percent**: the fastest run minus the slowest, over the median. A row at or above 10
  carries `**RUNS DISAGREE**` and decides nothing. The experiment that set this is below: three
  alternating rounds of two shapes of one unchanged server disagreed about which was faster.
- **load low /100** and **load span /100**: the machine's one-minute load average while the runs were
  taken, in hundredths, as the lowest reading and how far it moved. A span at or above 100, one whole
  point of load, carries `**LOAD MOVED**`.
- **verdict**: both marks when both apply.

The two marks mean different things and need different answers. A wide spread means re-take the row.
A moved load means the machine was not the same machine throughout, so wait for a quiet one and
re-take everything. Added on 2026-09-21, because four attempts on 2026-09-20 were spoiled by other
work arriving and only the spread said so: on the last one the load average climbed from 4.40 to
10.27 during the run, and reading 13 marked rows was the only way to find out.

A row whose load columns say `unknown` was taken on a host that reports no load average. It is not a
quiet row; it is a row with no evidence either way.

## The pins

| alternative | source | pin | package hash in `build.zig.zon` |
|---|---|---|---|
| libuv | `https://github.com/libuv/libuv` | tag `v1.52.1`, commit `1cfa32ff59c076ffb6ed735bbc8c18361558661f` | `N-V-__8AACwTRQDmmfDj0GPrcObUmVnktArTdpjkEvRZXTx0` |
| libxev | `https://github.com/mitchellh/libxev` | commit `9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf` | `libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F` |
| `std.Io.Uring`, `std.Io.Threaded` | the Zig installation | 0.16.0 | not a package |

How each pin was chosen:

- libuv v1.52.1 is the release GitHub marks as latest: "Version 1.52.1 (Stable)", published
  2026-03-06. The tag object is `48dbd851fe4ad7d1252b75ac907c725a437e1634` and it names the commit
  above.
- libxev has no release tag, so the pin is a commit. `9ce8e8e` was the head of `main` on
  2026-09-19. Its `build.zig.zon` asks for Zig 0.16.0 or later, and the commit two before it is
  "Zig 0.16 Compatibility (#220)". With Zig 0.16.0, `zig build` in its tree succeeds for the
  host, for `x86_64-linux-gnu` and for `aarch64-linux-gnu`, and `zig build test` passes on the
  host. It needed no patch.

Zig checks the package hash against the content it unpacks, so a tag that moved or an archive
that changed fails the fetch. To move a pin, run `zig fetch --save=<name> <url>`, confirm that
`.lazy = true` is still set, read the alternative's columns of the table again, and correct the
table first.

## How the alternatives are built

```bash
zig build bench-alternatives
```

The step fetches both packages, compiles them, and installs four programs under `zig-out/bin`:
`libuv_echo`, `libuv_sizes`, `libxev_echo` and `libxev_sizes`. `build/alternatives.zig` holds the
wiring.

- **Nothing else fetches them.** Both packages are lazy, and Zig fetches a lazy package when the
  build script calls `lazyDependency` for it. The build script cannot see which step was asked
  for, so `build/alternatives.zig` calls `lazyDependency` only under the option `-Dalternatives`,
  and the step runs `zig build bench-alternatives -Dalternatives` as a child process. Checked by
  moving both packages out of `zig-pkg/` and building with an empty global cache:
  `zig build test` passed and fetched neither, and `zig build bench-alternatives` then fetched
  both. A project that depends on rotor returns from `build.zig` before it reaches this wiring.
- **A package the global cache already holds is a different case.** Zig 0.16 unpacks it into
  `zig-pkg/` on any step, lazy or not. That reads the local cache and not the network: with the
  network blocked, `zig build test` still passed and unpacked both. It compiles nothing, because
  no step that `zig build test` runs depends on an alternative.
- **`zig build test` does not compile these programs**, because compiling them needs the
  alternatives. Run `zig build bench-alternatives` after a Zig bump or a pin bump.
- **libuv ships no `build.zig`.** Zig's C compiler builds it as a static library from the source
  lists of its `CMakeLists.txt`: `uv_sources` (lines 175 to 187), the Unix list (237 to 255),
  and the macOS (283 to 312) or Linux (283, 284, 327 to 334) additions, with the definitions of
  lines 230, 308 and 328 and the flags `-std=gnu11 -fno-strict-aliasing`. It needs no system
  library beyond libc.
- **libxev ships a `build.zig`** that exports the module `xev`, and the programs import it.
- **Both are built ReleaseFast**, the way their own users ship them, so that no result of the
  harness comes from a handicapped build. rotor itself ships ReleaseSafe.
- **Targets.** The host build was run. `-Dtarget=x86_64-linux-gnu` and
  `-Dtarget=aarch64-linux-gnu` compile and link all four programs; nobody has run those
  binaries yet, because the `linux` machine is not chosen.

## The echo servers

`libuv_echo PORT` and `libxev_echo PORT` listen on 127.0.0.1, set `TCP_NODELAY` on every
connection, print one line when they listen, and echo until they get SIGTERM. Each is written the
way that is fastest for its library, and each file's header says how. Neither allocates per
operation: `libuv_echo` reads into one buffer shared by every connection and echoes with
`uv_try_write`, and `libxev_echo` gives each connection one completion and one 64 KiB buffer.

Proof that they work, run for each server on its own port: start it, wait for the listening line,
send `hello rotor` with `nc`, send 200,000 bytes with `nc`, compare both echoes byte for byte with
`cmp`, send SIGTERM, and check that the process is gone. Both servers passed. The short form of
that check, for `libuv_echo`:

```bash
zig-out/bin/libuv_echo 47311 &
printf 'hello rotor\n' | nc -w 2 127.0.0.1 47311
kill %1
```

Open for the harness:

- `libxev_echo` holds 64 KiB per connection, which is what a completion-based read without
  provided buffers costs. The harness has to choose its connection counts with that in mind.
- No file-read program exists yet. The libuv one must run in both of libuv's configurations: the
  thread pool, and the io_uring ring that `UV_LOOP_USE_IO_URING_SQPOLL` plus `UV_USE_IO_URING=1`
  turn on.

## What libuv_echo's two buffer shapes measured, and what that says about the harness

`libuv_echo --buffers one` gives a connection one buffer and calls `uv_read_stop` while the echo
write borrows it, then `uv_read_start` when the write ends. `--buffers two` gives it two buffers
and two write requests and never stops reading, for twice the memory. Neither allocates per
message, which libuv's own `test/echo-server.c` does.

The question was whether the stop and start cost a watcher change per message and so handicap
libuv. Three alternating rounds on the `mac` machine on 2026-09-20, 16 connections, 4 KiB, four
seconds each, operations per second:

| round | `one` | `two` |
|---|---|---|
| 1 | 89,392 | 82,826 |
| 2 | 85,514 | 78,236 |
| 3 | 83,573 | 93,952 |

**The rounds disagree**: `one` wins the first two and loses the third. The spread inside one
shape, 78,236 to 93,952 for `two`, is wider than any gap between the shapes. The same machine
gave libuv 63,360 in a run an hour earlier. So this does not settle which shape is faster, and it
settles something more useful about the instrument.

**The echo workload's run-to-run noise on a busy machine is larger than the differences it is
meant to resolve.** A single run of a candidate is not evidence, whatever it says. Before any
comparison is published the harness must, on a quiet machine, repeat each candidate several
times, alternate them so drift hits every candidate equally, and report the spread beside the
median. A row without a spread cannot be read.

`one` stays the default: it is never clearly behind and it holds half the memory per connection.
The question of which shape is faster is open, and answering it needs the same quiet machine
every other number does.

## The buffer a candidate holds, and the row that measured it instead of the loops

The first full comparison put rotor at less than half of libuv and libxev on the 64 KiB rows,
28,616 against 60,979 and 61,858, and rotor's row had a spread of 4, so it was not noise. It was
not the loop either.

`rotor_echo` cuts its pool into 8 KiB buffers, so a 64 KiB message arrived in eight pieces and
cost eight sends. libuv, libxev and `std_io_echo` each hold one 64 KiB buffer per connection and
echo a whole message with one write. The comparison was measuring how the candidates were sized.

Sized alike, on the same machine, 16 connections, 64 KiB, four seconds:

| rotor's buffer | operations per second | p50 ns |
|---|---|---|
| 8 KiB | 27,488 | 548,863 |
| 64 KiB | 57,544 | 284,671 |

So `echo_runner` now passes `--buffer-bytes` equal to the payload to any candidate that takes it,
which is rotor alone: the others have one buffer per connection and nothing to choose. rotor is
still a little behind on that row with buffers matched, and that is a result and not an artefact.

The general rule this earned: **a comparison must state what each candidate holds per connection,
and match it where a candidate has the choice.** A pool of small buffers is a real design, and it
wins where messages are small; it must not be entered against 64 KiB buffers on a 64 KiB workload
and reported as a loss of the loop.

## A defect in libxev_echo, mostly fixed, and what is left of it

Running the comparison on 2026-09-20 made libxev log, on every closed connection:

```text
error(libxev_kqueue): invalid state in submission queue state=.active
```

That is libxev's own diagnostic, not the harness's, and the cause was in this tree. A connection
held one completion, and the close was asked for from inside a callback of that same completion.
libxev acts on a callback's return value only after it returns, so the completion was still
`.active` when the close arrived. A second completion per connection, used for the close alone,
fixes it: it costs one completion per connection and nothing on the message path.

**What is left.** With that fix the 4 KiB rows are silent: three rounds of 16 connections, and
three more through the runner, logged nothing. The 64 KiB rows still log it about once per three
rounds. The untested guess is the short-write path, where `on_write` submits the rest of a write
on the connection's own completion from inside that completion's callback; but a read submitted
the same way after a whole write never logs, which argues against it. The cause is not known.

So the 4 KiB libxev rows are evidence and the 64 KiB ones carry this caveat. What the error costs
is also unknown: every run completed and the client saw no stall, so it may be a complaint about
a close the loop then performs anyway.

This is the third candidate written by this project that was wrong in a way one smoke test did
not show. The others: `libuv_echo` echoed one message per connection, and `std_io_echo` served
one connection ever. All three argue the same thing: a candidate needs a test that keeps several
connections busy, not one that sends a message.

## `std.Io.Uring` is absent, because it does not compile

A seven-line program that calls `std.Io.Uring.init` and nothing else fails to build for Linux on
Zig 0.16.0, the pinned compiler:

```text
std/Io/Uring.zig:2732:32: error: expected type '...!Io.Dir', found '...'
note: 'error.ReadOnlyFileSystem' not a member of destination error set
```

`dirOpen` returns an error its own `Dir.OpenError` does not name. Nothing in this tree reaches
that function: naming the type is enough, because every arm of a switch is analysed whatever a
run-time flag says. So `std_io_echo` keeps the arm behind `uring_compiles`, which is false, and
the program builds for Linux with `threaded` alone.

`docs/decisions/0003-speed-sources.md` names `std.Io.Uring` as an alternative, and it cannot be
one on this compiler. Set `uring_compiles` to true when a Zig that builds it is pinned; nothing
else changes.

## rotor loses the 64 KiB row on io_uring, on clean rows

> **These rows are withdrawn, 2026-09-20.** They were taken before `rotor_echo` set
> `TCP_NODELAY`, and `libuv_echo` and `libxev_echo` always have. So they compare a Nagle-on
> candidate against Nagle-off ones, which is the socket option and not the loop. Milestone 4's
> own rule is that a comparison matches what each candidate holds per connection. Two defects
> since fixed also touched them: a refused submission stalled a connection silently, and a
> receive ending in `buffers_exhausted` closed the client. Every TCP row here has to be measured
> again. They are kept below, struck through in words rather than deleted, because the reasoning
> underneath them is still the reasoning to test.

Five alternating rounds in the `orbstack` container, 16 connections, three seconds, buffers
matched to the payload:

| payload | rotor | `std.Io.Threaded` |
|---|---|---|
| 4 KiB | 210,932 (spread 6) | 153,468 (spread 4) |
| 64 KiB | 36,316 (spread 5) | 71,815 (spread 5) |

Every spread was under the threshold, so neither row was noise **of the thing it measured**. It
measured the wrong thing: see the withdrawal above. What survives is the question, not the
answer.

The untested explanation: a multishot receive from a provided-buffer group takes one buffer per
completion, and TCP delivers 64 KiB in several pieces, so `rotor_echo` echoes each piece with a
send of its own. A candidate that read into one buffer until it had the message would send once.
That is a property of how this server uses the group, not of the group; whether rotor's surface
lets a server do better, and whether the same gap appears on kqueue, is the first thing to settle
before any 64 KiB claim is made.

That experiment is still the right one and it needs no kernel above the 6.1 floor: rotor's
surface already offers a receive into a caller-named buffer, so a second `rotor_echo` shape that
accumulates a whole message and sends once separates this explanation from the Nagle one in two
runs.

## Two bugs in rotor_echo, and which rows they touched

Found on 2026-09-20 by reading the file, not by a test, which is the point of writing them down.

- **A short send dropped bytes.** `handle_send` gave the provided buffer back and ignored the
  count, so a send that moved less than it was given lost the rest out of the middle of the
  stream. No test saw it: the suite sends small messages that never go short.
- **A close gave its buffer back a second time.** The close borrowed the send's `user_data` tag,
  so its completion ran the send's handler, which gave back `sending[descriptor]` — a buffer
  already returned, or for a connection that never sent, an uninitialised id. The range assert
  catches an id past the group; it cannot catch the same id twice, so two connections could be
  handed one buffer and interleave their bytes in it.

**Which rows this touches.** The echo workload closes nothing until a run ends, so its rows are
unlikely to have been affected and the numbers above did not move. The accept storm closes a
connection per operation, so **every rotor accept-storm row taken before this fix was taken with
a corrupted buffer pool**. Re-run after the fix, macOS, 256 connections, three rounds: rotor
6,491 against libuv 6,571, libxev 6,508 and `std.Io.Threaded` 6,459 — still the four inside 2
percent, still the client and not the loops.

Both bugs are the caller's to make, which is the argument the API complaint rests on: rotor hands
a partial transfer to the caller and gives it one `user_data` word to tell its own operations
apart, and a candidate written carefully got both wrong.

## What the accept storm measured, and what it could not

A run is one burst: `connections` sockets opened and connected at once, each sending a byte and
reading it back, so the server has to have accepted every one of them. Sustained churn cannot be
measured on loopback at all, and `bench/echo/storm.zig` records why.

**On macOS, 256 connections, three rounds:**

| candidate | connections per second | spread |
|---|---|---|
| rotor | 6,359 | 3 |
| libuv | 6,405 | 6 |
| libxev | 6,386 | 2 |
| `std.Io.Threaded` | 6,429 | 1 |

Four candidates inside 1.1 percent of each other, on rows clean enough to believe. That is not a
tie between the loops: **it is the client**. The same burst on io_uring reads 121,564 for rotor,
nineteen times more, and the client is the only thing that changed. rotor's kqueue client makes a
system call per operation where its io_uring client batches, so on macOS the storm measures the
client's submission cost and every candidate waits behind it.

So **no macOS accept-storm row is evidence about a candidate**, and the workload needs a client
that is not the bottleneck there before it can be. That is a harness problem and not a rotor one.

**On io_uring, 256 connections, nine rounds:**

| candidate | connections per second | spread |
|---|---|---|
| rotor | 123,170 | 39 |
| `std.Io.Threaded` | 54,509 | 88 |

rotor's median is about 2.2 times the other's, and it held across runs of three and nine rounds.
Both rows are marked: a burst takes about 2 ms, so a scheduler hiccup moves a whole round, and
more rounds did not narrow it. **Nothing is decided.** What would decide it is a longer burst,
which costs ephemeral ports the run already budgets for, or several bursts inside one run, which
costs the same ports. The port range is the binding constraint on this workload and the machines
that can answer it are not the ones this was run on.

## Timer churn, and the one thing libuv cannot be asked for

`rotor_timers` and `libuv_timers` make the same measurement: keep N timers armed, re-arm each as
it fires, and report fires per second and how late each was against its deadline.

**libuv timers are milliseconds.** `uv_timer_start` takes a whole number of them, so a period
under 1,000 microseconds cannot be expressed at all and one that is not a whole millisecond is
rounded down. rotor's timer takes nanoseconds. `libuv_timers` refuses a period it would have to
round, so a run cannot silently compare a 1,500 microsecond timer against a 1,000 microsecond
one. That is a difference in what the two can be asked for, before any difference in what they do.

Single runs on the `mac` machine, 1 ms period, two seconds each. **Single runs are not evidence**
(this file's first section says why), and no `Series` was taken because the runner cannot yet
drive this workload:

| timers | rotor fires/s | libuv fires/s | rotor p50 late | libuv p50 late | rotor p99 | libuv p99 |
|---|---|---|---|---|---|---|
| 256 | 149,234 | 129,902 | 183 µs | 230 µs | 3.4 ms | 6.8 ms |
| 1,024 | 468,745 | 490,762 | 362 µs | 464 µs | 8.3 ms | 7.1 ms |
| 4,096 | 1,331,930 | 1,329,443 | 1,034 µs | 1,739 µs | 4.5 ms | 3.0 ms |

Throughput is level: within 15 percent at the smallest load and within 1 percent at the largest.
The median lateness is rotor's by 20, 22 and 41 percent, in that order, which is the one thing
consistent across all three. The tail is not rotor's at the two larger loads, and that is the
kind of mixed result a single run is least able to settle.

`bench/timers/timers_runner.zig` now drives this workload: it starts each candidate's program
once per round, alternating the candidates within a round, and reads the result line each one
printed. So these single runs are superseded by rows with a spread as soon as a quiet machine is
available. Nothing above has been re-taken.

### `std.Io` is the fourth candidate, and its shape is the row

`std.Io` offers no timer. It offers `sleep`, and a task that sleeps. So N timers written against
the interface is N tasks, and `bench/alternatives/std_io_timers.zig` writes it that way because
nothing else the interface offers arms a timer. Under `std.Io.Threaded` a sleeping task holds the
worker thread it runs on, because `sleep` there is `clock_nanosleep` on that thread. So **N timers
is N threads**.

What each candidate holds per armed timer, which is this file's rule applied to a workload with no
connections:

| candidate | per armed timer |
|---|---|
| rotor | one 64-byte slot of the loop's memory |
| libuv | one `uv_timer_t`, caller-owned |
| libxev | one `xev.Timer` and one `xev.Completion`, caller-owned |
| `std.Io.Threaded` | one OS thread with a default thread stack, plus one `Group.Task` |

The thread count is checked and not assumed. On the `mac` machine, a 512-timer run reported 513
threads while it ran, which is 512 workers and the main thread:

```bash
./zig-out/bin/std_io_timers --timers 512 --period-us 1000 --seconds 4 >/dev/null &
ps -M $! | wc -l
```

**That is a count of threads and not a measurement.** No throughput or lateness number for this
candidate is recorded anywhere yet, and the run above was made on a machine doing other work.

A host that refuses the threads fails the run: `Group.concurrent` answers
`error.ConcurrencyUnavailable`, and the program turns that into `error.ThreadPerTimerRefused` and
exits non-zero rather than arming fewer timers than its row would claim. The runner then names the
candidate and the count, and prints no row for it. A missing row at a large count is the same
finding stated more sharply.

`std.Io.Uring` is a candidate of this workload too, and it is absent for the reason this file's own
section gives: it does not compile on the pinned Zig. It is Linux-only besides, so the runner names
it and skips it on any other host.

## The cross-core message, and one way its candidates are not measured alike

`crosscore_runner` compares one cross-core message: rotor's `post`, libuv's `uv_async_send` and
libxev's `xev.Async`. All three block between messages, because neither alternative offers anything
else. There is no libuv or libxev call that polls for a notification without sleeping, so rotor is
compared in its `waiting` mode alone; `bench/crosscore/rotor_post.zig` keeps rotor's two other
modes and names them in the candidate column, so no table reads as though an alternative had been
offered the same choice.

**The percentiles are not computed the same way in all three.** rotor and libxev record into
`bench/harness/histogram.zig`. libuv sorts an array in C, because a C program cannot import that
file.

- The histogram keeps 7 sub-bucket bits, so one bucket spans about 1/128 of its value, and
  `percentile` returns `bucket_upper_ns`, the largest value that bucket holds.
- So rotor's and libxev's percentiles are **overstated by at most 0.78 percent**, and libuv's are
  exact.

The bias runs against rotor and never for it, which is why this is recorded and not corrected: no
reader can be misled in rotor's favour by it. It is worth fixing when two candidates land within
one percent of each other, and no run has. Throughput is unaffected, because every candidate
counts its own operations and divides by its own span.

No cross-core row is recorded here yet. The first three-way run was made on 2026-09-20 on a `mac`
carrying a load average above 13, which is not a measurement and is not reproduced in this file.

## Why rotor loses the file rows on macOS, and why that says nothing about Linux

Read on 2026-09-20 on a `mac` carrying a load average above 13. **The throughputs are not
measurements and no row of them belongs in a claim.** What is recorded here is the *shape* across
queue depth, which every candidate met under the same load, alternating within each round. The
ratio is the finding; the absolute numbers are not.

Random 4 KiB reads, three rounds each, reads per second:

| depth | rotor | libuv (thread pool) | ratio |
|---:|---:|---:|---:|
| 1 | 9,804 | 10,422 | 1.06 |
| 4 | 11,066 | 40,376 | 3.6 |
| 32 | 11,432 | 43,575 | 3.8 |

Three things in that table identify the cause.

- **At depth 1 the two are at parity.** rotor's read path is not slower than libuv's. The gap
  appears only as depth rises.
- **libuv gains about four times from depth 1 to depth 4, and then stops.** Its default pool is
  four threads: `static uv_thread_t default_threads[4]`, src/threadpool.c line 39. Its ceiling is
  its thread count.
- **rotor gains 17 percent across a 32-fold rise in depth**, and its p50 grows with depth:
  100,000 ns, then 363,000 ns, then 2,794,000 ns. That is a queue behind one server. libuv's p50
  at depth 32 is 722,000 ns, about four times lower, which is four servers.

**The cause is queue depth at the device, not parallelism across cores.** A 4 KiB O_DIRECT read is
a device round trip and not computation. libuv's pool is not computing on four cores; it is the
only way a blocking `pread` can have more than one request outstanding at once. rotor's kqueue
backend calls `std.c.pread` on the loop thread (src/kqueue/kqueue_perform.zig), so `--depth 32` is
depth 1 in fact.

That is `docs/decisions/0002-scope.md`'s recorded choice and not a defect. That record weighed
handing the read to a thread pool "as libuv does" and refused it, because the loop starts no
thread, and it wrote down the consequence: macOS is a development platform, and no file-workload
number from macOS is published as a claim. There is no fourth option either: macOS has `aio_read`
but not `EVFILT_AIO`, so those completions cannot reach a kqueue loop.

**It predicts the opposite on Linux.** io_uring submits N reads in one system call and the kernel
holds all N in flight at the device, which is real queue depth with no thread at all. If the Linux
rows show rotor flat across depth the way these do, that is a defect and this explanation does not
cover it. Rows C12 and C13 of `docs/costs.md` are depth 1 and depth 32 for this reason.

A consumer that wants parallel file I/O on a Mac runs one loop per thread. rotor enables that and
does not decide it, as `docs/decisions/0004-threading.md` has it.

## The size probes

`libuv_sizes` and `libxev_sizes` print the numbers of row 7 for the target they were built for.
On the host they print what the table says: `uv_write_t` 192, `uv_fs_t` 440, `uv_tcp_t` 264, and
`xev.Completion` 176 bytes with 8-byte alignment on kqueue. The Linux numbers were read as
constants from the assembly of a cross-compile, because a Linux binary does not run on the
development machine. Run both probes on the `linux` machine to confirm them.

| structure | aarch64 macOS | x86_64 Linux, glibc | aarch64 Linux, glibc |
|---|---|---|---|
| `uv_write_t` | 192 | 192 | 192 |
| `uv_fs_t` | 440 | 440 | 440 |
| `uv_tcp_t` | 264 | 248 | 248 |
| `xev.Completion`, io_uring | does not apply | 128 | 128 |
| `xev.Completion`, epoll | does not apply | 184 | 184 |
| `xev.Completion`, kqueue | 176 | does not apply | does not apply |

## What the record said and what the source says

The citations for every row are under the table in `docs/decisions/0003-speed-sources.md`. This
is the account of what changed. "As it was" means the source confirmed the cell.

| row | library | the record said, from memory | the pinned source says | verdict |
|---|---|---|---|---|
| 1 | libuv | no | no: `uv__io_uring_register` is defined at `src/unix/linux.c:450` and nothing calls it | as it was |
| 1 | libxev | no | no: `linux.IoUring.init(entries, 0)` at `src/backend/io_uring.zig:72`, and nothing is registered | as it was |
| 2 | libuv | no; readiness by epoll | no: none of libuv's 13 io_uring opcodes is an accept, receive or send (`src/unix/linux.c:138`); `epoll_pwait`, then `accept4` and `read` | as it was |
| 2 | libxev | no | no: `prep_accept` and `prep_recv` are single-shot (`src/backend/io_uring.zig:405`, `:456`) | as it was |
| 3 | libuv | no for sockets: one `recv` or `send` syscall each | the calls are `read`, and `write` or `writev`. libuv does batch its `epoll_ctl` calls through an io_uring ring, which every loop creates by default (`src/unix/linux.c:651`, `:1271`, `:1297`) | corrected |
| 3 | libxev | yes | yes on io_uring. On kqueue only registrations batch; each ready operation is its own syscall (`src/backend/kqueue.zig:1146`) | corrected |
| 4 | libuv | no: `epoll_wait` plus one syscall per ready socket | no: `epoll_pwait`, plus an `io_uring_enter` when registrations changed, plus one syscall per ready socket | detail added |
| 4 | libxev | yes | yes on io_uring (`src/backend/io_uring.zig:172`). No on kqueue: a `kevent` to submit and a second to wait (`src/backend/kqueue.zig:234`, `:493`) | corrected |
| 5 | libuv | caller-owned requests, plus an `alloc_cb` call per read | the same, and libuv calls `malloc` itself past 4 buffers per write (`src/unix/stream.c:1370`) and for every asynchronous file operation that names a path (`src/unix/fs.c:112`) | detail added |
| 5 | libxev | yes | yes: no backend or watcher names an allocator | as it was |
| 6 | libuv | no: a 4-thread pool runs file operations and DNS | the same, per process, on Linux and macOS. A loop option plus `UV_USE_IO_URING=1` moves up to 15 file operations to an io_uring ring with `IORING_SETUP_SQPOLL`; v1.49.0 turned that off by default (`src/unix/linux.c:766`, `:479`; `docs/src/fs.rst:19`) | detail added |
| 6 | libxev | yes on io_uring; a pool for files on kqueue | the same, and on epoll too. The pool is the caller's: the loop starts no thread, and a file operation fails with `error.ThreadPoolRequired` when no pool was given (`src/watcher/file.zig:131`, `src/backend/kqueue.zig:870`) | detail added |
| 7 | libuv | not a goal | measured: `uv_write_t` 192 bytes, `uv_fs_t` 440, `uv_tcp_t` 248 on Linux and 264 on macOS | corrected |
| 7 | libxev | caller-owned completion of a few hundred bytes | measured: 128 bytes on io_uring, which libxev's own test pins (`src/backend/io_uring.zig:1126`); 176 on kqueue, 184 on epoll | corrected |

The reading also corrected row 5 of `std.Io.Threaded`. The record said "thread pool, allocator".
The source says an I/O call allocates nothing: it is a blocking syscall on the calling thread
(`Io/Threaded.zig:12604`). The allocator serves one call per task that `async` or `concurrent`
starts (`Io/Threaded.zig:676`).

## Neither libuv nor libxev spreads TCP load across cores on kqueue

Read on 2026-09-21, from the pinned trees, when issue 1 asked how libuv and libxev produce a
loop-per-core server on kqueue. The answer is that neither does, and libuv declines the capability
on purpose.

| library | what it offers on kqueue | source |
|---|---|---|
| libuv | nothing. `uv_tcp_bind` with `UV_TCP_REUSEPORT` returns `UV_ENOTSUP` on macOS | `src/unix/core.c:2143`, `src/unix/tcp.c:170` |
| libxev | nothing. `xev.TCP.bind` sets `SO_REUSEADDR` and no more | `src/watcher/tcp.zig:88` |
| `std.Io.Threaded` | sets `SO_REUSEPORT` on every platform that defines it, macOS included | `Io/Threaded.zig:11688` |

`uv__sock_reuseport` has three branches: `SO_REUSEPORT_LB` on FreeBSD 12 and later,
`SO_REUSEPORT` on Linux, AIX 7.2.5, DragonFlyBSD 3.6 and Solaris 11.4, and `return UV_ENOTSUP` for
everything else. macOS is in the last one, and libuv's own comment gives the reason: a
`SO_REUSEPORT` without load balancing has semantics that "are completely different, therefore we
shouldn't enable it, but fail this operation". `docs/src/tcp.rst:159` says the same in the public
documentation, and the flag arrived in v1.49.0.

libuv's one sanctioned route to several cores on macOS is the model Node.js uses: one loop accepts,
then passes the accepted handle to another **process** through a pipe, with `uv_write2`'s
`send_handle` (`docs/src/stream.rst:190`). That is a different program, not a loop per core inside
one process.

libxev's `ThreadPool` is not a counter-example. It runs blocking file work, and a file operation
fails with `error.ThreadPoolRequired` when the caller gave the loop no pool
(`src/backend/kqueue.zig:870`); it moves no socket between loops. No libxev example or benchmark
runs a loop per core.

`std.Io.Threaded` is the one candidate that sets the option on macOS. It sets it whenever
`reuse_address` is set, on any platform that defines `SO.REUSEPORT`. On macOS that is the
behaviour `src/conformance/conformance_reuse_port.zig` measured as 0, 0, 0, 32 — every connection
to the last listener bound — which is the outcome libuv refuses to expose.

**What this settled.** The owner ruled on 2026-09-21 that the echo comparison measures 1 core only,
with no skewed rows, and `docs/decisions/0019-the-comparison-measures-one-core.md` records it and
amends decision 4. Rows C17, C18 and C19 are unaffected: `bench/crosscore/` measures the cross-core
message on its own, as decision 4 says.

## What this means for rotor's claims

Weaker than the record assumed:

- Source 7 against libxev. The completion is 128 bytes, not a few hundred, so the difference is
  one or two cache lines per operation and not several.
- Source 6 against libuv. It holds against the default, the thread pool. libuv can also run file
  reads on an io_uring ring, so the harness must run libuv both ways.
- Source 5 against libuv and `std.Io.Threaded`. Neither allocates per operation on the harness's
  workloads. `std.Io.Threaded` allocates per task.
- libuv already uses io_uring by default, for `epoll_ctl` alone. "libuv does not use io_uring" is
  false, and no document may say it.

Stronger than the record assumed:

- Source 4 against libxev on kqueue. libxev makes two `kevent` calls per tick, and its source
  carries a TODO to merge them. macOS numbers stay development numbers (decision 2).

Unchanged: against libxev on io_uring, sources 3 to 6 are parity, and sources 1 and 2 are the
difference.
