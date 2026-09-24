# 15. Datagrams

Status: **accepted** on 2026-09-20, by the owner, who asked for datagrams and named two consumers:
colibri's and chapulin's QUIC transport. Three of its questions he answered directly, recorded
under "What the owner has decided"; the rest are at the end with a proposed answer each, and the
implementation follows the proposed answer until he rules otherwise.

The probe that section demanded has since run, and it **corrected this record**: the payload sits
at a constant offset taken from the reserve asked for, not from the lengths the kernel writes.
The layout below is measured. Three of its four measurements are still open and are marked so.

## Why this reverses decision 2

Decision 2 puts UDP in "Not in version one" and gives the reason:

> **UDP and Unix sockets.** No consumer needs them yet. colibri's QUIC will want UDP, but colibri
> owns no I/O, so the need arrives with whoever embeds colibri.

That is a trigger, not a refusal, and the owner fired it. Two consumers need datagrams, not one:
colibri's QUIC transport and chapulin's. The second matters to the record, because a surface with
two consumers is settled by what both need and not by what one happens to do first.

This record supersedes the UDP half of that row. Unix sockets stay out, and no consumer asks for
them.

## What QUIC needs, which is more than "UDP"

A datagram arm on `Operation.Kind` is the easy part. Four things carry the performance:

1. **The peer address on every received datagram.** The kernel writes it into `msg_name`, so this
   needs `recvmsg` and no control message.
2. **The local address**, so a server on a wildcard address answers from the address the client
   wrote to. Clients on multi-homed paths break without it.
3. **The ECN codepoint**, both directions. QUIC's congestion control reads it; without it the
   stack runs a weaker controller than the specification assumes.
4. **Segmentation**, so one syscall carries many datagrams. Without it a QUIC stack does one
   syscall per packet and loses to TCP, which would be an odd result for this project to ship.

Items 2, 3 and 4 arrive and leave as **control messages**. That is the whole difficulty: a control
message is a kernel type, `Event` is 16 bytes with no room for one, and rotor's surface names no
kernel type.

## The decision

### Two operations, and no change to the twelve that exist

```zig
pub const Code = enum(u8) {
    accept, connect, receive, send, shutdown, close,
    read, write, fdatasync, timer, post, nop,
    receive_from, send_to,
};

/// Result: the bytes of one datagram, and 0 for a datagram that carries none. A datagram socket
/// does not close, so 0 is not an end of stream as it is for `receive`. One event per datagram,
/// each naming its own buffer of the group, until it is cancelled or fails.
///
/// It takes a group and is multishot, always: see "Two layouts, and only one of them is rotor's".
pub const ReceiveFrom = struct { socket: Descriptor, target: Target, multishot: bool = false };

/// Result: the bytes sent, which is every byte of `buffer` or none: a datagram send is not short.
/// `to` says where the datagram goes, what address to send it from, what codepoint to mark it
/// with, and whether to cut it into segments. It belongs to the loop until the final event
/// (decision 5, rule 3), as `Connect.address` does.
pub const SendTo = struct { socket: Descriptor, buffer: ConstBuffer, to: *const Outbound };
```

Adding two arms to the closed union is a compile error in every backend switch that does not
handle them, which is the union working as designed.

### What a received datagram carries

`src/core/datagram.zig` is new, and names no kernel type:

```zig
/// The two congestion bits of the IP header (RFC 3168). The values are the codepoints the bits
/// hold, so nothing turns one into the other.
pub const Ecn = enum(u8) { not_ect = 0, ect1 = 1, ect0 = 2, ce = 3 };

/// What one received datagram carries beside its bytes. Returned **by value**: a caller that
/// keeps the peer address does not keep the buffer, so a reply copies 24 bytes instead of
/// pinning a 64 KiB receive buffer for the life of the answer.
pub const Received = extern struct {
    /// Where the datagram came from.
    peer: Address,
    /// The address of this host it was sent to, when `flags.local`. `port` is 0: the kernel
    /// reports the address, and the port is the socket's.
    local: Address,
    /// The bytes of each segment when the kernel coalesced several datagrams into one, or 0 when
    /// it did not. Every segment but the last holds exactly this many bytes.
    segment_bytes: u16,
    ecn: Ecn,
    flags: Flags,
    reserved: [reserved_bytes]u8 = @splat(0),

    pub const Flags = packed struct(u8) {
        local: bool = false,
        ecn: bool = false,
        /// The datagram was longer than the buffer and the rest is gone.
        truncated: bool = false,
        reserved: u5 = 0,
    };
};
```

`Outbound` is the same shape for a send, with `peer` read rather than written.

### Where the kernel's bytes live: in front of the datagram, not in `Event`

A received datagram's buffer holds the kernel's own head, then the address, then the control
messages, then the datagram's bytes. That is the layout io_uring's multishot `recvmsg` already
writes, so on Linux rotor asks for the shape the kernel produces rather than copying out of it.
The kqueue backend writes the same head itself from its `msghdr`.

**Measured, and not as this record first guessed.** `tools/uring_probe_datagram.zig` ran it on
`orbstack`, Linux 7.0.14, on 2026-09-20:

```text
recvmsg_out: namelen 16, controllen 56, payloadlen 20, flags 0x0
prefix asked 112 (head 16 + name 32 + control 64); prefix written 88
cqe.res 132; payload sent 20; cqe.res - prefix 20
```

The kernel lays the payload out after the space the submission **asked for**, and writes the
bytes it **used** into the head. The two differ whenever the address or the control block is
shorter than its reserve: a `sockaddr.in` reports `namelen` 16 against a reserve of 32. An offset
computed from the written lengths lands at 88, which is 24 bytes short of the payload and inside
the control block. The first version of this record would have computed exactly that.

So the payload sits at a **constant offset**, fixed per buffer group at registration:

```text
prefix = @sizeOf(io_uring_recvmsg_out) + name_reserve + control_reserve
```

Two bytes of control per datagram were measured as 56 for IPv4 with `IP_PKTINFO` and
`IP_RECVTOS`, which is `CMSG_SPACE(12) + CMSG_SPACE(1)` = 32 + 24 on a 64-bit kernel.

### Two layouts, and only one of them is rotor's

**Measured on 2026-09-20, after the conformance suite refused to pass.** A *single-shot* `recvmsg`
with a provided buffer writes the datagram at the **front** of the buffer and answers the address
through the submission's own `msghdr`. A *multishot* one writes the head, the address and the
control block in front of the datagram. The probe shows it plainly: the head a single-shot receive
leaves is the datagram's own text read as integers.

```text
single-shot: recvmsg_out namelen 1869901682, controllen 1633951858, flags 0x70206d61
             cqe.res 20; payload sent 20
multishot:   recvmsg_out namelen 16, controllen 56, payloadlen 20
             cqe.res 132; cqe.res - prefix 20
```

So `receive_from` **takes a group and is multishot**, and `assert_valid` halts on anything else.
One accessor cannot read two layouts, and a surface whose buffer sometimes carries a prefix is
worse than one whose buffer always does. A QUIC stack wants multishot regardless. The kqueue
backend writes the multishot layout whatever shape it is given, so the two agree.

This was found by the conformance suite failing on io_uring after passing on kqueue, which is
what decision 10's one-suite rule is for.

One accessor turns the buffer into rotor's types, and it is the only supported reader:

```zig
pub const Delivery = struct { from: Received, bytes: []u8 };

/// The datagram an event names. `buffer` is the caller's buffer, or the provided buffer the
/// event named, which `provided_buffer` returns.
pub fn datagram(loop: *const Loop, buffer: []u8, event: Event) Delivery;
```

The bytes before the datagram are a reserve whose size is chosen at registration, by a new
`provide_datagram_buffers` and not by a change to `provide_buffers`. A fourth control message
later therefore costs no existing caller a layout change, and no TCP caller gains a precondition.

### What `Event.result` counts

**The datagram's own bytes**, as a TCP receive counts the bytes it received. `try event.outcome()`
means the same thing for every transfer in the surface.

The probe settled what that costs: `cqe.res` less the prefix **is** the payload length, so the
reap subtracts one constant the group already fixed. No dependent load into the buffer, no read
of the head on the hot path. It is one subtract in `uring_reap.complete` and one in kqueue's
`serve`. That function is four statements today and is the path decision 8's experiment measures,
so milestone 3 must know it moved. The alternative — reporting the bytes the datagram occupies, leaving the reap path
untouched — was rejected by the owner: it would hand a caller who writes
`parse(buffer[0..try event.outcome()])` rotor's head as packet bytes, and rotor cannot assert its
way out of a mistake in the caller's code.

## What it costs in memory: nothing in `Slot`, nothing in `Event`

- **`Event` stays 16 bytes.** No field, no flag bit. Its `buffer`, `more` and `buffer_id` bits
  keep their io_uring positions and their comptime assert.
- **`Slot` stays 64 bytes, one cache line, with both reserved bytes still reserved.** A
  `receive_from` stores what a `receive` stores. A `send_to` stores the `Outbound` pointer where a
  send stores its buffer pointer.
- **No pool, no `Options.datagrams`, no new limit on operations in flight.** The kernel copies
  `msg_name` when the submission is prepared, which is the fact `Extra.address` already rests on
  (recalled, and on the list to probe). The outbound control bytes, which the kernel reads later,
  live in a declared reserve inside the caller's own `Outbound` — decision 5, rule 3 already
  governs that memory, by the precedent `Connect.address` set.

So the change adds no allocation, no field to a hot structure, and no comptime assert to relax.

## macOS

macOS carries everything a QUIC stack needs to work, read from the SDK on 2026-09-20:

| need | option | note |
|---|---|---|
| local address in and out | `IP_PKTINFO` 26 | the header says "set src on sent dgram"; `struct in_pktinfo` is declared |
| ECN in | `IP_RECVTOS` 27, `IPV6_RECVTCLASS` 35 | |
| ECN out | `IP_TOS` 3, `IPV6_TCLASS` 36 | |
| do not fragment | `IP_DONTFRAG` 28, `IPV6_DONTFRAG` 62 | |

The IPv6 names sit behind `__APPLE_USE_RFC_3542`, which Zig does not define. That gates the C
header and not the kernel, and rotor passes the level and name as integers already.
`tools/macos_probe.zig` — the first macOS probe this tree has ever had — confirmed it on
2026-09-20, and found two things reading the header could not:

- **46 is a control message's type, not a socket option.** `IPV6_PKTINFO` is what the report
  arrives as; `IPV6_RECVPKTINFO`, 61, is what turns the report on. The backend set 46 with
  `setsockopt`, got EINVAL, ignored it, and reported no packet info on IPv6 at all. No test could
  have caught it: the suite's scenarios are IPv4, and the failure was silent by construction.
- **The type-of-service byte does not survive macOS loopback.** A datagram sent with TOS 0x2A
  arrives with TOS 0. Not the codepoint alone: the whole byte. So **a QUIC stack on macOS runs
  without ECN**, and rotor reports `not_ect` there however the sender marked it. Whether a real
  interface differs is unmeasured, because this tree measures loopback.

The second is a finding and not a fault: nothing in the suite may assert an ECN codepoint on that
host. What it is not, since decision 2's amendment of 2026-09-22, is a reason to treat macOS as a
rehearsal. It is a property of macOS loopback, measured there and nowhere else, so a congestion
controller that needs ECN needs a real interface to be tested on — on either kernel.

**What macOS does not have is segmentation.** `netinet/udp.h` defines exactly one option,
`UDP_NOCKSUM`. There is no GSO and no GRO. So:

- **`segment_bytes` above 0 is refused on kqueue**, with `unsupported`. The owner ruled on this.
- The suite's scenario for it has two arms that both assert — segmentation on Linux, the refusal
  on macOS — rather than one that compiles away on one side. Decision 10 runs one suite on both
  backends so the two cannot drift unnoticed, and a scenario that vanishes is how they would.
- `sendmsg_x` and `recvmsg_x` exist as syscalls 480 and 481 and send many datagrams in one call,
  which is `sendmmsg` and not GSO. They are declared in no public header and Zig does not expose
  them, so using them means hand-declaring a private kernel structure. rotor does not, and this
  record names the door in case a later one wants it.

**Amended on 2026-09-22.** This paragraph used to read that macOS is a development platform and
that no macOS datagram throughput number is published as a claim. Decision 2 now says macOS is a
production platform, so a macOS datagram number is a claim like any other. What stands is the
capability difference above: a QUIC stack on macOS sends one datagram per call and marks no
codepoint, and a row measured there is measuring that.

One correction worth recording, because it changes where macOS datagram work should go: the
missing GSO is not the kqueue backend's largest datagram cost. `kqueue_reap.zig` yields at most
one event per readiness and `serve` attempts one transfer, so a multishot datagram receive drains
one datagram per socket per tick, while `kevent`'s `data` field carries the waiting byte count and
is only ever written as 0. That is rotor's own code and a later record may fix it.

**Fixed on 2026-09-23.** The reap now serves a readiness until the amount in `data` is used
(decision 12, point 3). `bench/datagram/rotor_datagram.zig` reports the ticks a run took, which
shows how many datagrams one readiness served. epoll's reap still serves one operation per
direction: its readiness carries no amount, and decision 20 records the measurement that kept it
that way.

## Alternatives it beat

**Keep the metadata in `Event`.** It does not fit. `Event` is 16 bytes so a reap of 32 reads 512
contiguous bytes, and an `Address` alone is 24.

**A pool of control blocks inside the loop, indexed from the slot.** It needs a new limit, a new
`Options` field, a new error when the pool empties, and 16 bits of a full `Slot`. It exists only
because the send's control bytes must outlive the submission — and the caller's own `Outbound`
already outlives it under a rule decision 5 wrote for `Connect.address`.

**Put the whole thing at a fixed offset in the buffer, one global constant.** The offset then has
to be right for every group. A per-group reserve chosen at registration costs one argument and
survives a fourth control message.

**Do not add UDP at all; let the QUIC stack drive its own socket and use rotor for timers.** It
gives up the thing rotor is for. A QUIC stack with its own socket runs its own event loop beside
rotor's, which is two loops on one thread, and decision 4 says a loop belongs to one thread and
starts nothing.

**A `datagram` flag on the existing `receive` and `send`.** One kind would then mean two things,
and every backend switch would branch on a bool it cannot see in the tag. The union is closed so
that a kind means something.

## What must be measured before it is built

1. **Done, 2026-09-20.** `tools/uring_probe_datagram.zig` answered the payload offset, what
   `cqe.res` counts, that the single-shot and multishot layouts differ, and that `UDP_SEGMENT`,
   `UDP_GRO`, `IP_PKTINFO` and `IP_RECVTOS` are all present on `orbstack`. It corrected this
   record twice; the layout above is measured, not recalled.
2. **Open.** Whether the outbound control buffer must outlive `io_uring_enter`. Until it answers,
   the send path keeps that memory alive to the final event, which is what decision 5's rule 3
   already promises for every buffer an operation names, so a "no" costs nothing and a "yes" is
   already handled.
3. **Open.** A first macOS probe: that the RFC 3542 options are honoured when named by integer.
   rotor has no macOS probe today.
4. **Open.** Two rows of `docs/costs.md`: `recvmsg` with three control messages against `recv`,
   per datagram; `sendmsg` with one against `send`. Milestone 3 fills them.

## What is built, and what is not

Built and passing on both kernels as of 2026-09-20: the two operations, the core types, both
backends, `provide_datagram_buffers`, `open_datagram`, the accessor, six conformance scenarios and
five halt scenarios.

Not built, and each one is a separate piece of work:

- The macOS probe of point 3 above. The RFC 3542 options are set by their numbers and the
  conformance suite passes, which is evidence and not the probe this record asked for.
- `IORING_RECVSEND_BUNDLE` and incremental buffer consumption, both above the 6.1 floor.
- A datagram workload in `bench/` for milestone 4. No speed claim is made for any of this.

## How it is checked

Every check is on the real kernel, on both backends: rotor has no simulator (decision 10).

1. `conformance_udp.zig`: a datagram crosses and its peer address is right; a wildcard socket
   answers from the address it was written to; an ECN codepoint survives both directions; a
   datagram larger than the buffer reports `truncated`; a multishot receive names a buffer per
   datagram and ends with one final event.
2. The segmentation scenario, two arms, both asserting: Linux segments, macOS refuses.
3. The coalescing scenario tolerates GRO rather than requiring it: the segments must reassemble
   to what was sent, whether the kernel handed over one datagram or ten.
4. Fabricated control blocks for the paths a kernel will not produce on demand, one table per
   backend against one table of expectations.
5. Halt scenarios: a buffer no larger than the reserve, a segment count over the cap, a `send_to`
   whose families disagree, a multishot `receive_from` with no group, and a zero-length send.
6. Mutations, reported `CAUGHT` or `NOT CAUGHT`: the head length left out of `Event.result`, the
   peer address read from the wrong offset, `truncated` left off, the ECN codepoint reported as
   the raw TOS byte, `segment_bytes` accepted on kqueue.

## What the owner has decided

1. `Event.result` for a `receive_from` counts the datagram's own bytes, and both reap paths pay
   the subtract.
2. kqueue refuses `segment_bytes`, because macOS has no equivalent.
3. One record decides both operations and both land together.

## Open questions

The implementation follows the proposed answer to each until the owner rules.

1. Does a datagram group get a new `provide_datagram_buffers`, leaving `provide_buffers` and its
   callers untouched? **Proposed: yes.**
2. Is the control reserve chosen per group at registration, rather than by one global constant?
   **Proposed: yes.**
3. Does `sync.open_datagram` set `IP_DONTFRAG` by default, so an oversized datagram returns
   `message_too_long` instead of being fragmented? **Proposed: yes; QUIC needs the DF bit for
   path MTU discovery, and `EMSGSIZE` maps to `unexpected` today either way.**
4. Does `send_to` refuse a zero-length datagram, as `assert_transfer` refuses every zero-length
   transfer today? **Proposed: yes, and the record notes QUIC never sends one.**
5. Is it accepted that a datagram spends a whole provided buffer, so a burst of small datagrams
   can empty a group sized for coalescing and end a multishot receive with `buffers_exhausted`?
   **Proposed: yes, until a record raises the floor for incremental buffer consumption, which is
   recalled as above Linux 6.1.**
6. `Event.Code` gains `message_too_long` and `unsupported`, appended so no published value moves.
   **Proposed: yes.**
7. Does the kqueue drain loop named above belong to this record or a later one? **Proposed: a
   later one, because it changes the TCP path too and has no measurement behind it yet.**
8. Two files must be split before this is written: `uring_sync.zig` is at 498 lines of 500 and
   `kqueue_sync_socket.zig` would cross it. Are those splits their own commits? **Proposed: yes,
   landed first and separately.**
9. Is it accepted that no cell of `docs/costs.md` is filled until this lands, because the paths it
   touches are the paths that table measures? **Proposed: yes, which is the order the owner
   already gave: finish the implementation, then benchmark.**
