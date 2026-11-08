# Proofs

Machine-checked proofs, in [Lean 4](https://lean-lang.org), of rotor's timers: the timer heap in
`src/core/timer_heap.zig`, and what `src/core/tables/tables.zig` and a backend's `flush` and `tick`
do to a timer. Also the deficit of a scheduling group, which `src/core/scheduling/scheduling_run.zig`
keeps (decision 30). Each proof is about a model of the Zig code, written to be read beside it. Every
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
| a cancel of a repeating timer whose fire is queued and not yet handed over makes that queued event its final one, and it says canceled | decision 5, rule 2; decision 14, rule 5 | `cancel_ends_queued`, `cancel_not_lost`, `cancel_not_lost_fired` |
| after an operation's final event, no later event carries its handle | decision 5, rule 1 | `final_is_last` |
| a group's deficit stays in `[1 - task_charge_max * 100, 0]` between visits, and at most its shares inside one | decision 30, "Bounds", G2 | `visit_bounds`, `visit_open_le` |
| the bulk credit leaves a debt, never takes credit away, and the next visit after it starts a task | decision 30, rule 5; the class A check that follows a bulk credit | `bulk_le_zero`, `le_bulk`, `bulk_then_start` |
| over `n` visits of a group that stays startable, its units served times 100 differ from `n` times its shares by less than `task_charge_max` units | decision 30, "Bounds", G3 | `runAll_eq`, `window` |

## What the proofs found

**A cancel of a repeating timer could be lost.** The first version of `Local.lean` proved it, as
`lost_cancel`:

1. A tick queues a fire for every timer that is due. Each queued timer's slot is `finishing`.
2. The tick hands over only as many events as the caller's array has room for.
3. A fire left over stays `finishing` until the next tick.
4. `Tables.cancellable` refused a `finishing` slot, so a cancel of that timer between the two
   ticks did nothing. `Tables.next_cancellable` skipped it too, so `cancel_all` did not reach it.
5. The next tick handed the fire over flagged `more`, and armed the timer again.

The caller asked the timer to stop, and no final event ever came. This contradicted decision 5,
rule 2 and decision 14, rule 5. The conformance suite reproduced it on all three backends
(`src/conformance/conformance_timers.zig`).

Camilo ruled on 2026-09-23 that the cancel replaces the queued fire: that event becomes the
timer's final one, and it says canceled. A cancel of a timer whose deadline passed before the loop
expired it already hands over the same event, so the caller gets one answer either way. The code
and the model changed together. `lost_cancel` became `cancel_not_lost`, which proves that the next
tick hands over the final event.

## How the models relate to the code

| model | Zig | what the model leaves out |
|---|---|---|
| `Heap.Defs` | `TimerHeap` | The capacity: the Zig `arm` asserts room, and the model has room everywhere. The array is a function from positions to entries. `sequence` does not wrap; `zigBefore_eq` covers the wrap. |
| `Timers.Defs`: `submit`, `armTimer`, `finishLocal`, `fireLocal`, `rearm`, `release`, `drain`, `drainFired`, `drainLists`, `requestCancel`, `cancellable` | `Tables.submit`, `arm`, `finish_local`, `fire`, `rearm`, `SlotTable.release`, the pops of `drain_lists` from each list, `drain_lists`, `request_cancel`, `cancellable` and `reachable` | Every slot holds a timer. A deadline on another kind of operation shares the heap, but its expiry goes to the backend's cancel. The slot table's free list is left out: `submit` takes the index a claim returns. The model's `Event` has no `dispatched` flag. Since decision 26, `drain_lists` copies that flag from the slot to the event. No theorem depends on it. Due timers wait on `fired` and the slots a cancel ends on `finished` (W3, ruled 2026-11-07). `drainFired` is `drain` with the two lists exchanged, so one proof covers the pops from both lists. The Zig `drain_lists` pops both lists in one loop, `fired` while it is under its share, and the model writes the same pops as `drainFired` and then `drain`. |
| `Timers.Defs`: `flushOne`, `flush`, `expire`, `tick` | a backend's `flush_one`, `flush`, `expire` and `tick` | A tick is `flush`, `expire`, `drain_lists`, `expire` again, then `drain_lists` into the room that is left. The share `core.tick_share` gives the lists only bounds that room, so the model drains into any room. The Zig tick's first expiry is `finish_due_timers`, which stops at the first deadline that is not a timer's, and its second comes after its reap (issue 10). Every slot here holds a timer, so the first is `expire`. The Zig tick also drains mailboxes and the offload, and waits and reaps before its second expiry. None of that reaches a timer's slot. |
| `Drr` | `scheduling_run.zig`: `start`, `close`, `visit` and `bulk_credit` | The tick's bound of 64 starts: a visit it cuts resumes with no second credit, so its starts are one list. The other groups, which do not change this group's deficit. `charge_task`: a task's units are its cost and its charges together, at most `task_charge_max` by the caller's rule; the code checks each charge alone, and the floor check of `charge` halts a large excess. A change of shares: the window bound holds for visits at one value. |

Two fields of the model's slot are not in the Zig slot: `first`, the first deadline, and `handed`,
the fires handed over. Nothing the model computes reads these two fields. They exist so a theorem
can say which deadline the k-th fire was for. The model's `Tables.fired` is a different thing: the
list of due timers, as in the Zig tables, which `fireLocal` appends to and `drainLists` reads.

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
| `RotorProofs/Timers/Local.lean` | what one step does, `cancel_not_lost` and its form on the fired list |
| `RotorProofs/Timers/Good.lean` | the invariant every reachable state satisfies, and its primitives |
| `RotorProofs/Timers/Expire.lean` | expiry keeps the invariant and queues every due timer |
| `RotorProofs/Timers/Ops.lean` | flush, both drains, cancel and tick keep it, and generations only grow |
| `RotorProofs/Timers/Reach.lean` | the theorems about every reachable state |
| `RotorProofs/Drr.lean` | the deficit of one scheduling group: its bounds, the bulk credit and the window bound |
