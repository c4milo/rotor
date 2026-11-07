//! The wakes a loop drops (decision 4, fourth amendment of 2026-11-06): each wake its `post` or a
//! flush asks for and the kernel refuses. The target is the read end of a pipe, which is no
//! eventfd, so the kernel refuses a write to it. In a group the wake is the same write. Split from
//! `epoll.zig` for the 500-line limit. Every test here makes an epoll instance, so each runs under
//! Linux alone: `tools/linux_test.sh` runs them in Docker.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
const Registry = epoll.Registry;

const memory_alignment = core.layout.memory_alignment;
const options_base: Loop.Options = .{ .operations = 4 };

/// Loop 0 is the pipe's read end, which sleeps, and loop 1 is the loop under test.
const loops = 2;

/// A registry whose loop 0 publishes the read end of a pipe and sleeps, so each post to it asks
/// for a wake that the kernel refuses.
const Target = struct {
    registry: Registry,
    memory: [Registry.memory_bytes(loops)]u8 align(memory_alignment),
    ends: [2]i32,

    fn init(target: *Target) !void {
        target.registry.init(&target.memory, loops);
        const rc = std.os.linux.pipe2(&target.ends, .{ .CLOEXEC = true });
        if (std.os.linux.errno(rc) != .SUCCESS) return error.PipeFailed;
        target.registry.set(0, target.ends[0]);
        target.registry.begin_sleep(0);
    }

    /// Runs after every loop of the registry ended: it closes the wakes the registry keeps.
    fn deinit(target: *Target) void {
        target.registry.end_sleep(0);
        target.registry.clear(0);
        epoll.wake_module.close_kept(&target.registry);
        for (target.ends) |end| _ = std.os.linux.close(end);
    }
};

const Sender = struct {
    memory: [Loop.memory_bytes(&options_base)]u8 align(memory_alignment),
    loop: Loop,

    fn init(sender: *Sender, registry: *Registry) !void {
        var options = options_base;
        options.id = 1;
        options.registry = registry;
        try sender.loop.init(&sender.memory, &options);
    }

    /// Submits a post operation to loop 0 and ticks until its event comes back. The flush sends
    /// the wake the post asked for.
    fn post_operation(sender: *Sender, payload: u64) !void {
        const post: core.Operation = .{ .user_data = payload, .kind = .{ .post = .{
            .target = 0,
            .message = .{ .payload = payload, .tag = 0 },
        } } };
        var handles: [1]core.Handle = undefined;
        try testing.expectEqual(@as(u32, 1), sender.loop.submit(&.{post}, &handles));
        var events: [1]core.Event = undefined;
        try testing.expectEqual(@as(u32, 1), try sender.loop.tick(&events, 0));
        // The post itself succeeded: the message is in the ring, and only its wake was refused.
        try testing.expectEqual(@as(i32, 0), events[0].result);
    }
};

test "a loop counts each wake the kernel refused, in post, in a flush and in a group" {
    if (!epoll.supported) return error.SkipZigTest;
    var target: Target = undefined;
    try target.init();
    defer target.deinit();
    var sender: Sender = undefined;
    try sender.init(&target.registry);
    try testing.expectEqual(@as(u64, 0), sender.loop.dropped_wakes());

    try sender.loop.post(0, .{ .payload = 1, .tag = 0 });
    try testing.expectEqual(@as(u64, 1), sender.loop.dropped_wakes());
    try sender.post_operation(2);
    try testing.expectEqual(@as(u64, 2), sender.loop.dropped_wakes());

    // In a group the registry holds the eventfd its creator made, and the wake is the same write.
    target.registry.group = true;
    try sender.loop.post(0, .{ .payload = 3, .tag = 0 });
    try sender.post_operation(4);
    target.registry.group = false;
    try testing.expectEqual(@as(u64, 4), sender.loop.dropped_wakes());

    // The count stays readable after `deinit`, and the next `init` starts it again.
    sender.loop.deinit();
    try testing.expectEqual(@as(u64, 4), sender.loop.dropped_wakes());
    try sender.init(&target.registry);
    try testing.expectEqual(@as(u64, 0), sender.loop.dropped_wakes());
    sender.loop.deinit();
    var out: [4]core.Message = undefined;
    try testing.expectEqual(@as(u32, 4), target.registry.mailbox(1, 0).pop_into(&out));
}

test "a wake the kernel takes is no drop" {
    if (!epoll.supported) return error.SkipZigTest;
    var target: Target = undefined;
    try target.init();
    defer target.deinit();
    // A real eventfd stands in for loop 0 now, and takes every write.
    var queue = try epoll.queue_module.Queue.init();
    defer queue.deinit();
    target.registry.clear(0);
    target.registry.set(0, queue.wake_descriptor);
    var sender: Sender = undefined;
    try sender.init(&target.registry);
    defer sender.loop.deinit();
    try sender.loop.post(0, .{ .payload = 1, .tag = 0 });
    try sender.post_operation(2);
    try testing.expectEqual(@as(u64, 0), sender.loop.dropped_wakes());
}
