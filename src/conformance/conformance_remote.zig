//! Remote scenarios (decision 4): a thread that owns no loop posts to one through a `Remote`, and
//! the loop receives the message as it would one from another loop.
//!
//! The thread is real. The point of a `Remote` is that the sender has no loop, so a stand-in that
//! posted from the loop's own thread would prove nothing about the path a worker takes.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Remote = backend.Remote;

/// The loop's id, and the id the remote claims beside it.
const loop_id: core.LoopId = 0;
const remote_id: core.LoopId = 1;
const ids: u16 = 2;

/// The wake scenario's ids: the loop this thread ticks only to wait, the loop that sleeps on the
/// other thread, and the remote on this thread.
const sleeper_id: core.LoopId = 1;
const waker_id: core.LoopId = 2;
const wake_ids: u16 = 3;

const tag_hello = 3;
const payload_hello = 41;

/// Posts the remote makes before the loop has published its queue, at most. Each failed post is
/// followed by a yield, so the loop thread gets its turn; a loop that never starts fails the
/// scenario here rather than hanging it.
const post_attempts_max: u32 = 100_000;

/// Pauses this thread makes before the sleeping loop has published its queue, at most: with a
/// millisecond each, a fifth of a second (`conformance_post.zig`).
const pause_attempts_max: u32 = 200;
const pause_ns = core.constants.ns_per_ms;

var registry_memory: [backend.Registry.memory_bytes(ids)]u8 align(core.layout.memory_alignment) =
    undefined;
const wake_registry_bytes = backend.Registry.memory_bytes(wake_ids);
var wake_registry_memory: [wake_registry_bytes]u8 align(core.layout.memory_alignment) = undefined;

/// The second thread: holds the remote, posts once, and records what the post answered.
const Sender = struct {
    registry: *backend.Registry,
    answer: ?core.remote.PostError = null,
    failure: ?anyerror = null,

    fn run(sender: *Sender) void {
        sender.send() catch |err| {
            sender.failure = err;
        };
    }

    fn send(sender: *Sender) !void {
        var remote: Remote = undefined;
        try remote.init(sender.registry, remote_id);
        defer remote.deinit();

        // The loop publishes its queue when it starts, and this thread may get here first. A post
        // before that finds no loop, which is the honest answer and not a failure: try again.
        var attempt: u32 = 0;
        while (attempt < post_attempts_max) : (attempt += 1) {
            remote.post(loop_id, .{ .payload = payload_hello, .tag = tag_hello }) catch |err| {
                if (err == error.LoopNotFound) {
                    std.Thread.yield() catch {};
                    continue;
                }
                sender.answer = err;
                return;
            };
            return;
        }
        return error.LoopNeverStarted;
    }
};

test "a thread with no loop posts through a remote, and the loop receives the message" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    registry.init(&registry_memory, ids);

    var harness: Harness = undefined;
    try harness.init(loop_id, &registry);
    defer harness.deinit();

    var sender: Sender = .{ .registry = &registry };
    const thread = try std.Thread.spawn(.{}, Sender.run, .{&sender});

    var events: [1]Event = undefined;
    try harness.collect(&events);
    thread.join();

    try testing.expect(sender.failure == null);
    try testing.expect(sender.answer == null);
    // The message arrives as a message event, exactly as one from another loop would.
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(@as(u64, payload_hello), events[0].user_data);
    try testing.expectEqual(@as(i32, tag_hello), events[0].result);
    // A message is not an operation, so nothing is in flight before or after it.
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}

test "a loop that posts to a remote's id is told there is no loop there" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    registry.init(&registry_memory, ids);

    var harness: Harness = undefined;
    try harness.init(loop_id, &registry);
    defer harness.deinit();

    // The remote lives on this thread for this scenario: it sends nothing here, and the question is
    // what a loop sees when it aims at the remote's slot.
    var remote: Remote = undefined;
    try remote.init(&registry, remote_id);
    defer remote.deinit();

    try harness.submit(&.{.{ .user_data = 5, .kind = .{ .post = .{
        .target = remote_id,
        .message = .{ .payload = 1, .tag = 1 },
    } } }}, &.{});
    var events: [1]Event = undefined;
    try harness.collect(&events);
    try testing.expectError(error.LoopNotFound, events[0].outcome());
}

test "a remote is answered loop_not_found before the loop starts and after it stops" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    registry.init(&registry_memory, ids);

    var remote: Remote = undefined;
    try remote.init(&registry, remote_id);
    defer remote.deinit();
    const message: core.Message = .{ .payload = 1, .tag = 1 };

    // Before: the loop's slot is empty.
    try testing.expectError(error.LoopNotFound, remote.post(loop_id, message));

    {
        var harness: Harness = undefined;
        try harness.init(loop_id, &registry);
        defer harness.deinit();
        // While the loop runs, the same post lands.
        try remote.post(loop_id, message);
        var events: [1]Event = undefined;
        try harness.collect(&events);
        try testing.expect(events[0].flags.message);
    }

    // After: the loop withdrew its slot at deinit, so the post finds nothing again.
    try testing.expectError(error.LoopNotFound, remote.post(loop_id, message));
}

test "a remote that outruns the loop is refused where the kernel bounds it, and never loses a message" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    registry.init(&registry_memory, ids);

    var harness: Harness = undefined;
    try harness.init(loop_id, &registry);
    defer harness.deinit();

    var remote: Remote = undefined;
    try remote.init(&registry, remote_id);
    defer remote.deinit();

    // Post without the loop ticking, so nothing drains meanwhile. What happens next is the kernel's,
    // and `backend.post_bounded` says which kernel this is:
    //
    // - kqueue: the mailbox holds `mailbox_messages`, and the next post is refused. It must be, and
    //   it must be refused with `MailboxFull` and not dropped.
    // - io_uring: rotor requires `IORING_FEAT_NODROP`, so a full completion ring overflows into a
    //   kernel list and every post lands while the kernel has memory. Nothing here is refused, so
    //   the scenario stops at a count the loop can drain inside its bound and asserts that every
    //   one of them arrives.
    var sent: u32 = 0;
    const attempts_max: u32 = if (backend.post_bounded) 1 << 16 else 1000;
    while (sent < attempts_max) : (sent += 1) {
        remote.post(loop_id, .{ .payload = sent, .tag = 1 }) catch |err| {
            try testing.expectEqual(error.MailboxFull, err);
            break;
        };
    }
    try testing.expect(sent >= 1);
    if (backend.post_bounded) {
        try testing.expect(sent < attempts_max);
    } else {
        try testing.expectEqual(attempts_max, sent);
    }

    // Every message that was accepted comes out, in order, and any refused one does not.
    var received: u32 = 0;
    var events: [64]Event = undefined;
    var rounds: u32 = 0;
    while (received < sent and rounds < conformance.collect_rounds_max) : (rounds += 1) {
        const count = try harness.loop.tick(&events, 0);
        for (events[0..count]) |event| {
            try testing.expect(event.flags.message);
            try testing.expectEqual(@as(u64, received), event.user_data);
            received += 1;
        }
    }
    try testing.expectEqual(sent, received);
}

/// The sleeping loop's thread: owns `sleeper_id` and makes one tick with a wait of a second, which
/// is what an idle core does. The idiom is `conformance_post.zig`'s, with a remote as the waker.
const Sleeper = struct {
    registry: *backend.Registry,
    /// How long the one tick that received the message took, or 0 when none arrived.
    waited_ns: u64 = 0,
    failure: ?anyerror = null,

    fn run(sleeper: *Sleeper) void {
        sleeper.sleep() catch |err| {
            sleeper.failure = err;
        };
    }

    fn sleep(sleeper: *Sleeper) !void {
        var harness: Harness = undefined;
        try harness.init(sleeper_id, sleeper.registry);
        defer harness.deinit();
        var events: [1]Event = undefined;
        const before = backend.testing.monotonic_ns();
        const count = try harness.loop.tick(&events, core.constants.ns_per_s);
        if (count == 1 and events[0].flags.message) {
            sleeper.waited_ns = backend.testing.monotonic_ns() - before;
        }
    }
};

test "a remote's post wakes a loop that sleeps in its tick, long before its wait is over" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    registry.init(&wake_registry_memory, wake_ids);
    var harness: Harness = undefined;
    try harness.init(loop_id, &registry);
    defer harness.deinit();
    var remote: Remote = undefined;
    try remote.init(&registry, waker_id);
    defer remote.deinit();
    var sleeper: Sleeper = .{ .registry = &registry };
    const thread = try std.Thread.spawn(.{}, Sleeper.run, .{&sleeper});

    // Give the other loop time to start and to fall asleep, then post once it is there. On kqueue
    // the post must trigger the sleeper's kqueue, or the sleeper wakes only when its second is
    // over; on io_uring the `MSG_RING` itself wakes it.
    var posted = false;
    var attempt: u32 = 0;
    while (!posted and attempt < pause_attempts_max) : (attempt += 1) {
        try harness.pause(pause_ns);
        if (registry.get(sleeper_id) < 0) continue;
        try harness.pause(pause_ns);
        remote.post(sleeper_id, .{ .payload = payload_hello, .tag = tag_hello }) catch |err| {
            if (err == error.LoopNotFound) continue;
            return err;
        };
        posted = true;
    }
    thread.join();
    try testing.expectEqual(@as(?anyerror, null), sleeper.failure);
    try testing.expect(posted);
    try testing.expect(sleeper.waited_ns > 0);
    try testing.expect(sleeper.waited_ns < core.constants.ns_per_s / 2);
}
