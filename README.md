# rotor

rotor is an event loop and I/O layer in Zig 0.16: a completion-based core over Linux io_uring and
macOS kqueue, with a benchmark harness that gates every speed claim. It allocates nothing, bounds
everything, keeps its assertions on in production, and gives a loop to one thread.

**Status: version one is built, tested on both kernels, and measured on two machines.** Both
backends pass the same 48-scenario conformance suite, `uring` under Linux and `kqueue` on macOS,
and every operation `docs/decisions/0002-scope.md` puts in version one exists: TCP, UDP, files,
timers, cancellation, messages between loops and from threads that own none, registered and
provided buffers. `docs/costs.md` holds the measured costs on the `mac` and `orbstack` machines;
`bench/alternatives/README.md` holds the comparison against libuv, libxev and `std.Io` on macOS,
the losing rows included. No claim is made for Linux hardware yet: that machine is not named.

Start with:

- `docs/using.md`, the guide for a program or a library that drives a loop.
- `docs/decisions/`, the decision records, each with the alternatives it beat.
- `docs/costs.md`, the latency table every design argument cites.
- `CLAUDE.md`, the rules of the tree.

```bash
zig build test
```
