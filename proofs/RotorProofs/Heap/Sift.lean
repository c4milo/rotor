import RotorProofs.Heap.Invariant

/-!
# The sifts keep the heap

`siftUp` and `siftDown` each end with a heap that holds the model and is ordered, from a start
that the callers establish: `arm` for `siftUp`, and `remove` for either. The order part of that
start is `UpOrder` and `DownOrder`: every parent and child the hole does not touch are in order,
and the hole's own neighbours are in the order the direction of the sift needs.
-/

namespace Rotor.Heap

/-- `c` is a child of `p`. Position 0 is no position's child, although `parent 0` is 0. -/
def IsChild (c p : Nat) : Prop := 0 < c ∧ parent c = p

theorem child_range {c p : Nat} (h : IsChild c p) : firstChild p ≤ c ∧ c ≤ firstChild p + 3 := by
  unfold IsChild parent firstChild arity at *; omega

theorem child_gt {c p : Nat} (h : IsChild c p) : p < c := by
  unfold IsChild parent arity at *; omega

theorem parent_isChild {c : Nat} (h : 0 < c) : IsChild c (parent c) := ⟨h, rfl⟩

/-- Every parent and child pair that does not touch the hole is in order. -/
def OrderedExcept (h : Heap) (hole : Nat) : Prop :=
  ∀ i, 0 < i → i < h.count → i ≠ hole → parent i ≠ hole →
    ¬ Before (h.entries i) (h.entries (parent i))

/-- What `siftUp` needs of the order: the pairs off the hole are in order, the hole's children
are at or after its parent, and `e` is before or level with them. -/
structure UpOrder (h : Heap) (hole : Nat) (e : Entry) : Prop where
  except : OrderedExcept h hole
  grand : hole ≠ 0 → ∀ c, IsChild c hole → c < h.count →
    ¬ Before (h.entries c) (h.entries (parent hole))
  below : ∀ c, IsChild c hole → c < h.count → ¬ Before (h.entries c) e

/-- What `siftDown` needs of the order: the pairs off the hole are in order, `e` is at or after
the hole's parent, and so are the hole's children. -/
structure DownOrder (h : Heap) (hole : Nat) (e : Entry) : Prop where
  except : OrderedExcept h hole
  above : hole ≠ 0 → ¬ Before e (h.entries (parent hole))
  grand : hole ≠ 0 → ∀ c, IsChild c hole → c < h.count →
    ¬ Before (h.entries c) (h.entries (parent hole))

@[simp] theorem place_entries_same (h : Heap) (p : Nat) (e : Entry) :
    (place h p e).entries p = e := by simp [place]

theorem place_entries_other (h : Heap) {p i : Nat} (e : Entry) (hi : i ≠ p) :
    (place h p e).entries i = h.entries i := by simp [place, hi]

/-! ## sift_up -/

theorem UpOrder.move {h : Heap} {hole : Nat} {e : Entry} (o : UpOrder h hole e)
    (hne : hole ≠ 0) (hlt : hole < h.count) (hb : Before e (h.entries (parent hole))) :
    UpOrder (place h hole (h.entries (parent hole))) (parent hole) e := by
  have hq : parent hole < hole := parent_lt hne
  have hq_up : parent hole ≠ 0 → ¬ Before (h.entries (parent hole)) (h.entries (parent (parent hole))) :=
    fun hq0 => o.except (parent hole) (by omega) (by omega) (by omega) (by have := parent_lt hq0; omega)
  constructor
  · intro i hi0 hi hiq hpi
    simp only [place_count] at hi
    by_cases hih : i = hole
    · exact absurd (congrArg parent hih) hpi
    · rw [place_entries_other _ _ hih]
      by_cases hph : parent i = hole
      · rw [hph, place_entries_same]
        exact o.grand hne i ⟨hi0, hph⟩ hi
      · rw [place_entries_other _ _ hph]
        exact o.except i hi0 hi hih hph
  · intro hq0 c hc hcl
    simp only [place_count] at hcl
    have hpq : parent (parent hole) ≠ hole := by have := parent_lt hq0; omega
    rw [place_entries_other _ _ hpq]
    by_cases hch : c = hole
    · subst hch; rw [place_entries_same]; exact hq_up hq0
    · rw [place_entries_other _ _ hch]
      have hc_q : ¬ Before (h.entries c) (h.entries (parent hole)) := by
        have := o.except c hc.1 hcl hch (by rw [hc.2]; omega)
        rwa [hc.2] at this
      exact not_before_trans hc_q (hq_up hq0)
  · intro c hc hcl
    simp only [place_count] at hcl
    by_cases hch : c = hole
    · subst hch; rw [place_entries_same]; exact before_asymm hb
    · rw [place_entries_other _ _ hch]
      have hc_q : ¬ Before (h.entries c) (h.entries (parent hole)) := by
        have := o.except c hc.1 hcl hch (by rw [hc.2]; omega)
        rwa [hc.2] at this
      exact before_asymm (before_of_before_not_before hb hc_q)

theorem UpOrder.finish {h : Heap} {hole : Nat} {e : Entry} (o : UpOrder h hole e)
    (hstop : hole ≠ 0 → ¬ Before e (h.entries (parent hole))) :
    Ordered (place h hole e) := by
  intro i hi0 hi
  simp only [place_count] at hi
  by_cases hih : i = hole
  · subst hih
    have hp : parent i ≠ i := by have := parent_lt (show i ≠ 0 by omega); omega
    rw [place_entries_same, place_entries_other _ _ hp]
    exact hstop (by omega)
  · rw [place_entries_other _ _ hih]
    by_cases hph : parent i = hole
    · rw [hph, place_entries_same]; exact o.below i ⟨hi0, hph⟩ hi
    · rw [place_entries_other _ _ hph]; exact o.except i hi0 hi hih hph

/-- `siftUp` from a heap with a hole ends in a heap that holds the model and is ordered. -/
theorem siftUp_valid (h : Heap) (hole : Nat) (e : Entry) (m : Nat → Option Entry)
    (st : Sifting h hole e m) (o : UpOrder h hole e) :
    Holds (siftUp h hole e) m ∧ Ordered (siftUp h hole e) ∧
      (siftUp h hole e).count = h.count ∧ (siftUp h hole e).sequence = h.sequence := by
  induction h, hole using siftUp.induct (e := e) with
  | case1 h =>
    rw [siftUp]; simp only [dite_true]
    exact ⟨st.finish, o.finish (fun h0 => absurd rfl h0), rfl, rfl⟩
  | case2 h hole hne hb ih =>
    rw [siftUp]; simp only [hne, dite_false, hb, ite_true]
    have hq : parent hole < hole := parent_lt hne
    have := ih (st.move (by have := st.hole_lt; omega) (by omega)) (o.move hne st.hole_lt hb)
    exact ⟨this.1, this.2.1, by rw [this.2.2.1]; rfl, by rw [this.2.2.2]; rfl⟩
  | case3 h hole hne hb =>
    rw [siftUp]; simp only [hne, dite_false, hb, Bool.false_eq_true, ite_false]
    exact ⟨st.finish, o.finish (fun _ => by simpa using hb), rfl, rfl⟩

/-! ## sift_down -/

theorem pick_not_after (h : Heap) (b c : Nat) :
    ¬ Before (h.entries b) (h.entries (pick h b c)) := by
  unfold pick
  split
  · rename_i hc
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hc
    exact before_asymm hc.2
  · exact before_irrefl _

theorem pick_candidate (h : Heap) (b c : Nat) (hc : c < h.count) :
    ¬ Before (h.entries c) (h.entries (pick h b c)) := by
  unfold pick
  split
  · exact before_irrefl _
  · rename_i hn
    simpa [hc] using hn

/-- The earliest child is at or before every child of `p` in the heap. -/
theorem earliestChild_min (h : Heap) (p : Nat) (c : Nat) (hc : IsChild c p) (hcl : c < h.count) :
    ¬ Before (h.entries c) (h.entries (earliestChild h p)) := by
  have hr := child_range hc
  unfold earliestChild
  generalize hf : firstChild p = f at hr
  have k0 := pick_not_after h f (f + 1)
  have k1 := pick_not_after h (pick h f (f + 1)) (f + 2)
  have k2 := pick_not_after h (pick h (pick h f (f + 1)) (f + 2)) (f + 3)
  have c1 := pick_candidate h f (f + 1)
  have c2 := pick_candidate h (pick h f (f + 1)) (f + 2)
  have c3 := pick_candidate h (pick h (pick h f (f + 1)) (f + 2)) (f + 3)
  have : c = f ∨ c = f + 1 ∨ c = f + 2 ∨ c = f + 3 := by omega
  rcases this with rfl | rfl | rfl | rfl
  · exact not_before_trans (not_before_trans k0 k1) k2
  · exact not_before_trans (not_before_trans (c1 hcl) k1) k2
  · exact not_before_trans (c2 hcl) k2
  · exact c3 hcl

theorem earliestChild_isChild (h : Heap) (p : Nat) (hf : firstChild p < h.count) :
    IsChild (earliestChild h p) p := by
  have := earliestChild_bounds h p hf
  unfold IsChild parent firstChild arity at *
  omega

theorem DownOrder.move {h : Heap} {hole : Nat} {e : Entry} (o : DownOrder h hole e)
    (hf : firstChild hole < h.count) (hb : Before (h.entries (earliestChild h hole)) e) :
    DownOrder (place h hole (h.entries (earliestChild h hole))) (earliestChild h hole) e := by
  have hc := earliestChild_isChild h hole hf
  have hcl := (earliestChild_bounds h hole hf).2.1
  have hgt := child_gt hc
  generalize hcdef : earliestChild h hole = c at hc hcl hgt hb
  have hmin : ∀ s, IsChild s hole → s < h.count → ¬ Before (h.entries s) (h.entries c) := by
    intro s hs hsl; rw [← hcdef]; exact earliestChild_min h hole s hs hsl
  constructor
  · intro i hi0 hi hic hpi
    simp only [place_count] at hi
    by_cases hih : i = hole
    · subst hih
      have hp : parent i ≠ i := by have := parent_lt (show i ≠ 0 by omega); omega
      rw [place_entries_same, place_entries_other _ _ hp]
      exact o.grand (by omega) c hc hcl
    · rw [place_entries_other _ _ hih]
      by_cases hph : parent i = hole
      · rw [hph, place_entries_same]; exact hmin i ⟨hi0, hph⟩ hi
      · rw [place_entries_other _ _ hph]; exact o.except i hi0 hi hih hph
  · intro _
    rw [hc.2, place_entries_same]; exact before_asymm hb
  · intro _ d hd hdl
    simp only [place_count] at hdl
    have hdgt := child_gt hd
    rw [hc.2, place_entries_same, place_entries_other _ _ (show d ≠ hole by omega)]
    have := o.except d hd.1 hdl (by omega) (by rw [hd.2]; omega)
    rwa [hd.2] at this

theorem DownOrder.finish {h : Heap} {hole : Nat} {e : Entry} (o : DownOrder h hole e)
    (hstop : ∀ c, IsChild c hole → c < h.count → ¬ Before (h.entries c) e) :
    Ordered (place h hole e) := by
  intro i hi0 hi
  simp only [place_count] at hi
  by_cases hih : i = hole
  · subst hih
    have hp : parent i ≠ i := by have := parent_lt (show i ≠ 0 by omega); omega
    rw [place_entries_same, place_entries_other _ _ hp]
    exact o.above (by omega)
  · rw [place_entries_other _ _ hih]
    by_cases hph : parent i = hole
    · rw [hph, place_entries_same]; exact hstop i ⟨hi0, hph⟩ hi
    · rw [place_entries_other _ _ hph]; exact o.except i hi0 hi hih hph

/-- `siftDown` from a heap with a hole ends in a heap that holds the model and is ordered. -/
theorem siftDown_valid (h : Heap) (hole : Nat) (e : Entry) (m : Nat → Option Entry)
    (st : Sifting h hole e m) (o : DownOrder h hole e) :
    Holds (siftDown h hole e) m ∧ Ordered (siftDown h hole e) ∧
      (siftDown h hole e).count = h.count ∧ (siftDown h hole e).sequence = h.sequence := by
  induction h, hole using siftDown.induct (e := e) with
  | case1 h hole hf hb ih =>
    rw [siftDown]; simp only [hf, dite_true, hb, ite_true]
    have hc := earliestChild_isChild h hole hf
    have hcl := (earliestChild_bounds h hole hf).2.1
    have hne : earliestChild h hole ≠ hole := by have := child_gt hc; omega
    have := ih (st.move hcl hne) (o.move hf hb)
    exact ⟨this.1, this.2.1, by rw [this.2.2.1]; rfl, by rw [this.2.2.2]; rfl⟩
  | case2 h hole hf hb =>
    rw [siftDown]; simp only [hf, dite_true, hb, Bool.false_eq_true, ite_false]
    refine ⟨st.finish, o.finish ?_, rfl, rfl⟩
    intro c hc hcl
    have hmin := earliestChild_min h hole c hc hcl
    exact not_before_trans hmin (by simpa using hb)
  | case3 h hole hf =>
    rw [siftDown]; simp only [hf, dite_false]
    refine ⟨st.finish, o.finish ?_, rfl, rfl⟩
    intro c hc hcl
    have := (child_range hc).1
    omega

end Rotor.Heap
