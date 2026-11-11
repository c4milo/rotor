//! What a loop receives from other threads, and the sleep handshake that makes sure it wakes for it
//! (decision 12, point 6): the messages other loops post to its mailboxes, on every backend since
//! 2026-09-25 (decision 4), and the results its offload's workers push to their rings, on kqueue
//! and epoll (decision 18). io_uring has no offload: the kernel performs its file operations.
//!
//! Each loop embeds one `Inbox`. Until 2026-09-23 the two readiness backends wrote these fields and
//! the handshake out twice, so every change to the handshake had to land in two places.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const event = @import("event.zig");
const mailbox = @import("mailbox.zig");
const offload = @import("offload.zig");
const operation = @import("operation.zig");

const reserved = @import("reserved.zig");
const Event = event.Event;
const Hook = reserved.Hook;
const LoopId = operation.LoopId;
const Mailbox = mailbox.Mailbox;
const Message = operation.Message;
const Registry = mailbox.Registry;

/// What the visits of one drain write: an event for each message of a caller's tag, and none for
/// a reserved tag: a `Message.wake` (decision 29), a call or a return (decision 32). One `Visit`
/// serves every ring of the drain, so a visit costs no new `Visit` and no sum of its own. A
/// reserved message still counts as one message of its ring's visit, so a ring of them cannot keep
/// the drain longer than `messages_per_drain` for each visit.
const Visit = struct {
    out: []Event,
    written: u32 = 0,

    /// Writes the event of `message` into the next place, and counts it only when its tag is a
    /// caller's. A reserved tag leaves an event of tag 0 in a place that the next message takes,
    /// or that no caller reads. There is no branch, so the compiler keeps the ring's read inline in
    /// the drain. A branch here made it a call: the work gate's `timer` row counted 1,179
    /// instructions on `mac`, against 1,151 at `48cacba` (decision 29, "What was built", item 1),
    /// and `post` 1,321 against 1,217 when decision 32 tried a branch to a cold function.
    /// `Event.message` keeps its check of the tag of every message that makes an event.
    fn write(visit: *Visit, message: Message) void {
        const reserved_tag = message.tag > constants.message_tag_max;
        const tag = if (reserved_tag) 0 else message.tag;
        visit.out[visit.written] = Event.message(message.payload, tag);
        visit.written += @intFromBool(!reserved_tag);
    }
};

/// The slow path of `drain_mailboxes`, which a backend hands it: a function that calls
/// `take_reserved` with the loop's hook. Decision 7 confines `noinline` and `@branchHint` to its
/// named files, so a backend keeps the slow path out of its tick there, and this file stays plain.
/// The drain returns what the slow path returns, so no value of the drain lives across the call,
/// and the drain saves no register for it.
pub const TakeReserved = fn (
    inbox: *Inbox,
    receiver: LoopId,
    events: []Event,
    first: LoopId,
    written: u32,
) u32;

/// The low bits of a reserved tag that are 0 in a wake and not 0 in a call or a return. The slow
/// path ORs them, one instruction for each message, and needs no compare with the wake's tag.
const handed_tag_bits: u32 = 3;

comptime {
    assert(constants.message_tag_wake & handed_tag_bits == 0);
    assert(constants.message_tag_call & handed_tag_bits != 0);
    assert(constants.message_tag_return & handed_tag_bits != 0);
}

/// What one slow path hands each reserved message: the loop's hook, and the sender of the ring it
/// visits now. The slow path writes `sender` before each ring it visits.
const Taker = struct {
    hook: *const Hook,
    sender: LoopId,
    /// Not 0 once the slow path handed a call or a return to the hook: the OR of each reserved
    /// tag's low bits (`handed_tag_bits`).
    handed: u32,

    /// Takes one message with a tag above `message_tag_max`: a wake, a call or a return. It writes
    /// no event. The hook checks the tag: a plain loop's `Hook.none` drops a wake and halts on any
    /// other tag (class B), and a reactor's hook halts on a tag that is not one of the three.
    fn take(taker: *Taker, message: Message) void {
        taker.hook.take(taker.hook.context, taker.sender, message);
        taker.handed |= message.tag & handed_tag_bits;
    }
};

/// The slow path of a drain whose visit of the ring of `first` read a reserved tag, with `written`
/// events before that visit. The ring has not taken the visit's slots back, so this visits it
/// again. Then it visits each sender that the drain did not visit yet, up to the cursor, as the
/// drain would. It hands each wake, call and return to `hook` in the order of its ring (decisions
/// 29, 32 and 33), and returns the events of the whole drain. When it handed a call or a return,
/// it sets `inbox.handed`. Halts on a `first` that is the receiver, and on a ring of `first` that
/// is empty, which no drain hands over (class B).
pub fn take_reserved(
    inbox: *Inbox,
    receiver: LoopId,
    events: []Event,
    first: LoopId,
    written: u32,
    hook: *const Hook,
) u32 {
    const registry = inbox.registry.?;
    const loops = registry.loop_count();
    assert(first != receiver);
    assert(!registry.mailbox(first, receiver).is_empty());
    var taker: Taker = .{ .hook = hook, .sender = first, .handed = 0 };
    var visit: Visit = .{ .out = events, .written = written };
    const cursor = inbox.sender_cursor;
    var sender: usize = first;
    for (0..loops) |_| {
        if (sender != receiver) {
            const room = @min(events.len - visit.written, constants.messages_per_drain);
            if (room == 0) {
                inbox.sender_cursor = @intCast(sender);
                break;
            }
            taker.sender = @intCast(sender);
            take_visit(registry.mailbox(@intCast(sender), receiver), &visit, @intCast(room), &taker);
        }
        sender += 1;
        if (sender == loops) sender = 0;
        if (sender == cursor) break;
    }
    assert(visit.written <= events.len);
    if (taker.handed != 0) inbox.handed = true;
    return visit.written;
}

/// The visit of one ring on the slow path: each message of a caller's tag writes an event, and each
/// reserved tag goes to the taker. The slots are the drain's until the ring takes them back, so
/// the reserved ones are read again before the release.
fn take_visit(ring: *Mailbox, visit: *Visit, room: u32, taker: *Taker) void {
    const before = visit.written;
    const peeked = ring.peek_each(room, visit, Visit.write);
    if (peeked.count == 0) return;
    if (visit.written - before != peeked.count) {
        for (0..peeked.count) |offset| {
            const message = ring.message_at(peeked, @intCast(offset));
            if (message.tag > constants.message_tag_max) taker.take(message);
        }
    }
    ring.release(peeked);
}

/// The slow path for a test's loop: a `Container` with the fields `inbox` and `hook`.
pub fn TestTake(comptime Container: type) type {
    return struct {
        pub fn take(inbox: *Inbox, receiver: LoopId, events: []Event, first: LoopId, written: u32) u32 {
            const container: *Container = @alignCast(@fieldParentPtr("inbox", inbox));
            return take_reserved(inbox, receiver, events, first, written, &container.hook);
        }
    };
}

pub const Inbox = struct {
    /// Where loops find each other's mailboxes. Null for a loop that posts to none and that none
    /// posts to.
    registry: ?*Registry,
    /// True while the registry says this loop sleeps, so `wake_up` ends it once.
    sleeping: bool,
    /// One ring per worker of the offload, which the worker writes and this loop reads. Empty
    /// unless the loop's file policy is `offload`.
    completions: []Mailbox,
    /// Set while this loop is inside its blocking call into the kernel, so a worker on another
    /// thread knows to wake it. The workers read it, so it is atomic, where `sleeping` is not
    /// (decision 18, and decision 12's point 6 for the race it settles).
    offload_asleep: std.atomic.Value(bool),
    /// The operations out on the offload's workers, the file operations that wait for room, and the
    /// closes that wait for a worker (decision 18, amendment of 2026-11-06). Only the loop thread
    /// touches it. It stays empty unless the loop's file policy is `offload`.
    offload_in_flight: offload.InFlight,
    /// The sender whose ring the next `drain_mailboxes` visits first (W3, ruled 2026-11-07). It is
    /// always below `registry.loop_count()`. Only the loop thread reads or writes it.
    sender_cursor: LoopId,
    /// True once a drain handed a call or a return to the loop's hook, which queued a task that the
    /// reactor's next tick runs (decision 33, "The reserved hook"). A tick that would block takes it
    /// with `take_handed`, and does not block, as after a drain that wrote an event. Only such a
    /// tick reads it, so a tick that does not block pays nothing for it, and a poll of the spin of
    /// decision 13 keeps it for the tick that ends the spin. The hook raised `outstanding`, so the
    /// next tick calls `take_kept_error`, which clears it. Only the loop thread touches it.
    handed: bool,

    /// `out` is the out array a loop with an offload carved from its memory, or null for one with
    /// no offload (`offload.InFlight`).
    pub fn init(registry: ?*Registry, completions: []Mailbox, out: ?*offload.OutArray) Inbox {
        return .{
            .registry = registry,
            .sleeping = false,
            .completions = completions,
            .offload_asleep = .init(false),
            .offload_in_flight = .init(out),
            .sender_cursor = 0,
            .handed = false,
        };
    }

    /// Moves the messages other loops posted to loop `receiver` into `events`, oldest first per
    /// sender, until the events run out. The drain visits the senders in turn from
    /// `sender_cursor`, at most `messages_per_drain` from each. When the events run out first, the
    /// cursor moves to the first sender the drain did not visit, so each sender gets one visit per
    /// rotation (W3, ruled 2026-11-07). A ring that still holds messages then is drained by a later
    /// tick, which does not wait while one does.
    ///
    /// A cursor at 0 visits the senders in the order of the plain loop below, which needs no wrap.
    /// The cursor stays at 0 until a drain runs out of events, so a loop that is not loaded pays
    /// only the cursor's load. Any other cursor takes `drain_from_cursor`.
    ///
    /// A `Message.wake`, a call and a return write no event. Each counts in its ring's visit, and
    /// the drain hands it to the loop's hook (decisions 29, 32 and 33). A ring that holds a
    /// reserved tag hands the rest of the drain to `take`.
    pub fn drain_mailboxes(inbox: *Inbox, receiver: LoopId, events: []Event, comptime take: TakeReserved) u32 {
        const registry = inbox.registry orelse return 0;
        if (inbox.sender_cursor != 0) return inbox.drain_from_cursor(registry, receiver, events, take);
        var visit: Visit = .{ .out = events };
        for (0..registry.loop_count()) |sender| {
            if (sender == receiver) continue;
            const room = @min(events.len - visit.written, constants.messages_per_drain);
            if (room == 0) {
                inbox.sender_cursor = @intCast(sender);
                break;
            }
            // The visit of one ring, written out in each drain: as a function the compiler kept it
            // out of line, which cost the work gate's `task` row about 12 instructions on `mac`.
            // An empty ring costs a visit and no room.
            const ring = registry.mailbox(@intCast(sender), receiver);
            const before = visit.written;
            const peeked = ring.peek_each(@intCast(room), &visit, Visit.write);
            if (peeked.count == 0) continue;
            // A ring that gave more messages than events holds a reserved tag.
            if (visit.written - before != peeked.count) return take(inbox, receiver, events, @intCast(sender), before);
            ring.release(peeked);
        }
        assert(visit.written <= events.len);
        return visit.written;
    }

    /// `drain_mailboxes` from a cursor above 0: each sender once, from the cursor, in one loop
    /// that wraps to sender 0 at the count of loops. The wrap is a compare, and no modulo. A drain
    /// that visited every sender keeps the cursor, and skips the store.
    fn drain_from_cursor(
        inbox: *Inbox,
        registry: *Registry,
        receiver: LoopId,
        events: []Event,
        comptime take: TakeReserved,
    ) u32 {
        const loops = registry.loop_count();
        const cursor = inbox.sender_cursor;
        assert(cursor < loops);
        var visit: Visit = .{ .out = events };
        var sender: usize = cursor;
        for (0..loops) |_| {
            if (sender == loops) sender = 0;
            if (sender != receiver) {
                const room = @min(events.len - visit.written, constants.messages_per_drain);
                if (room == 0) {
                    inbox.sender_cursor = @intCast(sender);
                    break;
                }
                // The visit of one ring, as `drain_mailboxes` writes it.
                const ring = registry.mailbox(@intCast(sender), receiver);
                const before = visit.written;
                const peeked = ring.peek_each(@intCast(room), &visit, Visit.write);
                if (peeked.count != 0) {
                    if (visit.written - before != peeked.count) return take(inbox, receiver, events, @intCast(sender), before);
                    ring.release(peeked);
                }
            }
            sender += 1;
        }
        assert(visit.written <= events.len);
        return visit.written;
    }

    /// True when a drain handed a call or a return since the last call, which clears it. The
    /// clear is on the rare path, so a tick that reads false makes one load and one branch.
    pub fn take_handed(inbox: *Inbox) bool {
        if (!inbox.handed) return false;
        inbox.handed = false;
        return true;
    }

    /// True while a ring to loop `receiver` holds a message: another loop's mailbox or an offload
    /// worker's. A host that reads it before it sleeps does not sleep on a message (decision 29).
    /// It reads each ring once, and changes nothing.
    pub fn holds_messages(inbox: *const Inbox, receiver: LoopId) bool {
        if (offload.pending(inbox.completions)) return true;
        const registry = inbox.registry orelse return false;
        for (0..registry.loop_count()) |sender| {
            if (sender == receiver) continue;
            if (!registry.mailbox(@intCast(sender), receiver).is_empty()) return true;
        }
        return false;
    }

    /// Tells the registry loop `receiver` is about to sleep, then looks at its mailboxes once more:
    /// a sender that posted before it saw the flag did not wake the loop, so the loop must not
    /// sleep on that message (decision 12, point 6). Returns the wait to sleep for, or null.
    pub fn settle_to_sleep(inbox: *Inbox, receiver: LoopId, wait: ?u64) ?u64 {
        const bound = wait orelse return null;
        // A loop with an operation held for room sleeps only while a worker owes it a result, and
        // the worker's push wakes it. The flush holds an operation only when the count is at its
        // limit, and a result taken since then made an event, so this tick does not sleep.
        assert(inbox.offload_in_flight.may_sleep());
        // The offload's workers are told the same thing the other loops are told, through a flag
        // of this loop's own: an offload works without a registry, because its workers own no loop.
        if (inbox.completions.len != 0) {
            inbox.offload_asleep.store(true, .seq_cst);
            if (offload.pending(inbox.completions)) return null;
        }
        const registry = inbox.registry orelse return bound;
        registry.begin_sleep(receiver);
        inbox.sleeping = true;
        for (0..registry.loop_count()) |sender| {
            if (sender == receiver) continue;
            if (!registry.mailbox(@intCast(sender), receiver).is_empty()) return null;
        }
        return bound;
    }

    /// Tells the registry, and the offload's workers, that loop `receiver` is awake again.
    pub fn wake_up(inbox: *Inbox, receiver: LoopId) void {
        if (inbox.completions.len != 0) inbox.offload_asleep.store(false, .seq_cst);
        if (!inbox.sleeping) return;
        inbox.registry.?.end_sleep(receiver);
        inbox.sleeping = false;
    }
};
