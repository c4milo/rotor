---------------------------- MODULE WakeMutants -----------------------------
\* The handshake broken on purpose, one way each. A configuration in mutants/ puts one in place of
\* the operator it breaks, with TLC's `Operator <- Mutant`, and TLC must find the lost wake. A
\* mutant that TLC passed would show `NoLostWake` holding for a reason other than the handshake.
\*
\* Two of them are what a weaker memory order than the code's would allow. With a release store of
\* `tail` and a relaxed or acquire load of the flag, x86 may make the load before the store is
\* seen: `SenderReadsFirst`. With a release store of the flag and acquire loads of `tail`, the
\* receiver may read the rings before its flag is seen: `FlagAfterRecheck`. The `seq_cst` accesses
\* the code makes rule both out.
EXTENDS Wake

\* M1: the receiver sets its flag and blocks without looking at the rings again.
BeginSleepSkipRecheck ==
    /\ rpc = "begin_sleep"
    /\ sleeping' = TRUE
    /\ rpc' = "wait"
    /\ checked' = {}
    /\ UNCHANGED <<tail, head, offloadAsleep, wake, pc, owes>>

\* M2: the receiver looks at the rings first and sets its flag after, as a store that others see
\* late would make it.
BeginSleepLookFirst ==
    /\ rpc = "begin_sleep"
    /\ rpc' = "recheck"
    /\ checked' = {}
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, wake, pc, owes>>

FlagAfterRecheck ==
    /\ rpc = "recheck"
    /\ \/ /\ checked = Senders
          /\ sleeping' = TRUE
          /\ rpc' = "wait"
          /\ UNCHANGED checked
       \/ \E s \in Senders \ checked :
            IF Pending(s) THEN rpc' = "wake_up" /\ UNCHANGED <<checked, sleeping>>
            ELSE checked' = checked \cup {s} /\ UNCHANGED <<rpc, sleeping>>
    /\ UNCHANGED <<tail, head, offloadAsleep, wake, pc, owes>>

\* M3: a sender reads the receiver's flag before its push is seen, as a store that sits in a store
\* buffer past a later load would make it. The read comes first and the push after.
SenderReadsFirst(p) ==
    /\ \/ pc[p] = "push"
       \/ p \in Senders /\ pc[p] = "flushed"
    /\ tail[p] < Messages
    /\ tail[p] - head[p] < Capacity
    /\ IF p \in Senders THEN owes' = [owes EXCEPT ![p] = @ \/ sleeping] ELSE UNCHANGED owes
    /\ pc' = [pc EXCEPT ![p] = "check"]
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, wake, rpc, checked>>

SenderPushesLate(s) ==
    /\ pc[s] = "check"
    /\ tail' = [tail EXCEPT ![s] = @ + 1]
    /\ pc' = [pc EXCEPT ![s] = "flushed"]
    /\ UNCHANGED <<head, sleeping, offloadAsleep, wake, owes, rpc, checked>>

\* M4: the receiver clears its flag once the rings look empty, before it blocks.
RecheckThenClear ==
    /\ rpc = "recheck"
    /\ \/ /\ checked = Senders
          /\ sleeping' = FALSE
          /\ rpc' = "wait"
          /\ UNCHANGED checked
       \/ \E s \in Senders \ checked :
            IF Pending(s) THEN rpc' = "wake_up" /\ UNCHANGED <<checked, sleeping>>
            ELSE checked' = checked \cup {s} /\ UNCHANGED <<rpc, sleeping>>
    /\ UNCHANGED <<tail, head, offloadAsleep, wake, pc, owes>>

\* M5: the receiver never tells its workers it is about to block.
OffloadFlagNeverSet ==
    /\ rpc = "offload_flag"
    /\ rpc' = "offload_check"
    /\ checked' = {}
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, wake, pc, owes>>

\* M6: a flush notes the receiver and never sends the wake it owes.
EndFlushNoWake(s) ==
    /\ pc[s] = "flushed"
    /\ owes' = [owes EXCEPT ![s] = FALSE]
    /\ pc' = [pc EXCEPT ![s] = IF tail[s] = Messages THEN "done" ELSE "push"]
    /\ UNCHANGED <<tail, head, sleeping, offloadAsleep, wake, rpc, checked>>

=============================================================================
