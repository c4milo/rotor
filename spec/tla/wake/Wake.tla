-------------------------------- MODULE Wake --------------------------------
\* The sleep handshake of decision 12, point 6, and decision 18: a loop that is about to block in
\* the kernel makes sure that every message another loop posts, and every result one of its
\* offload's workers pushes, either reaches it before it blocks or wakes it after. The code is
\* core/inbox.zig, core/mailbox.zig, core/mailbox_registry.zig, core/remote.zig, and each readiness
\* backend's offload file.
\*
\* One receiving loop. Each of `Senders` is a loop, or a `Remote`, that posts to it through a ring
\* of its own. Each of `Workers` is a worker of the receiver's offload, which pushes results through
\* a ring of its own. A ring is two counts: `tail`, which its producer writes, and `head`, which the
\* receiver writes. What a message says does not matter here, only that it is there.
\*
\* The model is sequentially consistent, and the code makes that true where it matters. The four
\* accesses the handshake rests on are `seq_cst` in the code: the push's store of `tail`
\* (`Mailbox.push`), the receiver's loads of `tail` (`Mailbox.is_empty`, `pop_into`), and both
\* sides' accesses to the flag (`Registry.begin_sleep`, `must_wake`, and the offload's flag). So
\* no store is seen later than a load its own thread makes after it. WakeMutants.tla shows what a
\* weaker order would let happen.
\*
\* The receiver's wait has no timeout here. In rotor a wait is bounded, so a lost wake would show
\* only as a late message; here it shows as a receiver that blocks with a message waiting and no
\* wake on its way, which `NoLostWake` refuses, and as a message never handed over, which
\* `Delivered` refuses.
EXTENDS Naturals

CONSTANTS
    Senders,   \* the loops, and remotes, that post to the receiver
    Workers,   \* the workers of the receiver's offload
    Messages,  \* how many messages each of them sends in all
    Capacity   \* the messages a ring holds; a push to a full ring waits for the receiver

\* A sender's push to a full ring is refused (`mailbox_full`) and the caller tries again later. A
\* worker's never is: the loop hands a worker no more work than its ring holds, and the worker
\* asserts its push. The model lets both wait, which only adds behaviours.

ASSUME Senders \cap Workers = {}
ASSUME Messages \in Nat /\ Capacity \in Nat \ {0}

Producers == Senders \cup Workers

VARIABLES
    tail,           \* [Producers -> Nat]: what each producer has pushed to its ring
    head,           \* [Producers -> Nat]: what the receiver has taken from each ring
    sleeping,       \* the registry's flag that the receiver is about to sleep
    offloadAsleep,  \* the inbox's flag the offload's workers read
    wake,           \* the kernel's wake event for the receiver: set by a trigger, taken by a call
    pc,             \* where each producer is
    owes,           \* [Senders -> BOOLEAN]: the sender's flush noted the receiver and owes a wake
    rpc,            \* where the receiver is in its tick
    checked         \* the rings the receiver has looked at since it set a flag

vars == <<tail, head, sleeping, offloadAsleep, wake, pc, owes, rpc, checked>>

Pending(p) == tail[p] # head[p]
AnyPending(set) == \E p \in set : Pending(p)

TypeOK ==
    /\ tail \in [Producers -> 0..Messages]
    /\ head \in [Producers -> 0..Messages]
    /\ \A p \in Producers : head[p] <= tail[p] /\ tail[p] - head[p] <= Capacity
    /\ sleeping \in BOOLEAN
    /\ offloadAsleep \in BOOLEAN
    /\ wake \in BOOLEAN
    /\ pc \in [Producers -> {"push", "check", "flushed", "done"}]
    /\ owes \in [Senders -> BOOLEAN]
    /\ rpc \in {"drain", "offload_flag", "offload_check", "begin_sleep", "recheck", "wait",
                "wake_up"}
    /\ checked \subseteq Producers

Init ==
    /\ tail = [p \in Producers |-> 0]
    /\ head = [p \in Producers |-> 0]
    /\ sleeping = FALSE
    /\ offloadAsleep = FALSE
    /\ wake = FALSE
    /\ pc = [p \in Producers |-> IF Messages = 0 THEN "done" ELSE "push"]
    /\ owes = [s \in Senders |-> FALSE]
    /\ rpc = "drain"
    /\ checked = {}

-----------------------------------------------------------------------------
\* The producers.

\* A producer pushes one message: its store of `tail` (`Mailbox.push`). A full ring refuses the
\* push, and the producer tries again once the receiver has taken some. A sender may push several
\* messages in one flush.
Push(p) ==
    /\ \/ pc[p] = "push"
       \/ p \in Senders /\ pc[p] = "flushed"
    /\ tail[p] < Messages
    /\ tail[p] - head[p] < Capacity
    /\ tail' = [tail EXCEPT ![p] = @ + 1]
    /\ pc' = [pc EXCEPT ![p] = "check"]
    /\ UNCHANGED <<head, sleeping, offloadAsleep, wake, owes, rpc, checked>>

\* A sender reads the receiver's flag after its push (`remote.send`, `Registry.must_wake`) and, when
\* the receiver said it sleeps, notes it for the wake its flush sends at the end (`Wakes.note`).
SenderCheck(s) ==
    /\ pc[s] = "check"
    /\ owes' = [owes EXCEPT ![s] = @ \/ sleeping]
    /\ pc' = [pc EXCEPT ![s] = "flushed"]
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, wake, rpc, checked>>

\* The flush ends and sends one wake to a receiver it noted, however many messages it posted
\* (`Wakes.send`).
EndFlush(s) ==
    /\ pc[s] = "flushed"
    /\ wake' = (wake \/ owes[s])
    /\ owes' = [owes EXCEPT ![s] = FALSE]
    /\ pc' = [pc EXCEPT ![s] = IF tail[s] = Messages THEN "done" ELSE "push"]
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, rpc, checked>>

\* A worker reads the receiver's offload flag after its push, and wakes the receiver at once when
\* it is set (`kqueue_offload.zig`, `epoll_offload.zig`).
WorkerCheck(w) ==
    /\ pc[w] = "check"
    /\ wake' = (wake \/ offloadAsleep)
    /\ pc' = [pc EXCEPT ![w] = IF tail[w] = Messages THEN "done" ELSE "push"]
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, owes, rpc, checked>>

-----------------------------------------------------------------------------
\* The receiver, one tick after another.

\* A tick hands over what the rings hold (`Inbox.drain_mailboxes` and the offload's drain). A tick
\* that handed over anything returns, and the next one drains again. A tick that handed over
\* nothing goes to sleep: through the offload's flag first when it has workers.
Drain ==
    /\ rpc = "drain"
    /\ head' = tail
    /\ rpc' = IF AnyPending(Producers) THEN "drain"
              ELSE IF Workers = {} THEN "begin_sleep" ELSE "offload_flag"
    /\ checked' = {}
    /\ UNCHANGED <<tail, sleeping, offloadAsleep, wake, pc, owes>>

\* The receiver tells its workers it is about to block (`Inbox.settle_to_sleep`).
OffloadFlag ==
    /\ rpc = "offload_flag"
    /\ offloadAsleep' = TRUE
    /\ rpc' = "offload_check"
    /\ checked' = {}
    /\ UNCHANGED <<tail, head, sleeping, wake, pc, owes>>

\* Then it looks at every worker's ring once more (`offload.pending`), one ring at a time. A result
\* that is there ends the sleep before it starts.
OffloadCheck ==
    /\ rpc = "offload_check"
    /\ \/ /\ checked = Workers
          /\ rpc' = "begin_sleep"
          /\ checked' = {}
       \/ \E w \in Workers \ checked :
            IF Pending(w) THEN rpc' = "wake_up" /\ checked' = {}
            ELSE checked' = checked \cup {w} /\ rpc' = rpc
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, wake, pc, owes>>

\* The receiver tells the other loops it is about to block (`Registry.begin_sleep`).
BeginSleep ==
    /\ rpc = "begin_sleep"
    /\ sleeping' = TRUE
    /\ rpc' = "recheck"
    /\ checked' = {}
    /\ UNCHANGED <<tail, head, offloadAsleep, wake, pc, owes>>

\* Then it looks at every sender's ring once more, one ring at a time (`Inbox.settle_to_sleep`). A
\* message that is there ends the sleep before it starts. When every ring is empty it blocks.
Recheck ==
    /\ rpc = "recheck"
    /\ \/ /\ checked = Senders
          /\ rpc' = "wait"
          /\ UNCHANGED checked
       \/ \E s \in Senders \ checked :
            IF Pending(s) THEN rpc' = "wake_up" /\ UNCHANGED checked
            ELSE checked' = checked \cup {s} /\ rpc' = rpc
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, wake, pc, owes>>

\* The blocking call returns when the wake event is set, and takes it.
Wait ==
    /\ rpc = "wait"
    /\ wake
    /\ wake' = FALSE
    /\ rpc' = "wake_up"
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, pc, owes, checked>>

\* Awake again: both flags cleared (`Inbox.wake_up`), and the tick drains what woke it.
WakeUp ==
    /\ rpc = "wake_up"
    /\ sleeping' = FALSE
    /\ offloadAsleep' = FALSE
    /\ rpc' = "drain"
    /\ checked' = {}
    /\ UNCHANGED <<tail, head, wake, pc, owes>>

\* A tick that polls the kernel instead of blocking can take a pending wake event, as a polling
\* tick does in rotor; the tick then drains, so nothing it announced is lost. It is never forced
\* to happen.
Poll ==
    /\ rpc \in {"drain", "wake_up"}
    /\ wake
    /\ wake' = FALSE
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, pc, owes, rpc, checked>>

Receiver == Drain \/ OffloadFlag \/ OffloadCheck \/ BeginSleep \/ Recheck \/ Wait \/ WakeUp

Next ==
    \/ Receiver
    \/ Poll
    \/ \E p \in Producers : Push(p)
    \/ \E s \in Senders : SenderCheck(s) \/ EndFlush(s)
    \/ \E w \in Workers : WorkerCheck(w)

Fairness ==
    /\ WF_vars(Receiver)
    /\ \A p \in Producers : WF_vars(Push(p))
    /\ \A s \in Senders : WF_vars(SenderCheck(s)) /\ WF_vars(EndFlush(s))
    /\ \A w \in Workers : WF_vars(WorkerCheck(w))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* What must hold.

\* A producer that will still wake the receiver: one that has pushed and not yet read the flag, or
\* a sender whose flush owes a wake.
MayWake(p) == pc[p] = "check" \/ (p \in Senders /\ owes[p])

\* The receiver never blocks with a message waiting, unless the wake event is set or a producer is
\* still on its way to setting it.
NoLostWake ==
    (rpc = "wait" /\ ~wake /\ AnyPending(Producers)) => \E p \in Producers : MayWake(p)

\* Every message is handed over in the end.
Delivered == <>(\A p \in Producers : head[p] = Messages)

=============================================================================
