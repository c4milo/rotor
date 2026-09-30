//! A loop's `post` with no operation (decision 4, amended 2026-09-29): the scenarios of
//! `conformance_post.zig` with each message sent by `Loop.post`, and the errors it returns. It
//! hands over no event, so a tick after it has nothing from it; on io_uring that tick is also the
//! one whose submit carries the wake.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const post_scenarios = @import("conformance_post.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const tag_ping = post_scenarios.tag_ping;
const tag_pong = post_scenarios.tag_pong;

const Peer = struct {
    registry: *backend.Registry,
    failure: ?anyerror = null,

    fn run(peer: *Peer) void {
        peer.serve() catch |err| {
            peer.failure = err;
        };
    }

    /// Owns loop 1: waits for one ping, answers with the payload plus one through `Loop.post`, then
    /// ticks once, which must hand over nothing.
    fn serve(peer: *Peer) !void {
        var harness: Harness = undefined;
        try harness.init(1, peer.registry);
        defer harness.deinit();
        var events: [1]Event = undefined;
        try harness.collect(&events);
        if (!events[0].flags.message or events[0].result != tag_ping) return error.NotAPing;
        try harness.loop.post(0, .{ .payload = events[0].user_data + 1, .tag = tag_pong });
        if (try harness.loop.tick(&events, 0) != 0) return error.PostHandedOverAnEvent;
    }
};

test "a loop's post reaches a loop on another thread, whose post answers, and neither makes an event" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const registry_alignment = core.layout.memory_alignment;
    var registry_memory: [backend.Registry.memory_bytes(2)]u8 align(registry_alignment) = undefined;
    registry.init(&registry_memory, 2);
    var harness: Harness = undefined;
    try harness.init(0, &registry);
    defer harness.deinit();
    var peer: Peer = .{ .registry = &registry };
    const thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});

    // Until the other loop publishes its ring, the post answers LoopNotFound, which is an error to
    // retry and not a halt.
    var attempt: u32 = 0;
    while (attempt < post_scenarios.post_attempts_max) : (attempt += 1) {
        harness.loop.post(1, .{ .payload = 41, .tag = tag_ping }) catch |err| switch (err) {
            error.LoopNotFound => {
                try harness.pause(post_scenarios.pause_ns);
                continue;
            },
            else => return err,
        };
        break;
    }

    // The one event is the answer: the post itself made none.
    var events: [1]Event = undefined;
    try harness.collect(&events);
    thread.join();
    try testing.expectEqual(@as(?anyerror, null), peer.failure);
    try testing.expect(attempt < post_scenarios.post_attempts_max);
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(@as(u64, 42), events[0].user_data);
    try testing.expectEqual(@as(i32, tag_pong), events[0].result);
}

test "a loop's post wakes a loop that sleeps in its tick, long before its wait is over" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const registry_alignment = core.layout.memory_alignment;
    var registry_memory: [backend.Registry.memory_bytes(2)]u8 align(registry_alignment) = undefined;
    registry.init(&registry_memory, 2);
    var harness: Harness = undefined;
    try harness.init(0, &registry);
    defer harness.deinit();
    var sleeper: post_scenarios.Sleeper = .{ .registry = &registry };
    const thread = try std.Thread.spawn(.{}, post_scenarios.Sleeper.run, .{&sleeper});

    // As in `conformance_post.zig`: post once the other loop says it sleeps, and a pause later.
    var posted = false;
    var posted_at_ns: u64 = 0;
    var attempt: u32 = 0;
    var events: [1]Event = undefined;
    while (!posted and attempt < post_scenarios.post_attempts_max) : (attempt += 1) {
        try harness.pause(post_scenarios.pause_ns);
        if (registry.get(1) < 0 or !registry.must_wake(1)) continue;
        try harness.pause(post_scenarios.pause_ns);
        posted_at_ns = backend.testing.monotonic_ns();
        try harness.loop.post(1, .{ .payload = 7, .tag = tag_ping });
        try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
        posted = true;
    }
    thread.join();
    try testing.expectEqual(@as(?anyerror, null), sleeper.failure);
    try testing.expect(posted);
    try testing.expect(sleeper.waited_ns > 0);
    try testing.expect(sleeper.waited_ns < core.constants.ns_per_s / 2);
    try testing.expect(sleeper.after_ns >= post_scenarios.quiet_wait_ns / 2);
    try testing.expect(sleeper.now_after_wake_ns >= posted_at_ns);
}

/// Ticks that hand over the messages of a full ring, at most: one per event slot, and some spare.
const drain_ticks_max = core.constants.mailbox_messages;

test "a loop's post answers LoopNotFound and MailboxFull, and hands over no event" {
    if (conformance.unsupported()) return error.SkipZigTest;
    // Ids 0 and 1 run loops on this thread; id 2 runs none.
    const loops = 3;
    var registry: backend.Registry = undefined;
    const registry_alignment = core.layout.memory_alignment;
    var registry_memory: [backend.Registry.memory_bytes(loops)]u8 align(registry_alignment) =
        undefined;
    registry.init(&registry_memory, loops);
    var first: Harness = undefined;
    try first.init(0, &registry);
    defer first.deinit();
    var second: Harness = undefined;
    try second.init(1, &registry);
    defer second.deinit();
    var lone: Harness = undefined;
    try lone.init(0, null);
    defer lone.deinit();

    const message: core.Message = .{ .payload = 1, .tag = tag_ping };
    try testing.expectError(error.LoopNotFound, first.loop.post(2, message));
    try testing.expectError(error.LoopNotFound, first.loop.post(loops, message));
    try testing.expectError(error.LoopNotFound, lone.loop.post(1, message));

    // The second loop never ticks, so it never says it sleeps: the posts wake nothing, and its ring
    // from the first loop fills.
    for (0..core.constants.mailbox_messages) |_| try first.loop.post(1, message);
    try testing.expectError(error.MailboxFull, first.loop.post(1, message));
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try first.loop.tick(&events, 0));

    // Every message that fit is handed over, and the ring takes a post again.
    var received: u32 = 0;
    var round: u32 = 0;
    while (received < core.constants.mailbox_messages and round < drain_ticks_max) : (round += 1) {
        received += try second.loop.tick(&events, 0);
    }
    try testing.expectEqual(core.constants.mailbox_messages, received);
    try first.loop.post(1, message);
}
