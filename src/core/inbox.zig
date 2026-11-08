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

const call_take = @import("call/call_take.zig");
const Dispatch = @import("dispatch/dispatch.zig").Dispatch;
const Groups = @import("scheduling/scheduling_groups.zig").Groups;
const Event = event.Event;
const Waker = call_take.Waker;
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
        const reserved = message.tag > constants.message_tag_max;
        const tag = if (reserved) 0 else message.tag;
        visit.out[visit.written] = Event.message(message.payload, tag);
        visit.written += @intFromBool(!reserved);
    }
};

/// The slow path of `drain_mailboxes`, which a backend hands it: a function that calls
/// `take_reserved` with the loop's dispatch, groups and wake. Decision 7 confines `noinline` and
/// `@branchHint` to its named files, so a backend keeps the slow path out of its tick there, and
/// this file stays plain. The drain returns what the slow path returns, so no value of the drain
/// lives across the call, and the drain saves no register for it.
pub const TakeReserved = fn (
    inbox: *Inbox,
    receiver: LoopId,
    events: []Event,
    first: LoopId,
    written: u32,
) u32;

/// The slow path of a drain whose visit of the ring of `first` read a reserved tag, with `written`
/// events before that visit. The ring has not taken the visit's slots back, so this visits it
/// again. Then it visits each sender that the drain did not visit yet, up to the cursor, as the
/// drain would. It takes each wake, call and return in the order of its ring (decisions 29 and 32),
/// and returns the events of the whole drain.
pub fn take_reserved(
    inbox: *Inbox,
    receiver: LoopId,
    events: []Event,
    first: LoopId,
    written: u32,
    dispatch: *Dispatch,
    groups: *Groups,
    waker: ?Waker,
) u32 {
    const registry = inbox.registry.?;
    const loops = registry.loop_count();
    var taker: call_take.Taker = .{
        .registry = registry,
        .dispatch = dispatch,
        .groups = groups,
        .waker = waker,
        .receiver = receiver,
        .sender = first,
        .woke = false,
    };
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
    if (taker.woke) dispatch.note_wake();
    assert(visit.written <= events.len);
    return visit.written;
}

/// The visit of one ring on the slow path: each message of a caller's tag writes an event, and each
/// reserved tag goes to `call_take`. The slots are the drain's until the ring takes them back, so
/// the reserved ones are read again before the release.
fn take_visit(ring: *Mailbox, visit: *Visit, room: u32, taker: *call_take.Taker) void {
    const before = visit.written;
    const peeked = ring.peek_each(room, visit, Visit.write);
    if (peeked.count == 0) return;
    if (visit.written - before != peeked.count) {
        for (0..peeked.count) |offset| {
            const message = ring.message_at(peeked, @intCast(offset));
            if (message.tag > constants.message_tag_max) call_take.take_reserved(taker, message);
        }
    }
    ring.release(peeked);
}

/// The slow path for a test's loop: a `Container` with the fields `inbox`, `dispatch` and `groups`.
/// It wakes no other loop.
pub fn TestTake(comptime Container: type) type {
    return struct {
        pub fn take(inbox: *Inbox, receiver: LoopId, events: []Event, first: LoopId, written: u32) u32 {
            const container: *Container = @alignCast(@fieldParentPtr("inbox", inbox));
            const dispatch = &container.dispatch;
            return take_reserved(inbox, receiver, events, first, written, dispatch, &container.groups, null);
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
    /// A `Message.wake` writes no event. It counts in its ring's visit, and a drain that took one
    /// tells the loop's dispatch (decision 29). A call or a return writes no event either: the
    /// drain queues its record's task (decision 32). A ring that holds a reserved tag hands the
    /// rest of the drain to `take`.
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
