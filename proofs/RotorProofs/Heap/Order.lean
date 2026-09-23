import RotorProofs.Heap.Defs

/-!
# The order entries come out in

`before` is a strict order on the pair (deadline, sequence): the heap's proofs use its
irreflexivity, its transitivity, and that "not before" is transitive too, which is what lets
"not before" stand for "at or after".

The last theorem is about the Zig comparison. The Zig heap keeps `sequence` modulo 2^32, and
compares two of them by their wrapping difference read as a signed 32-bit number. That agrees
with comparing the unbounded arm numbers this model keeps whenever the two differ by less than
2^31, which is the span the Zig comment on `before` requires of the live entries.
-/

namespace Rotor.Heap

/-- The order as a proposition: `a` comes out before `b`. -/
abbrev Before (a b : Entry) : Prop := before a b = true

theorem before_iff (a b : Entry) :
    Before a b ↔ a.deadline < b.deadline ∨ (a.deadline = b.deadline ∧ a.sequence < b.sequence) := by
  unfold Before before
  by_cases h : a.deadline = b.deadline <;> simp [h] <;> omega

theorem before_irrefl (a : Entry) : ¬ Before a a := by
  rw [before_iff]; omega

theorem before_asymm {a b : Entry} (h : Before a b) : ¬ Before b a := by
  rw [before_iff] at *; omega

theorem before_trans {a b c : Entry} (h₁ : Before a b) (h₂ : Before b c) : Before a c := by
  rw [before_iff] at *; omega

/-- "Not before" is transitive: `a` at or after `b`, and `b` at or after `c`, puts `a` at or
after `c`. -/
theorem not_before_trans {a b c : Entry} (h₁ : ¬ Before a b) (h₂ : ¬ Before b c) :
    ¬ Before a c := by
  rw [before_iff] at *; omega

/-- `a` before `b`, and `c` at or after `b`, puts `a` before `c`. -/
theorem before_of_before_not_before {a b c : Entry} (h₁ : Before a b) (h₂ : ¬ Before c b) :
    Before a c := by
  rw [before_iff] at *; omega

/-- `c` at or after `b`, and `b` after `a`... put the other way: `a` before `b`, and `b` at or
before `c`, puts `a` before `c`. -/
theorem before_of_not_before_before {a b c : Entry} (h₁ : ¬ Before b a) (h₂ : Before b c) :
    Before a c := by
  rw [before_iff] at *; omega

/-- Two entries with different sequences are ordered one way or the other. -/
theorem before_total {a b : Entry} (h : a.sequence ≠ b.sequence) : Before a b ∨ Before b a := by
  rw [before_iff, before_iff]; omega

/-! ## The Zig comparison of wrapping sequences -/

/-- 2^32, the modulus of a Zig `u32`. -/
def wrap : Nat := 4294967296

/-- 2^31: a wrapping difference at or above it is negative as an `i32`. -/
def half : Nat := 2147483648

/-- The Zig `before`'s tie-break: `@as(i32, @bitCast(a -% b)) < 0` for two `u32` sequences. -/
def wrappingBefore (a b : Nat) : Bool :=
  (a % wrap + wrap - b % wrap) % wrap ≥ half

/-- The wrapping comparison of two arm numbers, each kept modulo 2^32, is the comparison of the
numbers themselves while they differ by less than 2^31. -/
theorem wrappingBefore_eq (a b : Nat) (near : a < b + half ∧ b < a + half) :
    wrappingBefore a b = decide (a < b) := by
  unfold wrappingBefore wrap half at *
  by_cases h : a < b <;> simp [h] <;> omega

/-- The Zig `before`, with sequences kept modulo 2^32. -/
def zigBefore (a b : Entry) : Bool :=
  if a.deadline ≠ b.deadline then a.deadline < b.deadline
  else wrappingBefore a.sequence b.sequence

/-- The Zig `before` is the model's `before` for any two entries whose arms are less than 2^31
apart. -/
theorem zigBefore_eq (a b : Entry) (near : a.sequence < b.sequence + half ∧ b.sequence < a.sequence + half) :
    zigBefore a b = before a b := by
  unfold zigBefore before
  rw [wrappingBefore_eq _ _ near]

end Rotor.Heap
