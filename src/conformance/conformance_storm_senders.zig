//! The threads that post in the post storm of `conformance_storm.zig`: the peer loop and the
//! remotes, and what they share with the target.
const std = @import("std");
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const Random = core.random.Random;
const LoopId = core.LoopId;

const ms = core.constants.ns_per_ms;

pub const target_id: LoopId = 0;
pub const peer_id: LoopId = 1;
pub const first_remote_id: LoopId = 2;
/// The threads with no loop that post to the target.
pub const remotes = 3;
pub const ids: u16 = first_remote_id + remotes;

/// The posts of each sender that the target accepts. A sender makes a refused post again, so it
/// posts more times than this when the target falls behind.
pub const messages_per_sender = 2000;
pub const senders = remotes + 1;

/// The tag of the peer's last message, which wakes the target once the storm is over. It is
/// above every sender id, so `accept` never takes it for a storm message.
pub const tag_wake = ids;

/// Posts one sender makes, refusals included, before it gives up on a target that never drains.
const attempts_max: u64 = 1 << 22;

/// Pauses of a millisecond the peer makes while it waits for the quiet phase and for the target
/// to sleep. Generous, because the race gate runs the suite under ThreadSanitizer.
const peer_pauses_max = 20_000;
const peer_pause_ns = ms;

/// What the threads share: stop on a failure of the target, and the phases of the scenario.
pub const Shared = struct {
    registry: *backend.Registry,
    /// Set before the target's thread joins the others, so that no sender waits for a loop that
    /// stopped.
    stop: std.atomic.Value(bool) = .init(false),
    /// Senders that finished their storm messages, with or without a failure.
    finished: std.atomic.Value(u32) = .init(0),
    /// Set by the target once its pollers are removed and nothing is queued or in flight.
    quiet: std.atomic.Value(bool) = .init(false),
};

/// A thread with no loop: posts `messages_per_sender` messages through a `Remote`.
pub const Sender = struct {
    shared: *Shared,
    id: LoopId,
    random: Random,
    attempts: u64 = 0,
    refusals: u64 = 0,
    failure: ?anyerror = null,

    pub fn run(sender: *Sender) void {
        sender.send() catch |err| {
            sender.failure = err;
        };
        _ = sender.shared.finished.fetchAdd(1, .release);
    }

    fn send(sender: *Sender) !void {
        var remote: backend.Remote = undefined;
        try remote.init(sender.shared.registry, sender.id);
        defer remote.deinit();
        for (0..messages_per_sender) |sequence| {
            try sender.deliver(&remote, .{ .payload = sequence, .tag = sender.id });
            if (sender.random.chance(1, 16)) std.Thread.yield() catch {};
        }
    }

    /// Posts `message` until the target accepts it, and counts each refusal.
    fn deliver(sender: *Sender, remote: *backend.Remote, message: core.Message) !void {
        while (sender.attempts < attempts_max) {
            if (sender.shared.stop.load(.acquire)) return error.Stopped;
            sender.attempts += 1;
            remote.post(target_id, message) catch |err| switch (err) {
                error.MailboxFull => {
                    sender.refusals += 1;
                    std.Thread.yield() catch {};
                    continue;
                },
                else => return err,
            };
            return;
        }
        return error.AttemptsExhausted;
    }
};

/// The peer loop's thread: posts its storm messages with `Loop.post` and with post operations, at
/// seeded choice, then waits for the quiet phase and posts the message that wakes the target.
pub const Peer = struct {
    shared: *Shared,
    random: Random,
    attempts: u64 = 0,
    refusals: u64 = 0,
    /// The clock when the peer posted `tag_wake`, or 0 when it did not.
    posted_at_ns: u64 = 0,
    counted: bool = false,
    failure: ?anyerror = null,

    pub fn run(peer: *Peer) void {
        peer.serve() catch |err| {
            peer.failure = err;
        };
        peer.finish();
    }

    fn finish(peer: *Peer) void {
        if (peer.counted) return;
        peer.counted = true;
        _ = peer.shared.finished.fetchAdd(1, .release);
    }

    fn serve(peer: *Peer) !void {
        var harness: Harness = undefined;
        try harness.init(peer_id, peer.shared.registry);
        defer harness.deinit();
        for (0..messages_per_sender) |sequence| {
            try peer.deliver(&harness, .{ .payload = sequence, .tag = peer_id });
        }
        // On io_uring the wake of a `Loop.post` leaves with the poster's next tick. This tick sends
        // it before the peer counts as finished, which `Target.settle` waits for.
        var events: [1]Event = undefined;
        _ = try harness.loop.tick(&events, 0);
        peer.finish();
        try peer.wake(&harness);
    }

    fn deliver(peer: *Peer, harness: *Harness, message: core.Message) !void {
        while (peer.attempts < attempts_max) {
            if (peer.shared.stop.load(.acquire)) return error.Stopped;
            peer.attempts += 1;
            const refused = if (peer.random.chance(1, 4))
                try post_operation(harness, message)
            else
                try post_call(harness, message);
            if (!refused) return;
            peer.refusals += 1;
            std.Thread.yield() catch {};
        }
        return error.AttemptsExhausted;
    }

    /// Posts through `Loop.post`, and returns true when the target's ring was full.
    fn post_call(harness: *Harness, message: core.Message) !bool {
        harness.loop.post(target_id, message) catch |err| switch (err) {
            error.MailboxFull => return true,
            else => return err,
        };
        return false;
    }

    /// Posts through a post operation, waits for its event, and returns true on `mailbox_full`.
    fn post_operation(harness: *Harness, message: core.Message) !bool {
        try harness.submit(&.{Operation.post(0, target_id, message)}, &.{});
        var events: [1]Event = undefined;
        try harness.collect(&events);
        _ = events[0].outcome() catch |err| switch (err) {
            error.MailboxFull => return true,
            else => return err,
        };
        return false;
    }

    /// Waits for the quiet phase and for the target to sleep, then posts `tag_wake`.
    fn wake(peer: *Peer, harness: *Harness) !void {
        const shared = peer.shared;
        var pauses: u32 = 0;
        while (!shared.quiet.load(.acquire)) : (pauses += 1) {
            if (shared.stop.load(.acquire)) return error.Stopped;
            if (pauses == peer_pauses_max) return error.NeverQuiet;
            try harness.pause(peer_pause_ns);
        }
        pauses = 0;
        while (!shared.registry.must_wake(target_id) and pauses < peer_pauses_max) : (pauses += 1) {
            try harness.pause(peer_pause_ns);
        }
        // A pause after the target sleeps, so the post comes inside the wait and not before it.
        try harness.pause(peer_pause_ns);
        peer.posted_at_ns = backend.testing.monotonic_ns();
        try harness.loop.post(target_id, .{ .payload = 0, .tag = tag_wake });
        // On io_uring the wake of a `Loop.post` leaves with the poster's next tick.
        var events: [1]Event = undefined;
        _ = try harness.loop.tick(&events, 0);
    }
};
