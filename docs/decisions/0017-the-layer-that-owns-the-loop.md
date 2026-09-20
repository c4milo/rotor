# 17. The layer that owns the loop

Status: proposed on 2026-09-20, not ruled on. It names a component that does not exist, records
why two rules already written force it to exist, and lists what it would own. Nothing in rotor
changes either way, with one exception this record found and reports below: `Remote`.

## Context

Three separate questions asked on 2026-09-20 resolved to the same missing component.

1. **Where does TLS go?** chapulin is a TLS 1.3 library in C11 and colibri already links it
   (`0016-c-abi-for-c-consumers.md`). Version one of rotor leaves TLS out (`0002-scope.md`). So
   something has to hold a chapulin session against a rotor socket, and nothing does.
2. **Where does DNS go?** Version one leaves DNS out too. Resolution is I/O, so it cannot go where
   the HTTP state machine is.
3. **Where does decision 16's test go?** That record asks for "a harness that links chapulin's
   packaged object the way colibri already does", so chapulin's server role runs under a real
   event loop.

Two rules already written decide the answer, and they decide it together.

- **colibri owns no I/O.** Its own first non-negotiable, read on 2026-09-20: "colibri owns no
  I/O. No socket, no file descriptor, no `poll`, no thread." `0006-stompy-lineage.md` states the
  same fact more briefly. colibri is an **HTTP/2 and HTTP/3** library, client and server, as a
  state machine: bytes in, bytes out.
- **colibri already defines the TLS interface, and chapulin already fills it.** colibri's
  `src/tls/tls.zig` is "the TLS provider vtable, in both modes", and says "no production
  implementation is in this tree". The two modes are **record mode, which serves h2**, and **QUIC
  mode, which serves h3, where RFC 9001 §4 replaces the record layer**. So the shape of the
  chapulin interface is not this layer's to invent; it exists.
- **rotor's loop starts no thread and decides no threading.** CLAUDE.md non-negotiable 4 and
  `0004-threading.md`. rotor offers one loop per thread and a way to post between loops; it never
  places a thread or opens a connection on its own.

So the loop has to be owned by something, and that something is not rotor, not colibri, and not
chapulin. Each of the three questions above is that gap seen from a different side.

## Decision

Proposed: name the component and record what it owns, before any part of it is built.

Working name in this record: **the transport**. The name it carries in code is the owner's to
pick, and this record does not pick it. QUIC uses "transport" for something else, so a different
word may be the better one.

### What it owns

**It has two halves, because colibri speaks two protocols.** h2 runs over TLS over TCP, and h3
runs over QUIC, where the handshake is bound into the transport rather than wrapped around a byte
stream. colibri's TLS vtable already names these as record mode and QUIC mode, and they are not
variations of one job.

| job | half | why it lands here and nowhere else |
|---|---|---|
| Owns a rotor `Loop` and ticks it | both | rotor decides no threading, so a consumer decides it |
| Carries bytes between a socket and colibri's record-mode TLS provider | h2 | chapulin does the crypto; something must move the bytes |
| Holds the bytes of a TLS record that arrived in pieces | h2 | see "What it needs from rotor" below |
| Owns a QUIC endpoint: datagrams, packet pacing, loss detection, connection migration | h3 | all of it is I/O, and `quic` may not import HTTP in colibri either |
| Resolves names | both | resolution is I/O, and colibri owns none |
| Races A and AAAA, and races connects (RFC 8305) | both | connection sequencing is I/O |
| Holds the connection pool | h2 | pooling is I/O, and it is what collapses lookup volume |
| Holds decision 16's test of chapulin's server role | both | it is the only thing that can start a chapulin server under a loop |

The h3 half is much the larger, and it is the reason `0015-datagrams.md` exists. A reader who
takes "the transport" to mean a TLS wrapper around a socket has the h2 half and none of the h3
one.

### What it does not own

| not its job | whose |
|---|---|
| Moving bytes, timers, cancellation | rotor |
| HTTP framing and semantics | colibri |
| TLS handshake, records, certificates | chapulin |

### Where it lives

Outside rotor. The test is the one `0015-datagrams.md` failed and this passes: **can it be
written against rotor's public surface alone?** Datagrams could not. That work added two
`Operation.Kind` arms, a new core file (`src/core/datagram.zig`), two new backend files
(`src/uring/uring_datagram.zig`, `src/kqueue/kqueue_datagram.zig`), changes to eleven more backend
files and to `operation.zig`, `slot.zig` and `constants.zig`, two new declarations on the surface
(`provide_datagram_buffers`, `datagram`), and two kernel probes. Every job in the table above
needs none of that, so the transport is a library **on** rotor and not **in** it. Putting it in
rotor would spend two of CLAUDE.md's "ask before" items, a dependency and a module-graph edge, and
buy nothing.

It does not live in colibri either, for the reason that created it: colibri owns no I/O.
`0016-c-abi-for-c-consumers.md` open question 2 already proposes a candidate tree — "the cheapest
version of this may be a leg in colibri rather than a new harness anywhere" — and a test binary in
colibri's tree is a different thing from colibri the library. That distinction is this record's,
not 0016's.

## What it needs from rotor, and whether rotor has it

Read on 2026-09-20 from `src/core/operation.zig`, `src/core/surface.zig`, the two backends' own
files where a row names one, and `docs/decisions/0004-threading.md`.

| need | rotor today |
|---|---|
| TCP connect, send, receive, shutdown, close | `connect`, `send`, `receive`, `shutdown`, `close` |
| Many connections on one loop | multishot `accept`, multishot `receive` |
| UDP for DNS queries | `receive_from`, `send_to` (`0015-datagrams.md`) |
| Timers for a query timeout, the Happy Eyeballs delay and pool idle | `timer` |
| Abandon one connect that lost its race | `cancel(handle)` for that one operation, or `close`, which cancels that descriptor's operations (`0005-cancellation.md` rule 6). **Not `cancel_all`**, which cancels every operation on the loop |
| Hold a received buffer while a TLS record is still short | `give_back_buffer`, which `src/uring/uring_buffers.zig` and `src/kqueue/kqueue_buffers.zig` both document as called "after the caller has read the bytes the receive event named" |
| A resolver thread handing an answer to the loop | **See the gap below.** Not what it looks like |

### The buffer row, and a tension it exposes

A provided buffer stays the caller's until `give_back_buffer`, so a half-assembled TLS record may
keep one across ticks. The cost is that the group is one buffer smaller until it is returned, and
a group that runs out reports `buffers_exhausted`, which `bench/echo/rotor_echo.zig` handles by
re-arming. Whether that cost is acceptable under many slow TLS handshakes at once is a measurement
nobody has taken.

That reading is this record's, and it does not come from decision 5. Decision 5 rule 3 says "the
buffer belongs to the loop until the final event", and a multishot receive has no final event
while its `more` events flow. Decision 5 never mentions provided buffers or `give_back_buffer`.
So the rule as written and the provided-buffer path as built need reconciling, and no record does
it. That is a gap in decision 5, not a licence taken here.

### The gap: `Remote` is written down and not built

`0004-threading.md` says, under "What another thread may do":

> One thing: `post`. A thread that owns a loop posts through its own loop. A thread that owns no
> loop uses a `Remote`, a handle registered at init that counts against `loops_max`.

**No file under `src/` contains `Remote`.** `0002-scope.md`'s table does not list it either. What
is built is `post` as an `Operation.Kind` arm handed to `Loop.submit`, and `submit` calls
`assert_owner` first, which halts when the caller is not the thread that initialised that loop. So
a thread that owns no loop cannot post today: the call does not fail, it halts the process.

This matters to the transport, because a `getaddrinfo` worker is exactly such a thread. Its
choices today are:

- Give the worker its own rotor `Loop` — its own ring or kqueue, its own memory block and a
  registry slot — and post from there. That is heavy per worker.
- Answer through a socketpair the owning loop has a `receive` armed on. This needs nothing new.
- Build `Remote` as decision 4 describes it.

CLAUDE.md compresses this to "The one call another thread may make is `post`", which reads as
though any thread may post. Decision 4's own text is more careful, and the code is more restrictive
than either.

## Alternatives it beat

**Put each part where it is first needed.** TLS in chapulin's own tree, DNS in rotor, pooling in
colibri. Rejected: DNS in rotor needs a thread and a dependency, which non-negotiable 4 and the
"ask before" list both refuse; pooling in colibri breaks colibri's first non-negotiable. Each
placement breaks a rule that is already written down.

**Give rotor a C ABI and write the layer in C.** `0016-c-abi-for-c-consumers.md` proposes
declining a C ABI, and is not ruled on, so it rejects nothing yet. Its reasoning applies here all
the same: it argues the surface would exist for one caller's tests, and that the dependency points
the other way, because chapulin publishes a C ABI that colibri links.

**Build nothing and let each consumer write its own glue.** Rejected: the glue is the hard part.
Buffer ownership across a handshake, a short write that has to resume in ciphertext, and
`close_notify` against a FIN against decision 5's one final event are all places to get it wrong
once rather than three times. `0016-c-abi-for-c-consumers.md` makes the neighbouring point about
its own case: "partial reads and backpressure are exactly the class of defect a blocking test
cannot produce."

**Use libuv or libxev under colibri instead of rotor.** This is a real alternative and not a straw
one. Both are older, are used in production, and libuv already carries DNS and a thread pool. It
would make rotor's numbers irrelevant to colibri. What decides it is milestone 4: if rotor does
not beat them on the named workloads, this alternative is the right one, and the honest place to
find that out is the harness and not this record.

## What this record does not decide

It names a component. It does not start one, and a proposed record is not a licence to build what
it describes (CLAUDE.md).

## Open questions

1. **Is chapulin's C ABI buffer-in, buffer-out, or socket-shaped?** **Answered on 2026-09-20:
   buffer-shaped, and it cannot be otherwise.** chapulin fills colibri's TLS provider vtable, and
   colibri's first non-negotiable forbids it a socket or a file descriptor, so nothing chapulin is
   handed through that vtable can be an fd. colibri links it by `-Dchapulin-client=<checkout>` and
   `-Dchapulin-server=<checkout>`. The transport is glue and not a rewrite.
2. **Which tree owns it?** Its own, or a binary in colibri's tree that is not colibri the library.
3. **Does colibri speak HTTP/3?** **Answered on 2026-09-20: yes.** colibri's own CLAUDE.md calls
   it "an HTTP/2 and HTTP/3 library — client and server", and its modules include `quic`, `h3`
   and `qpack`. So `0015-datagrams.md`'s two-consumer argument stands as written, and this layer
   has the two halves the table above gives it. An earlier reading of this record had colibri at
   HTTP/1.1 and HTTP/2 and doubted 0015 on that basis; the doubt was wrong and is withdrawn.
4. **Is colibri's client hostname set bounded or unbounded?** A bounded set behind a pool makes
   `getaddrinfo` on one worker enough: the cache hits after warm-up and the worker goes cold. An
   unbounded set makes that worker the ceiling, and a nameserver that hangs blocks the queue behind
   it, which is libuv's own failure mode. Only the unbounded case argues for a resolver, and even
   then a library built to be driven by a foreign event loop beats writing one: `/etc/hosts`,
   `nsswitch.conf`, macOS split-horizon DNS, `.local`, `ndots` and source-port randomization are
   each a way to resolve differently from the rest of the machine. Whichever it is, the answer
   reaches the loop by one of the three routes named in "The gap" above.
5. **Should `Remote` be built, or should decision 4 drop it?** **Answered on 2026-09-20: built.**
   `0018-a-caller-supplied-thread-pool.md` needs it, because an offloaded file operation finishes
   on a thread that owns no loop. That also settles the resolver route in question 4: a
   `getaddrinfo` worker uses the same door.
6. **What does a TLS handshake cost rotor's buffer group?** The measurement named above. It is the
   one number that could send a requirement back to rotor.
