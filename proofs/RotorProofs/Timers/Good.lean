import RotorProofs.Timers.Local

/-!
# Timers: what every reachable state satisfies

`Good t m` holds of every state the operations reach, where `m` is the heap's model:

- the heap is valid for `m`, and `m` arms exactly the submitted timers, each for the deadline its
  `buffer` holds;
- the pending list holds distinct queued slots, and the finished list distinct finishing slots;
- no submitted timer is marked cancelled: marking one finishes it at once;
- every slot's deadline is its first deadline plus its fires times its period, and a queued slot
  has fired none;
- a finishing slot nobody cancelled finished with 0, its fire, and that fire was due by the clock
  the tables last read.

This file proves the primitives keep it; `Reach.lean` puts the operations together.
-/

namespace Rotor.Timers

open Rotor.Heap

structure Good (t : Tables) (m : Nat → Option Entry) : Prop where
  valid : Valid t.timers m
  armed : ∀ s x, m s = some x → (t.slots s).state = .submitted ∧ x.deadline = (t.slots s).last
  submitted : ∀ s, (t.slots s).state = .submitted → ∃ x, m s = some x
  submitted_unmarked : ∀ s, (t.slots s).state = .submitted → (t.slots s).cancelRequested = false
  pending : ∀ s, s ∈ t.pending → (t.slots s).state = .queued
  pending_nodup : t.pending.Nodup
  finished : ∀ s, s ∈ t.finished → (t.slots s).state = .finishing
  finished_nodup : t.finished.Nodup
  schedule : ∀ s, (t.slots s).last = (t.slots s).first + (t.slots s).fired * (t.slots s).period
  queued_fresh : ∀ s, (t.slots s).state = .queued → (t.slots s).fired = 0
  fired_result : ∀ s, (t.slots s).state = .finishing → (t.slots s).cancelRequested = false →
    (t.slots s).result = 0
  due : ∀ s, (t.slots s).state = .finishing → (t.slots s).result = 0 → (t.slots s).last ≤ t.now

theorem Good.unarmed {t : Tables} {m : Nat → Option Entry} (g : Good t m) {s : Nat}
    (hs : (t.slots s).state ≠ .submitted) : m s = none := by
  cases h : m s with
  | none => rfl
  | some x => exact absurd (g.armed s x h).1 hs

theorem update_none_of_none (m : Nat → Option Entry) (s : Nat) (h : m s = none) :
    update m s none = m := by
  funext j; by_cases hj : j = s
  · subst hj; simp [h]
  · simp [hj]

/-- Disarming a slot the heap does not hold changes nothing. -/
theorem disarm_unarmed (h : Heap) (m : Nat → Option Entry) (hv : Valid h m) (s : Nat)
    (hs : m s = none) : disarm h s = h := by
  unfold disarm; rw [position_none h m hv s hs]

/-- The state every slot starts in: free, generation 1, and every number 0. -/
def freshSlot : Slot :=
  { state := .free, generation := 1, userData := 0, repeating := false, cancelRequested := false,
    period := 0, after := 0, last := 0, result := 0, first := 0, fired := 0 }

/-- The tables `init` makes: every slot fresh, the heap empty, both lists empty. -/
def initial (entries : Nat → Entry) : Tables :=
  { slots := fun _ => freshSlot, timers := empty entries (fun _ => none), pending := [],
    finished := [], now := 0 }

theorem initial_good (entries : Nat → Entry) : Good (initial entries) (fun _ => none) where
  valid := empty_valid entries
  armed := by intro s x h; simp at h
  submitted := by intro s h; simp [initial, freshSlot] at h
  submitted_unmarked := by intro s h; simp [initial, freshSlot] at h
  pending := by intro s h; simp [initial] at h
  pending_nodup := List.nodup_nil
  finished := by intro s h; simp [initial] at h
  finished_nodup := List.nodup_nil
  schedule := by intro s; simp [initial, freshSlot]
  queued_fresh := by intro s h; simp [initial, freshSlot] at h
  fired_result := by intro s h; simp [initial, freshSlot] at h
  due := by intro s h; simp [initial, freshSlot] at h

/-! ## submit -/

theorem submit_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i after period userData : Nat)
    (hfree : (t.slots i).state = .free) : Good (submit t i after period userData) m := by
  have hnp : i ∉ t.pending := fun h => by have := g.pending i h; rw [hfree] at this; cases this
  have hi_unarmed : m i = none := g.unarmed (by rw [hfree]; decide)
  constructor
  · exact g.valid
  · intro s x hm
    have hsi : s ≠ i := by intro e; subst e; rw [hi_unarmed] at hm; cases hm
    simp only [submit, set_slots_other _ _ hsi]; exact g.armed s x hm
  · intro s hs
    by_cases hsi : s = i
    · subst hsi; simp [submit] at hs
    · simp only [submit, set_slots_other _ _ hsi] at hs; exact g.submitted s hs
  · intro s hs
    by_cases hsi : s = i
    · subst hsi; simp [submit] at hs
    · simp only [submit, set_slots_other _ _ hsi] at hs ⊢; exact g.submitted_unmarked s hs
  · intro s hs
    simp only [submit, List.mem_append, List.mem_singleton] at hs
    rcases hs with hs | hs
    · have hsi : s ≠ i := fun e => hnp (e ▸ hs)
      simp only [submit, set_slots_other _ _ hsi]; exact g.pending s hs
    · subst hs; simp [submit]
  · simp only [submit]
    exact List.nodup_append.mpr ⟨g.pending_nodup, by simp,
      by intro a ha b hb; simp at hb; subst hb; exact fun e => hnp (e ▸ ha)⟩
  · intro s hs
    have hsi : s ≠ i := by
      intro e; subst e; have := g.finished s hs; rw [hfree] at this; cases this
    simp only [submit, set_slots_other _ _ hsi]; exact g.finished s hs
  · exact g.finished_nodup
  · intro s
    by_cases hsi : s = i
    · subst hsi; simp [submit]
    · simp only [submit, set_slots_other _ _ hsi]; exact g.schedule s
  · intro s hs
    by_cases hsi : s = i
    · subst hsi; simp [submit]
    · simp only [submit, set_slots_other _ _ hsi] at hs ⊢; exact g.queued_fresh s hs
  · intro s hs hc
    by_cases hsi : s = i
    · subst hsi; simp [submit] at hs
    · simp only [submit, set_slots_other _ _ hsi] at hs hc ⊢; exact g.fired_result s hs hc
  · intro s hs hr
    by_cases hsi : s = i
    · subst hsi; simp [submit] at hs
    · simp only [submit, set_slots_other _ _ hsi] at hs hr ⊢; exact g.due s hs hr

/-! ## The primitives -/

/-- `finish_local` on a queued or submitted slot that is on neither list: the slot finishes, and
its heap entry, if it had one, is gone. A result other than 0 is a cancel's, whose slot is marked;
a 0 is a fire's, which was due. -/
theorem finishLocal_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i : Nat) (r : Int)
    (hstate : (t.slots i).state = .queued ∨ (t.slots i).state = .submitted)
    (hnp : i ∉ t.pending)
    (hresult : r = 0 ∨ (t.slots i).cancelRequested = true)
    (hdue : r = 0 → (t.slots i).last ≤ t.now) :
    Good (finishLocal t i r) (update m i none) := by
  have hnf : i ∉ t.finished := by
    intro h; have := g.finished i h; rcases hstate with hs | hs <;> rw [hs] at this <;> cases this
  have hvalid : Valid (disarm t.timers i) (update m i none) := by
    cases hmi : m i with
    | none =>
      rw [disarm_unarmed t.timers m g.valid i hmi, update_none_of_none m i hmi]; exact g.valid
    | some x => exact (disarm_valid t.timers m g.valid i x hmi).1
  have other : ∀ s, s ≠ i → (finishLocal t i r).slots s = t.slots s :=
    fun s hs => by simp [finishLocal, set_slots_other _ _ hs]
  have self : (finishLocal t i r).slots i = { t.slots i with state := .finishing, result := r } := by
    simp [finishLocal]
  constructor
  · exact hvalid
  · intro s x hm
    have hsi : s ≠ i := by intro e; subst e; simp at hm
    rw [update_other _ _ hsi] at hm
    rw [other s hsi]; exact g.armed s x hm
  · intro s hs
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hs; cases hs
    rw [other s hsi] at hs
    obtain ⟨x, hx⟩ := g.submitted s hs
    exact ⟨x, by rw [update_other _ _ hsi]; exact hx⟩
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
    · subst hsi; rw [self] at hc ⊢
      rcases hresult with hr | hr
      · exact hr
      · simp [hr] at hc
    · rw [other s hsi] at hs hc ⊢; exact g.fired_result s hs hc
  · intro s hs hr
    by_cases hsi : s = i
    · subst hsi; rw [self] at hr ⊢; exact hdue hr
    · rw [other s hsi] at hs hr ⊢; exact g.due s hs hr

/-- A backend's flush submits a queued timer that nobody cancelled and arms it `after` from now. -/
theorem flushArm_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i : Nat)
    (hq : (t.slots i).state = .queued) (hnp : i ∉ t.pending)
    (hnc : (t.slots i).cancelRequested = false) :
    Good (armTimer (t.set i { t.slots i with state := .submitted }) i)
      (update m i (some { deadline := t.now + (t.slots i).after, sequence := t.timers.sequence,
                          slot := i })) := by
  have hmi : m i = none := g.unarmed (by rw [hq]; decide)
  have hfresh := g.queued_fresh i hq
  have hnf : i ∉ t.finished := by intro h; have := g.finished i h; rw [hq] at this; cases this
  have ha := arm_valid t.timers m g.valid i (t.now + (t.slots i).after) hmi
  have other : ∀ s, s ≠ i →
      (armTimer (t.set i { t.slots i with state := .submitted }) i).slots s = t.slots s :=
    fun s hs => by simp [armTimer, set_slots_other _ _ hs]
  have self : (armTimer (t.set i { t.slots i with state := .submitted }) i).slots i =
      { t.slots i with state := .submitted, last := t.now + (t.slots i).after,
                       first := t.now + (t.slots i).after } := by
    simp [armTimer]
  have htimers : (armTimer (t.set i { t.slots i with state := .submitted }) i).timers =
      arm t.timers i (t.now + (t.slots i).after) := by simp [armTimer]
  constructor
  · rw [htimers]; exact ha.1
  · intro s x hm
    by_cases hsi : s = i
    · subst hsi; simp at hm; subst hm; rw [self]; exact ⟨rfl, rfl⟩
    · rw [update_other _ _ hsi] at hm; rw [other s hsi]; exact g.armed s x hm
  · intro s hs
    by_cases hsi : s = i
    · subst hsi; exact ⟨_, update_same _ _ _⟩
    · rw [other s hsi] at hs
      obtain ⟨x, hx⟩ := g.submitted s hs
      exact ⟨x, by rw [update_other _ _ hsi]; exact hx⟩
  · intro s hs
    by_cases hsi : s = i
    · subst hsi; rw [self]; exact hnc
    · rw [other s hsi] at hs ⊢; exact g.submitted_unmarked s hs
  · intro s hs
    have hsi : s ≠ i := fun e => hnp (e ▸ hs)
    rw [other s hsi]; exact g.pending s hs
  · exact g.pending_nodup
  · intro s hs
    have hsi : s ≠ i := fun e => hnf (e ▸ hs)
    rw [other s hsi]; exact g.finished s hs
  · exact g.finished_nodup
  · intro s
    by_cases hsi : s = i
    · subst hsi; rw [self]; simp [hfresh]
    · rw [other s hsi]; exact g.schedule s
  · intro s hs
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hs; cases hs
    rw [other s hsi] at hs ⊢; exact g.queued_fresh s hs
  · intro s hs hc
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hs; cases hs
    rw [other s hsi] at hs hc ⊢; exact g.fired_result s hs hc
  · intro s hs hr
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hs; cases hs
    rw [other s hsi] at hs hr ⊢; exact g.due s hs hr

/-- Taking the head off the finished list, which `drain` does before it hands the slot over. -/
theorem dropHead_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i : Nat)
    (rest : List Nat) (hfin : t.finished = i :: rest) : Good { t with finished := rest } m where
  valid := g.valid
  armed := g.armed
  submitted := g.submitted
  submitted_unmarked := g.submitted_unmarked
  pending := g.pending
  pending_nodup := g.pending_nodup
  finished s hs := g.finished s (by rw [hfin]; exact List.mem_cons_of_mem i hs)
  finished_nodup := by have := g.finished_nodup; rw [hfin] at this; exact this.of_cons
  schedule := g.schedule
  queued_fresh := g.queued_fresh
  fired_result := g.fired_result
  due := g.due

/-- `rearm` of a finishing slot that is on neither list: the next deadline is the last plus the
period, and the schedule stays true one fire later. -/
theorem rearm_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i : Nat)
    (hs : (t.slots i).state = .finishing) (hnf : i ∉ t.finished)
    (hnc : (t.slots i).cancelRequested = false) :
    Good (rearm t i)
      (update m i (some { deadline := (t.slots i).last + (t.slots i).period,
                          sequence := t.timers.sequence, slot := i })) := by
  have hmi : m i = none := g.unarmed (by rw [hs]; decide)
  have hnp : i ∉ t.pending := by intro h; have := g.pending i h; rw [hs] at this; cases this
  have ha := arm_valid t.timers m g.valid i ((t.slots i).last + (t.slots i).period) hmi
  have other : ∀ s, s ≠ i → (rearm t i).slots s = t.slots s := fun s h => rearm_other t h
  have self := rearm_slot t i
  constructor
  · rw [rearm_timers]; exact ha.1
  · intro s x hm
    by_cases hsi : s = i
    · subst hsi; simp at hm; subst hm; rw [self]; exact ⟨rfl, rfl⟩
    · rw [update_other _ _ hsi] at hm; rw [other s hsi]; exact g.armed s x hm
  · intro s hss
    by_cases hsi : s = i
    · subst hsi; exact ⟨_, update_same _ _ _⟩
    · rw [other s hsi] at hss
      obtain ⟨x, hx⟩ := g.submitted s hss
      exact ⟨x, by rw [update_other _ _ hsi]; exact hx⟩
  · intro s hss
    by_cases hsi : s = i
    · subst hsi; rw [self]; exact hnc
    · rw [other s hsi] at hss ⊢; exact g.submitted_unmarked s hss
  · intro s hsp
    have hsi : s ≠ i := fun e => hnp (e ▸ hsp)
    rw [other s hsi]; exact g.pending s hsp
  · exact g.pending_nodup
  · intro s hsf
    have hsi : s ≠ i := fun e => hnf (e ▸ hsf)
    rw [other s hsi]; exact g.finished s hsf
  · exact g.finished_nodup
  · intro s
    by_cases hsi : s = i
    · subst hsi; rw [self]; simp only
      rw [g.schedule s, Nat.add_mul, Nat.one_mul]; omega
    · rw [other s hsi]; exact g.schedule s
  · intro s hq
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hq; cases hq
    rw [other s hsi] at hq ⊢; exact g.queued_fresh s hq
  · intro s hf hc
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hf; cases hf
    rw [other s hsi] at hf hc ⊢; exact g.fired_result s hf hc
  · intro s hf hr
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hf; cases hf
    rw [other s hsi] at hf hr ⊢; exact g.due s hf hr

/-- `release` of a finishing slot that is on neither list. -/
theorem release_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i : Nat)
    (hs : (t.slots i).state = .finishing) (hnf : i ∉ t.finished) : Good (release t i) m := by
  have hmi : m i = none := g.unarmed (by rw [hs]; decide)
  have hnp : i ∉ t.pending := by intro h; have := g.pending i h; rw [hs] at this; cases this
  have other : ∀ s, s ≠ i → (release t i).slots s = t.slots s := fun s h => release_other t h
  have self := release_slot t i
  constructor
  · exact g.valid
  · intro s x hm
    have hsi : s ≠ i := by intro e; subst e; rw [hmi] at hm; cases hm
    rw [other s hsi]; exact g.armed s x hm
  · intro s hss
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hss; cases hss
    rw [other s hsi] at hss; exact g.submitted s hss
  · intro s hss
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hss; cases hss
    rw [other s hsi] at hss ⊢; exact g.submitted_unmarked s hss
  · intro s hsp
    have hsi : s ≠ i := fun e => hnp (e ▸ hsp)
    rw [other s hsi]; exact g.pending s hsp
  · exact g.pending_nodup
  · intro s hsf
    have hsi : s ≠ i := fun e => hnf (e ▸ hsf)
    rw [other s hsi]; exact g.finished s hsf
  · exact g.finished_nodup
  · intro s
    by_cases hsi : s = i
    · subst hsi; rw [self]; exact g.schedule s
    · rw [other s hsi]; exact g.schedule s
  · intro s hq
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hq; cases hq
    rw [other s hsi] at hq ⊢; exact g.queued_fresh s hq
  · intro s hf hc
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hf; cases hf
    rw [other s hsi] at hf hc ⊢; exact g.fired_result s hf hc
  · intro s hf hr
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hf; cases hf
    rw [other s hsi] at hf hr ⊢; exact g.due s hf hr

/-- Marking a slot cancelled keeps everything: the mark only ever excuses a result. -/
theorem mark_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i : Nat)
    (hns : (t.slots i).state ≠ .submitted) :
    Good (t.set i { t.slots i with cancelRequested := true }) m := by
  have other : ∀ s, s ≠ i → (t.set i { t.slots i with cancelRequested := true }).slots s = t.slots s :=
    fun s h => set_slots_other t _ h
  have self : (t.set i { t.slots i with cancelRequested := true }).slots i =
      { t.slots i with cancelRequested := true } := set_slots_same t i _
  constructor
  · exact g.valid
  · intro s x hm
    by_cases hsi : s = i
    · subst hsi; rw [self]; exact g.armed s x hm
    · rw [other s hsi]; exact g.armed s x hm
  · intro s hss
    by_cases hsi : s = i
    · subst hsi; rw [self] at hss; exact g.submitted s hss
    · rw [other s hsi] at hss; exact g.submitted s hss
  · intro s hss
    by_cases hsi : s = i
    · subst hsi; rw [self] at hss; exact absurd hss hns
    · rw [other s hsi] at hss ⊢; exact g.submitted_unmarked s hss
  · intro s hsp
    by_cases hsi : s = i
    · subst hsi; rw [self]; exact g.pending s hsp
    · rw [other s hsi]; exact g.pending s hsp
  · exact g.pending_nodup
  · intro s hsf
    by_cases hsi : s = i
    · subst hsi; rw [self]; exact g.finished s hsf
    · rw [other s hsi]; exact g.finished s hsf
  · exact g.finished_nodup
  · intro s
    by_cases hsi : s = i
    · subst hsi; rw [self]; exact g.schedule s
    · rw [other s hsi]; exact g.schedule s
  · intro s hq
    by_cases hsi : s = i
    · subst hsi; rw [self] at hq ⊢; exact g.queued_fresh s hq
    · rw [other s hsi] at hq ⊢; exact g.queued_fresh s hq
  · intro s hf hc
    by_cases hsi : s = i
    · subst hsi; rw [self] at hc; simp at hc
    · rw [other s hsi] at hf hc ⊢; exact g.fired_result s hf hc
  · intro s hf hr
    by_cases hsi : s = i
    · subst hsi; rw [self] at hf hr ⊢; exact g.due s hf hr
    · rw [other s hsi] at hf hr ⊢; exact g.due s hf hr

/-- `request_cancel` of a submitted timer: the slot is marked and finishes at once with
`canceled`, and its heap entry is gone. -/
theorem cancelSubmitted_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i : Nat)
    (hs : (t.slots i).state = .submitted) :
    Good (finishLocal (t.set i { t.slots i with cancelRequested := true }) i canceled)
      (update m i none) := by
  obtain ⟨x, hx⟩ := g.submitted i hs
  have hnp : i ∉ t.pending := by intro h; have := g.pending i h; rw [hs] at this; cases this
  have hnf : i ∉ t.finished := by intro h; have := g.finished i h; rw [hs] at this; cases this
  have hd := disarm_valid t.timers m g.valid i x hx
  let t' := finishLocal (t.set i { t.slots i with cancelRequested := true }) i canceled
  have other : ∀ s, s ≠ i → t'.slots s = t.slots s :=
    fun s h => by simp [t', finishLocal, set_slots_other _ _ h]
  have self : t'.slots i =
      { t.slots i with cancelRequested := true, state := .finishing, result := canceled } := by
    simp [t', finishLocal]
  have hcan : canceled ≠ 0 := by simp [canceled]
  show Good t' (update m i none)
  constructor
  · exact hd.1
  · intro s y hm
    have hsi : s ≠ i := by intro e; subst e; simp at hm
    rw [update_other _ _ hsi] at hm; rw [other s hsi]; exact g.armed s y hm
  · intro s hss
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hss; cases hss
    rw [other s hsi] at hss
    obtain ⟨y, hy⟩ := g.submitted s hss
    exact ⟨y, by rw [update_other _ _ hsi]; exact hy⟩
  · intro s hss
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hss; cases hss
    rw [other s hsi] at hss ⊢; exact g.submitted_unmarked s hss
  · intro s hsp
    have hsi : s ≠ i := fun e => hnp (e ▸ hsp)
    rw [other s hsi]; exact g.pending s hsp
  · exact g.pending_nodup
  · intro s hsf
    simp only [t', finishLocal, List.mem_append, List.mem_singleton, set_finished] at hsf
    rcases hsf with hsf | hsf
    · have hsi : s ≠ i := fun e => hnf (e ▸ hsf)
      rw [other s hsi]; exact g.finished s hsf
    · subst hsf; rw [self]
  · simp only [t', finishLocal, set_finished]
    exact List.nodup_append.mpr ⟨g.finished_nodup, by simp,
      by intro a ha b hb; simp at hb; subst hb; exact fun e => hnf (e ▸ ha)⟩
  · intro s
    by_cases hsi : s = i
    · subst hsi; rw [self]; exact g.schedule s
    · rw [other s hsi]; exact g.schedule s
  · intro s hq
    have hsi : s ≠ i := by intro e; subst e; rw [self] at hq; cases hq
    rw [other s hsi] at hq ⊢; exact g.queued_fresh s hq
  · intro s hf hc
    by_cases hsi : s = i
    · subst hsi; rw [self] at hc; simp at hc
    · rw [other s hsi] at hf hc ⊢; exact g.fired_result s hf hc
  · intro s hf hr
    by_cases hsi : s = i
    · subst hsi; rw [self] at hr; exact absurd hr hcan
    · rw [other s hsi] at hf hr ⊢; exact g.due s hf hr

end Rotor.Timers
