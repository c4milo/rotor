# 35. Parts a program leaves out at build time

Status: **proposed** on 2026-11-17. Nothing is built. It answers two issues from stompy:
[c4milo/rotor#9](https://github.com/c4milo/rotor/issues/9), a build without the io_uring backend,
and [c4milo/rotor#17](https://github.com/c4milo/rotor/issues/17), a build without the registry's
wake on kqueue. Each open question has a proposed answer. Nothing is built before Camilo accepts
this record.

Nothing was measured for this record. The change has no cost at run time, because each choice is
known at compile time. "What it costs" says what the build and the tests pay.

## Context

### What stompy checks

stompy's Postgres extension links rotor's loop inside `libstompy_core.a`. stompy's rule is that the
archive allocates nothing. Its build proves the rule from the archive's symbols: each C library
symbol that the archive needs must be on a closed list. A symbol on the list needs a reason.

At v0.11.0 the list holds four symbols for code that never runs in the extension:

| host | symbols | where they come from | why the code never runs |
|---|---|---|---|
| Linux | `mmap64`, `munmap` | the ring setup: `posix.mmap` <- `IoUring.SubmissionQueue.init` <- `uring_ring.Ring.init` <- `Io.init` and `uring.refused` | each entry point calls `require_backend(.epoll)` before it makes a loop, because a Postgres worker sleeps on the loop's descriptor (decision 23) |
| macOS | `dup`, `dup2` | `kqueue_wake.claim` <- `Loop.init` in `kqueue.zig`, and `kqueue_wake.release` <- `Loop.deinit` | each loop of the core starts with no registry |

### Why the code stays in the archive

Zig compiles a function only when something refers to it. Here the reference is in a branch on a
value that is known only at run time:

- `chosen()` in `src/rotor/rotor_loop_backend.zig` asks `uring.refused()` when no choice is stored.
  `rotor_sync.zig` and `rotor_loop.zig` switch on the choice, and each switch has a `.uring` arm.
- `Loop.init` in `kqueue.zig` calls `wake_module.claim` when `options.registry` is not null. Its
  `deinit` calls `wake_module.release` on the same condition.

A program cannot tell the compiler that the branch is dead. So the code compiles, and its C
library symbols go into the archive. The linker keeps them too, because the reference is in live
code.

On Linux the registry's wake makes raw system calls (`linux.dup3`, `linux.pipe2`), so it adds no
C library symbol. Only kqueue's wake calls the C library for it.

### The precedent

Decision 30 has a declaration that a program makes in its root file, `rotor_scheduling_groups`.
The public module reads it through `@import("root")`, as std reads `std_options`. Camilo ruled on
2026-11-07 that this read is not an edge of `build/modules.zig`, and that core reads no root file.

## The decision, as proposed

### One declaration in the program's root file

A program that leaves a part out declares `rotor_options` in its root file:

```zig
pub const rotor_options: rotor.Options = .{
    .uring = false,
    .registry = false,
};
```

`rotor.Options` has a default for each field, so a program names only what it leaves out. A
program that declares nothing gets what it gets today.

| field | default | when it is false |
|---|---|---|
| `uring` | `true` | Linux only. The build holds no io_uring backend. `chosen()` returns `.epoll` and does not ask the kernel. `require_backend(.uring)` returns `error.Unsupported`. `rotor.backend()` never reports `.uring` |
| `epoll` | `true` | Linux only. The build holds no epoll backend. `require_backend(.epoll)` returns `error.Unsupported`. Where the kernel refuses a ring, `Loop.init` returns the ring's error (open question 4) |
| `registry` | `true` | No loop joins a registry. `rotor.Registry.init`, `init_group` and `rotor.Remote.init` fail to compile when a program calls them. No backend compiles its registry's wake |

On macOS, `uring` and `epoll` have no effect, so one declaration serves a program that builds for
both hosts. On Linux, a declaration with both `uring` and `epoll` false fails to compile.

### Who reads it

- **The public module** reads `rotor_options` for `uring` and `epoll`. The type `Tag` in
  `rotor_loop_backend.zig` then holds only the backends the build carries. Each union over `Tag`
  loses a member, and each switch over it loses an arm. So the module never names `uring` when
  `uring` is false.
- **Each backend** reads `registry`. `Loop.init` and `Loop.deinit` refer to the wake only when
  `registry` is true, in a comptime branch. With it false, `Loop.init` asserts that
  `options.registry` is null.
- **Core reads no root file**, as decision 30 ruled.

A backend that reads the root file is new. Today the public module and the reactor read it. The
backend must read it itself, because the wake's reference is inside the backend's own `init` and
`deinit` (open question 1).

### What a program sees

- **A call that the declaration excludes fails to compile.** `rotor.Registry.init` holds a
  `@compileError` behind a comptime branch on `registry`. Zig reports the error only when a program
  calls the function, so a program that never calls it builds.
- **A loop cannot get a registry by mistake.** With `registry` false, no registry can be made. So
  the assertion in `Loop.init` is for rotor's own code, and no caller can reach it.

### How it is proved

stompy checks its own archive. rotor proves the choices by itself as well:

1. **An example with both parts left out.** A program under `examples/` declares
   `.uring = false` and `.registry = false`, and runs an echo server. `zig build test` runs it
   against `tools/echo_check.zig`, as it runs the other examples. The Linux gate runs it too, under
   both seccomp profiles. It must run epoll under both.
2. **A symbol check.** A tool reads the undefined symbols of that example's object file: ELF on
   Linux, Mach-O on macOS. It fails when `mmap64` or `munmap` is present on Linux, or when `dup`
   or `dup2` is present on macOS. The tool also checks the same object
   built with no declaration, and that object must hold the symbols. Without that second check, a
   change that drops a symbol from both builds passes the tool and proves nothing.
3. **Compile-fail cases.** `tools/compile_fail/` gains three programs: one that calls
   `Registry.init`, one that calls `Remote.init` with `registry` false, and one that sets both
   `uring` and `epoll` false on Linux.
4. **The conformance suite stays as it is.** Its root is Zig's test runner, which declares no
   `rotor_options`, so every suite keeps both backends and the registry.

## What it costs

- **At run time:** nothing. Each choice is a comptime constant. With a declaration, the code that
  it excludes is not compiled. Without one, the code is the same as today.
- **In the source:** a comptime branch around each wake's `claim` and `release` in three backends,
  and a `Tag` that depends on the declaration, with each switch over it written for a missing arm.
  About 25 lines that name `uring` in `src/rotor/` change, outside the tests.
- **In the tests:** one example program, one symbol tool, three compile-fail programs, and their
  runs in `zig build test` and in the Linux gate. The tool is the largest part: it parses two object
  formats. Each run takes a few seconds (a prior, not measured).
- **In the API:** one new public name, `rotor.Options`, and one declaration name,
  `rotor_options`.

## Where it meets the records

| record | how |
|---|---|
| 1, the module graph | No new edge. The root file is read through `@import("root")`, as decision 30 ruled for `rotor_scheduling_groups` |
| 2, the scope | No new operation. The table of decision 2 does not change |
| 4, threading | With `registry` false, a program has no `Registry` and no `Remote`, so `Loop.post` has no target. A program that needs posts keeps the default |
| 20, the epoll backend | The fallback at init stays the default. With `uring` false there is nothing to fall back from |
| 21, loops in several processes | A group is a registry, so `registry` false excludes `init_group` too |
| 23, a host that owns the wait | `require_backend` keeps its meaning. With `uring` false, `require_backend(.uring)` returns `error.Unsupported`, as it does today where the kernel refuses a ring |
| 30, scheduling groups | The same kind of declaration, read the same way. The two stay separate (open question 5) |
| 32 and 33, cross-core calls and the reactor | A call needs a registry, so `registry` false excludes calls. A reactor without calls builds as it does today |

## Alternatives it beat

1. **A build option of the rotor package**, passed as
   `b.dependency("rotor", .{ .uring = false, .registry = false })`. It is the usual Zig form for a
   dependency's settings, and `build.zig` shows it. But a generated options module must reach the
   public module and each backend, which adds an edge to the module graph for each of them.
   Decision 30 chose the root file for the same kind of setting, and two forms for one purpose would
   confuse a reader.
2. **The registry's wake as separate calls of the backend.** Each backend's `Loop.init` would take
   no registry. The public module would call `join` after `init` and `leave` before `deinit`, in a
   comptime branch, so no backend reads the root file. It changes the backend's surface
   (`src/core/surface.zig`), and every test that gives a loop a registry today would make two calls.
3. **The wake through pointers that the registry holds.** `Registry.init` would store the backend's
   `claim` and `release` functions, and a loop would call them through the registry. A program that
   never makes a registry would then never compile the wake, with no declaration at all for issue
   17. But a group's registry lives in memory that several processes share (decision 21), and a
   function pointer is not valid in another process. The pointers would have to live in each
   process's own memory, which adds a field to the loop: a change to a hot structure.
4. **A choice at run time**, such as a flag in `Loop.Options`. It does not remove a symbol, and both
   issues ask for that.
5. **The linker's removal of dead code.** The linker removes only what nothing refers to, and here
   live code refers to the wake.

## Open questions

Each question has a proposed answer.

1. **The mechanism.** Proposed: the root declaration, read by the public module and by each
   backend. The other choices are alternatives 1 to 3 above.
2. **The names.** Proposed: `rotor_options` of type `rotor.Options`, after std's `std_options` of
   type `std.Options`, with the fields `uring`, `epoll` and `registry`. The other choice for the
   backends was one field, `linux_backends`, with the values `both`, `uring` and `epoll`.
3. **A call that the declaration excludes.** Proposed: a compile error when a program calls it. The
   other choice was a halt at run time, which a test could reach only in a child process.
4. **`epoll` false where the kernel refuses a ring.** Proposed: `chosen()` returns `.uring` without
   a question to the kernel, and `Loop.init` returns the ring's own error. The other choice was a
   new error, `error.Unsupported`, from `Loop.init`.
5. **One declaration or two.** Proposed: `rotor_scheduling_groups` stays as decision 30 ruled, and
   `rotor_options` holds only what a build leaves out. The other choice was a field
   `scheduling_groups` in `rotor.Options`, which would change a ruled name.
6. **The symbol tool.** Proposed: rotor holds its own, so a change that brings a symbol back fails in
   rotor's gate and not first in stompy's. The other choice was to rely on stompy's check.

## Ask before

- Adding the public name `rotor.Options` and the declaration `rotor_options` (the API).
- A backend that reads the root file, which no record has ruled on (open question 1).
- The new tool under `tools/`, which `zig build test` would run.
