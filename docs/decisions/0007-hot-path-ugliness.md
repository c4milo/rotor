# 7. Where the hot path may buy speed with ugliness

Status: accepted for implementation on 2026-09-19. This record resolves the first collision
between the Abseil Performance Hints and the project rules.

## The collision

The Performance Hints favour hand-unrolled loops, raw pointers in place of spans, and hot
functions with no calls in them. The project rules cap cognitive complexity at 15 and files at
500 lines.

## Decision

### The two caps hold everywhere

No file is exempt from the complexity cap or the line cap, and the lint has no exemption
mechanism to reach for. This costs less than it seems, because the techniques the Hints name do
not raise the score:

- An unrolled loop is straight-line code. Cognitive complexity counts branches and nesting, and
  four copies of a statement add none.
- A raw many-item pointer in place of a slice removes a bounds check and adds no branch.
- Moving the slow path into its own `noinline` function, which the Hints recommend, lowers the
  caller's score.
- `inline`, `@branchHint` and `@prefetch` are annotations.

What the techniques cost is reading ease and safety, and the caps do not measure those. So the
resolution is about where such code may exist and what must stand behind it.

### Ugliness is confined to named files

These files may contain the techniques listed below. No other file may.

| file | what runs there |
|---|---|
| `src/core/slot_table.zig` | handle to slot, claim, release |
| `src/core/timer_heap.zig` | sift up, sift down |
| `src/uring/uring_submit.zig` | filling submission entries from a batch |
| `src/uring/uring_reap.zig` | copying completion entries into events |
| `src/kqueue/kqueue_submit.zig` | filling the changelist |
| `src/kqueue/kqueue_reap.zig` | turning kevents into events, including the inline `recv` and `send` |

None of these files exists yet. The list is the budget: adding a file to it changes this record.

The techniques:

1. `inline fn` and `@call(.always_inline, ...)`.
2. `[*]T` in place of `[]T` inside a loop whose bound was checked once before it.
3. A loop unrolled by hand.
4. `@branchHint(.unlikely)` and `.cold`, and a `noinline` slow path.
5. `@prefetch`.
6. `@setRuntimeSafety(false)` over one block. This one removes checks ReleaseSafe would keep, so
   it also needs the argument `0008-hot-path-assertions.md` requires for removing an assertion.

### Each use needs a ledger row

`docs/hot-path-ledger.md` holds one row per use: the file and function, the technique, the
workload in the harness that shows the gain, the numbers before and after with the machine and
the commit, and the date. The code carries a comment naming the row. The ledger starts empty,
because no code exists and so no measurement exists, and **an empty ledger means the hot path
is written plainly.** The first version of every file in the table is the plain version. The
ugly version is a later commit of type `perf` that adds its row.

Rules for a row:

- The gain is shown by a named harness workload, not only by a microbenchmark. A microbenchmark
  may find the change; the workload proves it matters.
- The gain exceeds the run-to-run noise the harness reports for that workload. A gain inside
  the noise does not land.
- When a compiler upgrade or a redesign makes the plain version as fast, the row and the
  ugliness are removed together. The harness re-runs the ledger's rows at each milestone.

### The lint enforces the confinement

From milestone 2, a `hot-path` rule, built on pepegrillo's readers, reports
`@setRuntimeSafety`, `@prefetch`, `always_inline` and `[*]` under `src/` outside the six files.
Inside them, review checks each use against the ledger.

## Alternatives it beat

**Exempt the hot files from the caps.** A 900-line file with functions scoring 30 is where the
bug in the submit path hides. The techniques do not need the exemption.

**Forbid the techniques outright.** Then a measured 10 percent on the echo workload could never
land, and the Hints' advice would be refused without a measurement, which is the mistake the
Hints warn about in reverse.

**Allow them anywhere with a measurement.** Ugliness spreads to wherever someone ran a
microbenchmark. Six files bound the area a reader must treat with suspicion.

## How it is checked

- `zig build lint` runs the confinement rule once it exists, and the canary tree gains a
  violation of it.
- The harness re-measures each ledger row per milestone and reports rows whose gain is gone.
