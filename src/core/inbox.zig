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

    pub fn init(registry: ?*Registry, completions: []Mailbox) Inbox {
        return .{
            .registry = registry,
            .sleeping = false,
            .completions = completions,
            .offload_asleep = .init(false),
        };
    }

    /// Moves the messages other loops posted to loop `receiver` into `events`, oldest first per
    /// sender, until the events run out. A ring that still holds messages then is drained by the
    /// next tick, which does not wait while one does.
    pub fn drain_mailboxes(inbox: *Inbox, receiver: LoopId, events: []Event) u32 {
        const registry = inbox.registry orelse return 0;
        var produced: u32 = 0;
        var messages: [constants.messages_per_drain]operation.Message = undefined;
        for (0..registry.loops()) |sender| {
            if (sender == receiver) continue;
            const room = @min(events.len - produced, constants.messages_per_drain);
            if (room == 0) break;
            const ring = registry.mailbox(@intCast(sender), receiver);
            const moved = ring.pop_into(messages[0..room]);
            for (messages[0..moved]) |message| {
                events[produced] = Event.message(message.payload, message.tag);
                produced += 1;
            }
        }
        assert(produced <= events.len);
        return produced;
    }

    /// Tells the registry loop `receiver` is about to sleep, then looks at its mailboxes once more:
    /// a sender that posted before it saw the flag did not wake the loop, so the loop must not
    /// sleep on that message (decision 12, point 6). Returns the wait to sleep for, or null.
    pub fn settle_to_sleep(inbox: *Inbox, receiver: LoopId, wait: ?u64) ?u64 {
        const bound = wait orelse return null;
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
