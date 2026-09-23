import RotorProofs.Timers.Defs

/-!
# Timers: what one step does

Theorems about a single `drain`, `rearm`, `release` and `cancel`, proved from the definitions
alone:

- `drain_repeating`: handing over a repeating timer's fire says `more`, and arms the next deadline
  at the last one plus the period, whatever the clock says (decision 14, rules 2 and 3).
- `drain_final`: handing over any other event is the operation's final one, and frees the slot
  under a new generation, so no later event can carry the old handle (decision 5, rule 1).
- `cancel_submitted`: a cancel of an armed timer ends it at once, and its next event is final and
  says canceled (decision 5, rules 2 and 5).
- `lost_cancel`: a cancel of a repeating timer whose fire is queued and not yet handed over is
  dropped, and the timer fires again. It contradicts decision 5, rule 2 and decision 14, rule 5.
-/

namespace Rotor.Timers

open Rotor.Heap

@[simp] theorem set_slots_same (t : Tables) (i : Nat) (s : Slot) : (t.set i s).slots i = s := by
  simp [Tables.set]

theorem set_slots_other (t : Tables) {i j : Nat} (s : Slot) (h : j ≠ i) :
    (t.set i s).slots j = t.slots j := by
  simp [Tables.set, h]

@[simp] theorem set_finished (t : Tables) (i : Nat) (s : Slot) : (t.set i s).finished = t.finished :=
  rfl

@[simp] theorem set_timers (t : Tables) (i : Nat) (s : Slot) : (t.set i s).timers = t.timers := rfl

@[simp] theorem set_now (t : Tables) (i : Nat) (s : Slot) : (t.set i s).now = t.now := rfl

@[simp] theorem set_pending (t : Tables) (i : Nat) (s : Slot) : (t.set i s).pending = t.pending := rfl

@[simp] theorem rearm_finished (t : Tables) (i : Nat) : (rearm t i).finished = t.finished := rfl

@[simp] theorem release_finished (t : Tables) (i : Nat) : (release t i).finished = t.finished := rfl

theorem rearm_slot (t : Tables) (i : Nat) :
    (rearm t i).slots i =
      { t.slots i with
        state := .submitted, last := (t.slots i).last + (t.slots i).period,
        fired := (t.slots i).fired + 1 } := by
  simp [rearm]

theorem rearm_other (t : Tables) {i j : Nat} (h : j ≠ i) : (rearm t i).slots j = t.slots j := by
  simp [rearm, set_slots_other _ _ h]

theorem rearm_timers (t : Tables) (i : Nat) :
    (rearm t i).timers = arm t.timers i ((t.slots i).last + (t.slots i).period) := rfl

theorem release_slot (t : Tables) (i : Nat) :
    (release t i).slots i =
      { t.slots i with state := .free, generation := (t.slots i).generation + 1 } := by
  simp [release]

theorem release_other (t : Tables) {i j : Nat} (h : j ≠ i) : (release t i).slots j = t.slots j := by
  simp [release, set_slots_other _ _ h]

/-- One step of `drain`: the head of the finished list is handed over. -/
theorem drain_step (t : Tables) (i : Nat) (rest : List Nat) (room : Nat)
    (hfin : t.finished = i :: rest) :
    drain t (room + 1) =
      let s := t.slots i
      let t1 : Tables := { t with finished := rest }
      let next := drain (if repeats s then rearm t1 i else release t1 i) room
      (next.1, { handle := ⟨i, s.generation⟩, userData := s.userData, result := s.result,
                 more := repeats s } :: next.2) := by
  rw [drain, hfin]

/-- Handing over a repeating timer's fire says `more`, keeps the slot, and arms the deadline the
period after the one it fired for: the clock does not enter it. -/
theorem drain_repeating (t : Tables) (i : Nat) (rest : List Nat) (hfin : t.finished = i :: rest)
    (hrep : repeats (t.slots i) = true) :
    let result := drain t 1
    result.2 = [{ handle := ⟨i, (t.slots i).generation⟩, userData := (t.slots i).userData,
                  result := (t.slots i).result, more := true }] ∧
      (result.1.slots i).state = .submitted ∧
      (result.1.slots i).last = (t.slots i).last + (t.slots i).period ∧
      (result.1.slots i).generation = (t.slots i).generation ∧
      result.1.timers = arm t.timers i ((t.slots i).last + (t.slots i).period) := by
  rw [drain_step t i rest 0 hfin]
  simp only [hrep, ↓reduceIte, drain, rearm_slot, rearm_timers, and_self]

/-- Handing over any other event is the operation's final one: it says no `more`, and the slot is
free under a new generation. -/
theorem drain_final (t : Tables) (i : Nat) (rest : List Nat) (hfin : t.finished = i :: rest)
    (hrep : repeats (t.slots i) = false) :
    let result := drain t 1
    result.2 = [{ handle := ⟨i, (t.slots i).generation⟩, userData := (t.slots i).userData,
                  result := (t.slots i).result, more := false }] ∧
      (result.1.slots i).state = .free ∧
      (result.1.slots i).generation = (t.slots i).generation + 1 := by
  rw [drain_step t i rest 0 hfin]
  simp only [hrep, Bool.false_eq_true, ↓reduceIte, drain, release_slot, and_self]

/-- A cancel of an armed timer, through a current handle, finishes it at once: its slot waits on
the finished list with `canceled`, it is marked so the event will not say `more`, and its heap
entry is gone, so it cannot fire again. -/
theorem cancel_submitted (t : Tables) (h : Handle) (hs : (t.slots h.index).state = .submitted)
    (hg : (t.slots h.index).generation = h.generation)
    (hnot : (t.slots h.index).cancelRequested = false) :
    let t' := cancel t h
    (t'.slots h.index).state = .finishing ∧ (t'.slots h.index).result = canceled ∧
      repeats (t'.slots h.index) = false ∧ t'.finished = t.finished ++ [h.index] ∧
      t'.timers = disarm t.timers h.index := by
  have hc : cancellable t h = true := by simp [cancellable, hs, hg]
  simp only [cancel, hc, ↓reduceIte, requestCancel, hnot, Bool.false_eq_true, hs, reduceCtorEq,
    finishLocal, set_slots_same, repeats, Bool.not_true, Bool.and_false]
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> first | trivial | rfl

/-- **A cancel can be lost.** Two fires are queued, and a tick has room to hand over one: the
first is handed over, and the second timer's slot stays `finishing`. `cancellable` refuses a
finishing slot, so a cancel of the second timer between the ticks changes nothing, and the next
tick hands its fire over with `more` and arms it again. The caller asked for the timer to stop,
and decision 5, rule 2 answers a cancel with the operation's final event; none comes, and the
timer keeps firing.

It needs only that the two queued fires are of different slots, and that the second repeats. A
tick queues a fire for every timer that is due, and hands over as many as its events have room
for, so any loop with more timers due at once than its tick's events hold reaches this state. -/
theorem lost_cancel (t : Tables) (a b : Nat) (rest : List Nat) (hab : a ≠ b)
    (hfin : t.finished = a :: b :: rest) (hb : (t.slots b).state = .finishing)
    (hrep : repeats (t.slots b) = true) :
    let first := drain t 1
    let h : Handle := ⟨b, (t.slots b).generation⟩
    let cancelled := cancel first.1 h
    cancelled = first.1 ∧
      (drain cancelled 1).2.map (·.more) = [true] ∧
      ((drain cancelled 1).1.slots b).state = .submitted := by
  have hba : b ≠ a := Ne.symm hab
  -- After the first tick's drain, b is still finishing and heads the finished list.
  have hfirst : (drain t 1).1.finished = b :: rest ∧ (drain t 1).1.slots b = t.slots b := by
    rw [drain_step t a (b :: rest) 0 hfin]
    by_cases ha : repeats (t.slots a) = true
    · simp only [ha, ↓reduceIte, drain, rearm_finished, rearm_other _ hba, and_self]
    · simp only [ha, Bool.false_eq_true, ↓reduceIte, drain, release_finished,
        release_other _ hba, and_self]
  simp only
  have hdrop : cancel (drain t 1).1 ⟨b, (t.slots b).generation⟩ = (drain t 1).1 := by
    have : cancellable (drain t 1).1 ⟨b, (t.slots b).generation⟩ = false := by
      simp [cancellable, hfirst.2, hb]
    simp [cancel, this]
  rw [hdrop]
  have hrep' : repeats ((drain t 1).1.slots b) = true := by rw [hfirst.2]; exact hrep
  have := drain_repeating (drain t 1).1 b rest hfirst.1 hrep'
  simp only at this
  refine ⟨rfl, ?_, this.2.1⟩
  rw [this.1]
  rfl

end Rotor.Timers
