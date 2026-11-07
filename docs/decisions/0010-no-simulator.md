# 10. rotor carries no simulator

Status: accepted on 2026-09-19. Camilo asked whether rotor needs a simulator and judged it
overkill. This record gives the reasoning and what replaces it. It amends decisions 1, 4, 5, 6, 8
and 9, each of which now says so under its status line.

Amended on 2026-11-06 by Camilo's ruling: build the seeded shuffle of each reaped batch now.
"Amendment of 2026-11-06" at the end says what was built.

## Context

The brief asked for a deterministic simulator before any backend, as stompy's non-negotiable 4
demands of stompy, with every test running against it. Milestone 1 was that simulator: a third
backend beside `uring` and `kqueue`, with an op clock, a seeded completion order and injected
faults.

The rule came from stompy, and it does not carry over. In stompy the simulated disk sits under
the code being tested: the journal runs on it unchanged. In rotor the code being tested is the
I/O layer itself, so a simulated backend sits beside the real backends. Its tests would run none
of the code that ships: not the submit path, not the reap path, not the retry on `EAGAIN`, not
the completion-queue overflow, not the linked timeout.

## Decision

rotor has no simulated backend and no simulated kernel. What checks rotor is this:

1. **Seeded property tests on `core`.** The slot table, the timer heap and the event queue are
   plain data structures. Each has a property test that draws from `core.random`, the splitmix64
   generator written out in `src/core/random.zig`, so a failure names a seed that replays it.
2. **One conformance suite against the real kernel.** One set of scenarios written against the
   `Loop` surface runs on whichever backend the host has: `kqueue` on the development Mac, and
   `uring` under Linux, in Docker with `seccomp=unconfined` as stompy's `tools/linux_test.sh`
   runs its tests. Both backends passing one suite is what shows that they present the caller
   one behaviour (decision 5).
3. **Fabricated completions for the paths the kernel will not produce on demand.** A test hands
   the backend's dispatch a completion entry it built: `EAGAIN`, `ENOMEM`, `ECANCELED`, a short
   count, a cancel's answer before and after its target's. stompy's `linux.zig` tests its
   `EAGAIN` retry this way today. The kernel decides who wins a cancel race and rotor only maps
   the answer, so the orderings to cover are few and a test can list them.
4. **The benchmark harness**, which is the gate for every speed claim and was never the
   simulator's job.

rotor keeps the property that made stompy's simulator possible: no kernel type appears in the
public surface, and a consumer's build picks the backend (`core/surface.zig`). A consumer that
needs deterministic replay substitutes its own twin of the surface. stompy already has one,
`src/sim/disk/`, and on the day stompy adopts rotor that twin presents rotor's surface, or stays
behind stompy's own `io` facade with rotor as the production side.

## What this costs

- **No deterministic search of cancel and completion orderings inside a real backend.** The
  fabricated-completion tests list the orderings by hand. An ordering nobody listed is not
  tested. If the list grows past what a reader can check, a seeded test that shuffles fabricated
  completions into every legal order is the next step, and it is a test file, not a simulator.
- **No simulated sockets for consumers.** stompy simulates its network at the message level,
  above any socket, and keeps doing so. A consumer that wants short reads and resets injected
  under real socket code has to build that, or ask for this decision to be reopened.
- **The fault-free kernel is the only kernel the conformance suite sees.** Torn writes and power
  loss stay where they are tested today: in stompy's crash harness, over a real disk.

## What it buys

- The riskiest assumption is the speed claim, and no simulator tests it. With milestone 1 gone,
  the `uring` backend and the harness come first, so the claim is tested weeks sooner. If the
  harness shows rotor cannot beat libxev, nothing else in this tree matters.
- Several thousand lines that would have modelled TCP, an accept queue, a disk image and a
  fault policy are not written, reviewed or kept in step with two real kernels.
- Every test runs the code that ships.

## Alternatives it beat

**The simulated backend of the brief.** Costed above: it tests itself.

**A simulated kernel boundary under the real backends**: the `uring` backend made generic over
its few kernel calls, with a seeded, fault-injecting fake beneath. It would run the code that
ships, deterministically, on any host, and I proposed it first. It is still a simulator: the
fake has to model what io_uring does with every opcode rotor uses, and that model is a belief
about the kernel that only the real kernel can confirm. Camilo judged it overkill for an I/O
layer this thin, and the evidence agrees: stompy's layer and TigerBeetle's are both tested
without one.

**Keep the simulator for consumers only.** A consumer-facing twin is worth having where a
consumer needs it, and the one consumer in sight already owns its twin.

## What changes elsewhere

- CLAUDE.md: non-negotiable 2 now covers `core`'s tests and the statistics of decision 9, and
  non-negotiable 3 is the conformance suite. The milestones are reordered.
- Decision 1: the module table loses `sim`.
- Decision 4: cross-core posting is tested with real threads, not simulated loops.
- Decision 5: "What the simulator injects" becomes the fabricated-completion list of point 3.
  Rule 3's buffer poisoning has no simulator to run in and is dropped.
- Decision 6: the twin stays with the consumer.
- Decision 8: class D assertions run in Debug test builds.
- Decision 9: rules 1, 2, 5 and 6 stand. The rules about the simulator's streams and the
  three-trace replay gate have nothing to apply to.

## Amendment of 2026-11-06: a twin's surface gains the view and the heartbeat

Decision 28 adds three names to the surface that a twin carries in place of the public module:

- `Loop.shared`, which returns the view that the program hands each library;
- `SharedLoop`, that view. `core.shared_loop.check` holds a view to its declarations: each call a
  library may make, and each call it refuses with a compile error;
- `Loop.heartbeat`, which returns what a thread of the program reads to see a stuck loop.

`core/surface.zig` lists `shared` and `heartbeat`. A twin that runs no callback for longer than
its threshold still reports no stall, because a twin's turns are what it says they are.

## Amendment of 2026-11-06: the seeded shuffle of each reaped batch

"What this costs" named a seeded shuffle of completions as the next step. Camilo ruled on
2026-11-06 to build it now. It is a switch of a test build. The kernel answers every operation, and
only the order of the events of one reap changes.

### What it does

The kernel promises no order between the completions of two operations in one reaped batch. A
build with the switch permutes the events of each reap before the caller or `Dispatch.end` sees
them. A scenario that assumes an order that rotor does not promise then fails.

- **Where.** Each backend's `tick` calls `tables.shuffle.reaped` on the events that its reap wrote.
  `tick` runs under the fast path of decision 26 and under `tick_dispatched`, so the shuffle covers
  the events that go back to the caller and the events that a record takes, on all three backends.
- **What stays.** The due timers, the finished list, the messages and the expired deadlines are
  not permuted. rotor decides their order, and promises part of it: timers fire in deadline order
  and in arm order (`timer_heap.zig`), and a ring hands its messages over in order (`mailbox.zig`).
- **Determinism.** The seed comes from the build. Each loop draws from `core.random` with the seed
  plus its id. The name of each shuffled test executable holds the seed, so a failure names it.

### The orders it keeps

| order | where rotor promises it | how the shuffle keeps it |
|---|---|---|
| The `more` events of an operation come before its final event | decision 5, rule 1 | The events of one `user_data` keep their order. |
| The datagrams and the bytes of a multishot receive stay in order, each with its provided buffer | decision 15, and decision 5's amendment of 2026-09-24 | The same rule. |
| A close ends after the operations it cancelled | decision 5, rule 6, and decision 11, point 5 | On io_uring the reap marks a close's event as a barrier. No event crosses it. |
| A ready completion wins over its deadline (issue 10) | decision 11, point 1 | The shuffle changes no result, and the deadlines expire after the reap. |

Two operations with the same `user_data` also keep their order. The shuffle then has fewer
orders, and it needs no read of the slot. Two operations on one socket have no order (decision 11,
point 8), so the shuffle may swap them.

### The switch

- `build/modules.zig` writes `shuffle_seed` into `assertion_options`, beside `class_a`. `core`
  already imports that module, so the switch adds no edge to the module graph.
- Off, which is the default, `Shuffle` has no bytes and each call site reads `enabled`, which is
  known at compile time. The text section of the kqueue program of `bench/work/work.zig` was the
  same, byte for byte, with and without this change, and the work gate passed.
- `zig build test` runs the kqueue suite on macOS, or the io_uring and epoll suites on Linux, once
  more with the switch on. It also runs the `uring` module's own tests with the switch on, on every
  host. `-Dshuffle-seed=N` names the seed, and the default is 1.
- `zig build test-linux` builds the io_uring and epoll suites with the switch on, and
  `tools/linux_test.sh` runs them, the epoll one under Docker's default seccomp profile.
- The narrow steps are `zig build test-conformance-kqueue-shuffled` and
  `zig build test-uring-shuffled`.

### What it found

The first version did not keep the order of a close. On io_uring the cancelled receive's event and
the close's event come in one reap. The scenario "a close ends the receive in flight for its
descriptor with canceled, then closes" failed with 5 of 8 seeds. The kernel makes that order: the
close is hard-linked behind the cancel. So the reap now marks a close's event as a barrier. With
the barrier, no scenario failed:

| backend | where | seeds | failed |
|---|---|---|---|
| kqueue | `mac`, natively | 1 to 21 | none |
| io_uring | Docker on `mac`, `seccomp=unconfined` | 1 to 12 | none |
| epoll | Docker on `mac`, default seccomp profile | 1 to 12 | none |

No scenario assumed an order that rotor does not promise.

### How it is checked

- `src/core/shuffle.zig`: the permutation holds each event once; the events of one `user_data`
  keep their order, and the final event stays last; one seed gives one order; a barrier keeps its
  place; each loop draws from the seed and its id.
- `src/uring/uring_reap_test.zig`: the reap marks a close's final event as a barrier, when the close
  succeeds and when it fails.
- `src/conformance/conformance_shuffle.zig`, on every backend: the receives of one reap reach the
  caller, and reach their records, in more than one order over eight rounds. A close's event stays
  after the receive it cancelled in each of eight rounds.

Mutations, 13, each CAUGHT. Against `zig build test-core`: a draw that always takes the first
event, a permutation that ignores the `user_data`, a barrier never noted, a start never reset, and a
seed that ignores the loop's id. Against `zig build test-conformance-kqueue-shuffled`: no shuffle in
the kqueue tick. Against `zig build test-uring-shuffled`: no barrier for a close, for one that
succeeds, and for one that fails. Against the Linux gate: no shuffle in the io_uring tick and in the
epoll tick, a barrier that the reap never applies, and no barrier for a close.
