# rotor

rotor is an event loop and I/O layer in Zig 0.16: a completion-based core over Linux io_uring and
macOS kqueue, with a benchmark harness that gates every speed claim.

**Status: version one is being built, milestone by milestone.** No kernel backend exists yet.
Start with:

- `docs/decisions/`, the decision records, each with the alternatives it beat.
- `docs/costs.md`, the latency table every design argument cites. Its measured columns are empty.
- `CLAUDE.md`, the rules of the tree.

```bash
zig build test
```
