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

const Event = event.Event;
const LoopId = operation.LoopId;
const Mailbox = mailbox.Mailbox;
const Registry = mailbox.Registry;

/// The event that hands `message` over.
fn message_event(message: operation.Message) Event {
    return Event.message(message.payload, message.tag);
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
    /// always below `registry.loops()`. Only the loop thread reads or writes it.
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
    pub fn drain_mailboxes(inbox: *Inbox, receiver: LoopId, events: []Event) u32 {
        const registry = inbox.registry orelse return 0;
        if (inbox.sender_cursor != 0) return inbox.drain_from_cursor(registry, receiver, events);
        var produced: u32 = 0;
        for (0..registry.loops()) |sender| {
            if (sender == receiver) continue;
            const room = @min(events.len - produced, constants.messages_per_drain);
            if (room == 0) {
                inbox.sender_cursor = @intCast(sender);
                break;
            }
            // An empty ring costs a visit and no room.
            const ring = registry.mailbox(@intCast(sender), receiver);
            produced += ring.pop_as(Event, events[produced..][0..room], message_event);
        }
        assert(produced <= events.len);
        return produced;
    }

    /// `drain_mailboxes` from a cursor above 0: each sender once, from the cursor, in one loop
    /// that wraps to sender 0 at the count of loops. The wrap is a compare, and no modulo. A drain
    /// that visited every sender keeps the cursor, and skips the store.
    fn drain_from_cursor(
        inbox: *Inbox,
        registry: *Registry,
        receiver: LoopId,
        events: []Event,
    ) u32 {
        const loops = registry.loops();
        const cursor = inbox.sender_cursor;
        assert(cursor < loops);
        var produced: u32 = 0;
        var sender: usize = cursor;
        for (0..loops) |_| {
            if (sender == loops) sender = 0;
            if (sender != receiver) {
                const room = @min(events.len - produced, constants.messages_per_drain);
                if (room == 0) {
                    inbox.sender_cursor = @intCast(sender);
                    break;
                }
                const ring = registry.mailbox(@intCast(sender), receiver);
                produced += ring.pop_as(Event, events[produced..][0..room], message_event);
            }
            sender += 1;
        }
        assert(produced <= events.len);
        return produced;
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
        for (0..registry.loops()) |sender| {
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
