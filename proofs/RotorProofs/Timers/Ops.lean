import RotorProofs.Timers.Expire

/-!
# Timers: the operations keep the invariant

`flush`, `drain`, `cancel` and a whole `tick` keep `Good`, and no operation lowers a slot's
generation. An event carries its slot's generation at the moment it is handed over, and a final
event leaves the slot at a higher one, so no event after it can carry its handle.
-/

namespace Rotor.Timers

open Rotor.Heap

/-! ## flush -/

theorem flushOne_pending (t : Tables) (i : Nat) : (flushOne t i).pending = t.pending := by
  unfold flushOne; dsimp only; split <;> rfl

theorem flushOne_now (t : Tables) (i : Nat) : (flushOne t i).now = t.now := by
  unfold flushOne; dsimp only; split <;> rfl

theorem flushOne_other (t : Tables) (i : Nat) {s : Nat} (h : s ≠ i) :
    (flushOne t i).slots s = t.slots s := by
  unfold flushOne; dsimp only; split
  · simp [finishLocal, set_slots_other _ _ h]
  · simp [armTimer, set_slots_other _ _ h]

theorem flushOne_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (i : Nat)
    (hq : (t.slots i).state = .queued) (hnp : i ∉ t.pending) : ∃ m', Good (flushOne t i) m' := by
  unfold flushOne
  dsimp only
  split
  · rename_i hc
    exact ⟨_, finishLocal_good t m g i canceled (Or.inl hq) hnp (Or.inr hc) (by simp [canceled])⟩
  · rename_i hc
    exact ⟨_, flushArm_good t m g i hq hnp (by simpa using hc)⟩

theorem flushFold_good : ∀ (l : List Nat) (t : Tables) (m : Nat → Option Entry), Good t m →
    t.pending = [] → (∀ j ∈ l, (t.slots j).state = .queued) → l.Nodup →
    ∃ m', Good (l.foldl flushOne t) m' ∧ (l.foldl flushOne t).pending = [] ∧
      (l.foldl flushOne t).now = t.now
  | [], t, m, g, hp, _, _ => ⟨m, g, hp, rfl⟩
  | j :: rest, t, m, g, hp, hq, hnd => by
    simp only [List.foldl_cons]
    have hj : (t.slots j).state = .queued := hq j (by simp)
    obtain ⟨m1, g1⟩ := flushOne_good t m g j hj (by rw [hp]; simp)
    have hnd' := List.nodup_cons.mp hnd
    obtain ⟨m', g', hp', hnow'⟩ := flushFold_good rest (flushOne t j) m1 g1
      (by rw [flushOne_pending]; exact hp)
      (by
        intro k hk
        have hkj : k ≠ j := fun e => hnd'.1 (e ▸ hk)
        rw [flushOne_other t j hkj]; exact hq k (by simp [hk]))
      hnd'.2
    exact ⟨m', g', hp', by rw [hnow', flushOne_now]⟩

theorem flush_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) :
    ∃ m', Good (flush t) m' ∧ (flush t).now = t.now := by
  have g0 : Good { t with pending := [] } m :=
    { g with pending := by intro s hs; simp at hs, pending_nodup := List.nodup_nil }
  obtain ⟨m', g', _, hnow⟩ :=
    flushFold_good t.pending { t with pending := [] } m g0 rfl g.pending g.pending_nodup
  exact ⟨m', g', hnow⟩

/-! ## drain -/

theorem drain_good : ∀ (room : Nat) (t : Tables) (m : Nat → Option Entry), Good t m →
    ∃ m', Good (drain t room).1 m' ∧ (drain t room).1.now = t.now
  | 0, t, m, g => ⟨m, g, rfl⟩
  | room + 1, t, m, g => by
    cases hfin : t.finished with
    | nil => rw [drain, hfin]; exact ⟨m, g, rfl⟩
    | cons i rest =>
      rw [drain_step t i rest room hfin]
      have g1 := dropHead_good t m g i rest hfin
      have hs : (t.slots i).state = .finishing := g.finished i (by rw [hfin]; simp)
      have hnf : i ∉ rest := (List.nodup_cons.mp (hfin ▸ g.finished_nodup)).1
      by_cases hrep : repeats (t.slots i) = true
      · simp only [hrep, ↓reduceIte]
        obtain ⟨m', g', hnow⟩ :=
          drain_good room _ _ (rearm_good { t with finished := rest } m g1 i hs hnf (by
            simp only [repeats, Bool.and_eq_true, Bool.not_eq_true'] at hrep; exact hrep.2))
        exact ⟨m', g', by rw [hnow]; rfl⟩
      · simp only [hrep, Bool.false_eq_true, ↓reduceIte]
        obtain ⟨m', g', hnow⟩ :=
          drain_good room _ _ (release_good { t with finished := rest } m g1 i hs hnf)
        exact ⟨m', g', by rw [hnow]; rfl⟩

/-! ## cancel -/

theorem cancel_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (h : Handle) :
    ∃ m', Good (cancel t h) m' ∧ (cancel t h).now = t.now := by
  unfold cancel
  split
  · rename_i hc
    unfold requestCancel
    dsimp only
    split
    · exact ⟨m, g, rfl⟩
    · rename_i hnot
      split
      · rename_i hq
        exact ⟨m, mark_good t m g h.index (by rw [hq]; decide), rfl⟩
      · rename_i hnq
        have hsub : (t.slots h.index).state = .submitted := by
          simp only [cancellable, Bool.and_eq_true, bne_iff_ne, ne_eq, beq_iff_eq] at hc
          cases hst : (t.slots h.index).state <;> simp_all
        exact ⟨_, cancelSubmitted_good t m g h.index hsub, rfl⟩
  · exact ⟨m, g, rfl⟩

/-! ## tick -/

theorem tick_good (t : Tables) (m : Nat → Option Entry) (g : Good t m) (now room : Nat)
    (hnow : t.now ≤ now) : ∃ m', Good (tick t now room).1 m' ∧ (tick t now room).1.now = now := by
  have g0 : Good { t with now := now } m :=
    { g with due := fun s hs hr => Nat.le_trans (g.due s hs hr) hnow }
  obtain ⟨m1, g1, hn1⟩ := flush_good _ m g0
  obtain ⟨m2, g2, hn2, _, _⟩ := expire_good _ m1 g1
  obtain ⟨m3, g3, hn3⟩ := drain_good room _ m2 g2
  exact ⟨m3, g3, by unfold tick; rw [hn3, hn2, hn1]⟩

/-! ## Generations only grow -/

/-- No slot's generation is lower in `t'` than in `t`. -/
def GenLe (t t' : Tables) : Prop := ∀ s, (t.slots s).generation ≤ (t'.slots s).generation

theorem GenLe.refl (t : Tables) : GenLe t t := fun _ => Nat.le_refl _

theorem GenLe.trans {a b c : Tables} (h₁ : GenLe a b) (h₂ : GenLe b c) : GenLe a c :=
  fun s => Nat.le_trans (h₁ s) (h₂ s)

theorem set_genLe (t : Tables) (i : Nat) (s : Slot) (h : (t.slots i).generation ≤ s.generation) :
    GenLe t (t.set i s) := by
  intro j; by_cases hj : j = i
  · subst hj; simpa using h
  · simp [set_slots_other _ _ hj]

theorem submit_genLe (t : Tables) (i after period userData : Nat) :
    GenLe t (submit t i after period userData) := by
  intro j; by_cases hj : j = i
  · subst hj; simp [submit]
  · simp [submit, set_slots_other _ _ hj]

theorem finishLocal_genLe (t : Tables) (i : Nat) (r : Int) : GenLe t (finishLocal t i r) :=
  set_genLe t i _ (Nat.le_refl _)

theorem flushOne_genLe (t : Tables) (i : Nat) : GenLe t (flushOne t i) := by
  unfold flushOne; dsimp only; split
  · exact finishLocal_genLe t i canceled
  · intro j; by_cases hj : j = i
    · subst hj; simp [armTimer]
    · simp [armTimer, set_slots_other _ _ hj]

theorem flush_genLe (t : Tables) : GenLe t (flush t) := by
  unfold flush
  suffices h : ∀ (l : List Nat) (a : Tables), GenLe t a → GenLe t (l.foldl flushOne a) from
    h t.pending _ (fun _ => Nat.le_refl _)
  intro l
  induction l with
  | nil => intro a ha; exact ha
  | cons j rest ih => intro a ha; exact ih _ (ha.trans (flushOne_genLe a j))

theorem expireSteps_genLe : ∀ (fuel : Nat) (t : Tables), GenLe t (expireSteps t fuel)
  | 0, t => GenLe.refl t
  | fuel + 1, t => by
    rw [expireSteps]
    cases popDue t.timers t.now with
    | mk answer heap =>
      cases answer with
      | none => exact GenLe.refl t
      | some i =>
        exact (finishLocal_genLe { t with timers := heap } i 0).trans (expireSteps_genLe fuel _)

theorem rearm_genLe (t : Tables) (i : Nat) : GenLe t (rearm t i) := by
  intro j; by_cases hj : j = i
  · subst hj; simp [rearm_slot]
  · simp [rearm_other t hj]

theorem release_genLe (t : Tables) (i : Nat) : GenLe t (release t i) := by
  intro j; by_cases hj : j = i
  · subst hj; simp [release_slot]
  · simp [release_other t hj]

theorem drain_genLe : ∀ (room : Nat) (t : Tables), GenLe t (drain t room).1
  | 0, t => GenLe.refl t
  | room + 1, t => by
    cases hfin : t.finished with
    | nil => rw [drain, hfin]; exact GenLe.refl t
    | cons i rest =>
      rw [drain_step t i rest room hfin]
      by_cases hrep : repeats (t.slots i) = true
      · simp only [hrep, ↓reduceIte]
        exact (rearm_genLe { t with finished := rest } i).trans (drain_genLe room _)
      · simp only [hrep, Bool.false_eq_true, ↓reduceIte]
        exact (release_genLe { t with finished := rest } i).trans (drain_genLe room _)

theorem cancel_genLe (t : Tables) (h : Handle) : GenLe t (cancel t h) := by
  unfold cancel requestCancel
  dsimp only
  split
  · split
    · exact GenLe.refl t
    · split
      · exact set_genLe t h.index { t.slots h.index with cancelRequested := true } (Nat.le_refl _)
      · exact (set_genLe t h.index { t.slots h.index with cancelRequested := true }
          (Nat.le_refl _)).trans (finishLocal_genLe _ _ _)
  · exact GenLe.refl t

theorem tick_genLe (t : Tables) (now room : Nat) : GenLe t (tick t now room).1 :=
  ((flush_genLe { t with now := now }).trans
    (expireSteps_genLe (flush { t with now := now }).timers.count _)).trans (drain_genLe room _)

/-- Every event `drain` hands over carries its slot's generation, at or above the generation the
slot had when the drain began; a final one leaves its slot at a higher generation than it
carries. -/
theorem drain_events : ∀ (room : Nat) (t : Tables), ∀ e ∈ (drain t room).2,
    (t.slots e.handle.index).generation ≤ e.handle.generation ∧
      (e.more = false → e.handle.generation < ((drain t room).1.slots e.handle.index).generation)
  | 0, t => by intro e he; simp [drain] at he
  | room + 1, t => by
    intro e he
    cases hfin : t.finished with
    | nil => rw [drain, hfin] at he; simp at he
    | cons i rest =>
      rw [drain_step t i rest room hfin] at he ⊢
      by_cases hrep : repeats (t.slots i) = true
      · simp only [hrep, ↓reduceIte, List.mem_cons] at he ⊢
        rcases he with he | he
        · subst he
          refine ⟨Nat.le_refl _, fun hmore => ?_⟩
          simp at hmore
        · have := drain_events room (rearm { t with finished := rest } i) e he
          have hg := rearm_genLe { t with finished := rest } i e.handle.index
          exact ⟨Nat.le_trans hg this.1, this.2⟩
      · simp only [hrep, Bool.false_eq_true, ↓reduceIte, List.mem_cons] at he ⊢
        rcases he with he | he
        · subst he
          refine ⟨Nat.le_refl _, fun _ => ?_⟩
          have := drain_genLe room (release { t with finished := rest } i) i
          rw [release_slot] at this
          simp only at this ⊢
          omega
        · have := drain_events room (release { t with finished := rest } i) e he
          have hg := release_genLe { t with finished := rest } i e.handle.index
          exact ⟨Nat.le_trans hg this.1, this.2⟩

end Rotor.Timers
