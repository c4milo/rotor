--------------------------- MODULE HeartbeatMutants --------------------------
\* The heartbeat's memory orders, and its second load of the stamp, dropped on purpose, one each.
\* A configuration in mutants/ puts one in place of the operator it breaks, with TLC's
\* `Operator <- Mutant`, and TLC must find a check that names a callback of another turn. A mutant
\* that TLC passed would show `NameOfTurn` holding for another reason. No test on a real core makes
\* this reorder on demand, so these mutants are how the orders are proved (decision 28, "How it
\* would be checked").
EXTENDS Heartbeat

\* M1: the loop stores a callback's name with relaxed order. The store carries nothing, so the
\* watch that reads a name of a later turn may still read the old stamp in load 3.
NameStoreRelaxed(b, r) == LoopViewOf(0, 0)

\* M2: the watch loads `running` with relaxed order. It takes nothing from the store it reads, so
\* load 3 may read the old stamp although the name is of a later turn: the reorder of load 3 before
\* load 2 that arm64 may make.
AfterNameLoadRelaxed(view, j) == [view EXCEPT !["run"] = Max(view["run"], j)]

\* M3: the watch makes no load 3, and takes load 1 for it. A turn that ends between load 1 and
\* load 2 then gives the next turn's name for the old stamp, whatever the orders.
LoadSecondSkipped ==
    /\ wpc = "load3"
    /\ second' = first
    /\ wpc' = "done"
    /\ UNCHANGED <<beat, run, lpc, turn, called, first, name, known>>
=============================================================================
