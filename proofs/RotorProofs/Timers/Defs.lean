import RotorProofs.Heap.Spec

/-!
# Timers: the model

A model of what `src/core/tables.zig` and a backend's `flush` and `tick` do to a timer, written to
be read beside them. Each definition names the Zig function it mirrors. The heap is the verified
model of `Heap/`, so every property proved about it holds here.

What it leaves out, and why the omission changes nothing proved here:

- Every slot holds a timer. Deadlines on other operations share the heap, and their expiry hands
  the operation to the backend's cancel, which is not a timer's path.
- The slot table's free list is left out: `submit` takes the index a claim would return, which
  must be a free slot.
- A tick is `flush`, then `expire`, then `drain_finished` into room for `room` events. The Zig tick
  also drains mailboxes and the offload, waits, and may expire and drain once more after a wait
  that produced nothing; a timer's slot sees that second pass as one more tick.

Two fields are the proof's and not the Zig slot's: `first`, the first deadline a timer was armed
for, and `fired`, how many of its fires have been handed over. Nothing the model computes reads
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
  fired : Nat
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
  /-- `finished`: finishing slots, oldest first. -/
  finished : List Nat
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
      first := 0, fired := 0 }
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

/-- A backend's `flush_one` for a timer: a queued timer already marked cancelled finishes there,
and any other is submitted and armed. -/
def flushOne (t : Tables) (i : Nat) : Tables :=
  let s := t.slots i
  if s.cancelRequested then finishLocal t i canceled
  else armTimer (t.set i { s with state := .submitted }) i

/-- A backend's `flush`: every queued slot, oldest first. -/
def flush (t : Tables) : Tables :=
  t.pending.foldl flushOne { t with pending := [] }

/-- The loop of `expire` and `Tables.next_expired`: pops a due timer and finishes it with 0, at
most `fuel` times, which the Zig loop bounds by the heap's count. -/
def expireSteps (t : Tables) : Nat → Tables
  | 0 => t
  | fuel + 1 =>
    match popDue t.timers t.now with
    | (none, _) => t
    | (some i, heap) => expireSteps (finishLocal { t with timers := heap } i 0) fuel

def expire (t : Tables) : Tables := expireSteps t t.timers.count

/-- `repeats`: the fire being handed over is one of many. -/
def repeats (s : Slot) : Bool := s.repeating && !s.cancelRequested

/-- `rearm`: the next deadline is the last one plus the period, never the clock plus the period
(decision 14, rule 3). -/
def rearm (t : Tables) (i : Nat) : Tables :=
  let s := t.slots i
  let due := s.last + s.period
  let t1 := t.set i { s with state := .submitted, last := due, fired := s.fired + 1 }
  { t1 with timers := arm t.timers i due }

/-- `SlotTable.release`: the slot is free, and its generation moves on. -/
def release (t : Tables) (i : Nat) : Tables :=
  let s := t.slots i
  t.set i { s with state := .free, generation := s.generation + 1 }

/-- `Tables.drain_finished` into room for `room` events. -/
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

/-- `Tables.request_cancel` for a timer: once, and a timer that is not still queued finishes at
once, because it lives in the heap and its cancel has no race (decision 5, rule 5). -/
def requestCancel (t : Tables) (i : Nat) : Tables :=
  let s := t.slots i
  if s.cancelRequested then t
  else
    let marked := t.set i { s with cancelRequested := true }
    if s.state = .queued then marked else finishLocal marked i canceled

/-- `Tables.cancellable`: the slot a handle names when a cancel can still reach it. A stale handle,
and a slot whose final event is already queued, give none. -/
def cancellable (t : Tables) (h : Handle) : Bool :=
  let s := t.slots h.index
  s.state != .free && s.generation == h.generation && s.state != .finishing

/-- A backend's `cancel` for a timer. -/
def cancel (t : Tables) (h : Handle) : Tables :=
  if cancellable t h then requestCancel t h.index else t

/-- A tick at clock `now`, with room for `room` events. -/
def tick (t : Tables) (now room : Nat) : Tables × List Event :=
  drain (expire (flush { t with now := now })) room

end Rotor.Timers
