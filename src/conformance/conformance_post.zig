//! Cross-core scenarios (decision 4): two loops on two real threads, each owned by the thread
//! that initialised it, talking through `post` alone.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;

const tag_ping = 1;
const tag_pong = 2;
/// Posts the first loop sends before the second loop has published its ring, at most: with a
/// pause of a millisecond after each, a fifth of a second.
const post_attempts_max = 200;

/// How long the first loop waits between two posts that found no ring.
const pause_ns = core.constants.ns_per_ms;

/// Waits one `pause_ns` through the loop itself, with a timer, so the other thread gets time to
/// start: a post that finds no ring ends in the same tick, and 200 of them take no time at all.
fn pause(harness: *Harness) !void {
    const timer: core.Operation = .{
        .user_data = 0,
        .kind = .{ .timer = .{ .after_ns = pause_ns } },
    };
    try harness.submit(&.{timer}, &.{});
    var events: [1]Event = undefined;
    try harness.collect(&events);
}

const Peer = struct {
    registry: *backend.Registry,
    failure: ?anyerror = null,

    /// The second thread: owns loop 1, waits for one ping, answers with the payload plus one.
    fn run(peer: *Peer) void {
        peer.serve() catch |err| {
            peer.failure = err;
        };
    }

    fn serve(peer: *Peer) !void {
        var harness: Harness = undefined;
        try harness.init(1, peer.registry);
        defer harness.deinit();
        var events: [1]Event = undefined;
        try harness.collect(&events);
        if (!events[0].flags.message or events[0].result != tag_ping) return error.NotAPing;
        try harness.submit(&.{.{ .user_data = 7, .kind = .{ .post = .{
            .target = 0,
            .message = .{ .payload = events[0].user_data + 1, .tag = tag_pong },
        } } }}, &.{});
        try harness.collect(&events);
        if (try events[0].outcome() != 0) return error.PongNotPosted;
    }
};

test "a message crosses to a loop on another thread and its answer comes back" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    registry.init();
    var harness: Harness = undefined;
    try harness.init(0, &registry);
    defer harness.deinit();
    var peer: Peer = .{ .registry = &registry };
    const thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});

    // The other loop publishes its ring when its thread gets there: until then a post ends with
    // loop_not_found, which is a result and not a halt.
    var posted = false;
    var attempt: u32 = 0;
    var events: [1]Event = undefined;
    while (!posted and attempt < post_attempts_max) : (attempt += 1) {
        try harness.submit(&.{.{ .user_data = 1, .kind = .{ .post = .{
            .target = 1,
            .message = .{ .payload = 41, .tag = tag_ping },
        } } }}, &.{});
        try harness.collect(&events);
        posted = if (events[0].outcome()) |_| true else |err| switch (err) {
            error.LoopNotFound => false,
            else => return err,
        };
        if (!posted) try pause(&harness);
    }
    try testing.expect(posted);

    try harness.collect(&events);
    thread.join();
    try testing.expectEqual(@as(?anyerror, null), peer.failure);
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(@as(u64, 42), events[0].user_data);
    try testing.expectEqual(@as(i32, tag_pong), events[0].result);
}
