# Proofs

Machine-checked proofs, in [Lean 4](https://lean-lang.org), of rotor's timers: the timer heap in
`src/core/timer_heap.zig`, and what `src/core/tables.zig` and a backend's `flush` and `tick` do
to a timer. Each proof is about a model of the Zig code, written to be read beside it. Every
definition names the Zig function it mirrors.

```bash
zig build proofs
```

That runs `lake build` here. It needs the toolchain `lean-toolchain` names, Lean 4.34.0, which
[`elan`](https://github.com/leanprover/elan) installs. The proofs use Lean alone, with no Mathlib.
Every theorem rests only on Lean's three standard axioms (`propext`, `Classical.choice` and
`Quot.sound`), and none uses `sorry`.

## What is proved

| claim | where it is made | theorem |
|---|---|---|
| `arm`, `disarm` and `pop_due` keep the heap ordered, and every armed slot's `heap_position` names its entry | `timer_heap.zig`, `assert_heap` | `arm_valid`, `disarm_valid`, `remove_valid`, `popDue_some` |
| each operation has exactly the effect of a model that scans for the minimum | the property test in `timer_heap.zig` | `arm_valid`, `disarm_valid`, `popDue_none`, `popDue_some` |
| `pop_due` answers null exactly when no armed entry is due, and otherwise the one entry that orders first | `timer_heap.zig`, `pop_due` | `popDue_none`, `popDue_some`, `first_unique` |
| the wrapping comparison of `sequence` agrees with arm order while live entries span fewer than 2^31 arms | `timer_heap.zig`, `before` | `zigBefore_eq` |
| a repeating timer is armed for its first deadline plus its fires times its period, whatever the clock read at each fire | decision 14, rule 3 | `armed_on_schedule` |
| a fire is handed over only once it is due, flagged `more`, and the next deadline is exactly one period later | decision 14, rules 2 to 4 | `handed_over_on_schedule` |
| a tick queues a fire for every timer that is due, so none is skipped | decision 14, rule 4 | `expire_queues_every_due` |
| a cancel of an armed timer disarms it at once, and its next event is final and says canceled | decision 5, rules 2 and 5 | `cancel_stops` |
| after an operation's final event, no later event carries its handle | decision 5, rule 1 | `final_is_last` |

## What the proofs found

**A cancel of a repeating timer can be lost.** `lost_cancel` in `RotorProofs/Timers/Local.lean`
proves it:

1. A tick queues a fire for every timer that is due. Each queued timer's slot is `finishing`.
2. The tick hands over only as many events as the caller's array has room for.
3. A fire left over stays `finishing` until the next tick.
4. `Tables.cancellable` refuses a `finishing` slot, so a cancel of that timer between the two
   ticks does nothing.
5. The next tick hands the fire over flagged `more`, and arms the timer again.

The caller asked the timer to stop, and no final event ever comes. This contradicts decision 5,
rule 2 and decision 14, rule 5. Any loop with more timers due at once than its tick's events hold
can reach this state. The Zig code has not been changed: how to fix it is the owner's decision.

## How the models relate to the code

| model | Zig | what the model leaves out |
|---|---|---|
| `Heap.Defs` | `TimerHeap` | The capacity: the Zig `arm` asserts room, and the model has room everywhere. The array is a function from positions to entries. `sequence` does not wrap; `zigBefore_eq` covers the wrap. |
| `Timers.Defs`: `submit`, `armTimer`, `finishLocal`, `rearm`, `release`, `drain`, `requestCancel`, `cancellable` | `Tables.submit`, `arm`, `finish_local`, `rearm`, `SlotTable.release`, `drain_finished`, `request_cancel`, `cancellable` | Every slot holds a timer. A deadline on another kind of operation shares the heap, but its expiry goes to the backend's cancel. The slot table's free list is left out: `submit` takes the index a claim returns. |
| `Timers.Defs`: `flushOne`, `flush`, `expire`, `tick` | a backend's `flush_one`, `flush`, `expire` and `tick` | A tick is `flush`, `expire`, then `drain_finished`. The Zig tick also drains mailboxes and the offload, and may expire and drain once more after a wait that produced nothing. A timer's slot sees that second pass as one more tick. |

Two fields of the model's slot are not in the Zig slot: `first`, the first deadline, and `fired`,
the fires handed over. Nothing the model computes reads them. They exist so a theorem can say
which deadline the k-th fire was for.

## Keeping them true

A model is only as good as its match with the code. When a function the models mirror changes,
change its model in the same commit, and run `zig build proofs`. A proof that no longer holds
fails to check, and names the theorem.

## Layout

| file | what it holds |
|---|---|
| `RotorProofs/Heap/Defs.lean` | the heap model |
| `RotorProofs/Heap/Order.lean` | the order entries come out in, and the wrapping comparison |
| `RotorProofs/Heap/Invariant.lean` | what a valid heap is, and what holds part way through a sift |
| `RotorProofs/Heap/Sift.lean` | `sift_up` and `sift_down` keep the heap |
| `RotorProofs/Heap/Spec.lean` | what `arm`, `disarm` and `pop_due` do to the model |
| `RotorProofs/Timers/Defs.lean` | the timer lifecycle model |
| `RotorProofs/Timers/Local.lean` | what one step does, and `lost_cancel` |
| `RotorProofs/Timers/Good.lean` | the invariant every reachable state satisfies, and its primitives |
| `RotorProofs/Timers/Expire.lean` | expiry keeps the invariant and queues every due timer |
| `RotorProofs/Timers/Ops.lean` | flush, drain, cancel and tick keep it, and generations only grow |
| `RotorProofs/Timers/Reach.lean` | the theorems about every reachable state |
