import RotorProofs.Timers.Good

/-!
# Timers: expiry

`expire` keeps the invariant, and it queues a fire for every timer that is due: after it, no
armed timer is due, and every timer that was due is on the finished list. With `Good.due`, a fire
is never early; with this, none is skipped (decision 14, rule 4).
-/

namespace Rotor.Timers

open Rotor.Heap

/-- One step of `expire`: `pop_due` answers a due timer, and `finish_local` queues its fire. -/
theorem expireOne_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i : Nat) (heap : Heap)
    (hpop : popDue t.timers t.now = (some i, heap)) :
    Good (finishLocal { t with timers := heap } i 0) (update m i none) ∧
      (finishLocal { t with timers := heap } i 0).timers.count = t.timers.count - 1 := by
  obtain ⟨x, hmi, hdl, _, _, hv, hcount, _⟩ :=
    popDue_some t.timers m g.valid t.now i (by rw [hpop])
  rw [hpop] at hv hcount
  obtain ⟨hsub, hdead⟩ := g.armed i x hmi
  have hdis : disarm heap i = heap := disarm_unarmed heap (update m i none) hv i (update_same _ _ _)
  have hnp : i ∉ t.pending := by intro h; have := g.pending i h; rw [hsub] at this; cases this
  have hnf : i ∉ t.finished := by intro h; have := g.finished i h; rw [hsub] at this; cases this
  have other : ∀ s, s ≠ i → (finishLocal { t with timers := heap } i 0).slots s = t.slots s :=
    fun s hs => by simp [finishLocal, Tables.set, hs]
  have self : (finishLocal { t with timers := heap } i 0).slots i =
      { t.slots i with state := .finishing, result := 0 } := by simp [finishLocal, Tables.set]
  refine ⟨?_, by show (disarm heap i).count = _; rw [hdis]; exact hcount⟩
  constructor
  · show Valid (disarm heap i) (update m i none); rw [hdis]; exact hv
  · intro s x' hm
    have hsi : s ≠ i := by intro e; subst e; simp at hm
    rw [update_other _ _ hsi] at hm; rw [other s hsi]; exact g.armed s x' hm
  · intro s hs
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hs; cases hs
    rw [other s hsi] at hs
    obtain ⟨y, hy⟩ := g.submitted s hs
    exact ⟨y, by rw [update_other _ _ hsi]; exact hy⟩
  · intro s hs
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hs; cases hs
    rw [other s hsi] at hs ⊢; exact g.submitted_unmarked s hs
  · intro s hs
    have hsi : s ≠ i := fun e => hnp (e ▸ hs)
    rw [other s hsi]; exact g.pending s hs
  · exact g.pending_nodup
  · intro s hs
    simp only [finishLocal, List.mem_append, List.mem_singleton] at hs
    rcases hs with hs | hs
    · have hsi : s ≠ i := fun e => hnf (e ▸ hs)
      rw [other s hsi]; exact g.finished s hs
    · subst hs; rw [self]
  · simp only [finishLocal]
    exact List.nodup_append.mpr ⟨g.finished_nodup, by simp,
      by intro a ha b hb; simp at hb; subst hb; exact fun e => hnf (e ▸ ha)⟩
  · intro s
    by_cases hsi : s = i
    · subst hsi; rw [self]; exact g.schedule s
    · rw [other s hsi]; exact g.schedule s
  · intro s hs
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hs; cases hs
    rw [other s hsi] at hs ⊢; exact g.queued_fresh s hs
  · intro s hs hc
    by_cases hsi : s = i
    · subst hsi; rw [self]
    · rw [other s hsi] at hs hc ⊢; exact g.fired_result s hs hc
  · intro s hs hr
    by_cases hsi : s = i
    · subst hsi; rw [self]; show (t.slots s).last ≤ t.now; rw [← hdead]; exact hdl
    · rw [other s hsi] at hs hr ⊢; exact g.due s hs hr

theorem finishLocal_finished (t : Tables) (i : Nat) (r : Int) :
    (finishLocal t i r).finished = t.finished ++ [i] := rfl

theorem finishLocal_now (t : Tables) (i : Nat) (r : Int) : (finishLocal t i r).now = t.now := rfl

/-- The loop of `expire` keeps the invariant and the clock, and, given fuel for every entry the
heap holds, queues every timer that was due. -/
theorem expireSteps_good : ∀ (fuel : Nat) (t : Tables) (m : Nat → Option Entry), Good t m →
    t.timers.count ≤ fuel →
    ∃ m', Good (expireSteps t fuel) m' ∧ (expireSteps t fuel).now = t.now ∧
      (∀ s x, m' s = some x → t.now < x.deadline) ∧
      (∀ s x, m s = some x → x.deadline ≤ t.now → s ∈ (expireSteps t fuel).finished) ∧
      (∀ s, s ∈ t.finished → s ∈ (expireSteps t fuel).finished)
  | 0, t, m, g, hfuel => by
    refine ⟨m, g, rfl, ?_, ?_, fun s hs => hs⟩
    · intro s x hm
      obtain ⟨i, hpos, _⟩ := g.valid.holds.in_heap s x hm
      have := (g.valid.holds.positioned s i hpos).1; omega
    · intro s x hm
      obtain ⟨i, hpos, _⟩ := g.valid.holds.in_heap s x hm
      have := (g.valid.holds.positioned s i hpos).1; omega
  | fuel + 1, t, m, g, hfuel => by
    rw [expireSteps]
    cases hpop : popDue t.timers t.now with
    | mk answer heap =>
      cases answer with
      | none =>
        simp only
        have hnone := (popDue_none t.timers m g.valid t.now).1.mp (by rw [hpop])
        refine ⟨m, g, by simp, hnone, ?_, fun s hs => hs⟩
        intro s x hm hd
        have := hnone s x hm; omega
      | some i =>
        simp only
        obtain ⟨g1, hcount⟩ := expireOne_good t m g i heap hpop
        obtain ⟨m', g', hnow', hnone', hall', hkeep'⟩ :=
          expireSteps_good fuel _ _ g1 (by rw [hcount]; omega)
        refine ⟨m', g', by rw [hnow']; rfl, ?_, ?_, ?_⟩
        · intro s x hm; have := hnone' s x hm; simpa [finishLocal_now] using this
        · intro s x hm hd
          by_cases hsi : s = i
          · subst hsi; apply hkeep'; rw [finishLocal_finished]; simp
          · apply hall' s x (by rw [update_other _ _ hsi]; exact hm)
            simpa [finishLocal_now] using hd
        · intro s hs; apply hkeep'; rw [finishLocal_finished]; simp [hs]

/-- `expire` keeps the invariant and the clock; after it no armed timer is due, and every timer
that was due is queued to be handed over. -/
theorem expire_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) :
    ∃ m', Good (expire t) m' ∧ (expire t).now = t.now ∧
      (∀ s x, m' s = some x → t.now < x.deadline) ∧
      (∀ s x, m s = some x → x.deadline ≤ t.now → s ∈ (expire t).finished) :=
  let ⟨m', g', hnow, hnone, hall, _⟩ := expireSteps_good t.timers.count t m g (Nat.le_refl _)
  ⟨m', g', hnow, hnone, hall⟩

end Rotor.Timers
