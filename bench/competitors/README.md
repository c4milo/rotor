# Competitors

This directory holds what the harness measures rotor against: the pinned version of each
competitor, one echo server written on each, and one probe that prints the size of each
competitor's per-operation structure. It also records how every libuv and libxev cell of the table
in `docs/decisions/0003-speed-sources.md` was settled. The rule is the project's: a claim is
measured or read from a source, never recalled.

Everything here was done on 2026-09-19 on the `mac` machine of `docs/costs.md`, with Zig 0.16.0.

## The pins

| competitor | source | pin | package hash in `build.zig.zon` |
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
`.lazy = true` is still set, read the competitor's columns of the table again, and correct the
table first.

## How the competitors are built

```bash
zig build bench-competitors
```

The step fetches both packages, compiles them, and installs four programs under `zig-out/bin`:
`libuv_echo`, `libuv_sizes`, `libxev_echo` and `libxev_sizes`. `build/competitors.zig` holds the
wiring.

- **Nothing else fetches them.** Both packages are lazy, and Zig fetches a lazy package when the
  build script calls `lazyDependency` for it. The build script cannot see which step was asked
  for, so `build/competitors.zig` calls `lazyDependency` only under the option `-Dcompetitors`,
  and the step runs `zig build bench-competitors -Dcompetitors` as a child process. Checked by
  moving both packages out of `zig-pkg/` and building with an empty global cache:
  `zig build test` passed and fetched neither, and `zig build bench-competitors` then fetched
  both. A project that depends on rotor returns from `build.zig` before it reaches this wiring.
- **A package the global cache already holds is a different case.** Zig 0.16 unpacks it into
  `zig-pkg/` on any step, lazy or not. That reads the local cache and not the network: with the
  network blocked, `zig build test` still passed and unpacked both. It compiles nothing, because
  no step that `zig build test` runs depends on a competitor.
- **`zig build test` does not compile these programs**, because compiling them needs the
  competitors. Run `zig build bench-competitors` after a Zig bump or a pin bump.
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
