import RotorProofs.Heap.Spec

/-!
# Timers: the model

A model of what `src/core/tables/tables.zig` and a backend's `flush` and `tick` do to a timer,
written to be read beside them. Each definition names the Zig function it mirrors. The heap is the verified
model of `Heap/`, so every property proved about it holds here.

What it leaves out, and why the omission changes nothing proved here:

- Every slot holds a timer. Deadlines on other operations share the heap, and their expiry hands
  the operation to the backend's cancel, which is not a timer's path.
- The slot table's free list is left out: `submit` takes the index a claim would return, which
  must be a free slot.
- A tick is `flush`, `expire`, `drain_lists`, `expire` again, then `drain_lists` into the room
  that is left. The Zig tick's first expiry is `finish_due_timers`, which stops at the first
  deadline that is not a timer's; here every slot holds a timer, so it is `expire`. The Zig tick
  also drains mailboxes and the offload, and waits and reaps before its second expiry; none of that
  reaches a timer's slot. The share the Zig tick gives its lists, `lists_max` of
  `core.tick_share`, is a count that only bounds the room here, so the model drains into any room.
- Due timers wait on `fired` and the slots a cancel ends on `finished`, both first in, first out
  (W3, ruled 2026-11-07). `drainLists` hands over `fired` first, up to its share, then `finished`.

Two fields are the proof's and not the Zig slot's: `first`, the first deadline a timer was armed
for, and `handed`, how many of its fires have been handed over. Nothing the model computes reads
them; they exist so a theorem can say which deadline the k-th fire was for.
-/

namespace Rotor.Timers

open Rotor.Heap

/-- `Slot.State`. -/
inductive State where
  | free
  | queued
  | submitted
  | finishing
  deriving DecidableEq, Repr

/-- The fields of `Slot` a timer uses. -/
structure Slot where
  state : State
  /-- `Slot.generation`: a handle names a slot and a generation. -/
  generation : Nat
  userData : Nat
  /-- `flags.multishot`: the timer repeats. -/
  repeating : Bool
  /-- `flags.cancel_requested`. -/
  cancelRequested : Bool
  /-- `timeout_ns`, which a timer uses for its period. -/
  period : Nat
  /-- `offset`, which a timer uses for its first delay. -/
  after : Nat
  /-- `buffer`, which a timer uses for the deadline it was last armed for. -/
  last : Nat
  result : Int
  /-- The proof's: the first deadline. -/
  first : Nat
  /-- The proof's: the fires handed over. -/
  handed : Nat
  deriving Repr

/-- `event.result_of(.canceled)`: some negative number, which is all this model needs of it. -/
def canceled : Int := -1

/-- `Handle`. -/
structure Handle where
  index : Nat
  generation : Nat

/-- `Event`, with the handle of the operation it belongs to, which is the proof's: the Zig event
carries `user_data` alone. -/
structure Event where
  handle : Handle
  userData : Nat
  result : Int
  more : Bool

/-- The parts of `Tables` a timer uses. -/
structure Tables where
  slots : Nat → Slot
  timers : Heap
  /-- `pending`: queued slots, oldest first. -/
  pending : List Nat
  /-- `finished`: finishing slots the loop ended itself, oldest first. -/
  finished : List Nat
  /-- `fired`: due timers, oldest first, in the order they came due (W3). -/
  fired : List Nat
  /-- `now_ns`, as the last tick read it. -/
  now : Nat

/-- Replaces slot `i`. -/
def Tables.set (t : Tables) (i : Nat) (s : Slot) : Tables :=
  { t with slots := update t.slots i s }

/-- `Tables.submit` for one timer, into slot `i`, which a claim returned and so is free. The
handle it gives the caller is `(i, generation)`. -/
def submit (t : Tables) (i after period userData : Nat) : Tables :=
  let s := t.slots i
  let filled : Slot :=
    { s with
      state := .queued, userData := userData, repeating := period != 0,
      cancelRequested := false, period := period, after := after, last := 0, result := 0,
      first := 0, handed := 0 }
  let t1 := t.set i filled
  { t1 with pending := t.pending ++ [i] }

/-- `Tables.arm` for a timer: due `after` from now, and `buffer` keeps that deadline, which every
later period is measured from (decision 14, rule 3). -/
def armTimer (t : Tables) (i : Nat) : Tables :=
  let s := t.slots i
  let due := t.now + s.after
  let t1 := t.set i { s with last := due, first := due }
  { t1 with timers := arm t.timers i due }

/-- `Tables.finish_local`: disarms the slot if it is armed, and queues its final result. -/
def finishLocal (t : Tables) (i : Nat) (result : Int) : Tables :=
  let s := t.slots i
  let t1 := t.set i { s with state := .finishing, result := result }
  { t1 with timers := disarm t.timers i, finished := t.finished ++ [i] }

/-- `Tables.fire`: a due timer's fire, 0. It disarms the slot if it is armed, and appends the slot to
`fired`, as `finishLocal` appends to `finished`: both lists stay first in, first out. -/
def fireLocal (t : Tables) (i : Nat) : Tables :=
  let s := t.slots i
  let t1 := t.set i { s with state := .finishing, result := 0 }
  { t1 with timers := disarm t.timers i, fired := t.fired ++ [i] }

/-- A backend's `flush_one` for a timer: a queued timer already marked cancelled finishes there,
and any other is submitted and armed. -/
def flushOne (t : Tables) (i : Nat) : Tables :=
  let s := t.slots i
  if s.cancelRequested then finishLocal t i canceled
  else armTimer (t.set i { s with state := .submitted }) i

/-- A backend's `flush`: every queued slot, oldest first. -/
def flush (t : Tables) : Tables :=
  t.pending.foldl flushOne { t with pending := [] }

/-- The loop of `expire` and `Tables.next_expired`: pops a due timer and moves it to `fired`, at
most `fuel` times, which the Zig loop bounds by the heap's count. -/
def expireSteps (t : Tables) : Nat → Tables
  | 0 => t
  | fuel + 1 =>
    match popDue t.timers t.now with
    | (none, _) => t
    | (some i, heap) => expireSteps (fireLocal { t with timers := heap } i) fuel

def expire (t : Tables) : Tables := expireSteps t t.timers.count

/-- `repeats`: the fire being handed over is one of many. -/
def repeats (s : Slot) : Bool := s.repeating && !s.cancelRequested

/-- `rearm`: the next deadline is the last one plus the period, never the clock plus the period
(decision 14, rule 3). -/
def rearm (t : Tables) (i : Nat) : Tables :=
  let s := t.slots i
  let due := s.last + s.period
  let t1 := t.set i { s with state := .submitted, last := due, handed := s.handed + 1 }
  { t1 with timers := arm t.timers i due }

/-- `SlotTable.release`: the slot is free, and its generation moves on. -/
def release (t : Tables) (i : Nat) : Tables :=
  let s := t.slots i
  t.set i { s with state := .free, generation := s.generation + 1 }

/-- The pops of `Tables.drain_lists` from the finished list, into room for `room` events. -/
def drain (t : Tables) : Nat → Tables × List Event
  | 0 => (t, [])
  | room + 1 =>
    match t.finished with
    | [] => (t, [])
    | i :: rest =>
      let s := t.slots i
      let again := repeats s
      let event : Event :=
        { handle := ⟨i, s.generation⟩, userData := s.userData, result := s.result,
          more := again }
      let t1 := { t with finished := rest }
      let next := drain (if again then rearm t1 i else release t1 i) room
      (next.1, event :: next.2)

/-- The two lists exchanged: what lets `drain`, written for `finished`, drain `fired`. -/
def swap (t : Tables) : Tables := { t with fired := t.finished, finished := t.fired }

/-- The pops of `Tables.drain_lists` from the fired list, into room for `room` events. -/
def drainFired (t : Tables) (room : Nat) : Tables × List Event :=
  let r := drain (swap t) room
  (swap r.1, r.2)

/-- `Tables.drain_lists` into room for `room` events: `fired` takes up to
`room - min |finished| (room / 2)` places, and `finished` the rest (W3, ruled 2026-11-07). It is
irreducible, so a proof unfolds it by name and the elaborator does not compute the room of its
second loop from the first loop's events. -/
@[irreducible] def drainLists (t : Tables) (room : Nat) : Tables × List Event :=
  let first := drainFired t (room - min t.finished.length (room / 2))
  let second := drain first.1 (room - first.2.length)
  (second.1, first.2 ++ second.2)

/-- `Tables.request_cancel` for a timer: once. A queued timer is left for the flush to end. A
repeating timer whose fire is queued and not yet handed over has that fire replaced with
`canceled`, so the event already on the fired list is its final one: Camilo's ruling of
2026-09-23 (decision 14, rule 5). Any other timer finishes at once, because it lives in the heap
and its cancel has no race (decision 5, rule 5). -/
def requestCancel (t : Tables) (i : Nat) : Tables :=
  let s := t.slots i
  if s.cancelRequested then t
  else
    let marked := t.set i { s with cancelRequested := true }
    if s.state = .queued then marked
    else if s.state = .finishing then t.set i { s with cancelRequested := true, result := canceled }
    else finishLocal marked i canceled

/-- `Tables.cancellable`, with `reachable`: the slot a handle names when a cancel can still reach
it. A stale handle gives none, and so does a slot whose final event is already queued. A repeating
timer whose queued fire says `more` has no final event yet, and a cancel reaches it. -/
def cancellable (t : Tables) (h : Handle) : Bool :=
  let s := t.slots h.index
  s.state != .free && s.generation == h.generation && (s.state != .finishing || repeats s)

/-- A backend's `cancel` for a timer. -/
def cancel (t : Tables) (h : Handle) : Tables :=
  if cancellable t h then requestCancel t h.index else t

/-- A tick at clock `now`, with room for `room` events: it expires and hands over what is
finished, then expires again, after the place where the Zig tick reaps, and hands over what that
finished into the room that is left (issue 10). -/
def tick (t : Tables) (now room : Nat) : Tables × List Event :=
  let first := drainLists (expire (flush { t with now := now })) room
  let second := drainLists (expire first.1) (room - first.2.length)
  (second.1, first.2 ++ second.2)

end Rotor.Timers
