# 23. A host that owns the wait

Status: **accepted** by Camilo on 2026-10-12, and **built** the same day. "Ruling" below says what
Camilo decided, and "What was built" follows it. Decision 20's ruling on its open question 5, the
fallback at init, stands: it is still what a process gets when it asks for nothing.

## Context

Some programs cannot sleep inside `tick`. stompy is the first. It runs a rotor loop inside a
Postgres background worker. A WAL flush, a shutdown and a reload of the configuration reach that
worker only through its Postgres latch, so the worker sleeps in Postgres's own wait. That wait
holds two things: the latch, and a descriptor that turns readable when the loop has something to
deliver. When the wait ends, the worker calls `tick(events, 0)` until a tick delivers nothing, and
then it sleeps again.

This record calls such a program a **host that owns the wait**, or a host.

Before this record stompy had two problems:

- It read the descriptor out of the loop's fields, `loop.inner.kqueue.queue.descriptor` and
  `loop.inner.epoll.queue.descriptor`. Those fields are not API (decision 1, "The public module").
- It could not ask for epoll on a kernel that gives io_uring, and an io_uring loop cannot be used
  this way, as the measurements below show.

Decision 20, open question 5 says the backend is chosen once per process, and ends: "No build
option to pin one backend was built: nothing asked for it yet". stompy's worker is the first thing
that asks.

## What was measured

stompy measured the three rows below on 2026-10-11, on macOS and on Linux 7.0.14 under Docker in
OrbStack. rotor measured them again on 2026-10-12: kqueue on the `mac` machine, macOS 26.6.2, and
the two Linux backends on `orbstack`, Linux 7.0.14 under Docker. In each row a loop has a receive
waiting on a TCP socket over loopback, and the peer then sends. Every cell is a yes or a no and
none is a time: the machine's load average was 75 to 100 during rotor's runs.

| backend | what the host waits with | woken when the receive becomes ready | readable after a tick that delivers nothing |
|---|---|---|---|
| kqueue | a second kqueue that holds `EVFILT_READ` on the loop's kqueue | yes | no |
| epoll | a second epoll instance that holds `EPOLLIN` on the loop's epoll instance | yes | no |
| io_uring | an epoll instance that holds `EPOLLIN` on the ring's descriptor | **no** | no |

The io_uring row is why a host cannot take whichever backend the kernel allows. The ring is set up
with `IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN` (`src/uring/uring_ring.zig`), so the
kernel posts a completion only when the loop's own thread enters the ring. While that thread sleeps
in `epoll_wait` with the ring's descriptor in the set, no completion wakes it. In rotor's check the
epoll instance reported nothing within 500 ms of the send, and the loop's next tick then delivered
the receive. That check ran once by hand, under Docker with `seccomp=unconfined`. It is not a test
in the tree, because `wait_descriptor` answers null on io_uring and the suite holds it to that.

The kqueue and epoll rows are the conformance scenario of
`src/conformance/conformance_wait_descriptor.zig`, which runs on every `zig build test` and in the
Linux gate.

## Ruling, 2026-10-12

Camilo was shown three ways rotor could serve a host:

1. The process picks its backend, and a loop names its descriptor.
2. rotor registers an eventfd with the ring and hands that out.
3. A loop option sets the ring up without `DEFER_TASKRUN`.

He ruled: "Pick the backend". That is the first. The other two are under "Alternatives it beat".

## What was built

### A process requires a backend: `rotor.require_backend`

```text
pub const RequireError = error{ Unsupported, OtherBackendChosen };
pub fn require_backend(wanted: Backend) RequireError!void
```

The process calls it before anything else of the module. `sync`, a `Registry`, a `Loop` and
`backend()` each make the choice when none is made, and the choice holds for the life of the
process, as decision 20 says and for the reasons it gives.

| the process | `wanted` | answer |
|---|---|---|
| has made no choice | a backend this host can run | the choice is stored, and the call succeeds |
| already runs `wanted` | the same backend | the call succeeds and changes nothing |
| already runs another backend | a backend of this system that is not the one it runs | `OtherBackendChosen` |
| any | `epoll` or `uring` on Darwin, `kqueue` on Linux | `Unsupported` |
| has made no choice | `uring`, on a kernel that refuses a ring | `Unsupported`, and nothing is stored |

- **It never falls back.** The caller named the backend, so it gets that one or an error. An error
  stores nothing: after a refused `require_backend(.uring)` the process has still made no choice,
  and may require epoll or leave the choice to the fallback.
- **The answers are error values and not assertions.** Which library of a process asks first is
  not a programmer's mistake that rotor can see, and a kernel that refuses a ring is the
  environment's answer.
- **A refusal is what decision 20 calls one**: `PermissionDenied` or `Unsupported` from the setup
  of a ring made the way a loop makes it (`uring.refused`). A process short of descriptors or
  memory is short of them on any backend, so the choice is stored and `Loop.init` reports it.
- **epoll and kqueue are not asked for.** `Loop.init` reports a kernel that lacks what they need.
- **`rotor.backend()` reports the choice** as before, so the choice is never silent.

The code is in `src/rotor/rotor_loop_backend.zig`, split from `rotor_loop.zig` for the 500-line
limit. It holds `chosen`, which decision 20 built, and `require` beside it. The stored value is
still the one atomic of `rotor_choice.zig`, and `require` stores it with the same compare and swap
`chosen` uses, so two threads that decide at once get one answer.

### A loop names what a host waits on: `Loop.wait_descriptor`

```text
pub fn wait_descriptor(loop: *const Loop) ?Descriptor
```

The surface of `src/core/surface.zig` gains the name, so every backend carries it, and so does a
consumer's own twin (decision 10).

| backend | answer |
|---|---|
| kqueue | the loop's kqueue |
| epoll | the loop's epoll instance, and not the eventfd that wakes the loop, which reports a post and nothing else |
| io_uring | null |

What the host does:

1. It waits for the descriptor to be readable, then calls `tick` with a wait of 0 until a tick
   delivers nothing, then waits again.
2. It ticks that way after it submits or cancels too, before it waits. An operation reaches the
   kernel in a tick.
3. It gives every tick a wait of 0. A tick that blocks arms the loop's wait timer (decision 12,
   point 7, and decision 20, "The wait timer"), and that timer makes the descriptor readable later
   for no operation. Measured on kqueue on 2026-10-12: a tick given a 200 ms wait delivered a
   receive at once, the descriptor turned readable when the timer fired, a tick then delivered
   nothing, and the descriptor stayed readable. On epoll this is read from the code, where a
   timerfd in the set is armed the same way, and was not measured.
4. It does nothing else to the descriptor. It does not read it, close it, or change what it holds,
   and it stops waiting on it before `deinit`, which closes it.

On Linux a host calls `rotor.require_backend(.epoll)` first, because an io_uring loop answers null.

What the descriptor does not report is under "Open questions", with what was measured for each.

### What this changes for stompy

stompy's worker calls `rotor.require_backend(.epoll)` on Linux before it opens a socket, and reads
`loop.wait_descriptor()` where it read the loop's fields.

## Alternatives it beat

None of the costs below was measured. The ruling did not need them: stompy's worker holds one
socket, so io_uring's speed buys it nothing.

1. **An eventfd registered with the ring, handed to the host** (the second way shown). The kernel
   signals the eventfd when the ring has completions, so a host could keep an io_uring loop inside
   its wait. It costs one more descriptor per loop and a signal from the kernel per batch of
   completions, on every loop that asks for it. It is the alternative to build if a host ever
   needs io_uring. Whether the signal comes while completion work is still deferred under
   `DEFER_TASKRUN` is recalled and was not tested, and would be the first thing to measure.
2. **A loop option that sets the ring up without `DEFER_TASKRUN`** (the third way shown). The
   kernel then runs completion work on its own schedule, so completions are slower for that loop,
   and it delivers that work by interrupting the thread, which here is the host's wait. The option
   would also make two kinds of io_uring loop for the conformance suite and the harness to cover.
3. **A build option that pins one backend**, the other shape decision 20 weighed. One binary would
   no longer run everywhere, and a consumer would need a second build of rotor for the one process
   that hosts a loop. A call at run time gives that process epoll and leaves every other process of
   the same binary on io_uring.
4. **A backend chosen per loop.** Decision 20 already says why the choice is per process: the
   sockets `sync` opens before any loop exists must suit the backend, and loops of two backends in
   one process cannot post to each other.
5. **Leaving the consumer to read the loop's fields.** Those fields are not API, and a consumer
   that reads them breaks when a backend moves one.

## What it costs

- **`require_backend`** adds nothing to any path a loop runs. `chosen` is the same one atomic load.
- **`wait_descriptor`** is one read of a field. The surface grows from 21 names to 22, and a
  consumer's twin must carry the new one.
- **A process that requires epoll gives up io_uring for every loop it runs**, since the choice is
  per process: none of decision 3's speed sources, and files need a policy (decision 18).

## How it is checked

- `src/rotor/rotor_loop_backend.zig` tests each answer of `require`. On Linux the test process has
  already chosen, so a test takes the stored choice out, requires a backend, and puts the choice
  back. The Linux gate runs these tests twice, as it runs all of the public module's. The run with
  io_uring is the one that shows a process that requires epoll runs epoll where the kernel gives a
  ring. The run under Docker's default seccomp profile is the one that shows `require(.uring)`
  refused with nothing stored.
- `src/rotor/rotor.zig` holds the public call to those answers, and the public `Loop` to its
  backend's descriptor.
- `src/conformance/conformance_wait_descriptor.zig` runs against every backend. One scenario
  requires a descriptor exactly from the backends that report readiness. The other is a host: a
  second kqueue or epoll instance holds the loop's descriptor, the loop is never given a wait, and
  the scenario requires the descriptor quiet after a tick that delivers nothing, readable once the
  peer's bytes arrive with no tick in between, and quiet again after the tick that delivers the
  receive. It skips on io_uring.
- `tools/halt/kqueue_scenarios.zig` and `tools/halt/epoll_scenarios.zig` each ask an ended loop for
  its descriptor, which must halt: a host that waited on -1 would never wake.

Both gates passed on 2026-10-12: `zig build test` on the `mac` machine, 137 of 137 steps, and
`tools/linux_test.sh` on `orbstack`, Linux 7.0.14. The executables that hold this record's tests:

| run | executable | passed | skipped | failed |
|---|---|---:|---:|---:|
| `zig build test`, macOS 26.6.2 | `rotor` | 14 | 5 | 0 |
| `zig build test`, macOS 26.6.2 | `conformance-kqueue`, and again with a spin budget | 82 | 1 | 0 |
| `tools/linux_test.sh`, with io_uring | `rotor` | 19 | 0 | 0 |
| `tools/linux_test.sh`, default seccomp | `rotor` | 19 | 0 | 0 |
| `tools/linux_test.sh`, with io_uring | `conformance-uring`, and again with a spin budget | 76 | 7 | 0 |
| `tools/linux_test.sh`, default seccomp | `conformance-epoll`, and again with a spin budget | 82 | 1 | 0 |

The five the public module skips on macOS are its Linux tests. One of the seven the io_uring suite
skips is the host scenario. The race gate was not run for this record; `zig build test` compiles
its executables, the new scenarios among them.

Mutations, each measured against the narrowest target that can catch it. "Linux gate" names one
executable of `zig build test-linux`, run in Docker the way `tools/linux_test.sh` runs it.

| mutation | measured against | result |
|---|---|---|
| `require` grants a backend of another operating system | `zig build test-rotor` on macOS | CAUGHT |
| the public `require_backend` grants everything | `zig build test-rotor` on macOS | CAUGHT |
| `require` does not store the choice | `rotor`, Linux gate, with io_uring | CAUGHT |
| `require` grants a backend when the process runs another | `rotor`, Linux gate, both runs | CAUGHT |
| `require(.uring)` does not ask the kernel for a ring | `rotor`, Linux gate, default seccomp | CAUGHT |
| a refused `require(.uring)` stores epoll | `rotor`, Linux gate, default seccomp | CAUGHT |
| kqueue's `wait_descriptor` answers null | `zig build test-conformance-kqueue`, `zig build test-rotor` | CAUGHT |
| epoll's `wait_descriptor` answers null | `conformance-epoll` and `rotor`, Linux gate, default seccomp | CAUGHT |
| epoll's `wait_descriptor` names the wake eventfd | `conformance-epoll`, Linux gate | CAUGHT, by the wake |
| io_uring's `wait_descriptor` names the ring | `conformance-uring` and `rotor`, Linux gate, with io_uring | CAUGHT |
| the public `Loop.wait_descriptor` answers null | `zig build test-rotor` on macOS | CAUGHT |
| kqueue's `wait_descriptor` loses its assertion | `zig build halt-check` | CAUGHT |
| epoll's `wait_descriptor` loses its assertion | `zig build halt-check` | CAUGHT |
| the surface list loses `wait_descriptor` | `zig build test-core`, `zig build test-rotor` | CAUGHT |
| kqueue: a tick with a wait of 0 does not carry its registrations to the kernel | `zig build test-conformance-kqueue` | CAUGHT, by the wake |
| kqueue: the loop's wake event is not cleared when it is delivered | `zig build test-conformance-kqueue` | CAUGHT, by the first quiet check |
| kqueue: a tick with a wait of 0 asks the kernel nothing while an operation waits | `zig build test-conformance-kqueue` | CAUGHT, by the tick after the wake |
| epoll: a descriptor is registered for writing though nobody waits to write | `conformance-epoll`, Linux gate, the new file alone | CAUGHT, by the first quiet check |
| epoll: a tick with a wait of 0 asks the kernel nothing while an operation waits | `conformance-epoll`, Linux gate, the new file alone | CAUGHT, by the tick after the wake |

Two notes on the table:

- "`require` does not store the choice" passes the run under the default seccomp profile, where
  the kernel refuses a ring and the process runs epoll whether or not it required it. Only the run
  with io_uring can catch it, and it does.
- The last two were measured with the suite narrowed to the new file. On Linux one process runs
  every scenario, and under each of those mutations an older scenario halts first, which ends the
  run before the new scenario is reached.

## What would reopen it

- A host that needs io_uring inside its own wait: many sockets, or files without an offload. Then
  alternative 1, the eventfd, is the one to build.
- A process that needs a hosted loop and io_uring loops at once. The choice is per process, and
  decision 20's reasons for that would have to be answered first.
- A host that cannot live with one of the open questions below.

## Open questions

Each has a proposed answer, and the implementation follows it until Camilo rules otherwise. The
measurements are of 2026-10-12, on macOS 26.6.2 for kqueue and on Linux 7.0.14 under Docker's
default seccomp profile for epoll, with a second kqueue or epoll instance holding the loop's
descriptor. They ran once by hand and are not tests in the tree: a test of them would make each gap
a requirement.

1. **A timer that comes due does not make the descriptor readable.** The loop keeps its timers and
   its operations' deadlines in a heap of its own, and a tick finds the ones that are due by
   reading the clock (`Tables.expire`). Each readiness backend also has a wait timer, an
   `EVFILT_TIMER` on kqueue and a timerfd on epoll, but only a tick that blocks arms it, to bound
   that tick's own wait at the nearest deadline (`Tables.wait_bound`). A tick with a wait of 0 arms
   neither. Measured on both: with a 5 ms timer submitted and one tick made, the descriptor was not
   readable within 100 ms, and the next tick delivered the timer. So a host must wake for its
   timers by its own means. stompy wakes at least every 10 ms, so it does not need more today. The
   loop already holds what a host would need, the nearest deadline (`TimerHeap.earliest_ns`), on
   the clock `now_ns` reports. *Proposed: not built. A call that names the nearest deadline is one
   more name on the surface, and the ruling did not ask for it.*
2. **A post does not make the descriptor readable, and neither does an offload worker's result.** A
   sender wakes a loop only when the loop said it would sleep, and a loop says so only inside a
   tick that blocks (`Inbox.settle_to_sleep`, decision 12, point 6). A hosted loop never blocks in
   a tick, so nothing wakes its host. Measured on both: a `Remote` posted to a hosted loop, the
   descriptor was not readable within 100 ms, and the next tick delivered the message. *Proposed:
   not built. A host that takes posts wakes on a period of its own. Building it means moving the
   sleep handshake to the host's wait: a call before the host sleeps and one after it wakes.*
3. **Readiness that is for no operation can keep the descriptor readable.** A tick with a wait of 0
   asks the kernel nothing while no operation of the loop waits on a descriptor (decision 12,
   point 6, and decision 20, "A tick with events and nothing waiting polls nothing"). So what the
   kernel holds ready for no operation stays, and a host's wait then ends at once, each time, until
   an operation waits again or the readiness goes. While any operation waits, every tick asks the
   kernel and the reap clears it, which is why the scenario above holds. Two cases were measured:
   - **epoll**: bytes arrive on a socket whose last receive has completed, and no operation of the
     loop waits. The read direction stays registered after a receive completes (decision 20, "The
     shape"), so the descriptor is readable. A tick delivers nothing and it stays readable. A
     receive that reads the bytes ends it.
   - **kqueue**: a receive that waits is cancelled, and bytes then arrive. kqueue leaves a
     cancelled operation's one-shot filter to fire (`kqueue_cancel.zig`), so the descriptor is
     readable. A tick delivers nothing and it stays readable, and it stays readable after a
     receive that reads the bytes, because that receive completes without waiting. It ends when an
     operation waits. An operation that ends by its `timeout_ns` takes the same path as a cancel.

   Neither case came up the other way round: kqueue's filter for a receive that completed has
   fired and is gone, and epoll takes a cancelled operation's direction out at once. *Proposed: not
   built, and written into `wait_descriptor`'s comment and the guide. A host keeps an operation
   waiting, as stompy's worker keeps a receive on its socket. Two ways to close it, neither chosen:
   a way for a host to make a tick ask the kernel whatever waits, which costs the measured paths
   of decision 12, point 6 nothing because only a host would use it; or leaving nothing registered
   for nobody, which costs kqueue a change per cancel and costs epoll the `epoll_ctl` calls that
   decision 20 measured as saved.*
4. **Should `require_backend(.epoll)` ask the kernel for epoll?** `require_backend(.uring)` asks
   for a ring, because a kernel that refuses one is common. A kernel at decision 2's floor has
   everything the epoll backend needs, and `Loop.init` answers `Unsupported` on one that does not.
   *Proposed: no.*
