# rotor rules

rotor is an event loop and I/O layer in Zig 0.16: a completion-based core over Linux io_uring and
macOS kqueue, with a deterministic simulated backend. Its goal is to beat libuv, libxev and
Zig's own `std.Io` implementations on named workloads, and to show it in a harness anyone can
re-run. Home: github.com/c4milo/rotor.

It is a standalone library. stompy is meant to become its first consumer
(`docs/decisions/0006-stompy-lineage.md`). rotor never depends on stompy and never names it in
source. colibri owns no I/O and is not a consumer.

## Read before changing behaviour

- `docs/decisions/` holds the numbered decision records. Each one records a decision with the
  alternatives it beat and the costs it was argued from. Cite them by number in commits and
  comments ("decision 5, rule 3").
- `docs/costs.md` holds the latency table every design argument cites by row id (`C7`).
- `docs/hot-path-ledger.md` holds one row per measured use of an ugly technique (decision 7).

If you are about to do something a record rejected, say so and stop. Do not reverse it in code.
A record marked "proposed" is not yet a licence to build what it describes.

## Non-negotiables

The architecture depends on every rule in this section.

1. **TigerStyle.** rotor allocates nothing: the caller hands each loop its memory at init, and
   no file under `src/` names an allocator. Every loop and queue is bounded. Every limit is
   named in a `constants.zig` with a doc comment, never written inline. Assertions stay on in
   production, roughly two per function, covering positive and negative space; decision 8 says
   which ones live on the hot path.
2. **Determinism.** One seed replays byte-identically across hosts and build modes. Nothing in
   `core` or `sim` reads the host clock, the PRNG, uninitialised memory, or a pointer value.
   Every sampling decision inside the simulator comes from the seeded generator and the op
   clock (decision 9).
3. **The simulator precedes the backend it tests.** Do not write a backend before the simulated
   backend and its fault injection can drive the same surface. Every test runs against the
   simulator.
4. **Shared-nothing.** A loop belongs to one thread. It holds no lock, starts no thread, and
   never moves work between cores on its own. The one call another thread may make is `post`
   (decision 4).
5. **Every operation ends with exactly one final event**, and its buffer belongs to the loop
   until then (decision 5).
6. **Invariants are code.** A violated invariant halts with the seed and the op that produced
   it.

## Performance discipline

The discipline is [Abseil's Performance Hints](https://abseil.io/fast/hints.html), applied to
Zig and to this tree.

- **Estimate before building.** A design argument cites rows of `docs/costs.md` and shows its
  arithmetic. A prior may decide what to build first. Only a measured cell may support a claim.
- **Measure, never assume.** A change that claims a gain carries a harness number, the command
  that produced it, and the machine. A change whose gain the harness cannot show does not land
  as a `perf` commit.
- **A speed claim the harness cannot reproduce does not go in a commit message or a document.**
  Report the runs where rotor loses, the skewed ones included.
- **Bulk first.** Batch submission and batch completion are the default shape. The
  one-operation call is a helper built on top.
- **Compact memory.** Order fields to cut padding, keep what one tick touches together, prefer
  a 32-bit index to a 64-bit pointer. Every hot structure says in a comment what its size and
  alignment are meant to be, with a comptime assert holding it there.
- **Avoid unnecessary work.** Fast path first, slow path in its own function. Compute expensive
  properties once at registration, not per operation. Nothing is computed inside a loop that
  could be computed outside it.
- **Statistics are sampled, never unconditional, and nothing logs on a hot path** (decision 9).
- **Ugly code needs a ledger row.** Unrolling, raw pointers, forced inlining and disabled safety
  checks live only in the files decision 7 names, each use with a row in
  `docs/hot-path-ledger.md`. The first version of a hot file is the plain version.

## Tests are proved by mutation

A test must fail when the code it covers is broken. When you add a check, break it on purpose
and confirm a test fails. Report the result as `CAUGHT` or `NOT CAUGHT` per mutation in the
commit body. A `NOT CAUGHT` means a test is missing; write it. Measure a mutation against the
narrowest target that can catch it: `zig build test-<module>`.

## Conventions

- Zig 0.16. One library, no binary, plus the harness under `bench/`.
- Names spell words out: `completion_bytes`, not `cmpl_sz`. Kernel vocabulary stays as the
  kernel spells it (`sqe`, `cqe`, `kevent`, `msg_ring`). One-letter names only for loop indices.
  `_bytes` and `_len` count bytes; `_max` names a limit.
- Functions stay at cognitive complexity 15 or less, scored by `tools/cognitive_complexity.zig`.
  `test` blocks are scored under the same limit. Split the function; never raise the threshold.
- A hand-written source file stays at or under 500 lines, its tests included, enforced by
  `tools/lint/file_length.zig`. Split the file, and name every piece after the file it came
  from, keeping the original name as the entry point: `uring.zig`, `uring_submit.zig`,
  `uring_reap.zig`. Four or more files sharing a prefix move into a subdirectory named for it.
- Operational errors — a refused operation, a short buffer, a limit reached — return error
  values. Assertions are for programmer error only.
- Write all prose in active voice with plain words: short sentences with one idea each, terms
  defined before use, lists for list-like content, no metaphors. Name what literally happens.
  One name per thing, and it is the name in the code.
- Every Markdown file is GitHub-flavored Markdown and must render on GitHub as written: real
  list markers only (no bare `3b.` lines), pipes inside a table cell escaped as `\|`, fenced
  code blocks with a language, no definition lists, no LaTeX.
- A number that was recalled and not measured or read from a source says so where it appears.

### Commits

- A commit message is a Conventional Commit: `type(scope)!: description`, with the scope and the
  `!` optional. The type is one of `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`,
  `ci`, `chore`. Scopes track the module graph: `core`, `sim`, `uring`, `kqueue`, `adapter`,
  `bench`, `tools`. A scope outside that set is a warning.
- The description is imperative, starts with a lowercase letter, and ends without a period. The
  subject line stays at or under 72 columns.
- Exactly one blank line separates the body from the subject. A body line stays at or under 100
  columns, and the body stays at or under 3 paragraphs and 100 words. The diff shows the what,
  so the body says why. Reasoning that outlives the commit belongs in `docs/`.
- Mutation results belong in the body when a commit adds or changes a check. Measured numbers
  belong in the body of a `perf` commit, with the workload's name.
- Stage by explicit path. Never `git add -A` and never `git add .`

## Layout

- `build.zig` stays short: build options and the module graph. Helpers belong in `build/`.
- `src/<module>/` is one Zig module, declared in `build/modules.zig` with its imports listed. A
  module can only `@import` what the build gives it. The graph is in decision 1: `core` imports
  nothing; `sim`, `uring` and `kqueue` import `core`; `adapter` imports `core` and one backend;
  nothing imports `bench`. Only `core` exists today.
- Each module owns its `constants.zig`. A limit two modules share belongs in
  `src/core/constants.zig`. A comptime assert stays with the constant it pins.
- Tests belong in the file they test.
- `tools/` is developer tooling, run by `zig build lint` and never linked into the library. Its
  rule implementations come from pepegrillo, a lazy package in `build.zig.zon`; `tools/` holds
  rotor's configuration of each rule.
- `docs/` is the design set. `bench/` will hold the harness, the cost probes of
  `docs/costs.md`, the pinned versions of what rotor is measured against, and the committed
  results with the machine and kernel beside them.

## Ask before

- Changing a named limit, or the size or layout of a hot structure.
- Adding a dependency. The library has none; pepegrillo is tooling.
- Weakening an assertion or an invariant to make a test pass, or moving an assertion to a
  slower class outside the thresholds of decision 8.
- Adding a file to decision 7's list of hot files.
- Adding an edge to the module graph.
- Building anything decision 2 leaves out of version one.

## Commands

- Build: `zig build`. `-Drelease` builds ReleaseSafe; ReleaseFast and ReleaseSmall are not
  offered, because assertions stay on in production.
- Lint: `zig build lint` — cognitive complexity over `build.zig`, `build`, `src` and `tools`,
  then the `tools/lint` rules: heap, determinism, unbounded-loop, relative-import, markdown,
  file-length and magic-numbers. A canary tree in `build/lint.zig` proves every rule runs.
- Test: `zig build test` — the lint, every module's unit tests, the tools' own tests, the hook
  check and the format check. Every change passes it before it is committed.
  `zig build test-<module>` and `zig build test-tools` run one target alone.
- Format: `zig build fmt`.
- Commit messages: `zig build hooks` once after cloning points `core.hooksPath` at `.githooks`;
  `zig build lint-commits` checks `origin/main..HEAD`. `.githooks/pre-push` is a copy of
  pepegrillo's hook, and `zig build test` fails when the two differ.
- Tooling: the first build fetches pepegrillo. After a bump with `zig fetch --save=pepegrillo
  git+https://github.com/c4milo/pepegrillo#<commit>`, confirm `.lazy = true` is still set in
  `build.zig.zon` and copy the new hook. `zig build --fork=<pepegrillo checkout>` builds against
  a local pepegrillo.

## Milestones

Each milestone ends with a gate that runs in `zig build test`, and with a report of the
measured numbers, the losing ones included.

- Milestone 0: the cost probes of `bench/costs/`, and `docs/costs.md` filled for both machines.
- Milestone 1: `core` and `sim`. The simulated backend with its op clock, seeded completion
  order, and faults: short reads, partial writes, `EAGAIN`, `ENOMEM`, cancellation races, torn
  operations. Gate: byte-identical replay of every seed, with statistics off and on.
- Milestone 2: `uring`. Gate: the simulator's tests pass on the real backend under Linux, and
  decision 8's experiment is reported.
- Milestone 3: `kqueue`. Same gate on macOS.
- Milestone 4: the harness. Echo at N connections with 4 KiB and 64 KiB payloads, sequential
  and random O_DIRECT reads, timer churn, accept storm; each on 1 core and N cores, even and
  skewed; one cross-core message on its own. Throughput and p50, p99, p999. libuv, libxev,
  `std.Io.Uring` and `std.Io.Threaded` pinned by version, in the same harness, in the same run.

## Where the work stands

The nine decision records are proposed and await the owner's review. `docs/costs.md` has no
measured cell. No loop code exists, and none is written until the records are accepted.
