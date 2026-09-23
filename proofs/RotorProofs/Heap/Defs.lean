/-!
# The timer heap: the model

A model of `TimerHeap` in `src/core/timer_heap.zig`, written to be read beside it. Each definition
names the Zig function it mirrors and computes what that function computes, with three changes:

- An array is a function from positions to entries. A position at or past `count` holds whatever
  it held last, as the Zig array does.
- The capacity is left out. The Zig `arm` asserts that the heap has room, and a model with room
  everywhere proves the same things about every heap that has it.
- `sequence` is a natural number that never wraps. The Zig heap keeps it modulo 2^32 and compares
  two of them by their wrapping difference; `Order.lean` proves the two comparisons agree while
  the live entries span fewer than 2^31 arms, the condition the Zig comment on `before` states.

A slot's `heap_position` is `position`, and `heap_position_none` is `none`.
-/

namespace Rotor.Heap

/-- `constants.timer_heap_arity`. -/
def arity : Nat := 4

/-- `parent_of`. Meaningful for a position above 0. -/
def parent (p : Nat) : Nat := (p - 1) / arity

/-- `first_child_of`. The children of `p` are this position and the `arity - 1` after it. -/
def firstChild (p : Nat) : Nat := p * arity + 1

/-- `TimerHeap.Entry`. -/
structure Entry where
  deadline : Nat
  sequence : Nat
  slot : Nat
  deriving DecidableEq, Repr

/-- `before`: the earlier deadline, and among equal deadlines the earlier arm. -/
def before (a b : Entry) : Bool :=
  if a.deadline ≠ b.deadline then a.deadline < b.deadline else a.sequence < b.sequence

/-- `TimerHeap`: `entries[0..count]` is the heap, `position` is every slot's `heap_position`, and
`sequence` is what the next `arm` stamps. -/
structure Heap where
  entries : Nat → Entry
  count : Nat
  position : Nat → Option Nat
  sequence : Nat

/-- A function with one value replaced: what a write to one array element does. -/
def update {α : Type} (f : Nat → α) (i : Nat) (v : α) : Nat → α :=
  fun j => if j = i then v else f j

/-- `place`: writes `e` at `p` and points its slot there. No entry moves any other way. -/
def place (h : Heap) (p : Nat) (e : Entry) : Heap :=
  { h with entries := update h.entries p e, position := update h.position e.slot (some p) }

theorem parent_lt {p : Nat} (hp : p ≠ 0) : parent p < p := by
  unfold parent arity; omega

/-- `sift_up`: places `e` at `p` or above it; every parent that orders after it moves down a level. -/
def siftUp (h : Heap) (p : Nat) (e : Entry) : Heap :=
  if _hp : p = 0 then place h p e
  else if before e (h.entries (parent p)) then
    siftUp (place h p (h.entries (parent p))) (parent p) e
  else place h p e
termination_by p
decreasing_by exact parent_lt _hp

/-- One step of `earliest_child_of`'s scan: `c` replaces `best` when it is in the heap and orders
first. The Zig loop stops at the first child past `count`; the children are consecutive, so every
later one is past it too, and skipping each is the same. -/
def pick (h : Heap) (best c : Nat) : Nat :=
  if c < h.count && before (h.entries c) (h.entries best) then c else best

/-- `earliest_child_of`: the position of the child of `p` that orders first. -/
def earliestChild (h : Heap) (p : Nat) : Nat :=
  pick h (pick h (pick h (firstChild p) (firstChild p + 1)) (firstChild p + 2)) (firstChild p + 3)

theorem earliestChild_bounds (h : Heap) (p : Nat) (hf : firstChild p < h.count) :
    firstChild p ≤ earliestChild h p ∧ earliestChild h p < h.count ∧
      earliestChild h p ≤ firstChild p + 3 := by
  unfold earliestChild pick
  split <;> split <;> split <;> simp_all <;> omega

theorem place_count (h : Heap) (p : Nat) (e : Entry) : (place h p e).count = h.count := rfl

/-- `sift_down`: places `e` at `p` or below it; at each level the earliest child moves up a level
when it orders before `e`. -/
def siftDown (h : Heap) (p : Nat) (e : Entry) : Heap :=
  if _hf : firstChild p < h.count then
    if before (h.entries (earliestChild h p)) e then
      siftDown (place h p (h.entries (earliestChild h p))) (earliestChild h p) e
    else place h p e
  else place h p e
termination_by h.count - p
decreasing_by
  have := earliestChild_bounds h p _hf
  rw [place_count]
  unfold firstChild arity at this
  omega

/-- The first two lines of `remove`: the removed entry's slot is no longer armed, and the heap
is one entry shorter. -/
def cut (h : Heap) (p : Nat) : Heap :=
  { h with position := update h.position (h.entries p).slot none, count := h.count - 1 }

/-- `remove`: takes the entry at `p` out and puts the last entry in its place. The last entry came
from anywhere in the heap, so it may order before its new parent, and then it moves up. -/
def remove (h : Heap) (p : Nat) : Heap :=
  if p = (cut h p).count then cut h p
  else if p != 0 && before ((cut h p).entries (cut h p).count) ((cut h p).entries (parent p)) then
    siftUp (cut h p) p ((cut h p).entries (cut h p).count)
  else siftDown (cut h p) p ((cut h p).entries (cut h p).count)

/-- `arm`: stamps the entry with `sequence`, counts it in, and sifts it up from the end. -/
def arm (h : Heap) (slot deadline : Nat) : Heap :=
  let e : Entry := { deadline := deadline, sequence := h.sequence, slot := slot }
  siftUp { h with sequence := h.sequence + 1, count := h.count + 1 } h.count e

/-- `disarm`: removes the slot's entry through its position. The Zig code asserts the slot is
armed; an unarmed slot leaves the model's heap alone. -/
def disarm (h : Heap) (slot : Nat) : Heap :=
  match h.position slot with
  | some p => remove h p
  | none => h

/-- `earliest_ns`. -/
def earliest (h : Heap) : Option Nat :=
  if h.count = 0 then none else some (h.entries 0).deadline

/-- `pop_due`: when the root is due, removes it and answers its slot. -/
def popDue (h : Heap) (now : Nat) : Option Nat × Heap :=
  if h.count = 0 then (none, h)
  else if now < (h.entries 0).deadline then (none, h)
  else (some (h.entries 0).slot, remove h 0)

end Rotor.Heap
