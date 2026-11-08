/-!
# DRR: the deficit bounds and the window bound of decision 30

A model of what `src/core/scheduling/scheduling_run.zig` does to the deficit of one group, written
to be read beside it. Each definition names the Zig function it mirrors.

- `credit` is `scheduling_unit_credit`, and `least C` is `deficit_min` for a `task_charge_max`
  of `C`.
- `startAll` is the loop of `start`: each start subtracts the credit of the task's units. `Starts`
  is the condition of that loop, a deficit above 0 before each start.
- `close` is `close`: unused credit is dropped and debt is kept.
- `visit` is one visit of `visit`: the credit of the group's shares, the starts, then the close.
- `bulk` is `bulk_credit`: the credit of the passes that start no task, in one step.

What it leaves out, and why the omission changes nothing proved here:

- The tick's bound of `tasks_per_tick_max` starts. A visit that the bound cuts stays open and
  resumes in the next run with no second credit, so its starts are one list here.
- The other groups. A group's deficit changes only in its own visits and in the bulk credit.
- `charge_task`. A charge subtracts more credit during a task's run. Here a task's units are its
  cost and its charges together, and the class A check of `charge` holds them to `C`.
- `set_scheduling_group_shares`. The window bound holds for a run of visits at one value of the
  shares.
-/

namespace Rotor.Drr

/-- `scheduling_unit_credit`: a share is a hundredth of a unit. -/
def credit : Int := 100

/-- `deficit_min`: `1 - task_charge_max * scheduling_unit_credit`. -/
def least (chargeMax : Int) : Int := 1 - chargeMax * credit

/-- The units of a list of starts. -/
def total : List Int → Int
  | [] => 0
  | u :: us => u + total us

/-- The loop of `start`: each start subtracts the credit of its units. -/
def startAll : Int → List Int → Int
  | d, [] => d
  | d, u :: us => startAll (d - credit * u) us

/-- The condition of that loop: `start` begins a task only while the deficit is above 0. -/
def Starts : Int → List Int → Prop
  | _, [] => True
  | d, u :: us => 0 < d ∧ Starts (d - credit * u) us

/-- Every task of the list costs 1 to `chargeMax` units, as `init_cost` and `charge` hold it. -/
def Costs (chargeMax : Int) : List Int → Prop
  | [] => True
  | u :: us => 1 ≤ u ∧ u ≤ chargeMax ∧ Costs chargeMax us

/-- `close`: `deficit = @min(deficit, 0)`. -/
def close (d : Int) : Int := min d 0

/-- One visit: the shares' credit, the starts, and the close. -/
def visit (shares d : Int) (us : List Int) : Int := close (startAll (d + shares) us)

theorem startAll_eq (d : Int) (us : List Int) : startAll d us = d - credit * total us := by
  induction us generalizing d with
  | nil => simp [startAll, total]
  | cons u us ih =>
    simp only [startAll, total, ih, credit]
    omega

theorem startAll_le (chargeMax d : Int) (us : List Int) (h : Costs chargeMax us) :
    startAll d us ≤ d := by
  induction us generalizing d with
  | nil => simp [startAll]
  | cons u us ih =>
    simp only [Costs] at h
    have := ih (d - credit * u) h.2.2
    simp only [startAll, credit] at *
    omega

/-- A start leaves the deficit at or above `least`: it began above 0 and took at most `chargeMax`
units. -/
theorem least_le_startAll (chargeMax d : Int) (us : List Int) (hs : Starts d us)
    (hc : Costs chargeMax us) (hd : least chargeMax ≤ d) : least chargeMax ≤ startAll d us := by
  induction us generalizing d with
  | nil => simpa [startAll] using hd
  | cons u us ih =>
    simp only [Starts] at hs
    simp only [Costs] at hc
    apply ih (d - credit * u) hs.2 hc.2.2
    simp only [least, credit] at *
    omega

/-- G2, between visits: a closed deficit stays in `[least, 0]`. -/
theorem visit_bounds (chargeMax shares d : Int) (us : List Int) (hm : 1 ≤ chargeMax)
    (hshares : 1 ≤ shares) (hlo : least chargeMax ≤ d)
    (hs : Starts (d + shares) us) (hc : Costs chargeMax us) :
    least chargeMax ≤ visit shares d us ∧ visit shares d us ≤ 0 := by
  have hstart := least_le_startAll chargeMax (d + shares) us hs hc (by omega)
  have hneg : least chargeMax ≤ 0 := by simp only [least, credit]; omega
  simp only [visit, close]
  omega

/-- G2, inside a visit: the deficit is at most the shares, so at most `scheduling_shares_max`. -/
theorem visit_open_le (chargeMax shares d : Int) (us : List Int) (_hhi : d ≤ 0)
    (hc : Costs chargeMax us) : startAll (d + shares) us ≤ shares := by
  have := startAll_le chargeMax (d + shares) us hc
  omega

/-- `bulk_credit`: `r` is the least count of visits that takes the deficit above 0, and the group
takes `r - 1` visits of credit. -/
def rounds (shares d : Int) : Int := (shares - d) / shares

def bulk (shares d : Int) : Int := d + (rounds shares d - 1) * shares

/-- The bulk credit leaves a debt: the next visit's credit, and not this one, starts a task. -/
theorem bulk_le_zero (shares d : Int) (hshares : 1 ≤ shares) : bulk shares d ≤ 0 := by
  have hmul : rounds shares d * shares ≤ shares - d :=
    Int.ediv_mul_le (shares - d) (by omega)
  simp only [bulk]
  have : (rounds shares d - 1) * shares = rounds shares d * shares - shares := by
    rw [Int.sub_mul, Int.one_mul]
  omega

/-- The bulk credit never takes credit away: `r` is at least 1. -/
theorem le_bulk (shares d : Int) (hshares : 1 ≤ shares) (hd : d ≤ 0) : d ≤ bulk shares d := by
  have hr : 1 ≤ rounds shares d := by
    simp only [rounds]
    apply Int.le_ediv_of_mul_le (by omega)
    omega
  simp only [bulk]
  have : 0 ≤ (rounds shares d - 1) * shares := Int.mul_nonneg (by omega) (by omega)
  omega

/-- After the bulk credit the next visit's credit takes the deficit above 0, so that visit starts
a task: the class A check in `visit` that follows a bulk credit. -/
theorem bulk_then_start (shares d : Int) (hshares : 1 ≤ shares) :
    0 < bulk shares d + shares := by
  have hmod := Int.emod_add_ediv_mul (shares - d) shares
  have hlt : (shares - d) % shares < shares := Int.emod_lt_of_pos (shares - d) (by omega)
  simp only [bulk, rounds]
  have : ((shares - d) / shares - 1) * shares = (shares - d) / shares * shares - shares := by
    rw [Int.sub_mul, Int.one_mul]
  omega

/-- Visits of one group that stays startable: each visit ends with its deficit at or below 0, so
the close keeps all of it. -/
def runAll (shares : Int) : Int → List (List Int) → Int
  | d, [] => d
  | d, us :: rest => runAll shares (startAll (d + shares) us) rest

/-- The units the visits of `runAll` start. -/
def served : List (List Int) → Int
  | [] => 0
  | us :: rest => total us + served rest

/-- The units of the visits telescope: the credit given less the credit served is the change of
the deficit. -/
theorem runAll_eq (shares d : Int) (visits : List (List Int)) :
    runAll shares d visits = d + visits.length * shares - credit * served visits := by
  induction visits generalizing d with
  | nil => simp [runAll, served]
  | cons us rest ih =>
    simp only [runAll, served, ih, startAll_eq, List.length_cons]
    simp only [credit]
    rw [Int.natCast_add, Int.add_mul]
    omega

/-- G3, the window bound: over `n` visits of a group that stays startable, its units served times
100 differ from `n` times its shares by less than `chargeMax` units of credit, whatever the
deficit was at the start and the end, as long as both lie in `[least, 0]`. -/
theorem window (chargeMax shares d : Int) (visits : List (List Int))
    (hstart : least chargeMax ≤ d ∧ d ≤ 0)
    (hend : least chargeMax ≤ runAll shares d visits ∧ runAll shares d visits ≤ 0) :
    credit * served visits - visits.length * shares < credit * chargeMax ∧
      visits.length * shares - credit * served visits < credit * chargeMax := by
  have heq := runAll_eq shares d visits
  simp only [least, credit] at *
  omega

end Rotor.Drr
