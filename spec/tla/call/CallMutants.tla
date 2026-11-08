----------------------------- MODULE CallMutants -----------------------------
\* The cross-core call of decision 32, broken on purpose, one step each. A configuration in
\* mutants/ puts one in place of the operator it breaks, with TLC's `Operator <- Mutant`, and TLC
\* must find the invariant that it breaks. A mutant that TLC passed would show the invariant
\* holding for another reason (decision 32, "How it would be checked", "Model").
EXTENDS Call

\* M1: a post sees every slot of the ring, so the posts of T can leave no slot for the return.
PostTCIgnoresReserve ==
    /\ Len(tc) < Cap
    /\ tc' = Append(tc, "post")
    /\ UNCHANGED <<ct, rec, callsOut, task, station, sends, finishes, failed, stray>>

\* M2: the record's task on C runs `finish` and does not lower `calls_out`.
RunCKeepsCount ==
    /\ task = "C"
    /\ task' = "none"
    /\ rec' = "idle"
    /\ finishes' = finishes + 1
    /\ UNCHANGED <<ct, tc, callsOut, station, sends, failed, stray>>

\* M3: the record's task on C runs `finish` first, and sets `idle` in a later step. So `finish`
\* runs while the record is not idle, and cannot send it again.
RunCIdleAfter ==
    \/ /\ task = "C"
       /\ task' = "none"
       /\ finishes' = finishes + 1
       /\ UNCHANGED <<ct, tc, rec, callsOut, station, sends, failed, stray>>
    \/ /\ rec = "back"
       /\ task = "none"
       /\ rec' = "idle"
       /\ callsOut' = callsOut - 1
       /\ UNCHANGED <<ct, tc, task, station, sends, finishes, failed, stray>>

\* M4: the record's task on T runs the handler whatever the station's state.
RunTIgnoresStop ==
    /\ task = "T"
    /\ task' = "none"
    /\ Answer
    /\ stray' = (station = "stopped")
    /\ UNCHANGED <<ct, callsOut, station, sends, finishes>>

\* M6: T's drain runs the handler of a call to a station that stopped, and then answers.
DrainTRunsHandlerWhenStopped ==
    /\ ct # <<>>
    /\ ct' = Tail(ct)
    /\ IF Head(ct) = "call"
       THEN IF station = "serving"
            THEN /\ rec' = "held"
                 /\ task' = "T"
                 /\ UNCHANGED <<tc, failed, stray>>
            ELSE /\ Answer
                 /\ stray' = TRUE
                 /\ UNCHANGED task
       ELSE UNCHANGED <<rec, task, tc, failed, stray>>
    /\ UNCHANGED <<callsOut, station, sends, finishes>>

\* M5: T schedules the record's task again after its return push, while C owns the record.
AnswerLaterSchedulesAgain ==
    /\ rec = "held"
    /\ task = "none"
    /\ Answer
    /\ task' = "T"
    /\ UNCHANGED <<ct, callsOut, station, sends, finishes, stray>>
=============================================================================
