import RotorProofs.Timers.Ops

/-!
# Timers: what holds of every run

`Reachable` is every state a loop reaches from `init` by submitting timers into free slots,
ticking with a clock that never goes back, and cancelling through any handle, current or stale.
The theorems below hold of all of them:

- `armed_on_schedule`: an armed timer is armed for its first deadline plus its fires times its
  period, whatever the clock read when each fire was handed over (decision 14, rule 3).
- `handed_over_on_schedule`: the fire a tick hands over was due, is the one the schedule names,
  and the timer is armed next for exactly one period later, so none is skipped (rules 3 and 4).
- `expire_queues_every_due`: a tick queues a fire for every timer that is due.
- `cancel_stops`: a cancel of an armed timer, through its handle, disarms it and makes its next
  event final (decision 5, rules 2 and 5).
- `cancel_ends_queued`: a cancel of a repeating timer whose fire is queued and not yet handed over
  makes that queued event its final one, and it says canceled (decision 14, rule 5).
- `final_is_last`: after an operation's final event, no event of any later tick carries its
  handle (decision 5, rule 1).
-/

namespace Rotor.Timers

open Rotor.Heap

/-- The states a loop reaches. -/
inductive Reachable : Tables → Prop where
  | init (entries : Nat → Entry) : Reachable (initial entries)
  | submit {t : Tables} (i after period userData : Nat) :
      Reachable t → (t.slots i).state = .free → Reachable (submit t i after period userData)
  | tick {t : Tables} (now room : Nat) :
      Reachable t → t.now ≤ now → Reachable (tick t now room).1
  | cancel {t : Tables} (h : Handle) : Reachable t → Reachable (cancel t h)

theorem Reachable.good {t : Tables} (r : Reachable t) : ∃ m, Good t m := by
  induction r with
  | init entries => exact ⟨_, initial_good entries⟩
  | submit i after period userData _ hfree ih =>
    obtain ⟨m, g⟩ := ih; exact ⟨m, submit_good _ m g i after period userData hfree⟩
  | tick now room _ hnow ih =>
    obtain ⟨m, g⟩ := ih; obtain ⟨m', g', _⟩ := tick_good _ m g now room hnow; exact ⟨m', g'⟩
  | cancel h _ ih =>
    obtain ⟨m, g⟩ := ih; obtain ⟨m', g', _⟩ := cancel_good _ m g h; exact ⟨m', g'⟩

/-- **Decision 14, rule 3.** An armed timer is armed for its first deadline plus its fires times its
period. Nothing in that sum is the clock at which a fire was handed over. -/
theorem armed_on_schedule {t : Tables} (r : Reachable t) (s : Nat)
    (hs : (t.slots s).state = .submitted) :
    ∃ m, Good t m ∧ ∃ x, m s = some x ∧
      x.deadline = (t.slots s).first + (t.slots s).fired * (t.slots s).period := by
  obtain ⟨m, g⟩ := r.good
  obtain ⟨x, hx⟩ := g.submitted s hs
  exact ⟨m, g, x, hx, by rw [(g.armed s x hx).2, g.schedule s]⟩

/-- **Decision 14, rules 2 to 4.** When a tick hands over a repeating timer's fire, the fire was
due, it was for the deadline the schedule names for its count of fires, the event says `more`,
and the timer is armed next for the deadline one period later: never a later one, so no period
is skipped, and never one read from the clock. It holds of every state a tick drains from. -/
theorem handed_over_on_schedule (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i : Nat)
    (rest : List Nat) (hfin : t.finished = i :: rest) (hrep : repeats (t.slots i) = true) :
    let s := t.slots i
    s.last = s.first + s.fired * s.period ∧ s.last ≤ t.now ∧
      (drain t 1).2.map (·.more) = [true] ∧
      ((drain t 1).1.slots i).last = s.first + (s.fired + 1) * s.period ∧
      ((drain t 1).1.slots i).state = .submitted := by
  have hs : (t.slots i).state = .finishing := g.finished i (by rw [hfin]; simp)
  have hc : (t.slots i).cancelRequested = false := by
    simp only [repeats, Bool.and_eq_true, Bool.not_eq_true'] at hrep; exact hrep.2
  have hr := g.fired_result i hs hc
  have hd := drain_repeating t i rest hfin hrep
  simp only at hd ⊢
  refine ⟨g.schedule i, g.due i hs hr, by rw [hd.1]; rfl, ?_, hd.2.1⟩
  rw [hd.2.2.1, g.schedule i, Nat.add_mul, Nat.one_mul, Nat.add_assoc]

/-- Every state a tick drains from satisfies the invariant: the drain above is every tick's. -/
theorem tick_drains_good {t : Tables} (r : Reachable t) (now : Nat) (hnow : t.now ≤ now) :
    ∃ m, Good (expire (flush { t with now := now })) m := by
  obtain ⟨m, g⟩ := r.good
  have g0 : Good { t with now := now } m :=
    { g with due := fun s hs hr => Nat.le_trans (g.due s hs hr) hnow }
  obtain ⟨m1, g1, _⟩ := flush_good _ m g0
  obtain ⟨m2, g2, _⟩ := expire_good _ m1 g1
  exact ⟨m2, g2⟩

/-- **Decision 14, rule 4.** A tick queues a fire for every timer that is due when it reads the
clock: after expiry no armed timer is due, and each that was is on the finished list. -/
theorem expire_queues_every_due (t : Tables) (m : Nat → Option Entry) (g : Good t m) :
    ∃ m', Good (expire t) m' ∧ (∀ s x, m' s = some x → t.now < x.deadline) ∧
      (∀ s x, m s = some x → x.deadline ≤ t.now → s ∈ (expire t).finished) :=
  let ⟨m', g', _, hnone, hall⟩ := expire_good t m g
  ⟨m', g', hnone, hall⟩

/-- **Decision 5, rules 2 and 5.** A cancel of an armed timer through its current handle disarms
it at once, so it cannot fire again, and its next event is its final one and says canceled. -/
theorem cancel_stops {t : Tables} (r : Reachable t) (h : Handle)
    (hs : (t.slots h.index).state = .submitted)
    (hg : (t.slots h.index).generation = h.generation) :
    ∃ m', Good (cancel t h) m' ∧ m' h.index = none ∧
      ((cancel t h).slots h.index).state = .finishing ∧
      ((cancel t h).slots h.index).result = canceled ∧
      repeats ((cancel t h).slots h.index) = false := by
  obtain ⟨m, g⟩ := r.good
  obtain ⟨m', g', _⟩ := cancel_good t m g h
  have hnot : (t.slots h.index).cancelRequested = false := g.submitted_unmarked _ hs
  have hcs := cancel_submitted t h hs hg hnot
  simp only at hcs
  refine ⟨m', g', g'.unarmed (by rw [hcs.1]; decide), hcs.1, hcs.2.1, hcs.2.2.1⟩

/-- **Decision 5, rule 2 and decision 14, rule 5.** A cancel, through its current handle, of a
repeating timer whose fire is queued and not yet handed over makes that queued event its final one:
the slot stays on the finished list and out of the heap, its event will not say `more`, and it says
canceled. The owner ruled on 2026-09-23 that the cancel replaces the queued fire. -/
theorem cancel_ends_queued {t : Tables} (r : Reachable t) (h : Handle)
    (hfin : h.index ∈ t.finished) (hrep : repeats (t.slots h.index) = true)
    (hg : (t.slots h.index).generation = h.generation) :
    ∃ m', Good (cancel t h) m' ∧ m' h.index = none ∧ h.index ∈ (cancel t h).finished ∧
      ((cancel t h).slots h.index).result = canceled ∧
      repeats ((cancel t h).slots h.index) = false := by
  obtain ⟨m, g⟩ := r.good
  obtain ⟨m', g', _⟩ := cancel_good t m g h
  have hs : (t.slots h.index).state = .finishing := g.finished _ hfin
  have hcf := cancel_finishing t h hs hg hrep
  refine ⟨m', g', g'.unarmed ?_, ?_, ?_, ?_⟩
  · rw [hcf, set_slots_same]; simp [hs]
  · rw [hcf, set_finished]; exact hfin
  · rw [hcf, set_slots_same]
  · rw [hcf, set_slots_same]; simp [repeats]

/-- One step a loop can take after another. -/
inductive Later : Tables → Tables → Prop where
  | refl (t : Tables) : Later t t
  | submit {t u : Tables} (i after period userData : Nat) :
      Later t u → Later t (submit u i after period userData)
  | tick {t u : Tables} (now room : Nat) : Later t u → Later t (tick u now room).1
  | cancel {t u : Tables} (h : Handle) : Later t u → Later t (cancel u h)

theorem Later.genLe {t u : Tables} (l : Later t u) : GenLe t u := by
  induction l with
  | refl => exact GenLe.refl _
  | submit i after period userData _ ih => exact ih.trans (submit_genLe _ i after period userData)
  | tick now room _ ih => exact ih.trans (tick_genLe _ now room)
  | cancel h _ ih => exact ih.trans (cancel_genLe _ h)

/-- Every event a tick hands over carries a generation at or above its slot's before the tick,
and a final one leaves its slot at a higher generation than it carries. -/
theorem tick_events (t : Tables) (now room : Nat) :
    ∀ e ∈ (tick t now room).2,
      (t.slots e.handle.index).generation ≤ e.handle.generation ∧
        (e.more = false →
          e.handle.generation < ((tick t now room).1.slots e.handle.index).generation) := by
  intro e he
  have := drain_events room (expire (flush { t with now := now })) e he
  have hg := ((flush_genLe { t with now := now }).trans
    (expireSteps_genLe (flush { t with now := now }).timers.count _)) e.handle.index
  exact ⟨Nat.le_trans hg this.1, this.2⟩

/-- **Decision 5, rule 1.** After an operation's final event, no event of any later tick carries
its handle: the slot's generation has moved past it and never comes back. -/
theorem final_is_last (t : Tables) (now room : Nat) (e : Event) (he : e ∈ (tick t now room).2)
    (hfinal : e.more = false) {u : Tables} (later : Later (tick t now room).1 u)
    (now' room' : Nat) (e' : Event) (he' : e' ∈ (tick u now' room').2)
    (hslot : e'.handle.index = e.handle.index) : e'.handle.generation ≠ e.handle.generation := by
  have h1 := (tick_events t now room e he).2 hfinal
  have h2 := later.genLe e.handle.index
  have h3 := (tick_events u now' room' e' he').1
  rw [hslot] at h3
  omega

end Rotor.Timers
