import RotorProofs.Heap.Sift

/-!
# What each operation does to the model

Each theorem takes a valid heap for a model `m` and says which model the heap is valid for after
the operation, and what the operation answers. Together they are the Zig property test's claim,
proved for every heap and every sequence of operations instead of 128 seeds:

- `arm_valid`: arming a slot the model does not hold adds that slot's entry, stamped with the
  heap's `sequence`.
- `disarm_valid`: disarming a slot removes its entry.
- `popDue_none`: `pop_due` answers null exactly when no armed entry is due.
- `popDue_some`: otherwise it answers the one armed entry that orders first, and removes it.
-/

namespace Rotor.Heap

/-- The empty heap `init` makes, valid for the empty model. -/
def empty (entries : Nat → Entry) (position : Nat → Option Nat) : Heap :=
  { entries := entries, count := 0, position := position, sequence := 0 }

theorem empty_valid (entries : Nat → Entry) :
    Valid (empty entries (fun _ => none)) (fun _ => none) where
  ordered := by intro i _ hi; simp [empty] at hi
  holds :=
    { at_position := by intro i hi; simp [empty] at hi
      in_model := by intro i hi; simp [empty] at hi
      positioned := by intro s i hs; simp [empty] at hs
      in_heap := by intro s x hm; simp at hm }
  fresh := { below := by intro s x hm; simp at hm, distinct := by intro s t x y hm; simp at hm }

theorem Holds.slot_eq {h : Heap} {m : Nat → Option Entry} (hh : Holds h m) {s : Nat} {x : Entry}
    (hm : m s = some x) : x.slot = s := by
  obtain ⟨i, hpos, hx⟩ := hh.in_heap s x hm
  rw [← hx]; exact (hh.positioned s i hpos).2

theorem Holds.slot_ne {h : Heap} {m : Nat → Option Entry} (hh : Holds h m) {i j : Nat}
    (hi : i < h.count) (hj : j < h.count) (hij : i ≠ j) : (h.entries i).slot ≠ (h.entries j).slot := by
  intro heq
  have a := hh.at_position i hi
  have b := hh.at_position j hj
  rw [heq, b] at a
  exact hij (Option.some.inj a).symm

/-- The root orders at or before every entry of an ordered heap. -/
theorem root_first {h : Heap} (ho : Ordered h) : ∀ i, i < h.count → ¬ Before (h.entries i) (h.entries 0) := by
  intro i
  induction i using Nat.strongRecOn with
  | ind i ih =>
    intro hi
    by_cases hi0 : i = 0
    · subst hi0; exact before_irrefl _
    · have hp := parent_lt hi0
      exact not_before_trans (ho i (by omega) hi) (ih (parent i) hp (by omega))

/-! ## arm -/

theorem arm_valid (h : Heap) (m : Nat → Option Entry) (hv : Valid h m) (slot deadline : Nat)
    (hfree : m slot = none) :
    Valid (arm h slot deadline)
      (update m slot (some { deadline := deadline, sequence := h.sequence, slot := slot })) ∧
      (arm h slot deadline).sequence = h.sequence + 1 ∧
      (arm h slot deadline).count = h.count + 1 := by
  let e : Entry := { deadline := deadline, sequence := h.sequence, slot := slot }
  let h1 : Heap := { h with sequence := h.sequence + 1, count := h.count + 1 }
  let m' := update m slot (some e)
  have hne : ∀ i, i < h.count → (h.entries i).slot ≠ slot := by
    intro i hi heq
    have := hv.holds.in_model i hi
    rw [heq, hfree] at this
    cases this
  have st : Sifting h1 h.count e m' := by
    constructor
    · show h.count < h.count + 1; omega
    · intro i hi hih
      have hi' : i < h.count := by simp [h1] at hi; omega
      exact hv.holds.at_position i hi'
    · intro i hi hih
      have hi' : i < h.count := by simp [h1] at hi; omega
      show update m slot (some e) (h.entries i).slot = some (h.entries i)
      rw [update_other _ _ (hne i hi')]; exact hv.holds.in_model i hi'
    · intro i hi hih
      have hi' : i < h.count := by simp [h1] at hi; omega
      exact hne i hi'
    · intro s i hs hse
      obtain ⟨hi, hslot⟩ := hv.holds.positioned s i hs
      exact ⟨by show i < h.count + 1; omega, by omega, hslot⟩
    · show update m slot (some e) slot = some e; simp
    · intro s x hm hse
      have hm' : m s = some x := by
        have : update m slot (some e) s = some x := hm
        rwa [update_other _ _ hse] at this
      obtain ⟨i, hpos, hx⟩ := hv.holds.in_heap s x hm'
      have hi := (hv.holds.positioned s i hpos).1
      exact ⟨i, by show i < h.count + 1; omega, by omega, hpos, hx⟩
  have o : UpOrder h1 h.count e := by
    constructor
    · intro i hi0 hi hih _
      exact hv.ordered i hi0 (by simp [h1] at hi; omega)
    · intro _ c hc hcl
      have := child_range hc
      simp [h1, firstChild, arity] at hcl this; omega
    · intro c hc hcl
      have := child_range hc
      simp [h1, firstChild, arity] at hcl this; omega
  have r := siftUp_valid h1 h.count e m' st o
  refine ⟨⟨r.2.1, r.1, ?_⟩, by rw [arm, r.2.2.2], by rw [arm, r.2.2.1]⟩
  have hseq : (siftUp h1 h.count e).sequence = h.sequence + 1 := r.2.2.2
  unfold arm; rw [hseq]
  constructor
  · intro s x hm
    by_cases hs : s = slot
    · subst hs; simp at hm; subst hm; simp
    · have : m s = some x := by simpa [m', update_other _ _ hs] using hm
      have := hv.fresh.below s x this; omega
  · intro s t x y hms hmt hxy
    by_cases hs : s = slot <;> by_cases ht : t = slot
    · rw [hs, ht]
    · subst hs
      simp at hms; subst hms
      have : m t = some y := by simpa [m', update_other _ _ ht] using hmt
      have := hv.fresh.below t y this; simp at hxy; omega
    · subst ht
      simp at hmt; subst hmt
      have : m s = some x := by simpa [m', update_other _ _ hs] using hms
      have := hv.fresh.below s x this; simp at hxy; omega
    · have hs' : m s = some x := by simpa [m', update_other _ _ hs] using hms
      have ht' : m t = some y := by simpa [m', update_other _ _ ht] using hmt
      exact hv.fresh.distinct s t x y hs' ht' hxy

/-! ## remove, disarm and pop_due -/

theorem Fresh.shrink {m m' : Nat → Option Entry} {sequence : Nat} (f : Fresh m sequence)
    (sub : ∀ s y, m' s = some y → m s = some y) : Fresh m' sequence where
  below s x hm := f.below s x (sub s x hm)
  distinct s t x y hs ht hxy := f.distinct s t x y (sub s x hs) (sub t y ht) hxy

theorem update_none_sub (m : Nat → Option Entry) (slot : Nat) :
    ∀ s y, update m slot none s = some y → m s = some y := by
  intro s y hm
  by_cases hs : s = slot
  · subst hs; simp at hm
  · rwa [update_other _ _ hs] at hm

@[simp] theorem cut_count (h : Heap) (p : Nat) : (cut h p).count = h.count - 1 := rfl
@[simp] theorem cut_entries (h : Heap) (p : Nat) : (cut h p).entries = h.entries := rfl
@[simp] theorem cut_sequence (h : Heap) (p : Nat) : (cut h p).sequence = h.sequence := rfl
theorem cut_position (h : Heap) (p : Nat) :
    (cut h p).position = update h.position (h.entries p).slot none := rfl

/-- The heap `cut` leaves, with a hole at `p` and the last entry to place, when `p` is not the
last position. -/
theorem cut_sifting (h : Heap) (m : Nat → Option Entry) (hh : Holds h m) (p : Nat)
    (hpl : p < h.count - 1) :
    Sifting (cut h p) p (h.entries (h.count - 1)) (update m (h.entries p).slot none) := by
  have hp : p < h.count := by omega
  generalize hxs : (h.entries p).slot = xs
  have hslot_x : ∀ i, i < h.count → i ≠ p → (h.entries i).slot ≠ xs :=
    fun i hi hip => hxs ▸ hh.slot_ne hi hp hip
  have hlast_ne : (h.entries (h.count - 1)).slot ≠ xs := hslot_x _ (by omega) (by omega)
  have hpos : (cut h p).position = update h.position xs none := by rw [cut_position, hxs]
  constructor
  · simpa using hpl
  · intro i hi hip
    simp only [cut_count, cut_entries] at hi ⊢
    rw [hpos, update_other _ _ (hslot_x i (by omega) hip)]; exact hh.at_position i (by omega)
  · intro i hi hip
    simp only [cut_count, cut_entries] at hi ⊢
    rw [update_other _ _ (hslot_x i (by omega) hip)]; exact hh.in_model i (by omega)
  · intro i hi _
    simp only [cut_count, cut_entries] at hi ⊢
    exact hh.slot_ne (by omega) (by omega) (by omega)
  · intro s i hs hsl
    rw [hpos] at hs
    by_cases hsx : s = xs
    · subst hsx; simp at hs
    · rw [update_other _ _ hsx] at hs
      obtain ⟨hi, hsi⟩ := hh.positioned s i hs
      have hip : i ≠ p := by intro e; subst e; exact hsx (hsi.symm.trans hxs)
      have hil : i ≠ h.count - 1 := by intro e; subst e; exact hsl hsi.symm
      exact ⟨by simp; omega, hip, by simpa using hsi⟩
  · rw [update_other _ _ hlast_ne]; exact hh.in_model (h.count - 1) (by omega)
  · intro s y hm hsl
    have hsx : s ≠ xs := by intro e; subst e; simp at hm
    rw [update_other _ _ hsx] at hm
    obtain ⟨i, hposi, hy⟩ := hh.in_heap s y hm
    obtain ⟨hi, hsi⟩ := hh.positioned s i hposi
    have hip : i ≠ p := by intro e; subst e; exact hsx (hsi.symm.trans hxs)
    have hil : i ≠ h.count - 1 := by intro e; subst e; exact hsl hsi.symm
    exact ⟨i, by simp; omega, hip, by rw [hpos, update_other _ _ hsx]; exact hposi, by simpa using hy⟩

/-- `cut` at the last position is the whole of `remove`, and leaves a valid heap. -/
theorem cut_last_holds (h : Heap) (m : Nat → Option Entry) (hh : Holds h m) (p : Nat)
    (hp : p < h.count) (hlast : p = h.count - 1) :
    Holds (cut h p) (update m (h.entries p).slot none) := by
  generalize hxs : (h.entries p).slot = xs
  have hslot_x : ∀ i, i < h.count → i ≠ p → (h.entries i).slot ≠ xs :=
    fun i hi hip => hxs ▸ hh.slot_ne hi hp hip
  have hpos : (cut h p).position = update h.position xs none := by rw [cut_position, hxs]
  constructor
  · intro i hi
    simp only [cut_count, cut_entries] at hi ⊢
    rw [hpos, update_other _ _ (hslot_x i (by omega) (by omega))]
    exact hh.at_position i (by omega)
  · intro i hi
    simp only [cut_count, cut_entries] at hi ⊢
    rw [update_other _ _ (hslot_x i (by omega) (by omega))]
    exact hh.in_model i (by omega)
  · intro s i hs
    rw [hpos] at hs
    by_cases hsx : s = xs
    · subst hsx; simp at hs
    · rw [update_other _ _ hsx] at hs
      obtain ⟨hi, hsi⟩ := hh.positioned s i hs
      have hip : i ≠ p := by intro e; subst e; exact hsx (hsi.symm.trans hxs)
      exact ⟨by simp; omega, by simpa using hsi⟩
  · intro s y hm
    have hsx : s ≠ xs := by intro e; subst e; simp at hm
    rw [update_other _ _ hsx] at hm
    obtain ⟨i, hposi, hy⟩ := hh.in_heap s y hm
    exact ⟨i, by rw [hpos, update_other _ _ hsx]; exact hposi, by simpa using hy⟩

/-- Removing the entry at `p` takes its slot out of the model. -/
theorem remove_valid (h : Heap) (m : Nat → Option Entry) (hv : Valid h m) (p : Nat)
    (hp : p < h.count) :
    Valid (remove h p) (update m (h.entries p).slot none) ∧
      (remove h p).count = h.count - 1 ∧ (remove h p).sequence = h.sequence := by
  have fresh' : Fresh (update m (h.entries p).slot none) h.sequence :=
    hv.fresh.shrink (update_none_sub m _)
  unfold remove
  split
  · -- The entry removed is the last one: nothing moves.
    rename_i hlast
    simp only [cut_count] at hlast
    refine ⟨⟨?_, cut_last_holds h m hv.holds p hp hlast, by simpa using fresh'⟩, rfl, rfl⟩
    intro i hi0 hi
    simp only [cut_count, cut_entries] at hi ⊢
    exact hv.ordered i hi0 (by omega)
  · rename_i hlast
    simp only [cut_count] at hlast
    have hpl : p < h.count - 1 := by omega
    have st := cut_sifting h m hv.holds p hpl
    have except : OrderedExcept (cut h p) p := by
      intro i hi0 hi _ _
      simp only [cut_count, cut_entries] at hi ⊢
      exact hv.ordered i hi0 (by omega)
    have grand : p ≠ 0 → ∀ c, IsChild c p → c < (cut h p).count →
        ¬ Before ((cut h p).entries c) ((cut h p).entries (parent p)) := by
      intro hp0 c hc hcl
      simp only [cut_count, cut_entries] at hcl ⊢
      exact not_before_trans (by have := hv.ordered c hc.1 (by omega); rwa [hc.2] at this)
        (hv.ordered p (by omega) hp)
    simp only [cut_count, cut_entries] at st except grand ⊢
    by_cases hup : (p != 0 && before (h.entries (h.count - 1)) (h.entries (parent p))) = true
    · simp only [hup, ↓reduceIte]
      simp only [Bool.and_eq_true, bne_iff_ne, ne_eq] at hup
      have o : UpOrder (cut h p) p (h.entries (h.count - 1)) := by
        refine ⟨except, by simpa using grand, ?_⟩
        intro c hc hcl
        have g := grand hup.1 c hc (by simpa using hcl)
        exact before_asymm (before_of_before_not_before hup.2 (by simpa using g))
      have res := siftUp_valid (cut h p) p (h.entries (h.count - 1)) _ st o
      exact ⟨⟨res.2.1, res.1, by rw [res.2.2.2]; simpa using fresh'⟩, by rw [res.2.2.1]; rfl,
        by rw [res.2.2.2]; rfl⟩
    · simp only [hup, Bool.false_eq_true, ↓reduceIte]
      have o : DownOrder (cut h p) p (h.entries (h.count - 1)) := by
        refine ⟨except, ?_, by simpa using grand⟩
        intro hp0
        simpa [hp0] using hup
      have res := siftDown_valid (cut h p) p (h.entries (h.count - 1)) _ st o
      exact ⟨⟨res.2.1, res.1, by rw [res.2.2.2]; simpa using fresh'⟩, by rw [res.2.2.1]; rfl,
        by rw [res.2.2.2]; rfl⟩

/-- Disarming an armed slot takes it out of the model. -/
theorem disarm_valid (h : Heap) (m : Nat → Option Entry) (hv : Valid h m) (slot : Nat) (x : Entry)
    (harmed : m slot = some x) :
    Valid (disarm h slot) (update m slot none) ∧ (disarm h slot).count = h.count - 1 ∧
      (disarm h slot).sequence = h.sequence := by
  obtain ⟨p, hpos, _⟩ := hv.holds.in_heap slot x harmed
  obtain ⟨hp, hslot⟩ := hv.holds.positioned slot p hpos
  unfold disarm
  rw [hpos]
  have := remove_valid h m hv p hp
  rwa [hslot] at this

/-- A slot the heap does not hold has no position, so disarming it changes nothing. -/
theorem position_none (h : Heap) (m : Nat → Option Entry) (hv : Valid h m) (slot : Nat)
    (hfree : m slot = none) : h.position slot = none := by
  cases hpos : h.position slot with
  | none => rfl
  | some p =>
    obtain ⟨hp, hslot⟩ := hv.holds.positioned slot p hpos
    have := hv.holds.in_model p hp
    rw [hslot, hfree] at this
    cases this

/-- Two armed entries that order neither way round are the same slot: arms are never shared. -/
theorem first_unique (h : Heap) (m : Nat → Option Entry) (hv : Valid h m) {s t : Nat} {x y : Entry}
    (hs : m s = some x) (ht : m t = some y) (hxy : ¬ Before x y) (hyx : ¬ Before y x) : s = t := by
  rw [before_iff] at hxy hyx
  exact hv.fresh.distinct s t x y hs ht (by omega)

/-- The root of a non-empty heap is armed, and orders at or before every armed entry. -/
theorem root_armed (h : Heap) (m : Nat → Option Entry) (hv : Valid h m) (hc : 0 < h.count) :
    m (h.entries 0).slot = some (h.entries 0) ∧
      ∀ t y, m t = some y → ¬ Before y (h.entries 0) := by
  refine ⟨hv.holds.in_model 0 hc, ?_⟩
  intro t y hm
  obtain ⟨i, hpos, hy⟩ := hv.holds.in_heap t y hm
  rw [← hy]
  exact root_first hv.ordered i (hv.holds.positioned t i hpos).1

/-- `pop_due` answers null exactly when no armed entry is due, and then changes nothing. -/
theorem popDue_none (h : Heap) (m : Nat → Option Entry) (hv : Valid h m) (now : Nat) :
    ((popDue h now).1 = none ↔ ∀ s x, m s = some x → now < x.deadline) ∧
      ((popDue h now).1 = none → (popDue h now).2 = h) := by
  unfold popDue
  by_cases hc : h.count = 0
  · simp only [hc, ↓reduceIte, true_iff, implies_true, and_true]
    intro s x hm
    obtain ⟨i, hpos, _⟩ := hv.holds.in_heap s x hm
    have := (hv.holds.positioned s i hpos).1
    omega
  · have hroot := root_armed h m hv (by omega)
    by_cases hnow : now < (h.entries 0).deadline
    · simp only [hc, hnow, ↓reduceIte, true_iff, implies_true, and_true]
      intro s x hm
      have := hroot.2 s x hm
      rw [before_iff] at this
      omega
    · simp only [hc, hnow, ↓reduceIte, reduceCtorEq, false_iff, false_implies, and_true]
      intro hall
      exact hnow (hall _ _ hroot.1)

/-- When `pop_due` answers a slot, that slot is armed and due, orders at or before every armed
entry, and is the only armed entry that does; and the heap left is valid without it. -/
theorem popDue_some (h : Heap) (m : Nat → Option Entry) (hv : Valid h m) (now s : Nat)
    (hs : (popDue h now).1 = some s) :
    ∃ x, m s = some x ∧ x.deadline ≤ now ∧
      (∀ t y, m t = some y → ¬ Before y x) ∧
      (∀ t y, m t = some y → ¬ Before x y → t = s) ∧
      Valid (popDue h now).2 (update m s none) ∧
      (popDue h now).2.count = h.count - 1 ∧ (popDue h now).2.sequence = h.sequence := by
  unfold popDue at hs ⊢
  by_cases hc : h.count = 0
  · simp [hc] at hs
  · by_cases hnow : now < (h.entries 0).deadline
    · simp [hc, hnow] at hs
    · simp only [hc, hnow, ↓reduceIte, Option.some.injEq] at hs ⊢
      subst hs
      have hroot := root_armed h m hv (by omega)
      have hr := remove_valid h m hv 0 (by omega)
      refine ⟨h.entries 0, hroot.1, by omega, hroot.2, ?_, hr.1, hr.2.1, hr.2.2⟩
      intro t y ht hxy
      exact (first_unique h m hv hroot.1 ht hxy (hroot.2 t y ht)).symm

end Rotor.Heap
