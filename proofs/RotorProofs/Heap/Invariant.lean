import RotorProofs.Heap.Order

/-!
# What a heap must satisfy

A heap is valid against a model `m`, a map from each slot to the entry it has armed, when three
things hold:

- `Ordered`: no entry orders before its parent, the heap order `assert_heap` checks.
- `Holds`: the heap holds exactly `m`'s entries, one per slot, and each slot's `position` names the
  position its entry is at, the other half of what `assert_heap` checks.
- `Fresh`: every armed entry's sequence is below the heap's `sequence`, and no two share one.

`m` is the model the Zig property test in `timer_heap.zig` keeps: each slot's deadline and arm.

While a sift runs, the heap has a hole: the position the entry being placed will land at, whose
array element is stale. `Sifting` states what holds of the other positions then, and the lemmas
below show that moving an entry into the hole, and then placing the entry itself, keep it.
-/

namespace Rotor.Heap

@[simp] theorem update_same {α : Type} (f : Nat → α) (i : Nat) (v : α) : update f i v i = v := by
  simp [update]

@[simp] theorem update_other {α : Type} (f : Nat → α) {i j : Nat} (v : α) (h : j ≠ i) :
    update f i v j = f j := by
  simp [update, h]

theorem update_apply {α : Type} (f : Nat → α) (i j : Nat) (v : α) :
    update f i v j = if j = i then v else f j := rfl

/-- No entry in the heap orders before its parent. -/
def Ordered (h : Heap) : Prop :=
  ∀ i, 0 < i → i < h.count → ¬ Before (h.entries i) (h.entries (parent i))

/-- The heap holds exactly the entries of `m`, one per slot, each where its slot's `position`
says. -/
structure Holds (h : Heap) (m : Nat → Option Entry) : Prop where
  at_position : ∀ i, i < h.count → h.position (h.entries i).slot = some i
  in_model : ∀ i, i < h.count → m (h.entries i).slot = some (h.entries i)
  positioned : ∀ s i, h.position s = some i → i < h.count ∧ (h.entries i).slot = s
  in_heap : ∀ s x, m s = some x → ∃ i, h.position s = some i ∧ h.entries i = x

/-- Every armed entry's sequence is below `sequence`, and no two armed entries share one. -/
structure Fresh (m : Nat → Option Entry) (sequence : Nat) : Prop where
  below : ∀ s x, m s = some x → x.sequence < sequence
  distinct : ∀ s t x y, m s = some x → m t = some y → x.sequence = y.sequence → s = t

/-- A valid heap. -/
structure Valid (h : Heap) (m : Nat → Option Entry) : Prop where
  ordered : Ordered h
  holds : Holds h m
  fresh : Fresh m h.sequence

/-- The heap part way through a sift that is placing `e`, with the hole at `hole`: every other
position holds a model entry and its slot points at it, and `e` is in the model and at no other
position. `e`'s own slot may still name a stale position. -/
structure Sifting (h : Heap) (hole : Nat) (e : Entry) (m : Nat → Option Entry) : Prop where
  hole_lt : hole < h.count
  at_position : ∀ i, i < h.count → i ≠ hole → h.position (h.entries i).slot = some i
  in_model : ∀ i, i < h.count → i ≠ hole → m (h.entries i).slot = some (h.entries i)
  not_placed : ∀ i, i < h.count → i ≠ hole → (h.entries i).slot ≠ e.slot
  positioned : ∀ s i, h.position s = some i → s ≠ e.slot →
    i < h.count ∧ i ≠ hole ∧ (h.entries i).slot = s
  placing : m e.slot = some e
  in_heap : ∀ s x, m s = some x → s ≠ e.slot →
    ∃ i, i < h.count ∧ i ≠ hole ∧ h.position s = some i ∧ h.entries i = x

theorem Sifting.slot_ne {h : Heap} {hole : Nat} {e : Entry} {m : Nat → Option Entry}
    (st : Sifting h hole e m) {i j : Nat} (hi : i < h.count) (hj : j < h.count)
    (hih : i ≠ hole) (hjh : j ≠ hole) (hij : i ≠ j) : (h.entries i).slot ≠ (h.entries j).slot := by
  intro heq
  have a := st.at_position i hi hih
  have b := st.at_position j hj hjh
  rw [heq] at a
  rw [a] at b
  exact hij (Option.some.inj b)

/-- Moving the entry at `q` into the hole makes `q` the hole. -/
theorem Sifting.move {h : Heap} {hole q : Nat} {e : Entry} {m : Nat → Option Entry}
    (st : Sifting h hole e m) (hq : q < h.count) (hqh : q ≠ hole) :
    Sifting (place h hole (h.entries q)) q e m := by
  have hslot : ∀ i, i < h.count → i ≠ hole → i ≠ q →
      (h.entries i).slot ≠ (h.entries q).slot :=
    fun i hi hih hiq => st.slot_ne hi hq hih hqh hiq
  constructor
  · simpa [place] using hq
  · intro i hi hiq
    simp only [place] at hi ⊢
    by_cases hih : i = hole
    · subst hih; simp
    · rw [update_other _ _ hih, update_other _ _ (hslot i hi hih hiq)]
      exact st.at_position i hi hih
  · intro i hi hiq
    simp only [place] at hi ⊢
    by_cases hih : i = hole
    · subst hih; simp only [update_same]; exact st.in_model q hq hqh
    · rw [update_other _ _ hih]; exact st.in_model i hi hih
  · intro i hi hiq
    simp only [place] at hi ⊢
    by_cases hih : i = hole
    · subst hih; simp only [update_same]; exact st.not_placed q hq hqh
    · rw [update_other _ _ hih]; exact st.not_placed i hi hih
  · intro s i hs hse
    simp only [place, update_apply] at hs ⊢
    by_cases hsq : s = (h.entries q).slot
    · simp only [hsq, ite_true] at hs
      cases hs
      exact ⟨st.hole_lt, Ne.symm hqh, by simp [hsq]⟩
    · simp only [hsq, ite_false] at hs
      obtain ⟨hi, hih, hslot'⟩ := st.positioned s i hs hse
      have hiq : i ≠ q := by
        intro hiq; subst hiq; exact hsq hslot'.symm
      exact ⟨hi, hiq, by simp [hih, hslot']⟩
  · exact st.placing
  · intro s x hm hse
    obtain ⟨i, hi, hih, hpos, hx⟩ := st.in_heap s x hm hse
    simp only [place, update_apply]
    by_cases hiq : i = q
    · subst hiq
      have hs : s = (h.entries i).slot := ((st.positioned s i hpos hse).2.2).symm
      refine ⟨hole, st.hole_lt, Ne.symm hqh, ?_, ?_⟩
      · simp [hs]
      · simp [hx]
    · have hs : s ≠ (h.entries q).slot := by
        have := (st.positioned s i hpos hse).2.2
        rw [← this]; exact hslot i hi hih hiq
      exact ⟨i, hi, hiq, by simp [hs, hpos], by simp [hih, hx]⟩

/-- Placing `e` in the hole leaves a heap that holds exactly the model. -/
theorem Sifting.finish {h : Heap} {hole : Nat} {e : Entry} {m : Nat → Option Entry}
    (st : Sifting h hole e m) : Holds (place h hole e) m := by
  constructor
  · intro i hi
    simp only [place] at hi ⊢
    by_cases hih : i = hole
    · subst hih; simp
    · rw [update_other _ _ hih, update_other _ _ (st.not_placed i hi hih)]
      exact st.at_position i hi hih
  · intro i hi
    simp only [place] at hi ⊢
    by_cases hih : i = hole
    · subst hih; simp only [update_same]; exact st.placing
    · rw [update_other _ _ hih]; exact st.in_model i hi hih
  · intro s i hs
    simp only [place, update_apply] at hs ⊢
    by_cases hse : s = e.slot
    · simp only [hse, ite_true] at hs
      cases hs
      exact ⟨st.hole_lt, by simp [hse]⟩
    · simp only [hse, ite_false] at hs
      obtain ⟨hi, hih, hslot⟩ := st.positioned s i hs hse
      exact ⟨hi, by simp [hih, hslot]⟩
  · intro s x hm
    simp only [place, update_apply]
    by_cases hse : s = e.slot
    · subst hse
      rw [st.placing] at hm
      cases hm
      exact ⟨hole, by simp⟩
    · obtain ⟨i, _, hih, hpos, hx⟩ := st.in_heap s x hm hse
      exact ⟨i, by simp [hse, hpos], by simp [hih, hx]⟩

end Rotor.Heap
