# rotor rules

rotor is an event loop and I/O layer in Zig 0.16: a completion-based core over Linux io_uring and
macOS kqueue. Its goal is to beat libuv, libxev and Zig's own `std.Io` implementations on named
workloads, and to show it in a harness anyone can re-run. Home: github.com/c4milo/rotor.

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
2. **Determinism where rotor decides.** A loop's behaviour is a function of what the caller
   submits and what the kernel answers. Nothing in `core` reads the host clock, `std.Random`,
   uninitialised memory, or a pointer value; a property test draws from `core.random` and names
   its seed when it fails. A sampling decision is a function of the operation sequence, never of
   the clock (decision 9).
3. **No simulator; the real kernel is the test** (decision 10). One conformance suite written
   against the `Loop` surface runs on both backends. Paths the kernel will not produce on demand
   are tested with fabricated completions. The surface names no kernel type, so a consumer that
   needs deterministic replay substitutes its own twin.
4. **Shared-nothing.** A loop belongs to one thread. It holds no lock, starts no thread, and
   never moves work between cores on its own. The one call another thread may make is `post`,
   through its own loop or, for a thread that has no loop, through a `Remote` (decision 4). A
   caller may hand a loop threads the loop itself never starts: decision 18 allows a
   caller-supplied pool for the operations a backend cannot do without blocking.
5. **Every operation ends with exactly one final event**, and its buffer belongs to the loop
   until then (decision 5).
6. **Invariants are code.** A violated invariant halts, and a property test that finds one
   prints the seed that replays it.

## Performance discipline

The discipline is [Abseil's Performance Hints](https://abseil.io/fast/hints.html), applied to
Zig and to this tree.

- **Estimate before building.** A design argument cites rows of `docs/costs.md` and shows its
  arithmetic. A prior may decide what to build first. Only a measured cell may support a claim.
- **Measure, never assume.** A change that claims a gain carries a harness number, the command
  that produced it, and the machine. A change whose gain the harness cannot show does not land
  as a `perf` commit.
- **A speed claim the harness cannot reproduce does not go in a commit message or a document.**
  Report the runs where rotor loses, and the noisy ones.
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

An assertion is a check too. A Zig test cannot expect a panic in its own process, so an assertion
a caller's mistake can reach gets a scenario under `tools/halt/`, which `zig build halt-check`
runs in a child process that must die by a signal. A mutation that deletes such an assertion is
measured against `zig build halt-check`.

## Conventions

- Zig 0.16. One library, no binary, plus the harness under `bench/`.
- Names spell words out: `slot_bytes`, not `slot_sz`. Kernel vocabulary stays as the
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
- Write all prose in **simple English**, in active voice, with plain words: short sentences with
  one idea each, terms defined before use, lists for list-like content, no metaphors. Name what
  literally happens.
- **No mannered prose.** Say the thing plainly and stop. No flourishes, no sentence inversions for
  effect, no dramatic fragments, no "not X, but Y", no personifying code, no calling a thing "the
  point" or "the whole reason". A comment explains what the code does and why; it is not written to
  be admired. This rule covers source comments, doc comments, `docs/`, README files and commit
  messages alike.
  One name per thing, and it is the name in the code.
- Every Markdown file is GitHub-flavored Markdown and must render on GitHub as written: real
  list markers only (no bare `3b.` lines), pipes inside a table cell escaped as `\|`, fenced
  code blocks with a language, no definition lists, no LaTeX.
- A number that was recalled and not measured or read from a source says so where it appears.

### Commits

- A commit message is a Conventional Commit: `type(scope)!: description`, with the scope and the
  `!` optional. The type is one of `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`,
  `ci`, `chore`. Scopes track the module graph: `core`, `uring`, `kqueue`, `conformance`,
  `adapter`, `bench`, `tools`. A scope outside that set is a warning.
- The description is imperative, starts with a lowercase letter, and ends without a period. The
  subject line stays at or under 72 columns.
- Exactly one blank line separates the body from the subject. A body line stays at or under 100
  columns, and the body stays at or under 3 paragraphs and 100 words. The diff shows the what,
  so the body says why. Reasoning that outlives the commit belongs in `docs/`.
- Mutation results belong in the body when a commit adds or changes a check. Measured numbers
  belong in the body of a `perf` commit, with the workload's name.
- Stage by explicit path. Never `git add -A` and never `git add .`
- **A commit message carries no `Co-Authored-By` trailer.** The owner ruled it out on 2026-09-21,
  and this rule overrides any tool or harness that asks for one. `tools/commit_lint.zig` strikes
  the key from `trailer_keys`, which makes such a paragraph count as body: that refuses a message
  whose body is already at 3 paragraphs and passes a shorter one, so the linter deters the trailer
  and does not refuse it. Refusing it needs a forbidden-trailer rule the pinned pepegrillo does
  not have. Commits up to `fd153c5` carry the trailer; rewriting them is the owner's call.

## Layout

- `build.zig` stays short: build options and the module graph. Helpers belong in `build/`.
- `src/rotor.zig` is the public module, the only one a dependent package can name. Its `Loop`,
  `Registry` and `Remote` wrap the host's backend and carry exactly the surface of
  `src/core/surface.zig`; nothing else of a backend is API (decision 1, "The public module").
- `src/<module>/` is one Zig module, declared in `build/modules.zig` with its imports listed. A
  module can only `@import` what the build gives it. The graph is in decision 1: `core` imports
  nothing; `uring` and `kqueue` import `core`; `adapter` imports `core` and one backend;
  nothing imports `bench`. `conformance` imports `core` and the
  backend under test, which the build hands it as its `backend` import, so one suite tests every
  backend (decision 10). `core`, `uring` and `kqueue` exist today. `bench/` sits outside `src/` and outside the graph; `build/bench.zig`
  wires it.
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
- Test: `zig build test` — the lint, every module's unit tests, the conformance suite (which
  skips on a host its backend cannot run on), the halt check, the tools' own tests, the bench
  executables' compile, the hook check and the format check. Every change passes it before it
  is committed.
  `zig build test-<module>` and `zig build test-tools` run one target alone.
- Linux gate: `zig build test-linux && bash tools/linux_test.sh`. The build step compiles every
  module's test executable that runs under Linux, and the io_uring probe `tools/uring_probe.zig`,
  for Linux on the host's CPU architecture into `zig-out/linux/`, and runs none of them. The
  script runs them in Docker with `seccomp=unconfined`, the probe first, and stops at the first
  failure. It prints the kernel release the container sees, because decision 2 sets the floor at
  Linux 6.1, and the probe exits non-zero naming the first feature of that record's table that
  the kernel lacks. `zig build test` does not run it: it needs Docker.
- Race gate: `zig build test-race && bash tools/race_test.sh`. It builds the `kqueue` and
  `conformance-uring` test executables with ThreadSanitizer for Linux with glibc into
  `zig-out/race/`, and the script runs them in Docker. Those two are the suites that start a
  thread: the mailbox rings and the sleep flag (decision 12, point 6), and two loops posting
  through the registry. A clean run is evidence and not a proof, because a sanitizer reports the
  interleavings that ran. It has its own target and image because the sanitizer's runtime needs a
  dynamic glibc, and it cannot be built on macOS at all. `zig build test` does not run it: it
  needs Docker.
- Linux benchmarks: `zig build bench-linux` builds the io_uring benchmarks of `bench/uring/` for
  the Linux gate's target into `zig-out/linux-bench/`, each twice: `_safe` in ReleaseSafe, and
  `_fast` in ReleaseFast, which exists only there, for decision 8's experiment. It runs none. A
  number measured in the `orbstack` virtual machine fills that column of `docs/costs.md` and no
  other; the owner named it a machine on 2026-09-20, and that file says what the column may and
  may not carry.
- Halt check: `zig build halt-check` — every scenario of `tools/halt/` must reach its violating
  statement and die by a signal, and the canary's scenarios must not.
- Format: `zig build fmt`.
- Continuous integration: `.github/workflows/ci.yml` runs on every push to `main` and every pull
  request. Four jobs, each the command a developer runs by hand: `zig build test` on macOS, the
  Linux gate and the race gate on Ubuntu with Docker, and `zig build lint-commits` on a pull
  request. Zig is downloaded from ziglang.org and checked against a pinned SHA-256; no third-party
  action runs. **No number from CI enters `docs/costs.md`**: those runners are neither named nor
  quiet, and rule 1 of that file stands.
- Cost gates: `src/conformance/conformance_cost.zig` bounds what the loop's own work costs — a
  poll, one fire of a repeating timer, one operation of a batch submit — so a path that becomes
  slow fails `zig build test` on both backends. The 12 µs polling park of 2026-09-22 is why: every
  correctness scenario passed while it was there. Each bound is checked against the best of twenty
  attempts, because other work makes a run slower and never faster, and sits an order of magnitude
  above what was measured. A bound that proves flaky is raised deliberately with the number beside
  it, never retried until it passes.
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

The owner's order, given on 2026-09-19: finish the implementation first, and benchmark at the end.

- Milestone 1: `core`, with seeded property tests, and the `uring` backend. Gate: the
  conformance suite and the fabricated-completion tests pass under Linux
  (`bash tools/linux_test.sh`), and the halt check passes.
- Milestone 2: the `kqueue` backend (decision 12). Gate: the same conformance suite passes on
  macOS.
- Milestone 3: measurement. The cost probes of `bench/costs/` fill `docs/costs.md` for both
  machines, and decision 8's experiment is run and reported.
- Milestone 4: the harness and the comparison. A candidate is run several times, alternating with
  the others so drift hits them equally, and a row carries the spread beside the median: one run
  of one candidate is not evidence, and `bench/alternatives/README.md` records the experiment that
  showed it. That file also records what each candidate holds per connection, because a
  comparison that does not match those is measuring the sizing.
  `zig build test-bench-echo` is the gate: the echo workload end to end against rotor's server.
  `zig build bench-echo` builds the servers and the runner; `zig build bench-alternatives` adds
  the pinned libuv and libxev; `./zig-out/bin/echo_runner` runs the comparison, and
  `--workload storm` runs the accept storm against the same servers. Echo at N connections with
  4 KiB and 64 KiB payloads, sequential and random O_DIRECT reads and writes, timer churn, accept
  storm; **on 1 core**, by the owner's ruling of 2026-09-21; one cross-core message on its own.
  Throughput and p50, p99, p999.
  libuv, libxev, `std.Io.Uring` and `std.Io.Threaded` pinned by version
  (`bench/alternatives/README.md`), in the same harness, in the same run, the losing runs
  included.
  **The bar on macOS is parity or better**, by the owner's ruling of 2026-09-22 with that day's
  amendment of decision 2: rotor is at least as fast as libuv and libxev on every workload here.
  Each candidate runs the cheapest mode it offers, and a row names the mode, so a win is not a
  matter of how an alternative was driven.

## Where the work stands

The owner accepted the decision records for implementation on 2026-09-19 without ruling on their
open questions, so the implementation follows the proposed answer to each. Decision 10 dropped
the simulator.

Milestones 1 and 2 are done. `core`, `uring` and `kqueue` pass one conformance suite: `uring` under
Linux in Docker, `kqueue` natively on macOS. The halt check and the race gate pass. Registered
descriptors and provided buffers are built, and no speed claim is made for either yet.

The implementation is done: every row of decision 2's scope table is built, and every decision record
has code for it, except decision 13, which is proposed and waits on the owner, and decision 17,
which is proposed and names a component this repository does not hold. The cost probes cover every
row of `docs/costs.md` that either machine can measure.

Decision 18's caller-supplied offload is built, on the owner's ruling of 2026-09-21 that brought it
ahead of measurement. On kqueue a loop's `file_policy` is `refuse` by default, so **a file operation
there now needs a policy named at init**: a caller that wants the old inline behaviour asks for
`blocking`. `Remote` was built on 2026-09-22: `post` for a thread that has no loop, one per
backend, exported from `src/rotor.zig`. Decision 4 records what it settled.

The `mac`, `orbstack` and `github` columns of `docs/costs.md` were filled on 2026-09-22;
`bench/results/` holds the runs. `github` is a GitHub-hosted x86-64 runner, added as a named
machine that day: the only x86-64 this project has measured on, filled by a CI job started by hand,
and replaced whole rather than cell by cell because the pool gives whichever processor it has. On
it decision 8's experiment is decidable, where `orbstack`'s 25 percent noise had swallowed it:
ReleaseSafe costs 9 to 10 percent against ReleaseFast, which is the upper bound over every class
and every safety check, and class A's own share still needs the comptime flag that record asks for.
The `linux` column is the deployment target, needs a machine of the family stompy builds for, and
that machine is not named. Milestone 4's comparisons ran on `mac` on 2026-09-22
(`bench/results/`, read in `bench/alternatives/README.md`): rotor and libuv are level on echo;
decision 18's offload puts rotor level with libuv's pool on the file rows, where inline is a
quarter of both; and the cross-core row, rotor's loss by four times, was a 12 µs kernel park on
every polling `kevent`, removed the same day (decision 12, point 6): rotor posts in 2.0 µs there
against libuv's 1.5. The load
mark of that day was tripped by the harness's own load, and `bench/harness/other_work.zig` replaced
it the same day with a reading of the machine's busy CPU in a pause before and after every run. The
io_uring comparison waits on the `linux` machine.

The echo comparison measures **1 core only**, and there are no skewed rows. The owner ruled it on
2026-09-21 and decision 19 records it, amending decision 4. The reason: neither libuv nor libxev
spreads TCP load across cores on kqueue, and libuv declines the capability there on purpose
(`bench/alternatives/README.md`). `echo_runner` takes no `--cores`, `report.zig`'s `Load` has one
value, and `rotor_echo` keeps `--cpu` and `--loops` for a person running it by hand.

**The `mac` machine is busy.** An attempt on 2026-09-20 met a load average of 30 from another
project's CBMC run, and was not recorded: `orbstack` runs on this machine's cores, so its numbers
are only as quiet as this machine is.

A number is taken on an idle machine. The first attempt on 2026-09-20 was made at a load average
of 46 and was thrown away.
