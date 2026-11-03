# 24. A simulated surface, and a search over its orders

Status: proposed on 2026-11-03, not ruled on. It would amend decision 10, which rejected "Keep the
simulator for consumers only". Decision 10 stays as it is until Camilo rules on this record.
Nothing in rotor changes before that.

## Context

### The bug that asked for it

On 2026-11-02 cocuyo's live check gave `Bogus` for google.com through `dns.google`. It did not
happen again when the name was asked alone. The cause was an order of completions on one loop.
Two DNSSEC walks shared one zone, and the answer of one came after the other walk had entered the
zone. The fix is cocuyo bb2029e.

No tool found it before the live check. The bug had no thread and no shared memory, so
ThreadSanitizer cannot see it. cocuyo's Lean model runs one walk at a time, so it cannot see it
either. A test found it again only when a seed chose the order of the replies: cocuyo 954aca9,
in `src/sim/sim_orders.zig`. With the fix taken out, seed 25 of 64 gave the same `Bogus`.

### What decision 10 decided, and why

Decision 10 has two parts.

1. **rotor's own tests run on the real kernel.** A simulated backend sits beside the real
   backends, so its tests run none of the code that ships. This record does not change that.
2. **A consumer that needs replay builds its own simulation.** Decision 10 rejected one in
   rotor because "the one consumer in sight already owns its twin": stompy's `src/sim/disk/`.

### What changed since 2026-09-19

- **More consumers have built simulations.** cocuyo's `src/sim/` presents rotor's surface to cocuyo's
  engine, and `zig build test-io` runs the engine on it. The directory holds 5,161 lines, counted
  on 2026-11-03. The loop and the network are 1,686 of them. Each next consumer would write and
  keep the same part again.
- **A simulation that a consumer owns can drift from rotor.** Nothing checks cocuyo's against the
  scenarios that rotor's backends pass. Its loop does what cocuyo's author believes rotor does.
- **Decision 22 accepted a `std.Io` adapter.** Once it is built, code that takes an `io: std.Io`
  runs on rotor. A simulated surface then serves that code too, through the same adapter.
- **The bugs that shared-nothing loops have are bugs of order.** Each loop belongs to one thread
  and takes no locks. So the cases to search are orders, not memory races:
  1. completions on one loop, in any order the kernel can give them;
  2. messages between loops, in any order of delivery;
  3. offloaded calls that end while other completions arrive;
  4. a thread that owns no loop and posts to one, which is the one place with shared memory.

## Decision, as proposed

rotor gets a module of its own, `simulated`, outside the public module and outside the backends. A
consumer's test build binds its `rotor` import to `simulated`, as cocuyo binds it to `sim` today. The
module has two parts.

### The simulation

It presents exactly the surface of `src/core/surface.zig`, as each backend does:

1. **One seed decides every choice.** The order of completions on a loop, the order of messages
   between loops, and the end of each offloaded call all come from a generator that the caller
   seeds. One seed gives one run, and gives it again.
2. **Time is virtual.** `Loop.now_ns` moves only when the simulation moves it. A timeout of hours costs
   no time.
3. **Faults are the seed's too.** A datagram can be lost, delayed, duplicated or cut. A stream
   read can be short. A connect can be refused or reset. A file write can fail.
4. **Sockets are simulated at the surface.** The simulation holds an endpoint table and delivers what
   one endpoint sends to another. It models no kernel structure.

### The search over orders

1. **A seeded walk** over the choices, for a large test, and a range of seeds that a build step
   runs, as cocuyo's `zig build orders` does.
2. **PCT** (probabilistic concurrency testing): a seeded schedule that changes the priority of
   loops and completions at a few points. It gives a stated probability of finding a bug that
   needs a given number of ordered steps.
3. **Replay and shrink.** A failure prints its seed and the list of choices. The simulation shrinks
   the list to the fewest choices that still fail, then prints the trace of the run that remains.
4. **The checks a test states.** Assertions stay on. The simulation reports a deadlock, when every loop
   waits and no timer is due. It reports a test whose run does not end within a bound of steps.
   A test can require a run to end as the same work ends in one order, as cocuyo's check does.

Two later stages each need a ruling of their own:

5. **DPOR** (dynamic partial-order reduction): every order that can change the result, for a
   small test.
6. **A runtime for the `__tsan_*` hooks**, written in Zig, with vector clocks. It would cover the
   thread that posts to a loop, which is real shared memory. The scheduler that finds a race there
   would also replay it.

### What keeps the simulation true to rotor

Decision 10's main cost of a simulator still holds: a model is a belief about the kernel. This
record answers it with the suite that already checks the backends. **The conformance suite of
decision 10 runs on the simulation as a third target**, beside `uring` and `kqueue`. A scenario that the
simulation and a real backend pass differently fails the build. A scenario the simulation cannot
run yet is listed by name, so the gap is visible.

## What this costs

- **A module to keep.** cocuyo's simulation of the loop and the network is 1,686 lines. The
  one this record proposes covers more of the surface, so it is larger. That is an estimate from cocuyo's
  count, not a measurement.
- **Every change to the surface changes the simulation too.** The conformance suite makes a change
  that misses the simulation fail at once.
- **The conformance suite runs a third time.** It holds 4,427 lines today, counted on 2026-11-03.
  On the simulation it runs in virtual time, so its waits cost nothing.
- **It does not test rotor's own code.** Decision 10's first part stands. A bug in the submit
  path or the reap path stays the real kernel's to find.

## What it buys

- Each consumer stops building and keeping its own simulation.
- A simulation that the conformance suite checks, not one a consumer believes is right.
- Bugs of order become tests that fail on a seed, with no network and no luck.
- Through decision 22's adapter, the same search serves code written against `std.Io`.

## Alternatives it beat

**Keep decision 10 as it is.** Each consumer keeps its own simulation. It costs nothing in rotor,
and every consumer pays again. None is checked against rotor.

**The search in pepegrillo, with the simulation in rotor.** The machinery of search is not rotor's
alone, and pepegrillo already holds the tools of several projects. But the scheduler is the
simulation's own: what the search changes is the order the simulation chooses. Split across two packages,
each change to one would wait for the other. Camilo chose rotor for both on 2026-11-03.

**A simulated kernel boundary under the real backends.** Decision 10 rejected it, and this record
does not ask for it again. It would test rotor's own code, at the cost of a model of every
io_uring opcode.

## Open questions

Camilo answered all three on 2026-11-03, for the day this record is accepted:

1. The module is named `simulated`.
2. cocuyo's `src/sim/` moves onto it once it passes the conformance suite.
3. The parts come in this order: the simulation, the seeded walk and the conformance target
   first; then PCT, replay and shrink; then stages 5 and 6, each on a ruling of its own.
