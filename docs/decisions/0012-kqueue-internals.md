# 12. Inside the kqueue backend

Status: accepted on 2026-09-19, by the author of the backend before writing it. Each point is a
choice the code will embody, with the alternative it beat. kqueue reports readiness and io_uring
reports completion, so this backend does what the kernel does for `uring`: it performs the
operation when the descriptor is ready. The caller sees one behaviour, which the conformance
suite checks on both (decision 10). Where speed and sameness pull apart, sameness wins for what the
caller sees: one behaviour on both kernels is what decision 10 rests on.

**Amended on 2026-09-22.** This record used to add "macOS is a development platform (decision 2)"
as the reason a speed cost here was acceptable. Decision 2 now says macOS is a production platform,
so that reason is gone: a cost on this backend is a cost in production, and point 6's amendment of
the same day — a polling tick carrying its own wake trigger, worth 12 µs a tick — is what looking
for one found.

## 1. An operation is tried first, and waits for readiness only when it would block

`flush` performs the system call at once: `accept`, `recv`, `send`, `connect`. Only `EAGAIN`, or
`EINPROGRESS` for a connect, registers a one-shot filter, `EVFILT_READ` or `EVFILT_WRITE`, with
the handle as the filter's user data. When the filter fires, the reap performs the call again.

A send is almost always ready, so registering first would cost a `kevent` change and a wake for
nothing. The price is one wasted call for a receive on an idle socket. libuv and libxev make the
same choice.

An operation that completes in `flush` ends on the loop's finished list, like a timer, and its
event is handed over by the same tick. Decision 5's rule still holds: never from inside
`submit` or `cancel`.

Consequence, stated plainly: "one system call per tick" (decision 3, source 4) does not hold on
kqueue and is not claimed for it. Every transfer is its own call. One `kevent` call per tick
carries the registrations in and the readiness out.

## 2. One table maps a descriptor to the operations waiting on it

kqueue knows one registration per descriptor and filter, and its user data is one word. Two
receives waiting on one socket, or a cancel, or a close, all need to find the operations that
wait on a descriptor. The loop keeps an open-addressing table from descriptor to two list heads,
read and write, linked through `Slot.next`, in memory the caller handed in, with room for two
entries per slot of the slot table.

It is touched when an operation has to wait, when one is cancelled, and at close: never on the
path of an operation that completes at once. The `uring` backend refused this table
(decision 11, point 5) because it would have cost a cache line on every operation. Here it
costs one only where a `kevent` change is being paid for anyway.

With it, `close` keeps decision 5's rule 6 in full: every operation waiting on the descriptor
gets its `canceled` event first, then the close gets its own.

## 3. Multishot operations keep their filter

A multishot accept or receive registers its filter without `EV_ONESHOT`. kqueue is
level-triggered, so readiness the loop did not get to is reported again at the next tick, and a
tick takes no more readiness events than it has room for events. No queue is needed and none can
overflow.

**One readiness serves as many operations as it can**, since 2026-09-23. A readiness carries in
`data` the amount that is ready: the connections a listener has waiting, the payload bytes a socket
can read, or the room it has for bytes to send. Measured on macOS 26.6.2 that day: five datagrams of
100, 200, 300, 0 and 50 bytes read as 650, and five pending connections as 5. The reap tries the
waiters oldest first and stops when a call would block or fails, when the successes have used that
amount, or when the events are full. Every readiness keeps room for one event, because a one-shot
filter that fired and was not served does not report again. Before, a readiness served one
operation, so a burst of datagrams or connections took one tick, and one `kevent`, each
(decision 15, "One correction worth recording").

## 4. Provided buffers are picked by the loop

io_uring picks a buffer from a group itself. Here the loop does: a group is the caller's memory
cut into equal buffers, with a stack of free buffer ids. A receive from a group pops an id,
receives into that buffer, and names it in the event. `give_back_buffer` pushes the id. An empty
stack ends a multishot receive with `buffers_exhausted`, as on io_uring. `register_buffers`
records nothing and changes nothing: there is no page pinning to save.

**A receive from a group is not tried at the flush**, where a receive into the caller's own buffer
is (point 1). epoll tries a single-shot one there since 2026-09-23, because on epoll a receive that
waits pays an `epoll_ctl` of its own (decision 20). Here the filter it registers rides in the
tick's one `kevent` call, so trying it first saves no system call, and when its bytes have not come
it costs a `recv` that answers EAGAIN. It was built and timed on 2026-09-23 with
`rotor_echo --shape group_single`, five alternating rounds at a load average of about 7
(`bench/results/echo-group-single-mac-2026-09-23.md`), and not kept:

| payload | build | median echoes per second | spread percent |
|---:|---|---:|---:|
| 4096 | waits | 148,176 | 21 |
| 4096 | tried at the flush | 139,763 | 10 |
| 65536 | waits | 51,359 | 6 |
| 65536 | tried at the flush | 50,065 | 10 |

Both medians are lower with the change, inside the spread. At that load the times are not a claim,
and they show no gain.

## 5. Files block the loop, and a sync is a full sync

A file operation runs inline in `flush`: `pread`, `pwrite`, and for `fdatasync` and `fsync`,
`fcntl(F_FULLFSYNC)`. Decision 2 accepted the blocking. `F_FULLFSYNC` is what makes the promise
of either sync true on macOS: a plain `fsync` leaves the bytes in the drive's cache. It writes the
data and all of the file's metadata, so it keeps `fsync`'s promise as well as `fdatasync`'s, and
the two operations are the same call on this backend (decision 2, its amendment of 2026-09-26). `open_file`
with `direct` sets `F_NOCACHE`, the nearest macOS has to O_DIRECT, and `set_file_size`
preallocates with `F_PREALLOCATE` and then sets the length.

Observed on Darwin 25.6 while writing the calls:

- `F_PREALLOCATE` reserves from the physical end of the file, and APFS keeps blocks past the end
  of the file after a close. So `set_file_size` reserves only the bytes the file lacks. Asking
  for the full size each time would leak blocks.
- `sync_directory` is a plain `fsync`. devfs and autofs refuse `F_FULLFSYNC` on a directory
  descriptor, and APFS accepts it, so the directory entry is less durable than the file's data.
  No test on this host can tell a dropped directory `fsync` from a made one.

## 6. A post is a ring in shared memory plus a wake

Decision 4 settled the shape. The details:

- The registry holds one single-producer single-consumer ring of messages per ordered pair of
  loops, in memory the application hands it, sized for the loops it will run and not for
  `loops_max`: `loops × loops × ring_bytes`.
- The producer's index and the consumer's index sit on separate 128-byte lines, so the two
  threads never write one line.
- A post writes the message and, when the ring was empty, triggers an `EVFILT_USER` event on the
  receiver's kqueue. That is one `kevent` call for a burst, made in the sender's tick.
- The post's own final event is 0, or `mailbox_full` when the ring has no room, or
  `loop_not_found`. It is produced by the sender's `flush` with no wait.
- The receiver drains the rings that name it twice in each tick, straight into the caller's
  events: before the `kevent` call, inside the places that the kernel's reserve leaves, and after
  it, into what is left (W3, amended 2026-11-07). Each drain starts at `Inbox.sender_cursor` and
  visits the senders in turn, at most `messages_per_drain` from each. When the events run out, the
  cursor moves to the first sender the drain did not visit. A ring that still holds messages is
  drained by a later tick, which does not wait while any ring is non-empty.

These rings are the one place in rotor where two threads touch the same memory. They are tested
with two real threads under load, not only by the conformance suite's single message.

**Added on 2026-09-26: the sleep handshake is modelled.** A test with two threads shows the
interleavings that ran, and the race gate the same. `spec/tla/wake/Wake.tla` models one receiver,
the loops that post to it, and its offload's workers, and TLC checks every interleaving of a small
configuration (`zig build tla`, and a job of its own in CI). Two properties hold: the receiver never
blocks with a message in a ring and no wake on its way, and every message is handed over in the
end. Each mutant breaks one step, and TLC must find a lost wake in it:

| mutant | step broken |
|---|---|
| `skip_recheck` | the receiver blocks without reading the rings after it sets its flag |
| `flag_after_recheck` | the receiver's flag is seen after it reads the rings |
| `sender_reads_first` | a sender reads the flag before its push is seen |
| `clear_before_wait` | the receiver clears its flag before it blocks |
| `no_offload_flag` | the receiver never sets the flag its workers read |
| `flush_sends_no_wake` | a flush notes the receiver and sends no wake |
| `never_delivered` | the same, checked against the second property alone |
| `no_wait_blocks` | a tick with a wait of 0 skips the handshake and then blocks |

On 2026-11-06 the model got a receiver step for a tick with a wait of 0, `DrainNoWait`. A poller
that returns true forces that wait (decision 26), and so does a queued task (decision 27). The tick
drains the rings and returns without a flag. The last mutant breaks that step.

The second and third are what a store waiting in a store buffer past a later load would allow,
which is why the four accesses of `src/core/mailbox.zig`'s argument are `.seq_cst`. The model
assumes that ordering and does not prove the code has it. The AArch64 test of that file is the
evidence for the code.

**Amended on 2026-09-22: a polling tick carries the loop's own wake trigger.** On macOS 26.6.2 a
`kevent` that finds nothing ready parks the thread through the scheduler even with a zero timeout:
12 µs, measured on the `mac` machine, against 444 ns for a call that finds one event ready. `poll()`
on the kqueue descriptor costs 7.8 µs, and `kevent64` with `KEVENT_FLAG_IMMEDIATE` is refused with
`EINVAL` there. A tick polls when its caller gave it no wait, when it already holds finished work or
a message, or when a timer is due, and every such tick paid the park. So `kqueue_tick.zig` adds a
`NOTE_TRIGGER` of the loop's own `EVFILT_USER` event to the changelist of a polling tick: the kernel
applies it, finds the wake event ready and returns in the same call, and the reap drops the wake
event as it always did. A changelist already at `changes_max` triggers with a call of its own.
Measured on the cross-core workload (`bench/alternatives/README.md`): one message from post to reap
went from 6,015 ns to 2,007 ns, and an empty polling tick from 12.5 µs to 358 ns.

**Amended on 2026-09-25: a polling tick with nothing to ask the kernel makes no call.** A tick that
polls, carries no change, and has no operation waiting for readiness skips its `kevent` call. The
kernel could report only the loop's own wake event, which names no operation, and what a wake
announces, a message or an offload's result, is read from its ring before and after the call either
way. A wake another loop sent stays set, and the next call that waits ends at once: the wasted wake
this point already allows. A trigger the loop armed itself is different. A poll whose readiness
filled the caller's room leaves it set, and skipping the next call would leave it for the next wait.
So `Loop.trigger_armed` is set when a poll arms the trigger and cleared when a call hands the wake
event back, and a tick skips its call only while it is clear. A loop with any operation waiting on a
descriptor still makes the call, so an echo server's ticks do not change.

Measured on `mac` on 2026-09-25, from commit `507c762` with and without the change, six alternating
rounds each, once the machine was quiet
(`bench/results/crosscore-kqueue-skip-poll-mac-2026-09-25.md`). Each cell is the median of the six
rounds' medians, with their range:

| candidate | messages per second, `507c762` | messages per second, with the skip | change |
|---|---:|---:|---:|
| rotor | 401,918 (397,314 to 405,679) | 474,017 (470,848 to 480,272) | +17.9 percent |
| libuv | 554,143 (544,180 to 575,142) | 562,818 (551,731 to 584,316) | +1.6 percent |
| libxev | 457,676 (449,241 to 468,663) | 465,845 (459,163 to 480,232) | +1.8 percent |

The ranges of rotor's rounds do not overlap. libuv and libxev do not run the change, so their 1.6
and 1.8 percent is how far the machine moved. rotor's p50 stayed at 2,007 ns and its p99 went from
5,503 to 5,023 ns. Every row carries the harness's **OTHER WORK** mark: the machine was quieter
than on 2026-09-22 and was not idle. rotor now passes libxev on this workload and is still 16
percent behind libuv, so the parity bar of decision 2 is not met here. `rotor_post` in the same
spell (`bench/results/decision-13-idle-kqueue-mac-2026-09-25.md`) agrees: in `waiting` mode with no
gap, one message went from 2,007 to 1,503 ns and the answering loop's CPU per round trip from 2.4
to 1.9 µs.

Mutations, each measured against `zig build test-kqueue` and `zig build test-conformance-kqueue`:

| mutation | caught by | result |
|---|---|---|
| the poll never skipped | `test-kqueue` | CAUGHT |
| the flag never cleared by the wake event | `test-kqueue` | CAUGHT |
| an armed trigger ignored | `test-conformance-kqueue` | CAUGHT |
| arming a poll never sets the flag | `test-conformance-kqueue` | CAUGHT |

**Amended on 2026-09-29: a tick does less of its own work per message.** rotor's cross-core rate was
10 percent behind libuv's. Both make the same `kevent` calls per message, and rotor made about 4,000
more instructions per round trip. Most were its own code, found with `sample` on a program that runs
the ping-pong on two loops in one thread, where no call is made:

- `drain_mailboxes` and the offload's `drain` each declared a 512-byte array of messages as
  `undefined`, which ReleaseSafe fills with a pattern, and a tick called each of them twice. Now the
  ring writes messages straight into the caller's events (`Mailbox.pop_as`), and a loop with no
  offload returns before the array exists. This is in `core`, so epoll and io_uring run it too, and
  no speed claim is made for them.
- A tick that had events to hand over and made no call drained the rings and the offload a second
  time. It now returns: what arrived since waits for the next tick, which does not block while a
  ring holds it.
- The clock is read with `clock_gettime_nsec_np`, which `clock_gettime` calls before it splits the
  answer into a `timespec` that the tick joined again: 11.0 ns a read against 17.1.
- A wake's call carries no timeout. It asks for no events, so it returns at once. A zero timeout
  cost about 500 instructions per round trip in a probe of two threads and no rotor.

rotor's own code per round trip went from 3,969 instructions and 775 cycles to 2,774 and 413, and the
two-thread run from about 35,200 instructions to about 33,600, against libuv's 31,100. `mac` was busy
that evening, so by Camilo's ruling of that day the rate was taken on three of GitHub's `macos-latest`
runners, virtual M1s with 3 processors, 10 alternating rounds on each
(`bench/results/crosscore-own-work-github-macos-2026-09-29.md`):

| measure | result |
|---|---|
| rotor after over rotor before, each round | median 1.048, higher in 22 of 30 rounds |
| rotor over libuv, before | 0.903 to 0.920, by runner |
| rotor over libuv, after | 0.933 to 0.956, by runner |

The rate on `mac` is still to be taken. What is left of the gap is not rotor's code: `sample` puts it
at about 4 percent of the time a thread runs, and the rest is inside the kernel's wake path. The
harness asks for the user-interactive QoS class for rotor and libxev and libuv's program asks for
none, but on those runners removing it from rotor, or giving it to libuv, moved neither.

Deleting the clock read's one assertion is **NOT CAUGHT** by `zig build halt-check`: no parameter
reaches it, as none reached the checks on the return code it replaces (decision 8).

### Amendment of 2026-11-07: the sender cursor and the shares of a tick (W3)

Camilo ruled on 2026-11-07 for W3, the fair tick order, with the recommended answer to each of its
questions. Two defects led to it. The drain started at sender 0 in every call, so when senders 0
to 2 filled the room, the senders above them were never visited. And the finished list took every
place first, so a long list kept the messages and the `kevent` call out of a tick.

The sender cursor:

- `Inbox.sender_cursor`, a `LoopId`, is the sender the next drain visits first. Only the loop
  thread reads or writes it, and it is always below `registry.loops()`.
- A drain visits each sender once, from the cursor, and wraps to 0 at the count of loops. When the
  events run out, the cursor moves to the first sender not visited. A drain that visited every
  sender keeps the cursor and makes no store.
- With `L` loops and a mailbox reserve of `M`, a sender with messages is visited within
  `ceil((L - 2) / ceil(M / 32)) + 1` ticks: 4 ticks at `L = 5` and `N = 64`, 63 ticks at `L = 64`.
- The cursor is a function of the count of drains and the counts each pop found. It reads no clock
  and no random value (non-negotiable 2).

The shares of a tick, `core.tick_share.split`:

| limit | value | what it is |
|---|---:|---|
| `kernel_share_divisor` | 4 | the kernel keeps `max(1, N / 4)` places for operations, plus its own entries |
| `mailbox_share_divisor` | 4 | the mailboxes keep `M = max(1, N / 4)` places |
| `kernel_own_max` | 3 | the most entries of a kernel answer that name no operation |
| `fair_events_min` | 10 | below this many events a tick keeps no reserve |

Each backend names its own entries in `own_entries_max`: 3 on kqueue (the wake trigger, the wait
timer and the group watch), 2 on epoll (the wake eventfd and the wait timer), and 0 on io_uring. A
place that a reserve does not use goes back in the same tick: to the mailboxes, then to the lists
when they filled their share. On kqueue the tick that makes no call gives the places back too.

What the build found, against the design of W3:

- The design wrote the drain as two ranges over one helper. Its first build cost each tick about
  160 more instructions in cachegrind. The drain is one loop, which wraps the sender with a
  compare, and its cost fell to about 30 a tick. The fast path below moved that loop into
  `drain_from_cursor`, for a cursor above 0.
- The design said a kqueue that passes `!quiet` as true while it is quiet is an equivalent mutant.
  It is not: a quiet tick that makes no call then gives the kernel's places back only to the lists,
  and the conformance suite catches it.
- The seeded program of `conformance_program.zig` assumed that a send's event comes before the
  event of the receive that read its bytes. Since W3 a send that ended at the flush can wait on
  `finished` past the reap, so its ledger now counts the unread bytes with a saturated subtraction.

### How W3 is checked

The unit tests are in `inbox_test.zig`, `tick_share.zig` and `tables_finish.zig`, with a seeded
property test of the cursor's bound. The conformance scenarios are `conformance_fair.zig` on every
backend, and `conformance_fair_readiness.zig` on kqueue and epoll. The halt scenarios are in
`tools/halt/core_scenarios_share.zig`. Mutations, each measured against its narrowest target:

| mutation | target | result |
|---|---|---|
| the cursor resets to 0 at each drain | `test-core` | CAUGHT |
| the cursor is not stored | `test-core` | CAUGHT |
| the cursor moves to start + 1 | `test-core` | CAUGHT |
| the cursor stays at the sender the room cut | `test-core` | CAUGHT |
| the drain does not skip the receiver after the wrap | `test-core` | CAUGHT, after a test was added; NOT CAUGHT before |
| `split` keeps `K = 0` | `test-core`; `test-conformance-kqueue` | CAUGHT; CAUGHT |
| `split` leaves out the own entries | `test-core` | CAUGHT |
| `split` keeps `M = 0` | `test-core`; `test-conformance-kqueue` | CAUGHT; CAUGHT |
| `split` keeps reserves below `fair_events_min` | `test-core` | CAUGHT |
| the kqueue tick that makes no call loses its give-back | `test-conformance-kqueue`; `work-gate` (`batch` fails) | CAUGHT; CAUGHT |
| kqueue `after_kernel` loses its give-back | `test-conformance-kqueue` | CAUGHT |
| epoll `after_kernel` loses its give-back | `conformance-epoll`, Linux | CAUGHT |
| io_uring loses its give-back | `conformance-uring`, Linux | CAUGHT |
| `finish_due_timers` puts timers on `finished` | `test-core` | CAUGHT |
| `next_expired` puts timers on `finished` | `test-core` | CAUGHT |
| `drain_lists` gives `fired` all of `F` | `test-core` | CAUGHT |
| `drain_lists` gives `finished` all of `F` | `test-core` | CAUGHT |
| `fired` takes only its half when `finished` is short | `test-core` | CAUGHT |
| `finished` takes only its share when `fired` is short | `test-core` | CAUGHT |
| `wait_bound` does not read `fired` | `test-core` | CAUGHT |
| delete the room assertion of `kernel_reserve` | `halt-check` | CAUGHT |
| delete the own-entries assertion of `kernel_reserve` | `halt-check` | CAUGHT |
| delete the cursor assertion of `drain_from_cursor` | `halt-check` | CAUGHT |
| delete the share assertion of `drain_lists` | `halt-check` | CAUGHT |
| delete the fired part of `assert_empty` | `halt-check` | NOT CAUGHT: the check of the slots in use halts on the same state |
| kqueue passes `!quiet` as true while quiet | `test-conformance-kqueue` | CAUGHT |
| the fast path only below `N / 2 - own`, or up to one entry more | `test-core` | CAUGHT; CAUGHT |
| the fast path always taken; never taken | `test-core` | CAUGHT; CAUGHT |
| the fast path leaves out the own entries | `test-core` | CAUGHT |
| the fast path says the lists are capped | `test-core` | CAUGHT |
| the fast path calls the drain for empty lists | `test-core`; `work-gate` | NOT CAUGHT, it changes no event; CAUGHT |
| `kernel_reserve` keeps a reserve below `fair_events_min` | `test-core` | CAUGHT |
| `kernel_reserve` keeps a reserve for a kernel that cannot answer | `test-core` | CAUGHT |
| the mailbox drain takes the plain loop for any cursor | `test-core` | CAUGHT |
| the mailbox drain never takes the plain loop | `test-core`; `work-gate` | NOT CAUGHT, it changes no event; CAUGHT |
| the plain loop does not store the cursor when the events run out | `test-core` | CAUGHT |
| `drain_lists` gives `fired` the share of `finished` too | `test-core` | CAUGHT |

### The fast path of the first drain

The first build of W3 cost each tick about 80 instructions, and seven rows of each section moved
past the tolerance of the instruction gate. Camilo ruled on 2026-11-07: add a fast path, measure
again, and ask him about each row still over 2 percent. Cachegrind attributed the 80, per tick of
the `task` workload, on arm64 Linux with io_uring:

| where | what it cost | instructions |
|---|---|---:|
| `drain_lists` against the old `drain_finished` | an array of the two lists' shares, built on the stack, and a loop over it | +35 |
| the two mailbox drains | the cursor's load and check, the wrap compare and the second index of each visit | +32 |
| the tick | `split`, the slice to `N - K`, and `capped` | +14 |

The fast path is in `core.tick_share.drain_first`. When the lists hold `c` entries and
`c + own_entries_max <= N / 2`, the share cannot cut them. The tick then drains them whole and
computes only `K`. The arithmetic, for `N >= fair_events_min`, with both divisors at least 4:

- `K <= N / 4 + own` and `M <= N / 4`, so `K + M <= 2 * (N / 4) + own <= N / 2 + own`.
- So `lists_max = N - K - M >= N / 2 - own >= c`, and `drain_lists` would also take every entry, in
  the same order. Both paths write the same events.
- The mailboxes then get `N - K - c >= M`, and the kernel keeps `K`. Every bound of W3's section
  3.6 holds as with the share.

Below `fair_events_min`, `lists_max` is `N`, so the lists are never cut there either. The fast path
says the lists are not capped, because its drain emptied them. The other changes:

- Empty lists skip the call to `drain_finished`. Most ticks find both lists empty.
- `drain_lists` pops both lists in one loop, so `hand_over` has one call, which the compiler
  inlines. With a loop for each list, a drain of one timer cost 29 instructions more.
- `drain_mailboxes` runs the plain loop of before W3 while the cursor is 0. The cursor stays at 0
  until a drain runs out of events, so a loop that is not loaded pays only the cursor's load. Any
  other cursor takes `drain_from_cursor`, the wrapping loop.
- Two forms that the build tried cost more: the two ranges of the design's drain, as a helper
  that the compiler did not inline, and a loop for each list, whose `hand_over` it did not inline.

The instruction gate on 2026-11-07, rotor's own instructions per iteration. `mac` is an Apple M1
Pro on macOS 26.6.2, counted with `/usr/bin/time -l`, the median of 3 runs. The Linux rows are
cachegrind in an arm64 container on `mac`. "Before W3" is `0c1fcf7`, and "first build" is
`005cb7c`. The baseline is not changed.

| section | row | baseline | before W3 | first build | with the fast path | percent |
|---|---|---:|---:|---:|---:|---:|
| macos-aarch64-kqueue | `post` | 1217 | 1217 | 1379 | 1199 | -1.5 |
| macos-aarch64-kqueue | `post-operation` | 3051 | 3004 | 3317 | 3114 | +2.1 |
| macos-aarch64-kqueue | `timer` | 1111 | 1094 | 1185 | 1151 | +3.6 |
| macos-aarch64-kqueue | `batch` | 24624 | 24567 | 24516 | 24772 | +0.6 |
| macos-aarch64-kqueue | `wait` | 5296 | 5293 | 5388 | 5290 | -0.1 |
| macos-aarch64-kqueue | `task` | 615 | 615 | 696 | 606 | -1.5 |
| macos-aarch64-kqueue | `tasks-64` | 4558 | 4544 | 4624 | 4534 | -0.5 |
| macos-aarch64-kqueue | `record` | 1222 | 1226 | 1317 | 1283 | +5.0 |
| macos-aarch64-kqueue | `poller` | 573 | 573 | 654 | 564 | -1.6 |
| linux-aarch64-uring | `post` | 1061 | 1063 | 1223 | 1039 | -2.1 |
| linux-aarch64-uring | `post-operation` | 2794 | 2827 | 3136 | 2905 | +4.0 |
| linux-aarch64-uring | `timer` | 1025 | 1037 | 1128 | 1082 | +5.6 |
| linux-aarch64-uring | `batch` | 23757 | 23761 | 23770 | 24012 | +1.1 |
| linux-aarch64-uring | `task` | 559 | 557 | 638 | 545 | -2.5 |
| linux-aarch64-uring | `tasks-64` | 3910 | 3908 | 3989 | 3896 | -0.4 |
| linux-aarch64-uring | `record` | 1153 | 1154 | 1245 | 1199 | +4.0 |
| linux-aarch64-uring | `poller` | 516 | 517 | 598 | 505 | -2.1 |
| linux-aarch64-epoll | `post` | 1150 | 1150 | 1312 | 1142 | -0.7 |
| linux-aarch64-epoll | `post-operation` | 2931 | 2931 | 3240 | 3039 | +3.7 |
| linux-aarch64-epoll | `timer` | 1051 | 1051 | 1143 | 1104 | +5.0 |
| linux-aarch64-epoll | `batch` | 23845 | 23773 | 23785 | 24038 | +0.8 |
| linux-aarch64-epoll | `wait` | 632 | 632 | 717 | 629 | -0.5 |
| linux-aarch64-epoll | `task` | 593 | 593 | 675 | 589 | -0.7 |
| linux-aarch64-epoll | `tasks-64` | 3985 | 3944 | 4026 | 3940 | -1.1 |
| linux-aarch64-epoll | `record` | 1175 | 1175 | 1267 | 1228 | +4.5 |
| linux-aarch64-epoll | `poller` | 557 | 557 | 639 | 553 | -0.7 |

Nine rows stay over 2 percent: `post-operation`, `timer` and `record` in each section. Each of them
hands over an event from the lists in each tick. Against the tree before W3, cachegrind puts the
rest of `timer` on io_uring in three places: the drain of one fired timer, 21 more, because the
loop computes the share and pops both lists once more before it stops; the tick, 23 more, for
`drain_first`, the slice to `N - K` and `capped`; and the two mailbox drains, 10 more. A due timer's
push onto `fired` costs 9 fewer than its push onto `finished` did. These rows wait for Camilo's
ruling. Three io_uring rows, `post`, `task` and `poller`, sit more than 2 percent under the
baseline, and the gate asks for a lower line. The x86-64 rows are not measured: they come from CI.

## 7. Timers, deadlines, cancellation

As in `uring`, from `core`: the heap orders every deadline, the nearest one bounds the `kevent`
wait, and a passed deadline is a cancel the loop issues (decision 11, point 1). A cancel of an
operation that waits for readiness unlinks it from its descriptor's list and ends it at once
with `canceled`. The filter is left to fire: it is one-shot, and the reap finds no operation
waiting and does nothing.

**Amended on 2026-09-26, by Camilo's ruling of that day: a timer event bounds the wait, and the
`kevent` call that waits carries no timeout.** On macOS a `kevent` call with a timeout costs about
1,000 more instructions in the kernel than the same call with none, whatever the timeout is. A
tick always blocked with a timeout, because its wait is bounded (`wait_ns_max`) even when no
deadline is due. libuv passes no timeout when no timer is due, and this was the largest part of
rotor's loss to libuv on the cross-core message. Measured with two threads on two kqueues sending
an `EVFILT_USER` trigger back and forth, without rotor, three runs of 200,000 round trips each on
`mac` on 2026-09-26, in instructions per round trip as `/usr/bin/time -l` counts them, user and
kernel together:

| how each side bounds its wait | instructions per round trip |
|---|---:|
| no timeout | 28,900 to 30,048 |
| no timeout, and an `EVFILT_TIMER` armed once | 29,208 to 29,535 |
| a 1 ms timeout | 31,284 to 31,837 |
| a 10 s timeout | 31,067 to 31,386 |
| no timeout, and an `EVFILT_TIMER` armed again by every call | 31,140 to 31,800 |

So an armed timer costs a wait nothing, and arming it costs what a timeout costs. The design:

- Each loop has one `EVFILT_TIMER`, one-shot, and `Loop.wait_timer_deadline_ns` records when it
  fires, or 0 when it is not armed. A tick that blocks arms it in its changelist and waits with no
  timeout.
- The timer is left in place when it fires no later than this wait's deadline and has not fired
  yet. A loop that waits often, such as the two loops of a ping-pong, arms it about once per wait
  bound instead of once per tick.
- A timer an earlier tick armed can fire before this tick's deadline. When its event is all the
  call returned, the tick arms the timer for the time left and waits again, at most
  `wait_timer_rearms_max` times, so a quiet tick still takes its whole wait.
- A changelist with no room for the timer makes the call carry the timeout, as before.
- The reap drops the timer's event, which names no operation, and sets the deadline back to 0.

What it costs: 8 bytes in `Loop`, and in a loop that waits often, one more `kevent` call about once
per wait bound, when a timer fires before a later tick's deadline. `rotor_post` in `waiting` mode,
two loops of a ping-pong, counted 37,631 and 37,788 instructions per round trip before the change
and 35,550 and 35,902 after, in two sets of ten alternating runs on `mac` on 2026-09-26. The
machine's load average was 12 to 20, so no rate is claimed there. The rate was taken on 2026-09-27,
once the load had stayed under 1.5: six alternating rounds of each build, every row still marked for
other work (`bench/results/crosscore-kqueue-wait-timer-mac-2026-09-27.md`). rotor's cross-core rate
rose 5.2 percent, from 481,174 to 506,099 messages per second, and its p50 fell from 2,007 to 1,503 ns;
libuv and libxev, which the change does not reach, moved -0.2 and 0.5 percent. rotor is 10 percent
behind libuv and 9 percent ahead of libxev on this workload.

Alternatives:

- **A wait with no bound in the API**, as libuv's and libxev's loops have. The backend would pass no
  timeout when no deadline is due. It changes the public API and the named limit `wait_ns_max`, and
  only a caller that asks for it gains. Declined the same day in favor of this design.
- **A longer wait bound.** A 10 s timeout costs what a 1 ms one does, above.
- **Arming the timer on every wait.** It costs what the timeout costs, above.

The epoll backend took this design on 2026-09-26 with a timerfd (decision 20, "The wait timer"), and
the io_uring backend on 2026-09-27 with one armed `IORING_OP_TIMEOUT` (decision 6, "The wait
timer").

**Fixed on 2026-09-27: the wait timer asks to fire when it is due (`NOTE_CRITICAL`).** Without that
flag macOS may fire an `EVFILT_TIMER` late, to coalesce it with other timers, by more the lower the
process's priority tier. A tick's wait then ended late, and so did every timer deadline a tick
waited for. The conformance suite's test that a repeating timer does not drift failed on GitHub's
macOS runners in four of the nine runs after this point landed, and in none of the fifteen before.
Measured on `mac` with a probe outside rotor, a 5 ms wait 40 times, the median lateness and its p90:

| how the wait is bounded | normal | the process marked background (`taskpolicy -b`) | the thread marked background |
|---|---:|---:|---:|
| `EVFILT_TIMER` | 1,180 µs (1,305) | 99,147 µs (100,848) | 99,294 µs (100,607) |
| `EVFILT_TIMER` with `NOTE_CRITICAL` | 33 µs (55) | 36 µs (303) | 50 µs (900) |
| a `kevent` timeout, before this point | 636 µs (662) | 642 µs (680) | 645 µs (1,038) |

So with the flag a wait ends closer to its deadline than the timeout did. The conformance suite run
as a background process failed three times of three without it and passed five of five with it; the
tree before the wait timer passed three of three. `kqueue_tick.zig` marks its own thread background
and requires the best of twenty quiet ticks of 5 ms to end within 50 ms of the wait; until
2026-09-30 it was the best of five within 20 ms, which failed three times on a machine at load
averages of 36 to 98, where a background thread also waits for a core. With the flag
removed that test fails: CAUGHT. The cross-core rate above was measured before the fix, in a
ping-pong whose timer rarely fires, and was not measured again.

**Amended the same day: the tick reads `CLOCK_MONOTONIC_RAW`.** `CLOCK_MONOTONIC` on macOS counts in
1,000 ns steps and costs 20.1 ns a read; `CLOCK_MONOTONIC_RAW` counts in 41 ns steps and costs 14.5
ns, and both keep counting while the machine sleeps. So `Loop.now_ns` counts in 41 ns steps on this
backend. The benchmark harness reads the same clock, so its spans and a loop's deadlines agree. Since
2026-09-29 the tick reads it with `clock_gettime_nsec_np` (point 6, its amendment of that day).

Mutations, measured against `zig build test-kqueue`, and against `zig build halt-check` for the two
assertions on the timer's bound:

| mutation | result |
|---|---|
| the timer armed again on every wait | CAUGHT |
| no second wait after a timer that fired early | CAUGHT |
| the reap leaves the deadline set | CAUGHT |
| no check for a full changelist | CAUGHT |
| a timer the kernel refused waited on again | CAUGHT |
| no check that the deadline passed before waiting again | CAUGHT |
| a second wait whatever the call returned | CAUGHT |
| a timer of 0 ns allowed | CAUGHT |
| a timer above `wait_ns_max` allowed | CAUGHT |

## 8. Accepted sockets

macOS has no `accept4`. The backend sets `O_NONBLOCK` and `FD_CLOEXEC` on an accepted socket
with two `fcntl` calls, and `SO_NOSIGPIPE` with a `setsockopt`, because macOS has no
`MSG_NOSIGNAL` either. That is three system calls per accepted connection that Linux does not
pay, and the accept-storm numbers on macOS will show it.

Observed on Darwin 25.6: an accepted socket inherits `O_NONBLOCK` and `SO_NOSIGPIPE` from its
listener, and does not inherit `FD_CLOEXEC`. With a listener from `sync.listen`, two of the three
calls change nothing. The backend still makes all three, because the caller may hand it a
listener it opened some other way. Dropping the two calls for a listener the loop can prove it
prepared is a measured optimisation for later, not a default.

## 9. Registered descriptors are a table in the loop

kqueue has nothing to register a descriptor with. The loop copies the list
`register_descriptors` was handed into a table of its own, 4 KiB for
`registered_descriptors_max` entries, inside the `Loop`. The flush swaps the index an operation
names for the descriptor registered there, and clears the flag, before anything else reads the
slot. So the table of waiters, the cancel and the close all see a descriptor, as before.

`register_descriptors` refuses a descriptor that is not open with `DescriptorInvalid`, which it
finds with `fcntl(F_GETFD)`, because io_uring refuses one. Nothing is gained on this backend and
nothing is claimed: the table exists so that one program runs on both.

## 10. A call that fails keeps its registrations

**Amended on 2026-11-06, by Camilo's ruling of that day.** He asked for an investigation and a
proposal, and then accepted the proposal below, with the behaviour it changes for a tick that meets
a refused change. The code is built.

### The defect

Until this amendment, `tick` set `changes_used` to 0 after its `kevent` call, whether the call
succeeded or failed. When the call failed, the registrations on the list were lost. An operation
whose registration was on the list then waited until its deadline or a cancel. With no deadline it
waited for ever.

A resend of the list is not always safe, because a call can apply part of its list before it fails.

### What a failed call applies

A probe in C ran these cases on macOS 26.6.2 on 2026-11-06. "Room" is the length of the eventlist.

| case | answer | changes applied |
|---|---|---|
| the kqueue descriptor is a socket | -1, EBADF | none |
| a refused EV_DELETE second of three, room 0 | -1, ENOENT | the first only |
| a refused EV_DELETE second of three, room 1 | 1, the refusal with EV_ERROR | all three |
| two refused changes of four, room 1 | -1, EBADF of the second | those before the second |
| EV_ADD twice, then EV_DELETE twice, with EV_RECEIPT | 4 answers: 0, 0, 0, ENOENT | all |
| EV_DELETE of a one-shot filter that fired | ENOENT | none |
| EV_ADD of a closed fd, a missing EV_DELETE, an EV_ADD, all with EV_RECEIPT, room 3 | 3 answers: EBADF, ENOENT, 0; no readiness | the last |

So:

- A refused change fails the call only when the eventlist has no room for its answer. The call
  then stops at that change. The changes before it are applied, and the changes after it are not.
- A call that returns a refusal or a receipt does not read readiness. With EV_RECEIPT, a readiness
  that the call did not read stays for the next call.
- An EV_ADD of a filter that is there answers 0, so it is safe to send again. An EV_DELETE of a
  filter that is not there answers ENOENT.
- kevent(2) ties EINTR to the timeout, so a call ends in EINTR only while it waits. It also says
  that the kernel applies every change before it reads events. The probe did not make a call end in
  EINTR.

A tick's call has room 0 when the drains filled the caller's events before the call. Then one
refused change, such as an EV_ADD for a descriptor the caller closed, fails the tick. The tick
returns `Unexpected`, and the changes after the refused one are lost.

### What was decided

`kqueue_tick_recover.zig` holds the change. A call that succeeds empties the list, as before. A call
that fails goes to `recover`:

1. The tick's own trigger and wait timer leave the list, and `wait_timer_deadline_ns` goes back to
   0. A deadline left set for a timer that is not armed would let a later wait block for ever.
2. After `SystemResources`, every attempt applied the list before a signal ended its wait. The list
   is emptied and the error is returned.
3. With no registration on the list, the kqueue itself failed, and the error is returned.
4. Otherwise `apply_with_receipts` sends the registrations again in one call, with EV_RECEIPT on
   each and room for every answer. The refused ones stay on the list for the next tick.
5. When that call fails too, the kqueue failed. The list stays as it was, and the error is returned.
6. When it succeeds, the failed call stopped at a refused change. Nothing is lost, and the tick goes
   on with no readiness and no error.

A registration the failed call applied is applied again. An EV_ADD changes nothing. An EV_DELETE
comes back refused, and the next tick's reap tries the first waiter of that filter once. A try that
would block changes nothing.

The success path pays one branch. The failure path pays one more `kevent` call.

### Alternatives

- **Drop the list, as before.** It loses registrations, and an operation can wait for ever.
- **Keep the whole list and send it unchanged in the next tick.** It is one line. A refused change
  with no room fails every tick again while the room stays 0. The tick cannot tell a failed kqueue
  from a refused change.
- **EV_RECEIPT on every change of the tick's call.** No refused change fails a call then. But a call
  that returns a receipt does not read readiness, so each tick would need two calls.
- **Room in the eventlist for every change.** The reap needs one event for each readiness, so the
  room is the caller's free events. Each tick with more changes than that room would need a call of
  its own first.

### What it does not cover

- `apply_early` sends a full list early. When that call fails as a whole, it still drops the list,
  because a full list has no room for the new change.
- `Queue.call` sends the list again after EINTR. An EV_DELETE that the first attempt applied then
  comes back refused, and the reap tries the first waiter of that filter once.
- A refused change with no room for its answer, such as an EV_ADD for a closed descriptor, stays on
  the list. While the room stays at 0, each tick makes a failed call and a resend, one more `kevent`
  call per tick. The refusal reaches the reap only at a tick with room, so its waiter ends then.
- On a tick that waits and has room, two or more refused changes can still fail the call. The
  resend then succeeds, and the tick returns 0 events at once, without its wait.

### Checks

`kqueue_tick_test.zig` replaces the kqueue with a socket through `dup2`, so the call fails on
demand. A receive whose registration was on the list ends once the kqueue is back. A second test
puts a refused EV_DELETE before a registration, with room 0. The tick returns its event and no error,
and the receive ends two ticks later. `kqueue_tick_recover.zig` tests `recover` alone.
`tools/halt/kqueue_scenarios.zig` holds two scenarios for its assertions.

Mutations, measured against `zig build test-kqueue`, and against `zig build halt-check` for the
two assertions:

| mutation | result |
|---|---|
| a failed call empties the list, as before | CAUGHT |
| the tick's own trigger and timer kept | CAUGHT |
| the wait timer's deadline left set | CAUGHT |
| `SystemResources` handled as any other failure | CAUGHT |
| no early return with no registration | CAUGHT |
| receipts left on a list whose call failed | CAUGHT |
| a resend that failed reported as success | CAUGHT |
| a resend that worked still fails the tick | CAUGHT |
| registrations counted after the trigger | CAUGHT |
| `recover`'s assertion on the count deleted | CAUGHT |
| `apply_with_receipts`'s assertion on an empty list deleted | CAUGHT |

## Not in this backend

- One loop per core by SO_REUSEPORT: decision 4 recalled that macOS does not spread connections
  across such sockets, and the conformance suite's count of accepts per socket will say.
- Any claim about file workloads (decision 2).
