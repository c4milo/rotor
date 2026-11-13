# 34. A package of its own for `std.Io` and its Future API

Status: **accepted** on 2026-11-11 by Camilo ("The fourth round, 2026-11-11"). It was proposed on
2026-11-10. The session revised it that day four times: after two reviews, for Camilo's first
rulings, after a third review, and for his second rulings. On 2026-11-09 Camilo ruled where this
work goes ("Ruling, 2026-11-09"). On 2026-11-10 he ruled each open question up to 16, in two rounds
("Rulings, 2026-11-10"). On 2026-11-11 he ruled questions 17 and 18, and asked for question 19
("The third round, 2026-11-11"). Later that day he ruled question 19, and accepted this record. The
design below follows those rulings. The package calls `tick`, its type is generic over the
reactor's type, and it builds on decision 33's reactor at v0.11.0. No review read the answers to the
third review, or the revision for the second rulings.

Nothing of the package is built, and no repository exists. The package starts at step 0 of "Build
order". The session makes its repository when Camilo says so ("Ask before").

**Noted on 2026-11-13.** Camilo made the repository, github.com/c4milo/tejedor, on 2026-11-12. Step
0 of "Build order" is on its `main` at `ded6989`: the fiber switch, its tests and its probe. The
probe ran only on busy machines, so no number of it is final. Step 1 waits for Camilo's word.
"Upkeep" and "Where the code starts" each hold a note on what step 0 changed.

Decision 33 was accepted on 2026-11-10. Its steps 1 to 5 are on `main`, and v0.11.0 released them on
2026-11-11 (`f2890f5`). Each name of rotor in this record is the name that v0.11.0 holds. "Decision
33 as v0.11.0 built it" lists what this record changed at its acceptance to agree with that code.

Nothing was measured for this record. Each number is a row of `docs/costs.md`, a row of
`bench/baseline/work.txt`, a number that decision 22 measured, or a prior. A prior is arithmetic
over such rows. Each table of numbers names its source.

This record changes no source file of rotor. At its acceptance it amended decision 1, which still
said that the `std.Io` table is a module of rotor, and decision 2 gained a note. Decisions 26, 27
and 28 and the guide, `docs/using.md`, gained a note on who ticks ("Who ticks"). Camilo ruled that
the session writes those notes at this record's acceptance. Decision 22 gained one note that points
here, in the first commit of this record, and a second at its acceptance. "Ask before" lists each
item that needs Camilo's word first.

## Ruling, 2026-11-09

On 2026-11-09 Camilo wrote to this session: "Let's also use Zig's Futures API for the reactor".

The session told him three facts:

- Zig's Future API is `io.async`, `future.await` and `future.cancel`. It works only through a
  `std.Io`.
- `await` needs fibers.
- Decision 22 built that `std.Io` over rotor. Camilo removed it on 2026-11-05, for its size, its
  upkeep and the rules it bent.

The session then put four choices to him:

1. A package of its own. The session recommended this choice.
2. Inside rotor's `reactor` module.
3. Future-shaped names with no `std.Io`.
4. An explanation first.

Camilo chose "A package of its own". The text of that choice said: "A separate package gives a
std.Io over rotor.Reactor, with fibers that run as tasks in a scheduling group. rotor stays lean and
takes no upkeep from std.Io. This is the alternative you did not pick on 2026-11-05. I draft a
proposed decision first, and build nothing."

He gave no reason with the choice.

The session asked Camilo where the Future API goes, and he chose one of the four choices. So this
record takes two things as ruled:

1. The `std.Io` is in a package of its own, outside rotor.
2. A proposed decision comes first, and nothing is built.

The other sentences of the text are the session's words. They describe a design: a `std.Io` "over
rotor.Reactor, with fibers that run as tasks in a scheduling group". Camilo chose the text whole,
and he ruled on no part of that design. So this record proposes the design, and does not use the
text as a reason for it:

- Open question 2 asks who calls `tick`. The answer decides whether a fiber runs inside a
  `rotor.Task`.
- Open question 3 asks about `rotor.Reactor`. That type is decision 33's. Step 2 of that record
  built it (`bb81c21`).
- Item 7 of the decision proposes that rotor does not depend on the package.

## Rulings, 2026-11-10

On 2026-11-10 the session put eight of the open questions to Camilo, each with its choices. The
first choice of each row was the session's recommendation. Camilo chose one for each question, and
gave no reason with a choice.

| question | the choices | Camilo chose |
|---|---|---|
| 2. Who calls `tick`? | the program; the package; an explanation of both shapes first | **the package** |
| 1. The package's name | `tejedor`; `rotor-fibers`; `fibra` | **`tejedor`** |
| 3. The first rotor release that the package builds on | v0.10.0; a wait for v0.11.0 | **a wait for v0.11.0** |
| 10. Decision 22's two conditions | both bind, and the first means that rotor's own paths do not slow down; both bind, and the first sets a bar for the package's own speed; neither binds | **both bind, and the first means that rotor's own paths do not slow down** |
| 4. The default fibers, the default stack, and the limit | 256 fibers of 256 KiB, with a limit of 4,096; 256 fibers of 128 KiB, with a limit of 4,096; a ruling after the stack is measured | **256 fibers of 256 KiB, with a limit of 4,096** |
| 5. A guard page for each stack | always; an option that is on by default; none | **always** |
| 7. A default for `rest` | no default; a default of `std.Io.failing` | **no default** |
| 8. The calls that another thread may make | only `futexWake`; none in the first release | **only `futexWake`** |

What the choices said, where a ruling depends on it:

- **Question 2.** The choice said that the package ticks as decision 22's adapter did. Main code may
  `await` and block, and a wake between two fibers costs no tick. The package owns the loop and
  passes the view to each other library. A program with its own tick loop cannot use the package.
- **Question 1.** The choice said that a program types `tejedor.Fibers`, and that the repository
  takes the same name. The session makes no repository before Camilo says so. The option `count` is
  not ruled.
- **Question 3.** The choice said that the package starts only after decision 33 is accepted,
  built and tagged.
- **Question 10.** The choice said that the package's own speed has no fixed bar, and that Camilo
  reads the echo table before a release.
- **Question 4.** This record proposed a limit of 8,192, for the 4,097 fibers of a timer row under
  shape (b). The session told Camilo that the row needs 4,096 fibers when the package ticks.
- **Question 8.** The question asked which `std.Io` calls a thread that does not own the loop may
  make on `tejedor`. The choice said that `Event.set`, `Condition.signal` and `Mutex.unlock` work
  from such a thread, and that it shares no `Mutex` and no `Queue` with a fiber. Neither text named
  the 75 calls that go to `rest`.

Two rulings differ from what this record proposed: the package calls `tick`, and the package waits
for v0.11.0. Questions 6 and 9 are not ruled. The ruling on question 2 changes each halt that
question 9 asks about, and question 9 says how.

### The second round

Later on 2026-11-10 the session put the other questions to Camilo, after the design was revised for
the first round and a review was answered. The first choice of each row was this record's proposed
answer. Camilo gave no reason with a choice.

| question | the choices | Camilo chose |
|---|---|---|
| 11. Who makes the reactor? | the program; the package holds it | **the program** |
| 12. A record or a tag for each operation of a fiber | a record; a tag in `user_data` | **a record** |
| 13. A limit on the fibers that run between two ticks | a constant of 64; an option with a default of 64; no limit | **a constant of 64** |
| 14. Can the package run over a twin of the reactor? | a generic type; one fixed type; a fixed type now and a generic type later | **a generic type** |
| 15. Do the 75 calls that go to `rest` halt from another thread? | each call checks; no check on the 75 | **each call checks** |
| 16. A halt when nothing can wake a fiber | no halt; a halt behind an option | **no halt** |
| 9. The five halts at a limit | accept all five; remove the three that can go; only a function for an error of `tick` | **accept all five** |
| 6. What the first release holds | through the network calls; the Future API only | **through the network calls** |
| 1, the rest: the names of the sketch | rule them with the code; accept them as written; accept them with `fibers` for `count` | **rule them with the code** |
| The notes in rotor's other records, at acceptance | a note on who ticks in decisions 26, 27 and 28 and in the guide; an amendment of decision 1 with a note in decision 2. Camilo could select each one | **both** |
| Does Camilo accept this record now? | after decision 33; now | **after decision 33** |

What the choices said, where a ruling depends on it:

- **Question 11.** The choice said that the program keeps each call of the reactor but `tick`, and
  that this is less than the text of the choice on question 2.
- **Question 14.** The choice named the type `tejedor.Fibers(rotor.Reactor(rotor.Loop))`. It said
  that the name is longer than the `tejedor.Fibers` of question 1. It also said that the record does
  not yet design a twin's form of `rotor.sync` and of `Remote`.
- **Question 15.** The choice said that `io.random` then halts from another thread, and that a
  program must not make the package's `io` its `debug_io`.
- **Question 16.** The choice said that a deadlock of fibers is then silent.
- **Question 9.** The question listed the five halts of open question 9.
- **Question 6.** The choice named the calls for std tasks, sleep, the wake from another thread,
  `perform` and `call`, the nine network calls and `fileClose`, with echo numbers.
- **The names.** The choice said that each name stays a proposal, and that Camilo rules it when the
  first step shows it in a real program.
- **The notes.** The choice said that the session writes both when Camilo accepts this record, and
  not before. The session wrote them on 2026-11-11 ("The fourth round, 2026-11-11").
- **Acceptance.** The choice said that this record stays proposed until decision 33 is accepted
  and the twin's parts of question 14 are in this record.

So each open question up to 16 is ruled, and each name of the sketch but `tejedor` is a proposal.

### The third round, 2026-11-11

Decision 33 was accepted on 2026-11-10, and its step 2 put `rotor.Reactor(Loop)` on `main` on
2026-11-11 (`bb81c21`). That day the session put the two questions that were left to Camilo, and one
new question. The first choice of each row was the session's recommendation. Camilo gave no reason
with a choice.

| question | the choices | Camilo chose |
|---|---|---|
| 17. Where a twin's socket calls come from | an option, `Options.sockets`; a `sync` namespace that the twin's loop type declares, read at comptime | **an option** |
| 18. Does the package keep a twin of its own for its tests? | yes, a small one; no twin | **yes, a small one** |
| How the record handles a deadline inside a network call, which stompy's proxy asked for | a new open question 19; keep the second task; a deadline in each call | **a new open question 19** |

- **Question 17.** The choice said that the other answer needs a new public declaration on each
  reactor type, the type of its loop, and that step 3 of decision 33 did not add one.
- **Question 18.** The choice named decision 33's `examples/twin.zig` as the model.
- **The deadline.** The session wrote question 19 with the proxy's two facts, what rotor's
  operations give today, and the cost of each answer.

So each open question up to 18 is ruled. The fourth round ruled question 19.

### The fourth round, 2026-11-11

Later on 2026-11-11 the session put question 19 to Camilo, and then the acceptance of this record.
This record proposed answer 2 to question 19. Camilo gave no reason with a choice.

| question | the choices | Camilo chose |
|---|---|---|
| 19. A deadline inside a network call | keep the second task; map std's `Timeout` to `timeout_ns`; calls of the package's own | **map std's `Timeout` to `timeout_ns`** |
| Does Camilo accept this record now? | accept now; not yet | **accept now** |

What the choices said, where a ruling depends on it:

- **Question 19.** When `batchAwaitConcurrent` holds one `net_receive`, the package sets the
  operation's `timeout_ns` from the `Timeout`. It runs no timer of its own for that deadline. A send
  with a deadline keeps the second task, because std has no operation that sends. rotor's
  conformance suite gains the two scenarios for the probe of 1 ns, in a change of their own. The
  batch calls are in step 6 ("Which calls run where"), which question 6 left out of the first
  release.
- **Acceptance.** The session put it after question 19, with three changes to rotor's documents.
  The second round ruled the first two. The session made each of them the same day:
  - a note on who ticks in decisions 26, 27 and 28, and in the guide's section "A library on a
    reactor" ("Who ticks");
  - an amendment in the header of decision 1, and a note in decision 2 ("What changes in rotor");
  - this record's status in the README's table of decision records.

So each open question has a ruling, and this record is accepted. Each name of the sketch but
`tejedor` is still a proposal, which Camilo rules with the code (open question 1).

## Context

### What the Future API is in Zig 0.16.0

These facts were read from `std/Io.zig` of the Zig 0.16.0 on the development machine, on 2026-11-10:

- `io.async(function, args)` (line 2326) returns a `Future(Result)` (line 1176). It calls `async` of
  the table. The table may run the function at once, on the caller's stack.
- `io.concurrent` (line 2365) calls `concurrent` of the table. That call gives the function a unit
  of concurrency, or it returns `error.ConcurrencyUnavailable`.
- `future.await(io)` and `future.cancel(io)` call `await` and `cancel` of the table. Each returns
  the function's result, so each stops its caller until the function returns.
- A `Group` (line 1218) holds functions that a caller awaits or cancels together, through four more
  calls of the table.
- The table is `Io.VTable` (line 51). It holds 109 function pointers, counted again for this record.
- The table marks `async`, `concurrent`, `await`, `cancel`, `groupAsync` and `groupConcurrent` as
  "Thread-safe". std also marks `io.random`, `io.randomSecure` and the `Queue` type as safe from
  several threads (lines 2465, 2482 and 2181).

So a caller gets the Future API only through a `std.Io`. A `std.Io` whose `await` stops its caller
needs something to suspend: a thread or a fiber (decision 1).

### Words

std and rotor each use the words "task" and "group". "Table" and "record" each name more than one
thing in rotor's documents. So this record gives each word below one meaning:

| word | meaning |
|---|---|
| **std task** | a function that `io.async`, `io.concurrent`, `Group.async` or `Group.concurrent` starts. std's own word is "task" |
| **rotor task** | a `rotor.Task`: a struct that a tick calls once, in a later part of that tick or in the next one (decision 27) |
| **`Io.Group`** | std's set of std tasks, which a caller awaits or cancels together |
| **scheduling group** | rotor's queue of rotor tasks, with shares (decision 30) |
| **reactor** | the value that the package ticks: the program's `rotor.Reactor(rotor.Loop)` of decision 33, which is the host's reactor, or the reactor of a twin |
| **twin** | a loop type of a program's own, which carries rotor's surface for replay (decision 10). Its reactor is `rotor.Reactor(Twin)` (decision 33) |
| **main context** | the thread's own stack: the program's code on the reactor's thread, outside each fiber and outside each tick |
| **context** | a fiber, or the main context |
| **callback** | a function that a tick calls: a record, a poller or a rotor task |
| **event handler** | the program's function that takes each event that a tick returns |
| **record** | a completion record: a `rotor.Completion` that an operation names, and that a tick calls for each event of that operation (decision 26) |
| **call record** | a `rotor.CallRecord`, which holds one cross-core call (decision 32) |
| **this record**, **decision record** | this document, and each other document of `docs/decisions/` |
| **the table** | `Io.VTable`: the 109 function pointers of a `std.Io`. Each other table has its full name here, as "the table of pollers" |
| **slot** | the place of one operation in flight. A reactor has `operations` of them, and it is **full** when none is free |
| a call **blocks** | its context stops until an event. The thread does not stop: it runs another context, or it ticks |
| a tick **waits** | its thread sleeps in the kernel |
| a fiber is **active** | from the start of its std task until the function of that std task returns |
| a fiber is **in use** | from the start of its std task until the fiber is free again |

rotor's documents say "a tick that blocks" for a tick whose thread sleeps in the kernel. This record
says "a tick waits" for that. It keeps "blocks" for a call, as std's own comments do (`std/Io.zig`,
line 1272). A call of `rest` can stop the whole thread in the kernel. This record says that such a
call "holds the thread".

A fiber of an `Io.Group` is free when its function returns. A fiber of a future stays in use after
its function returns, until `await` or `cancel` takes the result. The result is in that fiber's
stack. Decision 22's code worked the same way (`adapter_tasks.zig`).

### What decision 22 built, and why it went

Decision 22 built a `std.Io` whose state was one `rotor.Loop` and a pool of fibers. Its files were
in `src/rotor/adapter/`. Steps 1 to 3 landed on 2026-11-05 (`dfbb644`, `8f76dd7`, `89b0a8a`): the
calls for std tasks, the network calls, then datagrams, batches and files. Camilo removed it the
same day (`46235cb`). The fiber switch probe and row C26 of `docs/costs.md` went too (`85d5e67`).

Decision 22, "Why it was removed", gives the facts of that choice. They are its size, its upkeep,
the rules of rotor that it bent, and numbers from Linux only. That section names two alternatives.
One is a package of its own that depends on rotor's public module. This record is that alternative.

Camilo accepted decision 22 on 2026-09-27 on two conditions: "it keeps rotor's performance, and its
API follows rotor's own primitives" (its open question 1). The removal of 2026-11-05 withdrew
neither. On 2026-11-10 Camilo ruled that both bind the package (open question 10).

How that code worked matters for this record. The package keeps the first point, and changes the
other three:

- **It ticked the loop itself.** A context that blocked switched to the next ready fiber. When none
  was ready, it called `tick` on its own stack (`adapter_scheduler.zig`, `block`).
- **It read each event from `tick`.** Each of its operations carried the tag `0xADA7` and the
  fiber's index in `user_data`. An event without the tag went to a handler of the caller.
- **It ran fibers until none was ready.** No limit bounded the fibers between two ticks.
- **No tick of it called a callback.** Decision 26 gave rotor its records and its pollers one day
  after the removal.

### What rotor gained since the removal, and decision 33

Since 2026-11-05 rotor gained records and pollers (decisions 26 and 29). It gained the view, a
`*rotor.SharedLoop`, which each library on a loop holds (decisions 27 and 28). It gained rotor tasks
and scheduling groups (decisions 27 and 30), `Message.wake` (decision 29) and cross-core calls
(decision 32). v0.10.0 holds each of them.

Decision 33 splits rotor into a plain `rotor.Loop` and `rotor.Reactor(rotor.Loop)`, which holds each
of those things. Camilo accepted it on 2026-11-10, and v0.11.0 released it on 2026-11-11
(`f2890f5`). Camilo ruled on 2026-11-10 that the package waits for that release (open question 3).
So this record describes the package on the names of v0.11.0 only. Three facts about decision 33
bear on this one:

- Each of its sixteen open questions holds a ruling.
- Camilo ruled its open questions 13 and 16 on 2026-11-11, with the counts of its step 2: form H.
  The host's reactor holds its own state and a `rotor.Loop` by value (`src/rotor/rotor.zig`,
  `Reactor`). The name that a program types, `rotor.Reactor(rotor.Loop)`, did not change.
- A plain `rotor.Loop` calls no record, and has no poller and no view. The package does not run on
  one.

### Decision 33 as v0.11.0 built it

Before its acceptance, this record named rotor's types as decision 33 proposed them. At its
acceptance the session checked each name against v0.11.0, and changed these places:

| this record said | v0.11.0 holds |
|---|---|
| `rotor.Reactor` is proposed and not built, and step 3 put it on `main` | step 2 built it (`bb81c21`), and step 3 moved the reactor's code to `src/reactor/` (`7679de4`) |
| ten of decision 33's sixteen open questions hold no ruling, and questions 13 and 16 are open | each question holds a ruling. Camilo ruled form H for questions 13 and 16 on 2026-11-11 |
| the reactor declares the 43 names of today's `rotor.Loop`, and `tick` is one of its seven calls that wrap | the reactor declares the loop's 28 names and 16 names of its own. Eight of the 28 do the reactor's part: `memory_bytes`, `init`, `deinit`, `submit`, `tick`, `drain`, `assert_empty` and `wait_limit`. `wait_until` fails to compile (decision 33, status; the guide, "Make a reactor") |
| whether the reactor declares `TickError` is open | both reactors declare `TickError` and `DrainError`. The host's reactor also declares `InitError`, `RegisterError`, `ProvideError` and `PostError`. Both declare `AddPollerError`, `ScheduleError`, `ReserveSchedulingGroupError` and `CallError` |
| decision 33 gives no list of names for `rotor.Reactor(Twin)`, so this record asked for one sentence there | `src/reactor/reactor.zig` declares each name that `Fibers` asks for on `reactor.Reactor(Loop)`, which `rotor.Reactor(Twin)` returns. Decision 33 was accepted without the sentence |
| `src/core/dispatch/dispatch.zig` | `src/reactor/dispatch/dispatch.zig` |
| the guide's section "A library that shares a loop" | "A library on a reactor", with the same sentence on who ticks |
| the README's list of decision records stops at decision 24 | it lists each record up to 34 |

What this record says of the port, and of the view's 21 library calls, agrees with v0.11.0. The
package's poller answers `.now` or `.none` alone, so the package needs no `WaitLimit.least`, which
v0.11.0 added.

## The decision, as proposed

This record calls the design below shape (a): the package calls `tick`. Shape (b) is a library on a
`*rotor.SharedLoop` that the program ticks. Camilo did not choose it ("Alternatives it beat").

1. **A package outside rotor gives a `std.Io` on fibers.** Its state is one reactor, on one thread,
   and a pool of fibers. So `io.async`, `future.await`, `future.cancel` and the `Io.Group` calls
   work on that thread.
2. **The package calls `tick`, and the program makes the reactor.** Camilo ruled both (open
   questions 2 and 11). The program hands the package a pointer to its reactor. While the package's
   value lives, the package is the one caller of `tick`.
3. **A fiber is no rotor task.** The package keeps a ready list of its own. A context that blocks
   switches to the next ready context. Only the main context ticks, which is a proposal. A constant
   of 64 bounds the contexts that run between two ticks, by Camilo's ruling (open question 13).
4. **Each operation of a context names a record** in the context's own struct (decision 26). The
   package puts no tag in `user_data`. Camilo ruled it (open question 12).
5. **The package runs 34 of the 109 calls.** The other 75 go to `rest`, a `std.Io` that the program
   hands to `init`. One of the 34, `netLookup`, is a wrapper around the call of `rest`. Each of the
   109 but `futexWake` halts from another thread, by Camilo's rulings (open questions 8 and 15).
6. **The package adds calls of its own** for what the table cannot say. One blocks a context on a
   rotor operation, and one blocks it on a cross-core call. One names how another thread posts a
   wake.
7. **rotor does not depend on the package.** rotor names it in no source file, and adds nothing for
   it without Camilo's word.
8. **Each release of the package pins one Zig version and one rotor tag.** The first release pins
   v0.11.0, by Camilo's ruling.
9. **The package's type is generic over the reactor's type.** Camilo ruled it (open question 14). A
   program types `tejedor.Fibers(rotor.Reactor(rotor.Loop))`. A test can run the same code over the
   reactor of a twin ("Over a twin").

### What the package is, and is not

It is:

- A `std.Io` for one thread. Each fiber of one value runs on the thread that owns the reactor.
- Bounded at `init`. The program hands over one block of memory: a struct for each context, then the
  stacks. The package names no allocator.
- The one caller of `tick` on its reactor, in the program's place. Each other library on that
  reactor holds the view, as decisions 26 to 28 describe.

It is not:

- A thread pool. It starts no thread, and no fiber moves to another thread or another reactor.
- A module of rotor. It is outside rotor's module graph, outside its lint and outside its releases.
- A way to the speed sources through `std.Io`. The table cannot register a buffer or arm a multishot
  receive (decision 1). Code that wants them calls rotor ("`perform`, and a multishot operation").
- A `std.Io` for several threads. Each call that the package runs halts from another thread,
  `futexWake` aside. So does each of the 75 calls that go to `rest`, by Camilo's ruling on question
  15. "How a wake from another thread arrives" lists what another thread may call.
- A library for a program with a tick loop of its own, such as a host that owns the wait (decision
  23).

### What the package holds

Camilo ruled that the program makes the reactor (open question 11). The program keeps it, and `init`
takes a pointer to it, as decision 22's `init` took a `*rotor.Loop`. The package cannot tick through
a view, because a view refuses `tick` at compile time. From `init` until `deinit` returns, each call
of the reactor is in one of three sets:

| call of the reactor | who makes it |
|---|---|
| `tick` | the package alone |
| `drain`, `cancel_all`, `discard_tasks`, `deinit` | the program, after the package's `deinit`. `drain` ticks, and `cancel_all` ends the operation that a context waits for |
| each other call, such as `shared`, `reserve_scheduling_group`, `set_scheduling_group_shares`, `heartbeat`, `statistics`, the buffer calls, `submit`, `cancel` and `post` | the program, as with no package. The package makes five of them too: `submit`, `cancel`, `shared`, `add_poller` and `remove_poller`. It forwards none |

The first two rows hold five of the calls that the view refuses for each library: the five of
decision 28. Nothing in rotor's types refuses a `tick` by the program. So this record proposes a
check. The package keeps the `now_ns` that its last tick left, and it halts at its next tick when
the reactor's `now_ns` differs. Only a tick writes `now_ns` (`src/core/tables/tables.zig`,
`note_clock`, `note_woken`).

The text of Camilo's choice on question 2 said more: the package owns the loop and passes the view
to each other library. His ruling on question 11 took less. The package owns the tick, and the
program takes the view from its own reactor.

### The shape a caller sees

This is a sketch. Camilo ruled the name `tejedor`, and a type that is generic over the reactor's
type (open questions 1 and 14). The text of his choice named
`tejedor.Fibers(rotor.Reactor(rotor.Loop))`. Each name of the sketch but `tejedor` is a proposal,
and Camilo rules each one with the code.

```zig
const std = @import("std");
const rotor = @import("rotor");
const tejedor = @import("tejedor");

const Reactor = rotor.Reactor(rotor.Loop); // decision 33
const Fibers = tejedor.Fibers(Reactor);

fn run(reactor: *Reactor, memory: []align(tejedor.memory_alignment) u8, rest: std.Io) !void {
    var fibers: Fibers = undefined;
    try fibers.init(reactor, memory, rest, &.{});
    defer fibers.deinit(); // no fiber is in use: `await` freed the fiber of `serve`

    const io = fibers.io();
    var served = try io.concurrent(serve, .{io}); // `serve` starts on a fiber
    // The main context blocks here. The package runs the fibers, and ticks the reactor.
    try served.await(io);
}
```

The calls of the package, as a sketch:

```zig
/// `Reactor` is `rotor.Reactor(rotor.Loop)`, or the reactor of a twin ("Over a twin").
pub fn Fibers(comptime Reactor: type) type {
    return struct {
        const This = @This();

        pub const Options = struct {
            /// The fibers, at most `constants.fibers_max`, 4,096.
            count: u16 = 256,
            /// With its guard page: a whole number of 64 KiB, and at least 128 KiB.
            stack_bytes: u32 = 256 * 1024,
            /// Takes each event that a tick returns: an event of an operation that names no
            /// record, and a message that another loop posts. With null, such an event halts.
            event_handler: ?EventHandler = null,
            /// The reactor's id in its registry, for a `futexWake` from another thread.
            loop_id: ?rotor.LoopId = null,
            /// The calls that open and name a socket outside the reactor. The default is
            /// `Sockets.host` on the host's reactor, and `Sockets.unset` on each other one.
            sockets: Sockets = default_sockets,
        };
        pub const InitError = error{ SystemResources, PollersFull };
        pub const PerformError = error{ Canceled, OperationsFull };

        pub fn memory_bytes(options: *const Options) usize;
        /// The most operations that the package holds in flight, for the reactor's `operations`.
        pub fn operations(options: *const Options) u32;
        /// `rest` runs each call that the package does not run. From here until `deinit`, only
        /// the package ticks `reactor`.
        pub fn init(
            fibers: *This,
            reactor: *Reactor,
            memory: []align(memory_alignment) u8,
            rest: std.Io,
            options: *const Options,
        ) InitError!void;
        /// Halts while a fiber is in use.
        pub fn deinit(fibers: *This) void;
        pub fn io(fibers: *This) std.Io;
        /// Submits `operation`, and blocks the context that calls it until its one event.
        pub fn perform(fibers: *This, operation: *const rotor.Operation) PerformError!rotor.Event;
    };
}

pub const EventHandler = struct {
    state: *anyopaque,
    handle: *const fn (state: *anyopaque, event: rotor.Event) void,
};

/// The calls that open, name and close a socket outside the reactor ("Over a twin"). Two values
/// come with the type: `Sockets.host`, and `Sockets.unset`, whose calls halt.
pub const Sockets = struct {
    listen: *const @TypeOf(rotor.sync.listen),
    open_datagram: *const @TypeOf(rotor.sync.open_datagram),
    open_socket: *const @TypeOf(rotor.sync.open_socket),
    local_address: *const @TypeOf(rotor.sync.local_address),
    peer_address: *const @TypeOf(rotor.sync.local_address),
    close_now: *const @TypeOf(rotor.sync.close_now),
};

/// How a thread that does not own the reactor posts the wake of a `futexWake`.
pub const WakePath = struct {
    state: *anyopaque,
    post_wake: *const fn (state: *anyopaque, target: rotor.LoopId) void,

    /// `Poster` has rotor's `post`: `rotor.Remote`, a view, a plain loop, or a twin's form.
    pub fn init(comptime Poster: type, poster: *Poster) WakePath;
};

/// Stores `path` in a `threadlocal` variable. The thread clears it with null before the `deinit`
/// of what `path` names.
pub fn set_wake_path(path: ?WakePath) void;
```

A program names the type once, as the first sketch does, and then types `Fibers.Options` and
`Fibers.operations`. This record writes those names in the same way.

It follows the API rules of the Zig projects. `init` starts the value in place and takes
`*const Options`. Each option has a default, and the type copies what it keeps. `rest` has no
default, by Camilo's ruling, so it is a parameter of `init`. `deinit` ends what `init` starts. The
generic type takes the name of the thing, as `std.ArrayList(T)` does.

`deinit` halts while a fiber is in use, as a loop's `deinit` halts while an operation is in flight.
A future that no caller awaits keeps its fiber. So the program awaits or cancels each future and
each `Io.Group` first. Each of those calls blocks the main context until the std task returns.

#### `perform`, and a multishot operation

`perform` takes an operation that makes one event. A multishot operation gives its record many
events before the final one (decision 26). `perform` returns one `rotor.Event`, so it refuses such
an operation:

- It halts at the call for `accept_multishot`, `receive_group`, `receive_from` and a timer that
  repeats.
- Its record asserts that each event is the final one.

So `perform` reaches the speed sources that make one event, such as a receive into a registered
buffer. Code that wants a multishot receive names a record of its own, as each library does. Such a
record wakes a fiber with `Event.set`, which is a `futexWake` on the reactor's thread.

### Which calls run where

The counts are of the 109 fields of `Io.VTable` at Zig 0.16.0. "Step" is the step of "Build order"
that builds the row. Until its step is built, a row goes to `rest`.

| calls of `Io.VTable` | count | what runs them | step |
|---|---:|---|---:|
| `async`, `concurrent`, `await`, `cancel`, `groupAsync`, `groupConcurrent`, `groupAwait`, `groupCancel`, `recancel`, `swapCancelProtection`, `checkCancel` | 11 | the package. A std task takes a free fiber. With no fiber free, `async` and `groupAsync` run the function on the caller's stack, which std allows. `concurrent` and `groupConcurrent` then return `ConcurrencyUnavailable` | 1 |
| `futexWait`, `futexWaitUncancelable`, `futexWake` | 3 | the package: one list of the contexts that wait. A timeout is one `timer` operation. `futexWake` is the one call that another thread may make | 1, and 2 for another thread |
| `now` for the `awake` and `boot` clocks, `sleep` | 2 | `now_ns` of the reactor, and one `timer` operation | 1 |
| `netLookup` | 1 | the package, as a wrapper around the call of `rest` ("Why `netLookup` is a wrapper") | 1 |
| `netListenIp`, `netBindIp` | 2 | `rotor.sync.listen` and `rotor.sync.open_datagram`, at once, on the caller's stack | 4 |
| `netAccept`, `netConnectIp`, `netRead`, `netWrite`, `netSend`, `netShutdown` | 6 | one operation each: `accept`, `connect`, `receive`, `send`, `send_to`, `shutdown` | 4 |
| `netClose`, `fileClose` | 2 | one `close` operation, which blocks the context, in each place. rotor's `close` first cancels each operation in flight for the descriptor (decision 5, rule 6). `rotor.sync.close_now` cancels none, so the package does not use it for these calls | 4 |
| `operate`, `batchAwaitAsync`, `batchAwaitConcurrent`, `batchCancel` | 4 | the package, for `net_receive`. When `batchAwaitConcurrent` holds one `net_receive`, its `Timeout` becomes the operation's `timeout_ns`, and the package runs no timer for it (open question 19). The other three kinds of `Io.Operation` go to `rest` | 6 |
| `fileReadPositional`, `fileWritePositional`, `fileSync` | 3 | `read`, `write`, `fsync`, under the reactor's file policy (decision 18). A file operation that the reactor refuses goes to `rest` | 6 |
| `crashHandler`, the 26 directory calls, 24 file calls, the 15 process calls, `clockResolution`, `random`, `randomSecure`, 6 network calls, and `now` for the other clocks | 75 | `rest` | none |

The first nine rows hold 34 calls: the 33 that decision 22 ran on the loop, and `netLookup`. The
package runs 17 of them after step 1, 27 after step 4, and all 34 after step 6. `fileClose` was in
decision 22's step for files. Here it is in step 4 with `netClose`, because no file policy refuses a
close, and `std.Io.failing` halts on each close.

#### Why `netLookup` is a wrapper

`netLookup` takes a `Queue` of the caller. No other call that goes to `rest` takes a std object that
a fiber can wait on. The connect by host name of std starts the lookup with `io.async`. Then it
waits on that queue with the same `io` (`HostName.connectMany`, lines 343 to 352). So the fiber that
waits is on the package's futex list. `rest` cannot wake it:

- `std.Io.Threaded` fills and closes the queue with its own `io` (`Threaded.zig`, lines 13472 and
  13502 to 13520). So `Queue` wakes the getter through `Threaded`'s futex (`Io.zig`, line 1989). The
  package's list never sees that wake.
- `std.Io.failing` returns `error.NetworkDown` and does not close the queue (`Io.zig`, lines 3430 to
  3436). std's rule is that the call closes it, also on an error (`HostName.zig`, line 155).

With each one the fiber never resumes. Decision 22's code had the same path. So the package runs
`netLookup` itself:

1. It makes a queue of its own on the caller's stack, with room for 32 results. That is the room
   that `connectMany` gives its own queue. The rule of std is that a lookup does not block on a
   queue of 16 or more (`HostName.zig`, line 153).
2. It calls `netLookup` of `rest` with that queue. No fiber waits on it, so `rest` wakes nothing.
3. It moves each result to the caller's queue with the package's own `io`.
4. It closes the caller's queue with the package's own `io`, also when `rest` returned an error.
   Then it returns what `rest` returned.

It costs two things. The caller gets no result before the whole lookup ends. With a `Threaded`, the
lookup holds the loop's thread for its length, as each call of `rest` that sleeps in the kernel.

#### What `rest` is

`rest` is a `std.Io` that the program hands to `init`, as in decision 22. It has no default, by
Camilo's ruling (open question 7). The package starts no thread with either value below.

The forwarders are built from `Io.VTable` at comptime, as `adapter_rest.zig` built them. A forwarder
of that file has no owner check. It reads only `rest`, which no call changes after `init`. Camilo
ruled one change: each forwarder checks the owner, as each call that the package runs does,
`futexWake` aside (open question 15). Then `io.random` and `io.randomSecure` halt from another
thread, though std marks them safe there. A program also does not make the package's `io` its
`debug_io`.

**A `std.Io.Threaded` of the program's.** A call then runs on the thread that makes it, or on
threads that the program's value owns (decision 22, `adapter.zig`). A call that sleeps in the kernel
there holds the reactor's thread for its length. The stall count of decision 28 sees it.

**`std.Io.failing`** (`std/Io.zig`, lines 2512 to 2638), for a program that wants no thread. std
describes it as a system that supports no `Io` operation. These rows come from the function of each
of the 75 calls:

| what `failing` does | calls | which |
|---|---:|---|
| returns an error | 54 | each call that is in no row below |
| halts, because its function is `unreachable` | 14 | `dirClose`, `fileIsTty`, `fileEnableAnsiEscapeCodes`, `fileSupportsAnsiEscapeCodes`, `fileUnlock`, `fileMemoryMapDestroy`, `fileMemoryMapSetLength`, `fileMemoryMapRead`, `fileMemoryMapWrite`, `lockStderr`, `unlockStderr`, `childWait`, `childKill`, `netInterfaceName` |
| returns with no error, and does nothing | 6 | `crashHandler`, `dirSetTimestamps`, `fileSetTimestamps`, `fileDowngradeLock`, `dirRead`, which reports no entry, and `tryLockStderr`, which answers null |
| returns with no error, and its answer is not true | 1 | `random` fills its buffer with 0 (lines 3297 to 3300) |

Three more facts hold with `failing`:

- `now` for the other clocks answers time 0, with no error (lines 3308 to 3312). A `sleep` or a
  futex wait to a deadline on the `real` clock then computes its wait from time 0.
- So a program that hands over `failing` uses none of those clocks, no `random`, and no call of the
  second row.
- Until its step is built, a call of the package goes to `rest` too. `failing` halts on five of
  them: `netClose` and `fileClose` before step 4, and the three batch calls before step 6.

### How one call that blocks runs

Each context has a struct, `Fiber`, in the caller's memory, as in decision 22's code. It holds the
context's saved registers, its place on a list, and one `rotor.Completion`. The example is
`io.sleep` on a fiber F.

1. F calls `io.sleep`. The table calls the package's function on F's stack.
2. The function is a cancel point. It returns `error.Canceled` when a cancel waits for F.
3. It builds `rotor.Operation.timer(0, after_ns, 0)`. It names F's record with
   `rotor.Completion.mark(&fiber.completion, operation)`, and calls `reactor.submit`. It keeps the
   handle in `Fiber`.
4. It marks F blocked, and switches to the first context on the ready list. When that list is empty,
   it switches to the main context, which ticks.
5. A tick takes the timer's final event, and calls F's record with it (decision 26).
6. The record's function stores the result in `Fiber`, and puts F at the end of the ready list. It
   does no other work.
7. The tick returns to the main context, which switches to the first ready context.
8. When F's turn comes, F goes on inside `io.sleep`, which returns.

So a call that blocks costs one switch away and one switch back, the calls through the table, and
one record. It costs no rotor task. "What it costs" gives the rows.

### The ready list and the tick

The ready list holds each context that can run, in the order in which each became ready. Its code
starts from decision 22's `adapter_scheduler.zig`. Four rules differ from that code, because a tick
now calls callbacks. Camilo ruled the second and the fourth. The first and the third are proposals.

**1. Only the main context calls `tick`.** A fiber that needs a tick switches to the main context,
which blocks while a fiber runs. Decision 22's code ticked on the stack of the context that blocked.
With that rule and callbacks, two things go wrong:

- Each callback of another library runs on a fiber's stack, inside its `stack_bytes`.
- A fiber of an `Io.Group` whose function returned ticks on its own stack, after it went on the free
  list (`adapter_tasks.zig`, `end_member`; `adapter_scheduler.zig`, `leave`). A callback in that
  tick can start a std task on the same stack.

With this record's rule, each callback runs on the thread's own stack, as in a program that ticks.
The rule costs one more switch for each tick.

**2. A named limit bounds the contexts that run between two ticks.** After
`resumes_between_ticks_max` switches to a context, the next context that blocks or ends switches to
the main context. The main context then ticks with a wait of 0. Camilo ruled a constant of 64 (open
question 13), which is the value of rotor's `tasks_per_tick_max`. Decision 22's code had no such
limit. Without it, two fibers that wake each other keep the thread from each tick. Then no I/O
arrives, and no callback of another library runs. The limit does not stop one fiber that computes
and never blocks.

**3. The package chooses the wait of each tick.** With an empty ready list, the wait is
`rotor.constants.wait_ns_max`, 10 s. The reactor ends that wait earlier at an event, a timer, a
poller's limit, a message or a wake. At the limit of rule 2, the wait is 0. While a context waits
for a free slot, the wait is 0 too ("When the reactor is full").

**4. The package does not halt when nothing is in flight.** Decision 22's code halted when each
context waited and no operation was in flight. The package cannot know that nothing can wake a
context. Another library can, and so can a message from another loop, or a `futexWake` from another
thread. So the main context ticks again, and the thread sleeps in the kernel. A deadlock of fibers
is then silent. Camilo ruled no halt, with that cost (open question 16).

Two facts follow. A wake between two contexts costs no tick: the context that waits goes on the
ready list. No fiber runs while the main context runs: a new fiber first runs when the main context
blocks.

**What decision 28's stall count sees.** A turn runs from one stamp of a tick to the first stamp of
the next tick. Here one turn holds the callbacks of the tick that ended, then each context that
runs, then the pollers of the next tick. rotor counts a stall when those together last
`stall_turn_ns` or more, and the count is exact. A stall's `callbacks` counts the records, the rotor
tasks and the pollers of the turn (`src/core/stall.zig`, `Turn.callbacks`). No fiber is one of them.
The package's poller is one of them in each turn, because each tick calls it. So:

- No turn reads `callbacks == 0`.
- A turn of fibers alone reads 1, when no other library added a poller. The stall then names the
  package's poller, and no function of a std task (`stall.zig`, `name_of_one`).
- A turn with one record reads 2, and the stall names nothing. So does a turn of fibers alone when
  another library added a poller.
- A watch on the heartbeat reads a null name while a fiber runs, as for code outside a callback.

With the default `stall_turn_ns` of 10 ms, 64 fibers of about 156 µs each fill one turn, by
arithmetic.

### Where a call comes from

A call of the `io` comes from a fiber, from the main context or from a callback. Each is on the
reactor's thread.

**The main context.** The program's own code may make each call of the `io`, and each call of the
package. A call that blocks there blocks the main context. The package then runs the ready contexts,
and ticks by the rules above, until the call can return. Three facts hold there:

- No future names the main context, so no cancel reaches it.
- With no fiber free, `async` runs the function there, and each of its calls may block.
- `now_ns` is 0 until a tick reads the clock. So before its first operation the package ticks once
  with a wait of 0, when the reactor read no clock yet. Decision 22's code did the same.

**A callback.** A record, a poller or a rotor task of another library runs inside a tick, on the
thread's own stack. It cannot block: its wait would need a tick inside a tick, which halts (decision
26). The event handler runs after the tick returns. It cannot block either, because the main context
is still blocked in its own call. Each may hold the same `io`. So the package sets a flag from the
start of each tick until the event handler took that tick's last event. While the flag is set, these
rules apply:

| call in a callback | result |
|---|---|
| `concurrent`, `Group.concurrent` | starts a fiber, which runs after the tick. With no fiber free, `ConcurrencyUnavailable` |
| `async`, `Group.async` | starts a fiber. With no fiber free, std's rule leaves one choice: the function runs on the callback's stack. The first call of that function that must block halts |
| `await` or `cancel` of a future whose fiber is not active, and `Group.await` or `Group.cancel` with no active member | returns, and frees the future's fiber |
| `futexWake`, `checkCancel`, `netListenIp`, `netBindIp`, `now` | work, because none blocks |
| `netClose`, `fileClose` | halts, as each call that must block. A close is one `close` operation and its final event. `rotor.sync.close_now` is no substitute: it is for a descriptor with no operation in flight |
| `netLookup` | calls `rest`, and works while the caller's queue has room for each result. A put that must block halts |
| each call that must block: `await` of an active fiber's future, `Group.await` with an active member, `sleep`, `futexWait`, a network operation, a close, `perform`, `call` | halts, with a message that states the rule: a callback starts a fiber for work that blocks |

A close, a `sleep` and a network operation halt on each run, so a test finds them. Other halts
depend on state. `Mutex.lock` waits only while another holder has the lock, and `Event.wait` only
while the event is unset. `Queue.put` waits only on a full queue, and `Queue.get` only on an empty
one. So a record that hands work to a fiber through a `Queue` halts the process when the queue fills
under load. A test can pass for a long time first. Two calls are safe in a callback: `Event.set`,
and `Queue.put` with a least count of 0, which does not wait (`std/Io.zig`, lines 2006 and 2007).

A std task whose arguments or result are larger than a fiber holds follows the rules for "no fiber
free", in each place.

### Other libraries on the same reactor

**The view.** The program calls `reactor.shared()`, and hands the view to each library, as the guide
says. A library needs no change for the package. Each of its callbacks runs inside a tick that the
package makes, so it waits for at most `resumes_between_ticks_max` contexts. No share of decision 30
divides the thread between the fibers and the rotor tasks. That limit and rotor's
`tasks_per_tick_max` do.

**An event with no record, and a message.** `tick` returns both to its caller, which is the package
(decision 26). Each operation of the package names a record. So each event that `tick` returns
belongs to the program, or to a library that named no record. The package hands each one to the
event handler, in the order of the batch, before it runs a context. With no event handler, such an
event halts, as in decision 22's code. A `Message.wake` makes no event.

**The package's poller.** The package adds one `rotor.Poller` at `init`, and removes it at `deinit`.
The poller has two jobs:

- It keeps a tick from its wait while a context is ready. A poller of another library can call
  `futexWake`, or start a std task. The reactor does not see the ready list, so without this job
  that tick waits with a context ready. The package's poller answers `.now` when the ready list is
  not empty, and `.none` otherwise.
- It reads the flag of a wake from another thread ("How a wake from another thread arrives").

The reactor calls its pollers in the order in which the libraries added them (decision 26). The
package's poller must run after each other poller. So before each tick that can wait, the package
removes its poller and adds it again, which puts it last. After the last poller, a tick calls no
code of a library before its wait (`src/reactor/dispatch/dispatch.zig`, `Dispatch.begin`).

### When the reactor is full

`Fibers.operations` states the most operations that the package holds in flight: one for each fiber,
and one for the main context. Step 6 adds one for each socket that receives datagrams. The program
adds that count to its reactor's `operations`, as the guide asks for each library. Another library
can still fill the reactor.

`submit` takes no operation when no slot is free. Decision 22's code then ticked until an operation
ended, in a loop with no bound. In the package, a context that finds the reactor full blocks until
the next tick returns, and then submits again. The main context makes that tick with a wait of 0. So
a try takes each event that is ready, and no time in the kernel. A context tries `submit_tries_max`
times: 8, a prior with no measurement behind it. At most `resumes_between_ticks_max` contexts run
between two tries. So the tries end after 8 ticks that do not wait, and no clock bounds them.

| call | with a full reactor |
|---|---|
| `netAccept`, `netConnectIp`, `netRead`, `netWrite`, `netSend`, `netShutdown` | after the last try, returns `error.SystemResources`, which the error set of each one holds |
| `perform` | after the last try, returns `error.OperationsFull` |
| `sleep`, a futex wait with a timeout, `netClose` and `fileClose` | after the last try, halts. The message states what `Fibers.operations` asks for. None of them has an error for it: a `sleep` and a futex wait have `Canceled` alone, and a close returns nothing |
| the three file calls of step 6 | go to `rest` at once, as when the reactor refuses a file operation |

A close does not fall back to `rotor.sync.close_now`. That call is for a descriptor with no
operation in flight (`src/kqueue/kqueue_sync_socket.zig`, and the same in `src/linux_shared/`). A
fiber can wait in `netRead` on the socket that another context closes. In step 6 each datagram
socket also keeps one receive in flight. A plain close cancels neither, and rotor's `close`
operation cancels both first (decision 5, rule 6).

Each other limit has a name in the package's `constants.zig`, or is one of rotor's:

| limit | at the limit |
|---|---|
| `count` fibers, at most `fibers_max`, 4,096 | `concurrent` and `Group.concurrent` return `ConcurrencyUnavailable`. `async` and `Group.async` run the function on the caller's stack |
| the arguments and the result of a std task: 1,024 B and 512 B, as in decision 22's code | the same as with no fiber free |
| `resumes_between_ticks_max`, 64 | the main context ticks with a wait of 0 |
| the events that one tick returns: decision 22's `events_per_tick`, 64 | the reactor hands over the other events in the next tick, as for each caller of `tick` |
| the reactor's pollers: `pollers_max`, 8 | `init` returns `PollersFull` |
| the calls out to one loop, and a ring's share of posts (decision 32) | `call` returns `CallsFull` or `MailboxFull` |
| the ready list and the futex list | none: each holds a context at most once, so `count + 1` bounds it |

### How a wake from another thread arrives

A thread that does not own the reactor may call `futexWake` for a context that waits. Camilo ruled
the calls that another thread may make: "only `futexWake`" (open question 8). In the second round he
ruled that each of the 75 calls that go to `rest` checks the owner too (open question 15). Of std's
types, such a thread may use only a part:

| a call of std, from another thread | what it calls | result |
|---|---|---|
| `Event.set`, `Condition.signal`, `Condition.broadcast`, `Mutex.unlock` | `futexWake` alone (`Io.zig`, lines 1855, 1726, 1745 and 1641) | works |
| `Event.isSet`, `Mutex.tryLock` | no call of the table | works |
| `Mutex.lock`, `Condition.wait`, `Event.wait` | `futexWait`, when the call must wait | halts then. `Mutex.lock` waits only while another holder has the lock (lines 1602 to 1618), so the halt depends on when each thread runs |
| `Queue.put`, `Queue.get`, `Queue.close` | a lock of the queue's `Mutex` first (lines 1941, 2045 and 1919) | the same |

So a thread hands a result to a fiber with `Event.set`, after it stores the result. It shares no
`Mutex` and no `Queue` with a fiber. A test can pass for a long time before a fiber holds the lock
at the wrong moment. A second `io` on the other thread does not help: its futex is its own. How the
wake runs:

1. The program turns it on: `Options.loop_id` holds the reactor's id in its registry.
2. Each other thread names how it posts, once. It calls `set_wake_path` with a `WakePath` of its own
   `rotor.Remote`, of the view of its own reactor, or of its own plain loop.
3. `futexWake` on that thread reads and writes no list. It swaps a flag in the `Fibers` value to
   true, with release order. When the flag was false, it posts `rotor.Message.wake` to `loop_id`.
4. The reactor drops the wake. A reactor that sleeps in `tick` wakes. Its table of pollers holds a
   poller, so its next tick does not wait before that poller runs (decision 29).
5. The package's poller swaps the flag to false, with acquire order. When it was true, the poller
   ends the futex wait of each context on the list, as a `futexWake` on the reactor's thread does.
   Each such context goes on the ready list, so the poller answers `.now`.
6. Each such context reads its futex word again. std allows a wake with no cause (`std/Io.zig`, line
   1543).

The package calls `tick` itself, and it still needs the poller for this path. A wake stores `.now`
only while the table of pollers holds one (decision 29). With no poller, a wake that a tick takes
before its wait does not stop that wait. The context then waits for up to `wait_ns_max`.

One wake from another thread costs more than one wake on the reactor's thread. It makes each context
on the futex list ready: at most `count + 1`. Each of them that waits with a timeout cancels its
timer, and arms a new one when it waits again. `Event.waitTimeout` returns `error.Timeout` for a
wake with no cause (`std/Io.zig`, lines 1824 to 1846). So each such wait on the reactor ends early,
with that error, at each wake from another thread.

`MailboxFull` on the wake is safe to drop, as decision 29 says of each wake. A thread that named no
path halts in `futexWake`, which has no parameter for a `Remote`. So a thread that holds no `Remote`
and no loop has no way to post, as on 2026-11-05. A worker of the program's `std.Io.Threaded` is
such a thread. Decision 29 rejected a second call across threads, and this record asks rotor for
nothing here.

### How cancel works

`future.cancel(io)` marks the fiber of the std task, acts on the wait of that fiber, and then blocks
as `await` does. The next cancel point of the std task returns `error.Canceled` once, as std asks.

| the fiber waits for | a cancel does | the wait ends |
|---|---|---|
| an operation: a `sleep` with a time, a network call, `perform` | `reactor.cancel(handle)`, which is a request (decision 5, rule 2) | at the operation's final event: `Canceled` when nothing moved, or the bytes that moved |
| a futex with no timeout, a `sleep` with no time, or a free slot | puts the fiber on the ready list | when the fiber next runs, with `error.Canceled` |
| a futex with a timeout | takes the fiber off the list, and cancels its timer | at the timer's final event, so no event of the package comes after its wait |
| the members of an `Io.Group`, in `Group.await` | puts the fiber on the ready list. `Group.await` then asks each member to cancel, and blocks again with no cancel point | after the last member returns. Only then `Group.await` returns `error.Canceled` |
| another future, in `await` | nothing: `await` is no cancel point | when that future ends |
| a cross-core call | nothing: the target owns the call record until it answers (decision 32) | at `finish`. The next cancel point returns `error.Canceled` |

The row for an `Io.Group` is std's rule (`std/Io.zig`, lines 1272 to 1275), and decision 22's
`group_await` did the same. A member writes the `Io.Group`, so the caller must not leave before the
last member returns. `Group.cancel` asks each member to cancel and blocks until the last one
returns. It is no cancel point.

So each operation of a context still ends with exactly one final event, and the context does not go
on before it (decision 5).

## What the package needs from rotor

Camilo ruled that the package waits for v0.11.0. So the rows below check each name against the code
of that tag (`f2890f5`). No row leaves a question open.

| the package names | where v0.11.0 gives it |
|---|---|
| `rotor.Reactor(rotor.Loop)`, which the program makes | `src/rotor/rotor.zig`, `Reactor`: the one export for the reactor. By form H it holds its own state and a `rotor.Loop` by value |
| on the reactor: `tick`, `submit`, `cancel`, `now_ns`, `shared`, `add_poller`, `remove_poller` | `src/rotor/rotor.zig` and `src/reactor/reactor.zig` declare each, on the host's reactor and on the generic one. `tick` and `submit` are two of the eight calls that do the reactor's part |
| the error of `tick` | `TickError`, which both reactors declare. The package reads the error from the call, or names `Reactor.TickError` |
| the reactor's view, `rotor.SharedLoop` on the host, for `Service.send` | `reactor.shared()` gives it, with 21 library calls and nine refused calls |
| `rotor.Completion.mark(&record, operation)` | `src/reactor/reactor.zig`. It replaced `Operation.completion` (decision 33, open question 5) |
| `rotor.Completion` and `rotor.Poller`, each with `init`, and `rotor.WaitLimit` | `src/rotor/rotor.zig`: the same names. `Completion` and `Poller` are the reactor's, and `WaitLimit` is the core's |
| `rotor.Operation`, with `timer`, `accept`, `connect`, `receive`, `send`, `send_to`, `shutdown`, `close`, `read`, `write`, `fsync`, `receive_from`, and its `kind`, which `perform` reads | the core's (`src/core/operation.zig`) |
| `rotor.Event`, with `is_final`, `rotor.Handle`, `rotor.Code`, `rotor.Error`, `rotor.Address`, `rotor.Descriptor` | the core's: the operations and their completions stay in the core |
| `rotor.Message.wake`, `rotor.LoopId`, and `post` on a `rotor.Remote`, on a view or on a plain `rotor.Loop`, through `WakePath.init` | the core's, and each reactor's `post` |
| `rotor.sync`: `listen`, `open_socket`, `open_datagram`, `local_address`, `close_now`, and the types in their forms, for `Sockets` | the backend's, through `src/rotor/rotor.zig`. Decision 33 moved no I/O out of the core |
| `rotor.Service`, `rotor.CallRecord`, `rotor.CallResult`, `rotor.CallOptions`, `rotor.CallError` | `src/rotor/rotor.zig`: the same names. `Service` and `CallRecord` are those of the host's reactor |
| for datagrams, in step 6: `reserve_buffer_group`, `provide_datagram_buffers`, `datagram`, `give_back_buffer`, `release_buffers` | the core's, and each reactor declares them too |
| `rotor.constants`: `timeout_ns_max`, `wait_ns_max` | `src/core/constants.zig`. Neither moved to `src/reactor/constants.zig` |

So shape (a) needs no name that v0.11.0 does not give. It names more of the reactor than shape (b)
did: the reactor's type, and its `tick`.

### What rotor does not give

Each row is an ask-before item. rotor adds none of them for the package without Camilo's word. The
column "without it" says what the package does, so no row stops a step. "rotor" in the second column
is rotor at v0.11.0.

| the package would use | rotor | without it | cost to rotor |
|---|---|---|---|
| a send and a receive of several buffers, for `netRead` and `netWrite` | `receive` and `send` take one buffer | one buffer for each call. std's `Reader` and `Writer` take the short count and call again (decision 22, step 2) | a change to the core's `Operation`, in a decision record of its own. Decision 22, open question 4, deferred it until the numbers show the cost |
| the peer's address of an accepted socket | `accept` reports the descriptor alone. `sync` has `local_address` and no call for the peer | `Sockets.host` calls `getpeername`, one system call for each accept | one more name on `sync`, on each backend. The test of its 24 names changes |
| the options `ip6_only` and `allow_broadcast` at a bind | `sync.open_datagram` sets neither | the bind answers `OptionUnsupported`, as in decision 22 | fields in `DatagramOptions`, on each backend |
| a wake from a thread that holds no `Remote` and no loop | none. Decision 29 rejected a second call across threads | the program gives each such thread a `Remote`: one id of the registry each, of `loops_max` (256) | an amendment of non-negotiable 4, decision 4 and the wake model. This record does not ask for it |
| a place after each other poller, or a call that keeps the tick that runs from its wait | the reactor calls its pollers in the order in which the libraries added them. A poller's answer and a queued rotor task keep a tick from its wait (`src/reactor/dispatch/dispatch.zig`, `Dispatch.begin`). So do an operation that waits for the flush, a result that waits for its hand-over, and a timer that is due (`src/core/tables/tables_deadline.zig`, `wait_bound`) | the package removes its poller and adds it again before each tick that can wait. A timer of 0 ns for each such wake is the other way. It takes a slot, which a full reactor does not have, and it makes one more final event. So this record prefers the move | one more call. Decision 29, item 2, rejected a second way to say "do not block". This record does not ask for it |
| the name of a fiber's function in a stall and in a watch | the reactor writes the name of each callback on the heartbeat's line, through the port. Decision 33 keeps that writer out of the API ("The port") | a stall of fibers names the package's poller at most, and a watch reads a null name | a public call that writes a name on the line. This record does not ask for it |
| a refusal of a second caller of `tick` | none: `tick` checks its thread, and not its caller | the package's check of `now_ns` halts at the package's next tick | this record does not ask for it |
| the type of a reactor's loop, from the reactor's type | neither reactor declares a name for it (`src/reactor/reactor.zig`, `src/rotor/rotor.zig`) | a twin's sockets come through `Options.sockets`, at run time ("Over a twin") | one declaration on each reactor type, and one more name in the test of the reactor's names. Camilo ruled the option on 2026-11-11 (open question 17), so rotor gives none |
| a row of its own in the echo comparison | `bench/echo/echo_runner_setup.zig` holds a fixed list of candidates. rotor's package holds no `bench/` (`build.zig.zon`, `.paths`) | the package builds rotor's bench programs from a checkout at the pinned tag. It drives `echo_client` itself, with the runner's rules | an option of the runner that adds one candidate by name and path. rotor still names no package |

## Over a twin

Camilo ruled a generic type, so that the package can run over a twin of the reactor (open question
14). A test then types `tejedor.Fibers(rotor.Reactor(Twin))`. This section says what
`Fibers(Reactor)` asks of a `Reactor` type, and what it asks beyond that type. Each part is a
proposal: the ruling names the generic type, and no part of this section.

### What `Fibers(Reactor)` asks of the reactor's type

`Fibers` checks `Reactor` at comptime, before it makes a type. One compile error names each
declaration that `Reactor` lacks, as decision 33's check of the port does. This is the whole list:

| `Fibers(Reactor)` asks for | its form | where v0.11.0 gives it to a twin's reactor |
|---|---|---|
| `tick` | `(reactor: *Reactor, events: []rotor.Event, wait_ns: u64) Reactor.TickError!u32`. `Fibers` reads the error set from the call | `src/reactor/reactor.zig`: the reactor's `tick`, over the loop's `tick_backend`. `TickError` is the error set of `tick_backend` |
| `submit`, `cancel`, `now_ns` | the forms of the core's surface | `src/reactor/reactor.zig`: each forwards to the loop inside, and `submit` also counts the operations that name a record |
| `add_poller`, `remove_poller`, `shared` | `shared` returns `*Reactor.SharedLoop` | `src/reactor/reactor.zig`: three of the 16 names of the reactor |
| `SharedLoop` | the reactor's view | `src/reactor/reactor.zig`: each reactor type declares its own |
| for `call` alone: a `Service` of that reactor | its `send` takes `*Reactor.SharedLoop` | `src/reactor/reactor.zig`: each reactor type declares `Service` and `CallRecord` over its own view |

`Fibers` asks for no type of a twin's own. Over a twin too, the operations, the events, the handles,
the records and the pollers are rotor's types. Decision 33, "The port", holds a twin to the same
rule. Each type of the port is a Zig type, a type that the public module exports, or the twin's own.

Decision 33's text lists the names of `rotor.Reactor(rotor.Loop)` alone. The code gives the list
for a twin. `rotor.Reactor(Twin)` returns `reactor.Reactor(Twin)`, and `src/reactor/reactor.zig`
declares each name of the table on that type. It also declares `TickError`, `DrainError` and the
error sets of the reactor's own calls.

### What it asks of a twin's behaviour

- **Only `tick` moves `now_ns`, and `now_ns` is above 0 after the first tick.** The guide defines
  `now_ns` as the clock "as the last `tick` read it". The package's check for a second caller of
  `tick` compares it ("What the package holds"). So a twin with a clock of its own moves that clock
  inside `tick`.
- **The rules of the surface.** A timer runs from `now_ns` (decision 14, rule 6). A `close`
  operation first cancels each operation in flight for its descriptor, and each operation ends with
  one final event (decision 5). Each event carries the `user_data` and the `dispatched` bit of its
  operation (decision 33, "The line"). Decision 10 holds each twin to those rules already.

### Sockets outside the reactor

Four calls of the package open or name a socket with no operation: `netListenIp`, `netBindIp`,
`netConnectIp` and `netAccept`. On the host they call `rotor.sync` and `getpeername`, which are
system calls. A twin has no kernel, and its descriptors are numbers of its own. So the package takes
those calls from the program, in `Options.sockets`:

- `Sockets` holds six functions: `listen`, `open_datagram`, `open_socket`, `local_address`,
  `peer_address` and `close_now`. Each has the form of the `rotor.sync` call of its name, and
  `peer_address` has the form of `local_address`. A twin can write each form, because the public
  module exports each type in it.
- On the host's reactor the default is `Sockets.host`: `rotor.sync`, and `getpeername`.
- On each other reactor the default is `Sockets.unset`, and each of its calls halts. A real
  descriptor must not reach a twin, so a twin's program names the twin's sockets.
- `close_now` is only for a socket that the package opened and that holds no operation in flight.
  `netClose` and `fileClose` stay `close` operations, on a twin's reactor too.

It costs one indirect call (C5) in each of the four calls, on the host too. Open question 17 asked
whether those calls come at comptime, from the twin's loop type. Camilo ruled the option on
2026-11-11.

### A wake from another thread

`WakePath` names no type of rotor. It holds a pointer and one function, which posts
`rotor.Message.wake`. `WakePath.init(Poster, poster)` builds it at comptime for a type that has
rotor's `post`: `rotor.Remote`, a view, a plain loop, or a twin's form of one of them. So the
package needs no name for a twin's `Remote` or for its plain loop. It costs one indirect call (C5)
for each wake from another thread.

### What does not come from the reactor

Three things of the package do not come from the reactor. The first is the fibers' stacks, with the
context switch and `mprotect` for the guard pages. The second is the owner check, which compares the
address of a `threadlocal` variable. Each is the same on each run. The third is `rest`, which the
program hands over, and which takes each call from the reactor's thread (open question 15).

So a run of the package replays when three things hold: the reactor is a twin's, `rest` replays, and
no other thread calls `futexWake`. Open question 18 asked whether the package keeps a small twin for
its own tests. Camilo ruled yes on 2026-11-11.

## A Future for a cross-core call

A context can wait for the reply of a call of decision 32. It needs a call of the package's own,
because `std.Io`'s table has no such call. A sketch, as a method of the type that `Fibers` returns:

```zig
/// Sends `request` to `target` through `service`, and blocks the context that calls it until the
/// call's `finish` runs. It is no cancel point while the call is out.
pub fn call(
    fibers: *This,
    comptime Service: type,
    service: *Service,
    target: rotor.LoopId,
    request: *const @FieldType(Service.Call, "request"),
    options: rotor.CallOptions,
) (rotor.CallError || error{ Expired, TargetStopped })!@FieldType(Service.Call, "reply");
```

`Service` is a type that the reactor's `Service` returns, which is `rotor.Service` on the host. It
declares `Call`, its `CallRecord`, whose fields `request` and `reply` give the two types.

How it runs:

1. The function holds a `Service.Call` in a struct on the context's own stack. That stack does not
   move while the context waits.
2. It calls `service.send(shared, target, &record, request, options)`, with the view that
   `reactor.shared()` gives. `CallsFull`, `MailboxFull` and `LoopNotFound` come back as error
   values, and then nothing waits.
3. The context blocks.
4. The call record's `finish` runs as a rotor task on the caller's reactor, in the call's named
   scheduling group (decision 32). It copies the result, and puts the context on the ready list. So
   the context runs after that tick returns, and no second tick passes first.
5. The function returns the reply by value, or `error.Expired` or `error.TargetStopped`.

It needs nothing new from rotor. The program gives each call a named scheduling group, as each call
of decision 32 needs. The target owns the call record until it answers, and decision 32 rejected
`cancel_call`, so a cancel waits for `finish`. `call` blocks, so a callback cannot make it.

`io.async` of a function that calls `call` gives a `std.Io.Future` for the reply, at the cost of one
fiber for each call in flight. Decision 32 rejected a future for the memory of each call. Here the
memory is the fiber's stack, which the caller handed over at `init`.

On the target, the function of a service runs as a rotor task, so it is a callback. When it answers
`.later`, it may start a fiber for the work with `concurrent`. That fiber calls
`record.answer(shared, &reply)` once, on the target's thread, as decision 32 asks.

## What it costs

### Each call that blocks

Each instruction count is a prior, by arithmetic over rows that count other workloads.

| part | count | cost | source |
|---|---:|---|---|
| a fiber switch | 2: one away, and one back | not measured. No row of `docs/costs.md` holds it | row C26 went with its probe (`85d5e67`) |
| a call through `std.Io`'s table | 1 or 2 | C5: 1.50 ns on `mac`, 1.53 on `orbstack`, 1.34 on `github` | `docs/costs.md` |
| the owner check of each call that the package runs | 1 | C21: 1.55 ns on `mac`, 0.93 on `orbstack`, 1.00 on `github` | `docs/costs.md` |
| the record, which the tick calls for the final event | 1 | at most 117 to 142 instructions: the `record` row less the `timer` row, in each section. The `timer` row runs the fast tick, and the `record` row runs the dispatched tick (`bench/work/work.zig`). The package's poller makes each tick a dispatched one in any case | `bench/baseline/work.txt` |
| the submit and the kernel's work for the operation | 1 | as for each operation of a library | none |

A switch from one fiber to the next is the switch away of the first and the switch back of the
second. So `k` fibers that run between two ticks make `k + 1` switches. Each tick has three more
costs:

| cost of each tick | prior | source |
|---|---|---|
| the switch to the main context. A fiber that is the only ready context switches there and back for each call that blocks, where decision 22's code made no switch | not measured | row C26 went with its probe |
| the package's poller: one indirect call and a load of the flag in each tick. Before each tick that can wait, the package moves it to the end of the table of pollers | C5 for the call. No row counts the rest. The `poller` row counts a whole tick with one poller that reports no work: 505 to 634 instructions | `docs/costs.md`, `bench/baseline/work.txt` |
| a tick with a wait of 0 after each 64 switches, while contexts stay ready | the backend's call: C7 is 300 ns on `github`, and C10 is 294 ns on `mac`. That is at most about 5 ns for each switch, by arithmetic, for the kernel's call alone | `docs/costs.md` |

A wake from another thread has two more costs, and no row counts either. It makes each context on
the futex list ready, and it ends each `Event.waitTimeout` there with `error.Timeout` ("How a wake
from another thread arrives").

Decision 22's code paid for no record and no poller. So the prior is that the package is slower than
that code on the same workload. How much is not known.

### Memory

- `count × stack_bytes`, one more 64 KiB for the alignment of the stacks, and one `Fiber` for each
  fiber and one for the main context.
- Decision 22's `Fiber` was 72 B. A `Completion` adds 8 B, so the prior is 80 B.
- The ruled defaults are 256 fibers of 256 KiB: 64 MiB. Decision 22's sketch had 256 fibers of 64
  KiB: 16 MiB.
- A guard page takes one page of each stack: 4, 16 or 64 KiB, by the host.

### What decision 22 measured

The only measurement of a `std.Io` on rotor is decision 22's echo run. It ran after steps 1 and 2,
on GitHub's runners (`bench/results/adapter-echo-github-2026-11-05.md`). A row's number is the
median of three runs, and each range below is over the 8 rows of a machine. None of them is a cell
of `docs/costs.md`.

| machine | `std.Io` on the adapter, as a share of rotor's own server | against `std.Io.Threaded` |
|---|---|---|
| Linux x86-64, 8 rows | 86 to 96 percent | ahead on 8 of 8 rows, at 111 to 162 percent of its rate |
| Linux arm64, 8 rows | 71 to 91 percent | ahead on 5 of 8 rows, at 81 to 142 percent of its rate |
| macOS | no row to use: 79 of 80 rows were flagged | no row to use |

Each run of the adapter reached about 135 MB of resident memory, for 512 fibers of 256 KiB. The
server of rotor's own reached 4 to 12 MB, and `std.Io.Threaded` about 27 MB.

No measured code is nearer to the package: that code ticked the loop itself. It differs from the
package in three ways. It used a tag and no record, it had no poller, and each context ticked on its
own stack. So these numbers are not numbers of the package. They are the prior that step 5 compares
with.

### The fiber switch has no measured cell

Row C26 was decision 22's first check. Its probe landed as `b2bcf60` and went as `85d5e67`, both on
2026-11-05. No quiet run filled a cell. `docs/costs.md` at `b2bcf60` holds one run on a busy `mac`,
at a load average of 45. It read 4.96 ns for one switch out and back, and 1.52 ns for a call of an
empty function. That file says that the run is not a cell.

The package measures the switch first, at step 0. It takes the probe of `b2bcf60`,
`bench/costs/probes/probes_fiber.zig`, with the corrected switch. It runs on a quiet `mac`, on
`orbstack` and on a GitHub runner, and a result names its machine. The number stays in the package's
own results: rule 1 of `docs/costs.md` takes a number only from a probe in rotor's `bench/costs/`.
If a decision record of rotor needs the row, the probe comes back to rotor, and that is Camilo's
choice.

## The rules of rotor that the package keeps, and those it cannot keep

The package is outside rotor's module graph and outside its lint. So rotor's gates check none of
this. The package runs pepegrillo's rules with a configuration of its own.

### Who ticks

Three texts of rotor say who calls `tick`:

- Decision 27, ruling 1: "Only the program ticks a shared loop. A library never calls `tick` on a
  loop it does not own. It submits, returns, and finishes its work in records, pollers and tasks."
- Decision 26, ruling 2, as Camilo corrected it: "only the program ticks a shared loop".
- The guide, "A library on a reactor": "Only the program calls `tick`".

Decision 28 builds on them. Its view refuses `tick` at compile time, and it calls `tick`, `drain`,
`deinit`, `cancel_all` and `discard_tasks` "the calls that only the program makes".

How the package stands to those texts:

- **By its words, the first sentence of each text forbids the package's `tick`.** The package is not
  the program. It is code that the program imports, on a reactor that other libraries share.
- **The second sentence of ruling 1 leaves room for an owner.** It forbids a tick "on a loop it does
  not own". No decision record of rotor names an owner of a loop other than the program.
- **The package keeps the reason of the rule.** Decision 26 gives it: a library's tick inside the
  program's call into another library nests the callbacks of the two. The package makes no such
  tick. It is the one caller of `tick`, and a callback that must block halts.
- **Decision 28's refusal does not reach the package.** The package holds the reactor, as the
  program does, so a `tick` by the program compiles too. Decision 28 asks that wrong use "halts at
  once" where the compiler cannot see it. The package's check of `now_ns` halts later: at the
  package's next tick.
- **The package calls `shared()` too,** for the view of a cross-core call. Decision 28 gives that
  call to the program.

Camilo ruled on 2026-11-10 that the package calls `tick`. That ruling answers open question 2 of
this record, and "Rulings, 2026-11-10" names no other decision. So the texts above and the ruling do
not agree as they are written. This record changes none of their words. In the second round Camilo
ruled a note for decisions 26, 27 and 28 and for the guide. The session wrote it on 2026-11-11, at
this record's acceptance, beside each text. Its words: a program may hand its reactor to one package
that ticks in its place. The program then calls no `tick` while that package's value lives.

### What it keeps

- **No allocator.** No file of the package names one. The caller hands over the memory at `init`.
- **Bounded, with named limits.** Its `constants.zig` holds `fibers_max`, the least and the most
  stack, and the bytes of the arguments and the result of a std task. It also holds
  `resumes_between_ticks_max`, `submit_tries_max` and `events_per_tick`. Each loop over contexts has
  a bound.
- **Assertions on,** in the two modes that rotor's build offers, Debug and ReleaseSafe.
- **One thread, and shared nothing.** Each fiber of a value runs on the reactor's thread. A program
  with one reactor for each core makes one value for each.
- **Determinism, in what the package decides (non-negotiable 2).** The ready list is first in, first
  out. The limit between two ticks is a fixed count, and the wait of each tick follows a fixed rule.
  The package reads no clock and no random source. It orders nothing by a pointer value: the futex
  list compares an address for equality alone. So what the package decides replays.
- **One final event** for each operation (decision 5). Each record does a small, fixed amount of
  work (decision 30): one store, and one push on the ready list.
- **An error value for a limit, where std's call has one.** A refused start is
  `ConcurrencyUnavailable`. A network call on a reactor that stays full is `SystemResources`. A
  refused call across cores is `CallsFull`.
- **Tests on the real kernel**, through rotor, on kqueue, io_uring and epoll (decision 10).
- **Ugly code only in a named file, with a ledger row (decision 7).** The context switch is
  assembly, in one file. The package keeps a ledger of its own for it.

### What it cannot keep

- **The words of the texts on who ticks,** as "Who ticks" says. Each text holds a note that points
  here.
- **An error value for each limit, and for each error of the kernel.** rotor's rule is that a limit
  reached returns an error value. Five paths end in a halt, because no error value can reach a
  caller there. Open question 9 lists them, and Camilo accepted all five.
- **Shares for the fibers (decision 30).** A fiber is no rotor task, so no scheduling group holds it
  and no share bounds it. A fiber that computes for long holds the reactor. rotor counts the stall,
  and names no fiber.
- **Determinism (non-negotiable 2), for what the package does not decide.** Three sources are not
  deterministic unless the program makes them so: `rest`, the real kernel under the reactor, and a
  `futexWake` from another thread. `now` for the real clock and the CPU clocks, `random` and
  `randomSecure` each go to `rest`, which reads the host. `now` for the `awake` and `boot` clocks
  reads `now_ns`, so it keeps the rule. A replay of a whole program needs a twin under the reactor
  (decision 10). Camilo ruled a generic type for that, and "Over a twin" says what the package asks
  of a twin.
- **Time that moves while a context runs.** `now_ns` is the stamp of the last tick, and a timer runs
  from it (the guide, "Submit and tick"). So `io.sleep` can return early, by at most the time since
  the last stamp. std's comment says that `sleep` waits for the whole time (`std/Io.zig`, line
  2391). `now` for the `awake` and `boot` clocks stands still between two ticks too. A fiber that
  reads it in a loop, with no call that blocks, never sees time pass.
- **std's rules for threads.** std marks six calls of the table as safe from each thread, and
  `Queue` as safe for many producers and consumers. rotor's rule is one thread for each loop
  (non-negotiable 4), and the package keeps it. So `Mutex.lock` and each `Queue` call can halt on
  another thread. Code that hands one `io` to several threads does not run on the package. By the
  ruling on question 15, `io.random` and `io.randomSecure` halt there too.
- **A halt for each broken invariant (non-negotiable 6).** No assertion sees a stack that overflows.
  The guard page turns it into a fault that ends the process.
- **A halt for a context that nothing can wake.** Rule 4 of "The ready list and the tick" says why,
  and Camilo ruled no halt (open question 16).
- **A fixed amount of work in its poller.** After a wake from another thread, the poller visits each
  context on the futex list: at most `count + 1`.
- **snake_case for each function.** The fields of `Io.VTable` are std's, in camelCase.

## Upkeep

- **Each release pins one Zig version and one rotor tag.** `build.zig.zon` holds the rotor tag and
  its hash. A comptime check refuses each other Zig version, because the table differs between
  versions.
- **The table is held at comptime.** The package fills `Io.VTable` field by field, as decision 22
  did. A call whose signature changed fails the build. Decision 22's code sent a new call of std to
  `rest` with no message, and dropped an own call whose name std removed. So the package adds two
  checks:
  - a comptime check holds each of its own calls to a field of the table;
  - a test holds the count of the fields, 109 at 0.16.0.
- **A Zig upgrade is a job of the package, with a release of its own.** Whoever makes that release
  reads `Io.VTable` again, call by call, against the list of the last release. That read covers
  three more things:
  - each parameter of a call that goes to `rest`, for a std object that a fiber can wait on, as
    `netLookup` has;
  - the rows of `std.Io.failing`, against "What `rest` is";
  - std's context switch, against the package's copy. Decision 22 found three errors in std's
    clobber lists at 0.16.0, and the same lists in 0.17.1.

  rotor's own Zig upgrade holds none of this work.
- **rotor's upgrade does not wait.** rotor does not depend on the package. A program that uses both
  builds with one Zig, so it waits for the slower of the two.
- **A rotor release is a job of the package too.** The first release pins v0.11.0. The package names
  the reactor's type and its `tick`. So a later release of rotor that changes either one changes the
  package.
- **Its CI is its own.** It runs the package's tests on the three kinds of runner of rotor's CI.
  Each test runs in Debug and in ReleaseSafe, because the switch's faults showed only in an
  optimized build (decision 22). On Linux each test runs with io_uring and with epoll. The wake from
  another thread runs under ThreadSanitizer, and each halt scenario runs in a child process.

**Noted on 2026-11-13.** Step 0 of the package found two more errors in std's clobber lists. Camilo
ruled a correction for each, and tejedor's records hold them:

- **Record 2, `f00f094`, ruled on 2026-11-12.** The x86-64 list names `xmm0` to `xmm15`. std names
  only `zmm0` to `zmm31`, and the compiler ignores those names on a processor with no AVX-512.
- **Record 3, `d790342`, ruled on 2026-11-13.** The aarch64 list names `nzcv`, the condition flags.
- **Record 3 also sets the form of the call.** On aarch64 each caller holds a copy of the switch.
  On x86-64 each caller calls it, and the compiler never inlines that call. The clobber type of Zig
  0.16.0 has no name for the x87 registers, `k0` to `k7`, `r16` to `r31` or `xmm16` to `xmm31`.
  The calling convention covers them.
- **Record 3 and `27a6403` leave the control registers to the thread.** The switch saves neither
  MXCSR nor the x87 control word on x86-64, nor FPCR on aarch64. A fiber that changes the rounding
  mode or the exception masks restores them before it blocks.

So at a Zig upgrade, the read of std's switch covers five corrections, the form of the call, and
the entry of record 4 ("Where the code starts").

## What changes in rotor

- **No source file, no build file and no dependency.** rotor does not depend on the package. No file
  under `src/`, `build/`, `bench/`, `tools/` or `examples/` names it.
- **No module and no edge.** The package is not decision 1's `adapter` module.
- **Decision 1 gained an amendment on 2026-11-11, at this record's acceptance.** Four parts of
  decision 1 still put the `std.Io` table in rotor:
  - its title, "with a std.Io adapter over it";
  - its decision, "A std.Io adapter sits over it, as a separate module that the core never imports";
  - its section "The adapter";
  - the `adapter` row of its module table.

  Its header held no amendment for the removal of 2026-11-05. The amendment says that rotor holds no
  `std.Io` table, and names decisions 22 and 34. Camilo ruled it in the second round.
- **Decision 2 gained a note with it,** by the same ruling. Its line "The std.Io adapter" stays
  under "Not in version one", because rotor still holds no `std.Io`. That line points at decision
  1's module, so the note points here.
- **Decision 22 gained one note** under "Why it was removed", which points here. It is in the first
  commit of this record. A second note there states the acceptance.
- **`docs/using.md` and the README each gain one sentence, and only after the package's first
  release.** Each says today that a `std.Io` adapter is not in version one, and that decision 2 says
  what would bring it in. The sentence would say where code written against `std.Io` runs. Before a
  release there is no package to name. This is an ask-before item.
- **The README's list of decision records changed in one row.** Its row for this record reads
  "accepted, not built" since 2026-11-11. Its row for decision 22 still reads "accepted, deferred".
- **`docs/costs.md` gains no row.** "The fiber switch has no measured cell" says why.
- **Decisions 26, 27 and 28 and the guide gained a note on who ticks on 2026-11-11, at this
  record's acceptance.** "Who ticks" gives the texts and the words of the note. Camilo ruled the
  note in the second round. In the guide the note is in "A library on a reactor".

## Where the code starts

The package starts from the tree before `46235cb`. That code is shape (a) on a plain loop, with a
tag in `user_data`. The line counts are from that commit's own summary.

| removed file | lines | what the package takes | what changes |
|---|---:|---|---|
| `adapter_switch.zig`, `adapter_switch_test.zig` | 323 | the corrected switch, the entry of a new fiber, and their tests | nothing but the names |
| `constants.zig` | 64 | the limits of the fibers and their stacks, and `events_per_tick` | the tag of `user_data` goes. The least stack becomes two granules, 128 KiB, for the guard page. `fibers_max` stays 4,096. `resumes_between_ticks_max` and `submit_tries_max` are new |
| `adapter.zig` | 361 | `Fiber`, the main context at index 0, the options, the layout of the memory, the array of events, and the code that fills the table | it becomes a function of the reactor's type, and holds a `*Reactor`, where it held a `*rotor.Loop`. `Fiber` gains a `Completion`. `Handler` becomes `EventHandler`. `rest` becomes a parameter of `init`. The options go by `*const`, and `init` returns an error |
| `adapter_scheduler.zig` | 283 | the free list, the ready list, `block`, `end_wait`, `interrupt`, `tick`, `poll`, and the futex list's unlink | only the main context ticks, so `block` and `leave` switch to it. The limit on the switches between two ticks is new. `hand_over` reads no tag: a record takes each event of a context, and the event handler takes each other event. A `submit` that takes none tries `submit_tries_max` times. The halt for "nothing is in flight" goes |
| `adapter_tasks.zig` | 290 | `async`, `concurrent`, `await`, `cancel`, the `Io.Group` calls and the cancel protection. `await` still frees a future's fiber, and `group_await` still passes a cancel to each member | the rules of "Where a call comes from" for a callback are new |
| `adapter_wait.zig` | 121 | the futex list, `sleep`, and `now` with its tick before the first operation | the wake from another thread is new, with the package's poller and `WakePath` |
| `adapter_rest.zig` | 102 | the forwarders | `netLookup` leaves them: the package wraps the call of `rest`. Each other one gains the owner check, by Camilo's ruling on question 15 |
| `adapter_net.zig`, `adapter_net_errors.zig` | 347 | the nine network calls and the maps of their errors | each operation names the context's record. A reactor that stays full is `SystemResources`. `net_close` stays one `close` operation that blocks its context, and it halts in a callback. Each call of `rotor.sync` and `getpeername` goes through `Options.sockets` |
| `adapter_datagram.zig`, `adapter_batch.zig`, `adapter_file.zig` | 480 | step 6, and `fileClose` in step 4 | the receive that each socket keeps in flight names a record of its own, where it had a bit of `user_data`. The view reserves the buffer group |
| the five other test files, `tools/halt/adapter_scenarios.zig`, `examples/std_io_echo.zig` | 1,438 | the scenarios and the mutation lists of decision 22. Each test still drives the loop from the main context | each test makes a reactor, where it made a loop. The tests of a callback, of the limit and of the poller are new |

The library files hold 2,300 lines together, which is decision 22's count. The removed code ticked
the loop and kept a ready list, as the package does. So it is nearer to the package than it was to
shape (b). Most of the change is in `adapter_scheduler.zig`, where a tick now calls callbacks.

**Noted on 2026-11-13.** The row of `adapter_switch.zig` says "nothing but the names", and step 0
changed more. The package added the two clobber names and the form of the call that "Upkeep" notes.
Its record 4, `ded6989`, ruled on 2026-11-13, also changed the entry of a new fiber:

- **The word of the argument is above the first stack pointer.** std's `Kqueue.mainIdleEntry` reads
  it below the stack pointer on aarch64. In a test of the package, a signal on Linux wrote over it.
- **`main` starts with a return address of zero.** Before, a stack trace from a fiber read a stale
  link register on aarch64, and the argument as a return address on x86-64.

## colibri, cocuyo and stompy

This section holds only what rotor's tree shows. It claims nothing more about the three projects.

- **colibri.** Decision 22 says that colibri's decision 150 chose the adapter for its `serve`
  module, and that colibri needs another path since the removal. Decision 33 says that colibri's
  decision 159, of 2026-11-08, gives colibri a host interface of its own, and that colibri calls no
  host. So colibri's library does not need a `std.Io` from rotor. The tree does not say whether its
  `serve` module still wants one. If it does, the package is the path that decision 22 named.
- **cocuyo.** The tree shows no request of cocuyo for a `std.Io`. Decision 22 says that a resolver
  on rotor, such as cocuyo, could take `netLookup` later. In the package, `netLookup` is a wrapper
  around the call of `rest`, and such a resolver could replace what the wrapper calls.
- **stompy.** The tree shows no request of stompy for a `std.Io`. Decision 27 says that stompy keeps
  turns in a fixed order after each tick. It also says that stompy's background worker sleeps in a
  wait of its own. A program with a tick loop of its own cannot use the package on that loop.
  Decision 32 says that stompy runs one loop for each CPU core, and sends requests between cores.
  `call` gives a context the reply of a call to such a loop.

Decision 26 says that colibri and cocuyo run on one loop that the program owns. On a reactor that
the package ticks, each is a library on the view. Decision 30's shares bound their rotor tasks, and
do not bound the fibers.

## Alternatives it beat

1. **The `std.Io` inside rotor's `reactor` module.** It is decision 22's shape in decision 33's
   module. It would reach the reactor's state through decision 33's port. So it could write a
   fiber's name on the heartbeat's line, and keep a tick from its wait with no poller. Camilo did
   not choose it. It brings back what the removal named:
   - about 2,300 lines and their tests in rotor;
   - a new read of the table in each Zig upgrade of rotor;
   - a determinism lint that skips a directory.
2. **Future-shaped names with no `std.Io`.** rotor would export a `Future` with `await` and
   `cancel`. Without a fiber, `await` cannot stop its caller. Such a future is a record with a
   callback under another name, and rotor has those: `Completion`, `Task` and `CallRecord`. A Zig
   programmer would find a `Future` that does not block strange, and code written against `std.Io`
   would still not run. Camilo did not choose it.
3. **std's own evented machinery, with rotor as its poller.** Decision 22 rejected it as its
   alternative 4, with these facts about `Uring`, `Dispatch` and `Kqueue` of std:
   - each allocates its fibers from a general-purpose allocator;
   - each runs fibers on threads that rotor does not own;
   - `Uring` and `Kqueue` move fibers between threads;
   - `Uring` does not compile on 0.16.0.

   Each of the first three breaks a rule that the package keeps.
4. **No futures.** rotor stays as it is, and code on the reactor writes records, pollers and rotor
   tasks. It costs nothing. Code written against `std.Io` does not run on rotor, which decision 22
   names as what rotor gives up. Camilo asked for the Future API on 2026-11-09.
5. **Shape (b): a library on a `*rotor.SharedLoop`, which the program ticks.** This record proposed
   it before the rulings. Each resume of a fiber is then one rotor task in a scheduling group, and
   the package ticks nothing. Camilo did not choose it (open question 2).

   | | shape (a) | shape (b) |
   |---|---|---|
   | a call that must block, in the program's own code | blocks | halts |
   | a wake between two fibers | no tick | one tick with a wait of 0: 545 to 668 instructions on the `task` row |
   | rotor's own work for each call that blocks, as a prior | the record: at most 117 to 142 instructions | the record and a rotor task: at most 170 to 199 instructions, or 309 to 347 on the run of the scheduling groups |
   | a fiber that runs long | a stall that names the package's poller at most, and no share bounds it | a stall that names the package's rotor task and its scheduling group |
   | a program with a tick loop of its own | cannot use the package | keeps its loop |
   | rotor's texts on who ticks | need a note ("Who ticks") | stand as they are |

   Each count is arithmetic over the rows of `bench/baseline/work.txt`, inside one of its five
   sections. The record is `record - timer`: 117 to 142. A rotor task in `.default` is
   `(tasks-64 - task) / 63`: 53 to 63. On the run of the scheduling groups it is
   `tasks-groups-4 / 64` or `tasks-groups-16 / 64`: 191 to 213, with the tick's own work in the
   count.
6. **Each context ticks on its own stack, as in decision 22's code.** It saves the switch to the
   main context for each tick. Rule 1 of "The ready list and the tick" gives its two faults.
7. **One fixed type of reactor.** A program then types `tejedor.Fibers`, and code on fibers gets no
   replay. Camilo did not choose it (open question 14).

## Build order

The package could start only after decision 33 was accepted, built and tagged as v0.11.0, and after
Camilo accepted this record. Each of these holds since 2026-11-11. The package's repository waits
for Camilo's word ("Ask before"). Each step is one or more commits in that repository, and each step
states how it is checked. Each check is proved by mutation, as rotor's are. No step changes rotor.
Camilo ruled that the first release goes through the network calls, which are steps 0 to 5 (open
question 6).

0. **The switch, and its number.** The corrected switch and its tests, and the probe of "The fiber
   switch has no measured cell". Check: the switch's tests pass in Debug and in ReleaseSafe, on
   aarch64 macOS, aarch64 Linux and x86-64 Linux. Decision 22's two mutations of the clobber lists
   are each caught. Camilo reads the probe's numbers before step 1.
1. **Contexts, std tasks, `Io.Group`s, cancel, futexes, `now`, `sleep` and the `netLookup` wrapper,
   on one thread.** The pool on the caller's memory, with a guard page for each stack. The ready
   list, the tick on the main context, a record for each context, the event handler and the
   package's poller. Its checks:
   - A test of each of the 17 calls, and of a cancel of each wait, on kqueue, io_uring and epoll.
     Each call that blocks runs once on a fiber and once on the main context.
   - A cancel of a fiber in `Group.await` reaches each member, and the call returns after the last
     member.
   - A lookup through `failing` returns `NetworkDown`, and the caller's queue is closed. With a
     `rest` of the test that puts two addresses, the caller gets both.
   - Two fibers wake each other without end, and a timer of the test's own record still fires.
   - A poller of the test, added after `init`, wakes a fiber, and that tick does not wait.
   - A record of the test starts a std task with `concurrent`, and its fiber runs after that tick.
   - An event with no record reaches the event handler. On a full reactor, a `sleep` returns when a
     slot is free before the last try.
      - Each test reads `reactor.statistics().stalls` as 0 at its end.
   - `Fibers` of a type that lacks `tick` and `shared` fails to compile, and the message names both.
   - The calls for std tasks also run over the test's own twin, by the ruling on open question 18.
     Two runs give the same order of events.
   - A halt scenario for each of these eight cases:
     - a call from another thread;
     - a call that blocks in a callback;
     - a `tick` by the program while the value lives;
     - an event with no record, and no event handler;
     - memory smaller than the options need;
     - a `deinit` while a fiber is in use;
     - a `sleep` on a reactor that stays full;
     - a fiber that overflows its stack, which dies by a signal at the guard page.
   - The mutations of decision 22's step 1, each caught.
   - The first numbers: "The timer program".
2. **The wake from another thread.** The flag, the poller's read of it, and `set_wake_path`. Its
   checks:
      - A thread with a `WakePath` of its `Remote` wakes a futex, also under ThreadSanitizer on
        Linux.
   - A halt scenario: a `futexWake` from a thread that named no path.
   - A halt scenario: a `Mutex.lock` from another thread while a fiber holds the lock.
3. **The calls of its own: `perform` and `call`.** Its checks:
   - A context waits for a timer through `perform`. On a reactor that stays full it gets
     `OperationsFull`.
   - A halt scenario: `perform` with a multishot operation.
   - Two reactors on two threads: a fiber on one waits for a call to the other, and gets a reply,
     `Expired` and `TargetStopped`. A full pair gives `CallsFull`.
   - A cancel while a call is out arrives after `finish`.
4. **The network calls, and `fileClose`.** The nine network calls of "Which calls run where", and an
   echo server written against `std.Io` alone. Its checks:
   - A test of each call and of its cancel, and the mutations of decision 22's step 2.
   - A network call on a reactor that stays full returns `SystemResources`.
   - A context closes a socket while a fiber waits in `netRead` on it. The read ends with its final
     event, and then the close returns.
      - A halt scenario: a `netClose` in a callback.
   - A halt scenario: `netListenIp` over a twin's reactor with the default `sockets`.
   - A checker drives the echo server on each backend.
5. **The numbers.** "The measurement plan", below. Camilo reads the results before a release.
6. **Datagrams, batches and files,** when a consumer asks. Decision 22's step 3 is the start.
   One part moves to step 4, by the ruling of 2026-11-11 under question 19: `operate`,
   `batchAwaitConcurrent` and `batchCancel` for one `net_receive` with its deadline.

### The timer program

Step 1 runs `bench/alternatives/std_io_timers.zig` on the package, beside `rotor_timers` and
`std.Io.Threaded`. That program never ran on decision 22's code. Its file before `46235cb` holds no
branch for the adapter, and decision 22 says that only the echo half of its numbers ran.

- **Its `main` gains one branch.** The branch makes the reactor and the `Fibers` value, and calls
  `churn` on the main context. `churn` does not change. Decision 22's echo program called `serve` on
  its main context in the same way (`serve_on_rotor`, in `std_io_echo.zig` before `46235cb`).
- **`churn` needs one fiber for each timer, and none for itself.** It starts each timer with
  `Group.concurrent`. Then it calls `Group.await` on the main context, which is no fiber. The
  runner's rows are 256 and 4,096 timers (`bench/timers/timers_runner.zig`). So the rows need 256
  and 4,096 fibers: the default `count`, and the ruled `fibers_max`. Under shape (b) `churn` ran on
  a fiber, so each row needed one more: the 4,097 of "Rulings, 2026-11-10".

At the least stack of 128 KiB, 4,096 fibers take 512 MiB. At the default of 256 KiB they take 1 GiB.

One fact bends the row. A timer of the package runs from the stamp of the last tick, so a fiber's
`sleep` can end early. The program reads such a wake as a lateness of 0 (`std_io_timers.zig`,
`lateness_of`). The row then favours the package against `std.Io.Threaded`, and the results say so.

### The measurement plan

The workload is decision 22's: the echo workload through `std.Io`.

- **The program.** The `serve` function of `bench/alternatives/std_io_echo.zig`, with no changed
  line. Its `main` gains one branch that calls `serve` on the main context, as decision 22's did.
- **The candidates.** rotor's own `rotor_echo`, `std_io_echo --backend threaded`, and the package's
  server. The first two are built with `zig build bench-echo` in a checkout of rotor at the pinned
  tag, because rotor's package holds no `bench/`.
- **The method.** rotor's `echo_client` measures each server. The rounds alternate between the
  candidates, so that drift moves each one alike. Each row holds the median and the spread of its
  rounds. The results hold each row that the package loses.
- **The rows.** 16 and 64 connections, at 4, 8, 16 and 64 KiB, on one core, as decision 22's run.
- **The machines.** GitHub's Linux runners on x86-64 and arm64, with io_uring, as decision 22's run.
  A quiet `mac` for kqueue, which decision 22 never got.
- **What it must show.** The gap to `rotor_echo` is the package's cost. The gap to `std.Io.Threaded`
  is the package's reason to exist. The shares of decision 22's run are the nearest prior. They come
  from other runs on other processors, so a gap to them proves nothing.
- **Where the numbers go.** They stay in the package's results. No number from CI enters
  `docs/costs.md`.

This record sets no bar for the result, by Camilo's ruling on open question 10. Three parts of the
design carry a cost that the results can show. They are the record of question 12, the limit of
question 13, and the rule that only the main context ticks. Camilo ruled the first two, so a change
to either is his to make, with the numbers.

## Open questions

Camilo ruled each question up to 16 on 2026-11-10, in two rounds ("Rulings, 2026-11-10"). He ruled
questions 17 and 18 on 2026-11-11 ("The third round, 2026-11-11"), and question 19 later that day
("The fourth round, 2026-11-11"). Each name of the sketch but `tejedor` is a proposal, which Camilo
rules with the code.

1. **What are the package's name and its repository?** The candidates were `tejedor`, with the type
   `tejedor.Fibers`, `rotor-fibers` and `fibra`. This record did not check whether another project
   holds one of them.
   **Ruled on 2026-11-10: `tejedor`.** The text of the choice said that the repository takes the
   same name. The session makes no repository before Camilo says so.
   **Ruled on 2026-11-10, in the second round: he rules each other name with the code.** Each name
   of the sketch stays a proposal until the first step shows it in a real program. Three of them
   have a reason to state:
   - `WakePath` and `set_wake_path`. `attach` and `Waker` already have a meaning in rotor's tree.
   - `EventHandler`. Decision 22's code named it `Handler`, a word that decision 32 uses for the
     function of a service.
   - The option `count`. Decision 22's code named that field `fibers`. With the type `Fibers`, a
     program would then type `Fibers.Options` and `.fibers`, which repeats the word.
2. **Who calls `tick`?** This record proposed the program: shape (b).
   **Ruled on 2026-11-10: the package.** The design of this record is shape (a), and shape (b) is
   item 5 of "Alternatives it beat".
3. **Does the package start on v0.10.0, or wait for v0.11.0?** This record proposed v0.10.0.
   **Ruled on 2026-11-10: it waits for v0.11.0.** The package starts only after decision 33 is
   accepted, built and tagged. Each of the three holds since 2026-11-11 (`f2890f5`).
4. **What are the default count of fibers, the default stack, and `fibers_max`?** This record
   proposed 256 fibers of 256 KiB, and a limit of 8,192 for the timer row of shape (b).
   **Ruled on 2026-11-10: 256 fibers of 256 KiB, with a limit of 4,096.** That is 64 MiB by default.
   No number says what stack other `std.Io` code needs.
5. **Does each stack have a guard page?** This record proposed yes, always, with `mprotect` at
   `init` and again at `deinit`.
   **Ruled on 2026-11-10: always.** It costs one page of each stack, and a least stack of two
   granules, 128 KiB. It also costs two system calls for each fiber, each of C6 or more, 112 ns on
   `mac`. `init` returns `SystemResources` when the kernel refuses one.
6. **Does the first release hold only the calls for std tasks, or the socket and file calls too?**
   This record proposed steps 0 to 5.
   **Ruled on 2026-11-10: through the network calls.** The text of the choice named the calls for
   std tasks, sleep, and the wake from another thread. It also named `perform` and `call`, the nine
   network calls and `fileClose`, with echo numbers. Those are steps 0 to 5. The file calls, the
   batches and the datagrams wait for a consumer, and until then `failing` halts on the three batch
   calls.
7. **Does `rest` have a default?** This record proposed none: `std.Io.failing` halts on 14 of the 75
   calls, and a `std.Io.Threaded` brings threads, which the program must own.
   **Ruled on 2026-11-10: no default.** `rest` is a parameter of `init`, so each option still has a
   default, as the API rules ask.
8. **May another thread make a call other than `futexWake`?** This record proposed no call that the
   package runs.
   **Ruled on 2026-11-10: only `futexWake`.** So a thread shares no `Mutex` and no `Queue` with a
   fiber ("How a wake from another thread arrives"). Neither the question nor the choice named the
   75 calls that go to `rest`, and the ruling on question 15 covers them.
9. **Does Camilo accept the halts that remain at a limit?** Under shape (b) this question listed
   three halts. The ruling on question 2 changes each of them, and three more come:

   | halt | under shape (a) |
   |---|---|
   | a `sleep`, or a futex wait with a timeout, on a full reactor | goes as shape (b) had it: the context waits for a tick, and submits again. A narrower halt remains: the reactor is still full after `submit_tries_max` tries |
   | a resume, when the program fills the scheduling group that it shares with the package | goes: no resume is a rotor task |
   | a call that blocks inside a std task that `async` ran outside a fiber, because no fiber could take it | goes for the program's own code, which may block on the main context. It remains in a callback |
   | a `netClose` or a `fileClose` on a reactor that is still full after the last try | new. A close returns no error, and `close_now` is no substitute ("When the reactor is full") |
   | a call in a callback that waits only in some states, such as a `Queue.put` on a full queue | new. The halt comes when the queue fills, so a test can miss it ("Where a call comes from") |
   | an error that `tick` returns | new. Under shape (b) the program's own `tick` returned it. Now it reaches the package inside a call that has no such error |

   So five halts remain: the first, the third and the three new ones.
   **Ruled on 2026-11-10: he accepts all five.** A program stays away from them in three ways. It
   adds `Fibers.operations` to its reactor's `operations`. Its callbacks start each std task with
   `concurrent`. They hand work to a fiber with `Event.set`, or with `Queue.put` and a least count
   of 0. Each tick between two tries on a full reactor has a wait of 0, so 8 tries can pass in
   microseconds.

   Camilo did not choose to remove a halt. Three of them can go. Each has a cost: deadlines in the
   package for a `sleep`, a close that returns early, or an option for a tick's error.
10. **Do decision 22's two conditions bind the package?** This record proposed that both bind, and
    asked which of two things the first one means.
    **Ruled on 2026-11-10: both bind, and the first means that rotor's own paths do not slow down.**
    The text of the choice said that the package's own speed has no fixed bar. The rest is this
    record's reading, and no part of the ruling. rotor changes no source file, so no row of
    `bench/baseline/work.txt` moves. For the second condition, the package's own calls take and
    return rotor's types.
11. **Who makes the reactor?** This record proposed the program.
    **Ruled on 2026-11-10: the program.** It makes the reactor, hands `init` a pointer, and keeps
    each call of the reactor but `tick` ("What the package holds"). The text of the choice said that
    this is less than the text of the choice on question 2. The other answer was a package that
    holds the reactor by value, and forwards each call that a program needs.
12. **Does each operation of a context name a record, or carry a tag in `user_data`?** This record
    proposed a record.
    **Ruled on 2026-11-10: a record.** `user_data` of the program's own operations stays whole, and
    no event of the package comes back from `tick`. The cost stays: the record's call for each call
    that blocks, a prior of at most 117 to 142 instructions. Decision 22's echo numbers are numbers
    of the tag, which was the other answer.
13. **Does a limit bound the contexts that run between two ticks, and is it 64?** This record
    proposed a constant of 64.
    **Ruled on 2026-11-10: a constant of 64.** It is `resumes_between_ticks_max`. The value is that
    of rotor's `tasks_per_tick_max`, and it is a prior. It costs one tick with a wait of 0 for each
    64 switches, while contexts stay ready.
14. **Is the package's type generic over the reactor's type?** On 2026-11-10 Camilo asked the
    session whether a package that ticks can still be deterministic. What the package decides
    replays ("What it keeps"). A replay of a whole program needs a twin under the reactor (decision
    10). This record proposed a generic type.
    **Ruled on 2026-11-10: a generic type.** The text of the choice named
    `tejedor.Fibers(rotor.Reactor(rotor.Loop))`. It said that the name is longer than the
    `tejedor.Fibers` of question 1. It also said that this record did not yet design a twin's form
    of `rotor.sync` and of `Remote`. "Over a twin" now holds that design. The type has one more
    cost. A program gets one copy of the package's code, and of each function of the `Io.VTable`,
    for each type of reactor.
15. **Do the 75 forwarders check the owner?** The ruling on question 8 names "only `futexWake`", and
    neither the question nor the choice named the calls that go to `rest`. Decision 22's forwarders
    had no check. This record proposed the check.
    **Ruled on 2026-11-10: each call checks.** One rule holds for each call of the `io`, and no step
    changes it. The text of the choice named two costs:
    - `io.random` halts from another thread. std marks it and `io.randomSecure` safe there
      (`std/Io.zig`, lines 2465 and 2482). Such a thread calls the program's own `rest`.
    - A program must not make the package's `io` its `debug_io`. std's panic code calls
      `crashHandler` on `std.Options.debug_io` (`std/debug.zig`, lines 536 and 1641).

    Each of the 75 calls also pays one owner check: C21.
16. **Does the package halt when nothing can wake a context?** This record proposed no halt.
    **Ruled on 2026-11-10: no halt.** The text of the choice said that a deadlock of fibers is then
    silent. When each context waits and nothing wakes one, the thread sleeps for 10 s at a time,
    with no end. The stall count does not see it, because a wait in the kernel is in no turn.
17. **Do a twin's sockets come from an option, or from the twin's loop type at comptime?** Proposed:
    an option, `Options.sockets` ("Over a twin"). It needs nothing from rotor. It costs one indirect
    call in four calls that also make a system call. A twin's program that names no sockets halts at
    its first such call, and does not fail to compile.

    The other answer reads a `sync` namespace from the twin's loop type, at comptime. Then a twin
    that lacks a call fails to compile, and no call is indirect. It needs one thing that decision 33
    does not give: a reactor's type that names the type of its loop. That is one declaration on each
    reactor type, which step 3 of decision 33 did not add ("What rotor does not give").
    **Ruled on 2026-11-11: an option.** `Options.sockets` stays as "Sockets outside the reactor"
    describes it, and rotor gains no declaration for it.
18. **Does the package keep a twin of its own for its tests?** Proposed: yes, a small one, in the
    tests alone. It carries the core's surface and decision 33's port, with timers and endpoints in
    memory, after the model of decision 33's `examples/twin.zig`. Step 1 then runs the calls for std
    tasks over it, and compares two runs. Its cost is upkeep: the twin follows each change of the
    surface and of the port, in each rotor release that the package pins.

    The other answer is no twin in the package. Its tests then prove only that `Fibers` runs on the
    host's reactor. The first consumer's twin finds each fault of the other path.
    **Ruled on 2026-11-11: yes, a small one.** It follows `examples/twin.zig`, the twin of decision
    33's step 4, and lives in the package's tests alone.
19. **Does a network call of the package take a deadline inside the call?** stompy's proxy asked it
    on 2026-11-11. Camilo had ruled that day that the proxy's TLS step runs on `rotor.Reactor(Loop)`
    and on this package. In this record a deadline is a second std task: it sleeps, and then cancels
    the receive ("How cancel works"). The proxy gave two facts:
    - One proxy loop holds thousands of client connections, each with a receive that waits, often
      for minutes. A second task for each receive doubles the fibers, and each fiber has its own
      stack of 256 KiB (question 4).
    - Before its pool lends an idle backend connection, it sends the connection a receive with a
      deadline of 1 ns. The answer must give the queued bytes or the end of the stream before it
      reports the timeout. So the probe tells a live idle backend from a dead one.

    What rotor gives today, with no change:
    - Each operation carries `timeout_ns`, a deadline from the tick that submits it
      (`src/core/operation.zig`). When the deadline passes first, the loop cancels the operation,
      and the final event is `error.Timeout`. Bytes that moved win over `Timeout` (decision 5,
      rule 4).
    - On each backend the deadline is an entry in the loop's timer heap (decision 11, point 1, which
      amends decision 5, rule 4). When it passes, the loop cancels the operation; on io_uring the
      cancel is an `ASYNC_CANCEL` entry at the next tick. It takes no second operation and no
      second fiber. *Corrected on 2026-11-11: this item first said that io_uring uses a linked
      timeout entry, after decision 5's text, which decision 11 had amended.*
    - The conformance suite holds "a receive whose bytes came before its deadline ends with them
      when the loop ticks late", with a deadline of 5 ms (`src/conformance/conformance_loop.zig`).
      No scenario holds a deadline of 1 ns on a socket that already holds bytes, or on a socket at
      the end of its stream.

    What std gives in Zig 0.16.0 (`std/Io.zig`):
    - `netRead` and `netWrite` take no deadline (lines 247 and 248). So `net.Stream.Reader` and
      `net.Stream.Writer` have none.
    - `io.operateTimeout` takes a `Timeout` for one `Io.Operation` (line 459). It calls
      `batchAwaitConcurrent`, which this record runs for `net_receive` ("Which calls run where").
      `Io.Operation` has no kind that sends.

    The answers:
    1. **Keep the second task.** Nothing changes. The proxy pays one fiber and its stack for each
       receive with a deadline. Its probe is a receive and a cancel at once.
    2. **Map std's `Timeout` to `timeout_ns`.** When `batchAwaitConcurrent` holds one `net_receive`,
       the package sets the operation's `timeout_ns` from the `Timeout`, and runs no timer of its
       own. A reader with a deadline then calls `io.operateTimeout`, inside std's interface. A send
       keeps the second task, because std has no operation that sends.
    3. **Calls of the package's own, beside the `io`.** A receive and a send that each take a
       deadline and set `timeout_ns`. They cover a send too. A library written against `std.Io`
       alone cannot call them.

    In each answer, rotor's conformance suite gains two scenarios for the probe: a receive with a
    deadline of 1 ns ends with the bytes on a socket that holds them, and with 0 on a socket at the
    end of its stream. They are tests, and they change no name of rotor. A backend that fails one is
    fixed in rotor. Proposed: answer 2. It stays inside std's interface, needs nothing new from rotor,
    and removes the second fiber of each receive. The session has not checked whether std's contract
    for an operation still in flight at its `Timeout` fits rotor's final event. The first step checks
    it.
    **Ruled on 2026-11-11: answer 2.** When `batchAwaitConcurrent` holds one `net_receive`, the
    package sets the operation's `timeout_ns` from the `Timeout`, and runs no timer of its own. A
    send with a deadline keeps the second task. The two scenarios for the probe of 1 ns come to
    rotor's conformance suite in a change of their own.

    *Ruled on 2026-11-11, after the acceptance: the first release takes the receive's batch.*
    Answer 2 runs through `batchAwaitConcurrent`, which is step 6, and question 6 put the first
    release at steps 0 to 5. The session put this to Camilo. He chose that the first release adds
    `operate`, `batchAwaitConcurrent` and `batchCancel` for one `net_receive` with its
    `timeout_ns`, so a TLS reader with a deadline and the probe of 1 ns work in the first release.
    The rest of step 6 waits for a consumer, as before.

## Ask before

For rotor:

- Each row of "What rotor does not give". This record asks for none of them.
- One sentence in `docs/using.md` and one in the README, after the package's first release.
- A row for the fiber switch in `docs/costs.md`, with its probe in `bench/costs/`, if a decision
  record of rotor needs the number.

This record asked for one sentence in decision 33, which would say that `rotor.Reactor(Twin)`
declares `submit`, `cancel` and `now_ns`. Camilo accepted decision 33 without it, and the code says
it: `src/reactor/reactor.zig` declares the three on each reactor type ("Over a twin").

Camilo ruled two items in the second round, and neither is an ask-before item. The session wrote
both on 2026-11-11, at this record's acceptance:

- the note on who ticks in decisions 26, 27 and 28 and in `docs/using.md` ("Who ticks");
- the amendment in the header of decision 1, with the note in decision 2 ("What changes in rotor").

For the package:

- The repository. Camilo ruled its name, and the session makes none before he says so.
- pepegrillo as its lint tools, and CI on GitHub's runners.

The start had two conditions: decision 33 accepted, built and tagged as v0.11.0, and this record
accepted. Both hold since 2026-11-11.

## Sources

- The session's question to Camilo on 2026-11-09, with its four choices and his answer, for "Ruling,
  2026-11-09". The session's transcript holds them.
- `std/Io.zig` of Zig 0.16.0 on the development machine, read on 2026-11-10. The lines:
  - `VTable` at 51, with 109 fields, and the six marks "Thread-safe" at 60 to 129;
  - `Future` at 1176, `Group` at 1218, and the rule of `Group.await` at 1272 to 1275;
  - the futex calls at 1540 to 1580;
  - `Mutex` at 1587 to 1651, `Condition` at 1653 to 1763, and `Event` at 1766 to 1870;
  - the queue's `close`, `put`, `putLocked` and `get` at 1918 to 2048, and `Queue` at 2181;
  - `async` at 2326, `concurrent` at 2365, `random` at 2465 and `randomSecure` at 2482;
  - `failing` at 2512 to 2638, and the function of each of its calls, up to line 3436.
- `std/Io/net/HostName.zig` of the same Zig: `lookup` at 150 to 165, and `connectMany` at 331 to
  362. `std/Io/Threaded.zig`: `futexWake` at 2536, and `netLookup` at 13465 to 13520.
- Decision 22, whole, and the removed code: `dfbb644`, `8f76dd7`, `89b0a8a`, the tree before
  `46235cb`, and that commit's summary of lines.
- The fiber switch probe and row C26: `b2bcf60` and `85d5e67`.
- `bench/results/adapter-echo-github-2026-11-05.md`.
- `src/rotor/rotor.zig`, `src/rotor/rotor_loop.zig`, `src/core/shared_loop.zig`,
  `src/core/surface.zig`, `src/core/operation.zig`, `src/core/event.zig`, `src/core/tasks.zig`,
  `src/core/dispatch/dispatch.zig` and `src/core/dispatch/dispatch_callbacks.zig` at `2b165b8`.
- `docs/using.md` at `2b165b8`: "Submit and tick", "Cross-core calls", "A library that shares a
  loop", "A host that owns the wait" and "Not in version one".
- `README.md` at `2b165b8`, "Limits", and decisions 1 and 2 as they are at that commit, for "What
  changes in rotor".
- `bench/baseline/work.txt`, `bench/work/work.zig` and `docs/costs.md` at `2b165b8`.
- `bench/alternatives/std_io_timers.zig` and `bench/timers/timers_runner.zig` at `2b165b8`.
- `build.zig.zon` at `2b165b8`, for the paths of rotor's package.
- Decisions 1, 2, 4, 5, 7, 10, 18, 23, 26, 27, 28, 29, 30, 32 and 33.
- For the revision after the rulings, at `e7bfcb1`, which changes no source file of `2b165b8`:
  - "Rulings, 2026-11-10". The revision did not read the session's transcript.
  - Decision 33, whole, and decisions 26 to 29 on who ticks, the pollers, the turn and the wake.
  - `docs/using.md`, "Stalls". `src/core/constants.zig`, `src/core/tables/tables.zig`,
    `src/core/tables/tables_deadline.zig`, `src/core/dispatch/dispatch.zig` and
    `src/core/call/call_service.zig`.
  - From the tree before `46235cb`: `adapter.zig`, `adapter_scheduler.zig`, `adapter_tasks.zig`,
    `adapter_wait.zig`, `adapter_rest.zig`, `adapter_net.zig`, `constants.zig`, and
    `bench/alternatives/std_io_echo.zig`.
- For the answers to the third review, at `c2dc00c`: `src/core/stall.zig`, `bench/work/work.zig`,
  `src/kqueue/kqueue_sync_socket.zig`, `src/linux_shared/linux_shared_sync_socket.zig`, decision 5,
  rule 6, and `docs/using.md`, "Submit and tick". From std: `Io.zig` at 1780 to 1846, 1970 to 2023
  and 2391, and `debug.zig` at 536 and 1641. The session's note holds Camilo's question on
  determinism, and the revision did not read the transcript.
- For the revision after the second rulings, at `c300342`: "The second round", as that commit holds
  it. Decisions 10 and 24, for a twin. Decision 33: "The port", "The public module", "How a twin's
  author learns the port" and "`SharedLoop` and the conformance suite". For the forms of the
  `rotor.sync` calls: `src/kqueue/kqueue_sync_socket.zig`.
- For the acceptance, at `f2890f5`, the tag of v0.11.0: decision 33 as accepted and built.
  `src/reactor/reactor.zig`, `src/rotor/rotor.zig`, `src/rotor/rotor_reactor.zig`,
  `src/reactor/reactor_calls.zig`, `src/core/surface.zig`, `src/reactor/dispatch/dispatch.zig`,
  `src/core/stall.zig` and `src/core/tables/tables_deadline.zig`. `docs/using.md`, "Make a reactor"
  and "A library on a reactor", and the README's table of decision records. The rulings of "The
  fourth round, 2026-11-11", as the session relayed them.
