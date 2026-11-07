------------------------------ MODULE Heartbeat ------------------------------
\* The heartbeat of decision 28: a loop's thread writes the stamp that started its open turn and
\* the name of the callback that runs now, and a watch on another thread reads them. The code is
\* core/stall.zig: `Heartbeat.note_clock`, `note_asleep`, `note_woken`, `enter` and `leave` on the
\* loop's side, and `Watch.check` on the watch's side.
\*
\* The loop stores `beat_ns` with release order at each stamp and before a wait, and stores a
\* callback's name in `running` with release order before the callback, and null after the
\* callbacks. `check` loads `beat_ns` with acquire order (load 1), `running` with acquire order
\* (load 2), and `beat_ns` again (load 3). When loads 1 and 3 are equal and not `asleep`, `check`
\* reports the name of load 2 as the callback of that turn. `NameOfTurn` says the report is right.
\*
\* The model is not sequentially consistent. It keeps every store of each location in the order
\* the loop made them, and lets a load read any store at or after the one its thread already knows.
\* A thread knows a store when it read it, or read a store whose release carried it: a release
\* store carries every store its thread made before it, and an acquire load takes what the store it
\* reads carries. This is the view model of release and acquire. So the model allows every order of
\* the loads that the memory orders allow, and the reorder of load 3 before load 2 that arm64 may
\* make without them. HeartbeatMutants.tla drops each order, and TLC must find a wrong report.
EXTENDS Naturals, Sequences

CONSTANTS
    Turns,      \* the turns the loop runs; a turn's stamp is its number
    Callbacks   \* the callbacks the loop calls in each turn

ASSUME Turns \in Nat \ {0} /\ Callbacks \in Nat \ {0}

\* `beat_ns` while the loop is in a kernel wait. Stamps are 1 .. Turns.
Asleep == 0
\* `running` while no callback runs. A name is <<turn, callback>>.
Null == <<0, 0>>

Locations == {"beat", "run"}
Views == [Locations -> Nat]

VARIABLES
    beat,   \* every store of `beat_ns`, in order: [value, view the store carries]
    run,    \* every store of `running`, in order
    lpc,    \* the loop's next step
    turn,   \* the loop's open turn
    called, \* the callbacks of the open turn the loop has called
    wpc,    \* the watch's next step
    known,  \* the watch's view: for each location, the first store it may still read
    first,  \* load 1
    name,   \* load 2
    second  \* load 3

vars == <<beat, run, lpc, turn, called, wpc, known, first, name, second>>

Max(a, b) == IF a > b THEN a ELSE b

\* The loop is the only writer, so it knows every store: the last one of `beat` it made is `b`, and
\* of `run` is `r`. A release store carries that knowledge.
LoopViewOf(b, r) == [l \in Locations |-> IF l = "beat" THEN b ELSE r]

\* What the store of a name carries: with release order, the loop's view. Replaced in mutants.
NameStoreView(b, r) == LoopViewOf(b, r)

\* What the watch knows after load 2 reads store `j` of `running`: with acquire order, also what
\* that store carries. Replaced in mutants.
AfterNameLoad(view, j) ==
    [l \in Locations |-> IF l = "run" THEN Max(view[l], j)
                                      ELSE Max(view[l], run[j].view[l])]

Store(history, value, view) == Append(history, [value |-> value, view |-> view])

Init ==
    /\ beat = <<[value |-> Asleep, view |-> LoopViewOf(1, 1)]>>
    /\ run = <<[value |-> Null, view |-> LoopViewOf(1, 1)]>>
    /\ lpc = "stamp"
    /\ turn = 1
    /\ called = 0
    /\ wpc = "load1"
    /\ known = LoopViewOf(1, 1)
    /\ first = Asleep
    /\ name = Null
    /\ second = Asleep

\* R1 or R2: the stamp that starts the turn, with release order.
Stamp ==
    /\ lpc = "stamp"
    /\ beat' = Store(beat, turn, LoopViewOf(Len(beat) + 1, Len(run)))
    /\ lpc' = "callbacks"
    /\ called' = 0
    /\ UNCHANGED <<run, turn, wpc, known, first, name, second>>

\* `enter`: the name of the next callback, before the loop calls it.
Enter ==
    /\ lpc = "callbacks"
    /\ called < Callbacks
    /\ run' = Store(run, <<turn, called + 1>>, NameStoreView(Len(beat), Len(run) + 1))
    /\ called' = called + 1
    /\ UNCHANGED <<beat, lpc, turn, wpc, known, first, name, second>>

\* `leave`: null after the callbacks, with release order. A run that called no callback stores
\* nothing, because `running` is null already: `end` and `begin` call `leave` only after a call.
Leave ==
    /\ lpc = "callbacks"
    /\ IF called > 0
          THEN run' = Store(run, Null, LoopViewOf(Len(beat), Len(run) + 1))
          ELSE UNCHANGED run
    /\ lpc' = "end"
    /\ UNCHANGED <<beat, turn, called, wpc, known, first, name, second>>

\* The turn ends at the next stamp, or the loop sleeps first: `note_asleep`, with release order.
EndTurn ==
    /\ lpc = "end"
    /\ \/ beat' = Store(beat, Asleep, LoopViewOf(Len(beat) + 1, Len(run)))
       \/ UNCHANGED beat
    /\ IF turn < Turns THEN lpc' = "stamp" /\ turn' = turn + 1 ELSE lpc' = "done" /\ UNCHANGED turn
    /\ UNCHANGED <<run, called, wpc, known, first, name, second>>

\* Load 1: `beat_ns` with acquire order.
LoadFirst ==
    /\ wpc = "load1"
    /\ \E i \in known["beat"] .. Len(beat) :
        /\ first' = beat[i].value
        /\ known' = [l \in Locations |-> IF l = "beat" THEN Max(known[l], i)
                                                       ELSE Max(known[l], beat[i].view[l])]
    /\ wpc' = "load2"
    /\ UNCHANGED <<beat, run, lpc, turn, called, name, second>>

\* Load 2: `running`.
LoadName ==
    /\ wpc = "load2"
    /\ \E j \in known["run"] .. Len(run) :
        /\ name' = run[j].value
        /\ known' = AfterNameLoad(known, j)
    /\ wpc' = "load3"
    /\ UNCHANGED <<beat, run, lpc, turn, called, first, second>>

\* Load 3: `beat_ns` again, with relaxed order.
LoadSecond ==
    /\ wpc = "load3"
    /\ \E k \in known["beat"] .. Len(beat) :
        /\ second' = beat[k].value
        /\ known' = [known EXCEPT !["beat"] = Max(known["beat"], k)]
    /\ wpc' = "done"
    /\ UNCHANGED <<beat, run, lpc, turn, called, first, name>>

Next ==
    \/ Stamp \/ Enter \/ Leave \/ EndTurn
    \/ LoadFirst \/ LoadName \/ LoadSecond

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ lpc \in {"stamp", "callbacks", "end", "done"}
    /\ wpc \in {"load1", "load2", "load3", "done"}
    /\ turn \in 1 .. Turns
    /\ called \in 0 .. Callbacks
    /\ known \in Views

\* A check that reports a turn names a callback of that turn, or none.
NameOfTurn ==
    (wpc = "done" /\ first = second /\ first # Asleep /\ name # Null) => name[1] = first
=============================================================================
