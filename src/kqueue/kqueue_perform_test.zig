//! `perform.attempt` under test, for what the conformance suite cannot force: a receive from a
//! group that finds its socket not ready. macOS only: the test makes real sockets.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const core = @import("core");
const kqueue = @import("kqueue.zig");
const perform = @import("kqueue_perform.zig");

const Loop = kqueue.Loop;

const options: Loop.Options = .{ .operations = 4, .entries = 4 };
const group_id = 2;
const group_buffers = 2;
const group_buffer_bytes = 8;

fn nonblocking_pair() ![2]i32 {
    var descriptors: [2]c_int = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &descriptors) != 0) {
        return error.SocketPairFailed;
    }
    for (descriptors) |descriptor| {
        const flags = std.c.fcntl(descriptor, std.c.F.GETFL, @as(c_int, 0));
        const nonblocking: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        if (std.c.fcntl(descriptor, std.c.F.SETFL, flags | nonblocking) != 0) {
            return error.NonBlockingFailed;
        }
    }
    return descriptors;
}

test "a receive from a group that would block gives its buffer back and asks to wait" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);
    const ring_bytes = comptime kqueue.buffers.ring_bytes(group_buffers);
    var ring_memory: [ring_bytes]u8 align(kqueue.buffers.ring_alignment) = undefined;
    var buffers: [group_buffers * group_buffer_bytes]u8 = undefined;
    try loop.provide_buffers(group_id, &ring_memory, &buffers, group_buffer_bytes);
    const pair = try nonblocking_pair();
    defer for (pair) |descriptor| {
        _ = std.c.close(descriptor);
    };

    _ = loop.submit(&.{.{ .user_data = 1, .kind = .{ .receive = .{
        .socket = pair[0],
        .target = .{ .group = group_id },
        .multishot = true,
    } } }}, &.{});
    const index = loop.tables.pending.pop(loop.tables.table.slots).?;
    const slot = loop.tables.table.at(index);

    // Nothing was sent: the call would block, and both buffers are still the group's.
    const blocked = perform.attempt(&loop, slot);
    try testing.expectEqual(perform.Attempt.Outcome.wait_read, blocked.outcome);
    try testing.expectEqual(@as(u16, group_buffers), loop.groups[group_id].free_count);

    // Bytes arrive: the receive takes buffer 0, and keeps it.
    try testing.expectEqual(@as(isize, 3), std.c.send(pair[1], "abc", 3, 0));
    const received = perform.attempt(&loop, slot);
    try testing.expectEqual(perform.Attempt.Outcome.done, received.outcome);
    try testing.expectEqual(@as(i32, 3), received.result);
    try testing.expectEqual(@as(?u16, 0), received.buffer_id);
    try testing.expectEqual(@as(u16, group_buffers - 1), loop.groups[group_id].free_count);
    try testing.expectEqualStrings("abc", loop.provided_buffer(group_id, 0)[0..3]);

    slot.state = .submitted;
    loop.tables.finish(index, slot);
}
