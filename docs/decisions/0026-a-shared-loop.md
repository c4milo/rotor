# 26. A loop that several libraries share

Status: **accepted** by Camilo on 2026-11-06, with the proposed answer to each open question, and
**built** the same day. It amends decision 1, which made the event batch the primary shape and
kept callbacks as a helper: the batch stays the default, and an operation may now name a record.
"What was built" at the end says where the code differs from the proposal, and what it measured.

## Context

colibri asked for this in rotor issue 14. colibri's client and server and cocuyo's resolver will
run on one `rotor.Loop`, which the program owns. Today the caller of `tick` gets every event of the
loop. So one library that ticks, for example inside `colibri.Client.fetch`, takes the events of the
other libraries, and they are lost to their owners.

Camilo ruled with colibri's session on 2026-11-06, and issue 14 records the ruling:

1. Model the shared loop on Seastar's reactor. Each operation carries a completion record that the
   library owns, a function and a context, and `tick` calls it.
2. Libraries take the loop at init, and any of them may tick. Camilo corrected this on 2026-11-06,
   with decision 27: only the program ticks a shared loop. A library submits, returns, and finishes
   its work in records, pollers and tasks, because a library's tick inside the program's call into
   another library nests one library's callbacks inside the other's.
3. Subsystems register pollers that the loop calls once per tick.
4. One loop per thread, shared nothing, as today.
5. An event of an operation with no record goes back to the caller of `tick`.

The description of Seastar comes from its published design and not from its source. Its reactor
calls `complete_with(result)` on the completion object that each I/O names, so it never sorts
events by owner. Its network stack, disk queues, timers and cross-core queues are pollers.

This record turns the ruling into a design that rotor can build. It also names where the ruling
meets decision 1 and non-negotiable 2, because CLAUDE.md asks for that before anything is built.

## The decision, as proposed

### A completion record

```zig
pub const Completion = struct {
    callback: *const fn (completion: *Completion, event: Event) void,
};
```

- **The library owns the record.** It puts a `Completion` inside its own struct, for example a
  socket slot or a timer, and finds its struct again with `@fieldParentPtr`. So the record holds
  only the function, 8 bytes, and the context is the struct around it.
- **An operation names its record** with `Operation.completion(record)`. That sets `user_data` to
  the record's address and sets a new field `dispatched` to true. An operation without it is as
  today.
- **The slot does not grow.** `Slot.Flags` has one reserved bit, and it becomes `dispatched`. The
  record's address is the `user_data` the slot already holds. So `Slot` stays at 64 bytes.
- **An event carries the bit too.** `Event.Flags` has 5 reserved bits, and one becomes
  `dispatched`. A backend copies it from the slot when it makes the event, as it copies `more`.

### What `tick` does

1. It calls each poller once, in the order they were added. A poller returns true when it did work.
   If any poller did work, the tick waits 0 ns, as Seastar's reactor does not sleep then.
2. The backend fills `events`, as today.
3. A core function walks the events the backend produced. It calls the record of each event that
   has `dispatched`, and moves the other events to the front of `events`.
4. `tick` returns the count of events at the front: the events that no record took.

Step 3 runs only while an operation with a record is in flight. The loop counts those operations,
and the count falls at each final event that step 3 hands to a record. A program that uses no
record pays one compare of a counter against 0 for each tick.

A callback may submit, cancel and give back buffers. It may not call `tick`: a tick inside a tick
halts. A callback that wants another pass returns, and the loop's next tick serves it.

### Pollers

```zig
pub const Poller = struct {
    poll: *const fn (poller: *Poller) bool,
};
```

- `loop.add_poller(poller)` and `loop.remove_poller(poller)`. The library owns the `Poller`, as it
  owns a `Completion`.
- The loop holds a table of `pollers_max` pointers, a new named limit in `core/constants.zig`. This
  record proposes 8. A full table is an operational error, `error.PollersFull`, and not an
  assertion.
- A poller runs once for each tick, never more. It may submit and it may not tick.

### What does not change

- The batch shape. A caller that names no record gets every event in `events`, as decision 1 says.
- Posts. A message another loop posts has no slot and no record, so it goes to the caller of
  `tick`. A library that needs its own messages is an open question below.
- Shared nothing (non-negotiable 4). The callbacks run on the loop's thread, inside its tick.
- Zero heap (non-negotiable 1). The records and pollers live in memory the library owns.

## Where it meets the records

- **Decision 1** rejected "callbacks as the primary shape". Its reasons were one indirect call per
  completion (C5) and 16 bytes of function and context in every in-flight record. This design keeps
  the batch as the default. It pays C5 only for an event whose operation asked for it. It puts no
  byte in the slot, because the context is the library's struct and the function is in the record.
  Decision 1's dispatch helper read a callback from a table that the caller registered once. A
  record for each operation replaces that table.
- **Non-negotiable 2** says that nothing in `core` reads a pointer value. The loop calls through
  the record's address and never decides anything from its value. The order of the callbacks is
  the order of the events, which is a function of what the caller submitted and what the kernel
  answered.
- **Decision 8.** The check that no tick runs inside a tick is a bool on the loop. It is class A.
  The walk of step 3 tests one bit for each event.
- **Decision 17**, proposed, names a layer that owns the loop and holds TLS and DNS. This record
  does not build that layer. It gives such a layer a way to share the loop with other libraries.

## What it costs

These are priors. Nothing here was measured.

| cost | when | rows | size |
|---|---|---|---|
| compare of the record count to 0 | each tick | C1 | under 1 ns |
| test of the `dispatched` bit | each event, while a record is in flight | C1 | under 1 ns |
| call through the record | each dispatched event | C5 | 1.3 to 1.5 ns on the three machines |
| read of the library's struct | each dispatched event | C1 to C3 | the library's own load, which a sort by owner pays too |
| call of each poller | each tick | C5 | 1.3 to 1.5 ns for each poller |
| table of pollers | each loop | none | `pollers_max` × 8 bytes, 64 bytes at 8 |

The instruction gate of `bench/work/work.zig` holds a program that names no record within 2
percent. A change that moves it by more fails `zig build test`.

## Alternatives it beat

These lost in the ruling of 2026-11-06.

- **A tag table that routes by a range of `user_data` bits.** Each library would need an agreed
  range, and a library that took the wrong range would take the events of another.
- **A router in each library**, such as colibri's `Host` or `LoopIds`. Each library would carry
  the same code, and two routers on one loop would still need one owner of `tick`.
- **Today's model, where the application sorts the events.** It works, and it is what a program
  with one library still gets. It asks each application to know the events of every library it
  uses.

This record adds one:

- **A 16-byte record in the slot, as decision 1 described.** It would cost 16 bytes that `Slot`
  does not have, and a layout change of a hot structure. The library's struct holds the context
  at no cost to the loop.

## How it would be checked

- A conformance scenario: two libraries on one loop, each with a receive and a timer, and each
  calls `tick` in turn. Every event reaches its own record, and none reaches the caller of `tick`.
- A conformance scenario: a loop with one operation with a record and one without. The event of
  the second reaches the caller, and the first reaches its record only.
- A conformance scenario: a poller that returns true makes the tick wait 0 ns, and each poller runs
  once for each tick.
- A conformance scenario: a callback submits, and the next tick serves what it submitted.
- A halt scenario: a callback that calls `tick`.
- A halt scenario: `remove_poller` with a poller that was not added.
- Mutations for each check, measured against `zig build test-conformance-<backend>` and
  `zig build halt-check`.
- The instruction gate for a program that names no record.

## Open questions

1. **Is `pollers_max` 8?** Proposed: yes. colibri and cocuyo need one each today.
2. **Does a post carry a record?** Proposed: no, not in this record. A message has a 32-bit tag
   and a 64-bit payload. A library that needs its own messages can put a record's address in the
   payload and call it itself. A later record can add a flag if two libraries need that.
3. **Does a `more` event of a multishot operation go to the record?** Proposed: yes, each event of
   the operation goes to it, as the ruling says. The count of operations with a record falls only
   at the final event.
4. **Does `drain` call the records?** Proposed: yes. `drain` is a series of ticks, so each final
   event of a cancelled operation reaches its record. A library sees the end of each of its
   operations.
5. **Are `Completion` and `Poller` the names?** Proposed: yes, with `Operation.completion`,
   `Loop.add_poller` and `Loop.remove_poller`.

## What was built

The code is `src/core/dispatch.zig`, the slot and event flag `dispatched`, the count in
`Tables.submit`, and the `tick` of each backend. It differs from the proposal in five places.

1. **A tick with nothing to dispatch skips the dispatch.** With no poller and no record in flight,
   no callback can run, so `tick` calls the backend directly. The pollers, the records and the
   check of a tick inside a tick run in `tick_dispatched`, a function of its own that is marked
   cold. Inside `tick`, that code cost every tick about 12 more instructions in saved registers.
2. **A poller may not add or remove a poller.** The loop walks the table while it calls the
   pollers, so such a call halts. A callback may add or remove one.
3. **`deinit` halts while a poller is still added.** The poller is the library's memory, and the
   library may free it once the loop has ended.
4. **Typed helpers.** `Completion.init(Parent, "field", handler)` and
   `Poller.init(Parent, "field", poll)` write the callback at compile time. The handler takes
   `*Parent`, and a wrong field, parent or signature fails to compile. The raw form stays.
5. **What true means.** A poller returns true when the tick must not block, for example because
   work is left. The tick then waits 0 ns. True means nothing else.

A poller sees `now_ns` as the last tick read it, because it runs before this tick reads the clock.
A tick that blocked read the clock again after its wait, so that reading is never older than the
end of the last wait. A timer fires when its deadline is at or before `now_ns`, so a poller that
reads its own deadline from the same reading sees it due too.
`release_buffers` is valid in a callback once the group's last operation has had its final event.

### What it measured

The instruction gate, for a program that names no record and adds no poller, against the tree
without this record. macOS counts the process's instructions with `/usr/bin/time -l` on `mac`.
Linux counts user instructions with cachegrind in an arm64 container on `mac`.

| backend | post | post-operation | timer | batch of 32 |
|---|---:|---:|---:|---:|
| kqueue | 1229 → 1241 (+1.0%) | 2988 → 3051 (+2.1%) | 1086 → 1111 (+2.3%) | 24189 → 24624 (+1.8%) |
| io_uring | 1040 → 1046 (+0.6%) | not counted | 1024 → 1031 (+0.7%) | 23532 → 23757 (+1.0%) |
| epoll | 1205 → 1217 (+1.0%) | not counted | 1070 → 1092 (+2.1%) | 23515 → 23845 (+1.4%) |

Cachegrind put the work in three places: about 8 instructions at each operation's submit, 2 at
each event, and about 6 in each tick. Two shapes of the code cost more, and were changed:

- A packed struct literal with two runtime fields compiled to a read of the old flags from memory
  and a second write. Building the flags in a local first saved 5 instructions at each event.
- The dispatch code inside `tick` made the compiler save four more registers in every tick.

Camilo raised the macOS rows of `bench/baseline/work.txt` for `post-operation`, `timer` and
`batch` on 2026-11-06. The tree without this record already sat about 1 percent over them.

The scenarios are in `conformance_dispatch.zig`: two libraries on one loop, an operation without a
record beside one with a record, a callback that submits, the pollers, and a multishot receive
whose datagrams and final event reach its record. The halt scenarios are in
`tools/halt/core_scenarios_dispatch.zig`.

Mutations, 20, each CAUGHT. Against `zig build halt-check`: no check of a tick inside a tick, of
an end or an abandon without a begin, of a poller added twice, of a poller never added, of a
poller added or removed from a poller, and of a poller left at `deinit`. Against the kqueue
conformance suite: a tick that always skips the dispatch, a poller whose true does not stop the
wait, an event without a record that is dropped, a record never called, a submit that counts no
record, and the flag dropped at the slot, at `drain_finished` and at kqueue's reap. Against the
Linux gate: the flag dropped at epoll's reap and its batch, and at io_uring's reap and its failure
path.
