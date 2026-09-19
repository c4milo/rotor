# 10. rotor carries no simulator

Status: accepted on 2026-09-19. The owner asked whether rotor needs a simulator and judged it
overkill. This record gives the reasoning and what replaces it. It amends decisions 1, 4, 5, 6, 8
and 9, each of which now says so under its status line.

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
about the kernel that only the real kernel can confirm. The owner judged it overkill for an I/O
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
