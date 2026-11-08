-------------------------------- MODULE Call --------------------------------
\* The cross-core call of decision 32, on two loops: C calls and T serves. The code is
\* src/core/call/: `call` and `end_call` on C, `take_call`, `answer` and `take_return` in the
\* drains, and the record's task, which runs the handler on T and `finish` on C.
\*
\* C reuses one record. The two rings, C to T and T to C, each hold `Cap` messages. A post sees
\* `Cap - CallsMax` of them, and a return sees all of them. Each loop posts to the other at any
\* time. T's handler answers at once or later, and T may stop serving. Each step is one loop's,
\* and the order of the steps is any order, as the threads of two loops interleave.
\*
\* The invariants: one result for each send; the record's task waits only on the loop that owns
\* the record; a return push never fails; `calls_out` counts the record from `send` until its
\* `finish`; and a station that stopped runs no handler, in the drain or in the record's task.
\* CallMutants.tla breaks one step each, and TLC must find the violation.
EXTENDS Naturals, Sequences

CONSTANTS
    Cap,        \* the messages one ring holds: `mailbox_messages`
    CallsMax,   \* `calls_per_pair_max`
    SendsMax    \* the sends the model makes, which bounds its state

ASSUME Cap \in Nat /\ CallsMax \in Nat \ {0} /\ CallsMax < Cap /\ SendsMax \in Nat \ {0}

\* What a post sees of a ring: `mailbox_posts_max`.
PostsMax == Cap - CallsMax

States == {"idle", "out", "held", "answered", "back"}

VARIABLES
    ct,         \* the ring from C to T: "post" or "call"
    tc,         \* the ring from T to C: "post" or "return"
    rec,        \* the record's state
    callsOut,   \* the count of ring C to T, which only C writes
    task,       \* where the record's task is queued: "none", "C" or "T"
    station,    \* T's station: "serving" or "stopped"
    sends,      \* the sends that returned success
    finishes,   \* the runs of `finish`
    failed,     \* TRUE once a return push found the ring full
    stray       \* TRUE once a stopped station ran the handler

vars == <<ct, tc, rec, callsOut, task, station, sends, finishes, failed, stray>>

Init ==
    /\ ct = <<>>
    /\ tc = <<>>
    /\ rec = "idle"
    /\ callsOut = 0
    /\ task = "none"
    /\ station = "serving"
    /\ sends = 0
    /\ finishes = 0
    /\ failed = FALSE
    /\ stray = FALSE

\* C sends: the record is idle, the pair has room, and the post's share of the ring has a slot.
Send ==
    /\ rec = "idle"
    /\ sends < SendsMax
    /\ callsOut < CallsMax
    /\ Len(ct) < PostsMax
    /\ ct' = Append(ct, "call")
    /\ rec' = "out"
    /\ callsOut' = callsOut + 1
    /\ sends' = sends + 1
    /\ UNCHANGED <<tc, task, station, finishes, failed, stray>>

\* A post from C to T, or from T to C, in the post's share of the ring.
PostCT ==
    /\ Len(ct) < PostsMax
    /\ ct' = Append(ct, "post")
    /\ UNCHANGED <<tc, rec, callsOut, task, station, sends, finishes, failed, stray>>

PostTC ==
    /\ Len(tc) < PostsMax
    /\ tc' = Append(tc, "post")
    /\ UNCHANGED <<ct, rec, callsOut, task, station, sends, finishes, failed, stray>>

\* T's answer: the record is answered, and the return goes through `push`, which sees every slot.
\* The push is T's last write of the record.
Answer ==
    /\ rec' = "answered"
    /\ IF Len(tc) < Cap
       THEN /\ tc' = Append(tc, "return")
            /\ UNCHANGED failed
       ELSE /\ failed' = TRUE
            /\ UNCHANGED tc

\* T's drain pops the head of ring C to T. A call to a station that serves becomes held, and its
\* task waits on T. A call to a station that stopped is answered in the drain, and no task waits:
\* the station may still name a loop of T's id that ended (decision 32, finish of 2026-11-08).
DrainT ==
    /\ ct # <<>>
    /\ ct' = Tail(ct)
    /\ IF Head(ct) = "call"
       THEN IF station = "serving"
            THEN /\ rec' = "held"
                 /\ task' = "T"
                 /\ UNCHANGED <<tc, failed>>
            ELSE /\ Answer
                 /\ UNCHANGED task
       ELSE UNCHANGED <<rec, task, tc, failed>>
    /\ UNCHANGED <<callsOut, station, sends, finishes, stray>>

\* The record's task on T: a stopped station answers with no handler run. A station that serves
\* runs the handler, which answers now or keeps the call held.
RunT ==
    /\ task = "T"
    /\ task' = "none"
    /\ \/ /\ station = "stopped"
          /\ Answer
          /\ UNCHANGED stray
       \/ /\ station = "serving"
          /\ Answer
          /\ UNCHANGED stray
       \/ /\ station = "serving"
          /\ UNCHANGED <<rec, tc, failed, stray>>
    /\ UNCHANGED <<ct, callsOut, station, sends, finishes>>

\* The handler answered `.later`, and T answers now.
AnswerLater ==
    /\ rec = "held"
    /\ task = "none"
    /\ Answer
    /\ UNCHANGED <<ct, callsOut, task, station, sends, finishes, stray>>

StopServing ==
    /\ station = "serving"
    /\ station' = "stopped"
    /\ UNCHANGED <<ct, tc, rec, callsOut, task, sends, finishes, failed, stray>>

\* C's drain pops the head of ring T to C. A return gives the record back, and its task waits on C.
DrainC ==
    /\ tc # <<>>
    /\ tc' = Tail(tc)
    /\ IF Head(tc) = "return"
       THEN /\ rec' = "back"
            /\ task' = "C"
       ELSE UNCHANGED <<rec, task>>
    /\ UNCHANGED <<ct, callsOut, station, sends, finishes, failed, stray>>

\* The record's task on C: `idle`, the count falls, and then `finish` runs.
RunC ==
    /\ task = "C"
    /\ task' = "none"
    /\ rec' = "idle"
    /\ callsOut' = callsOut - 1
    /\ finishes' = finishes + 1
    /\ UNCHANGED <<ct, tc, station, sends, failed, stray>>

Next ==
    \/ Send \/ PostCT \/ PostTC \/ DrainT \/ RunT \/ AnswerLater \/ StopServing \/ DrainC \/ RunC

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ rec \in States
    /\ callsOut \in 0 .. CallsMax
    /\ task \in {"none", "C", "T"}
    /\ station \in {"serving", "stopped"}
    /\ Len(ct) <= Cap /\ Len(tc) <= Cap

\* One result for each send: a record that is idle has had a `finish` for each send.
OneResult == finishes = IF rec = "idle" THEN sends ELSE sends - 1

\* The task waits only on the loop that owns the record, and on no loop while the record is out
\* or answered.
TaskOnOwner ==
    /\ task = "T" => rec = "held"
    /\ task = "C" => rec = "back"

\* A return push never meets a full ring.
ReturnNeverFails == ~failed

\* `calls_out` counts the record from `send` until its `finish`.
CallsOutCounts == callsOut = IF rec = "idle" THEN 0 ELSE 1

\* A station that stopped runs no handler.
NoHandlerWhenStopped == ~stray
=============================================================================
