# rotor

rotor is an event loop and I/O layer in Zig 0.16: a completion-based core over Linux io_uring and
macOS kqueue, with a benchmark harness that gates every speed claim.

**Status: version one is built and not yet measured.** Both backends pass the same 35-scenario
conformance suite, `uring` under Linux and `kqueue` on macOS, and every operation
`docs/decisions/0002-scope.md` puts in version one exists. No speed claim is made anywhere in this
tree: `docs/costs.md` has no measured cell, and the harness has published no comparison.

Start with:

- `docs/decisions/`, the decision records, each with the alternatives it beat.
- `docs/costs.md`, the latency table every design argument cites. Its measured columns are empty.
- `CLAUDE.md`, the rules of the tree.

```bash
zig build test
```
