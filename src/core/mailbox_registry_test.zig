//! Tests of `mailbox_registry.zig` that use only what it exports. Split from that file for the
//! 500-line limit; the tests that read its private layout stay there.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const layout = @import("layout.zig");
const operation = @import("operation.zig");
const registry_module = @import("mailbox_registry.zig");

const Descriptor = operation.Descriptor;
const Message = operation.Message;
const Registry = registry_module.Registry;
const descriptor_none = registry_module.descriptor_none;

const pair_loops = 5;
const pair_bytes = Registry.memory_bytes(pair_loops);

/// A distinct message for the ring from `sender` to `receiver`.
fn pair_message(sender: usize, receiver: usize) Message {
    return .{ .payload = sender * constants.loops_max + receiver, .tag = @intCast(sender) };
}

test "every ordered pair of loops has a mailbox of its own" {
    var memory: [pair_bytes]u8 align(layout.memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    try testing.expectEqual(@as(u16, pair_loops), registry.loops());
    for (0..pair_loops * pair_loops) |pair| {
        const sender = pair / pair_loops;
        const receiver = pair % pair_loops;
        const ring = registry.mailbox(@intCast(sender), @intCast(receiver));
        try testing.expect(ring.is_empty());
        try testing.expect(ring.push(pair_message(sender, receiver)));
    }
    var out: [2]Message = undefined;
    for (0..pair_loops * pair_loops) |pair| {
        const sender = pair / pair_loops;
        const receiver = pair % pair_loops;
        const ring = registry.mailbox(@intCast(sender), @intCast(receiver));
        try testing.expectEqual(@as(u32, 1), ring.pop_into(&out));
        try testing.expectEqual(pair_message(sender, receiver).payload, out[0].payload);
    }
}

test "a registry starts with no descriptor, publishes one and forgets it" {
    var memory: [pair_bytes]u8 align(layout.memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    for (0..pair_loops) |id| try testing.expect(registry.get(@intCast(id)) < 0);
    registry.set(3, 17);
    registry.set(pair_loops - 1, 0);
    try testing.expectEqual(@as(Descriptor, 17), registry.get(3));
    try testing.expectEqual(@as(Descriptor, 0), registry.get(pair_loops - 1));
    try testing.expectEqual(descriptor_none, registry.get(2));
    registry.clear(3);
    try testing.expectEqual(descriptor_none, registry.get(3));
    try testing.expectEqual(@as(Descriptor, 0), registry.get(pair_loops - 1));
    registry.set(3, 21);
    try testing.expectEqual(@as(Descriptor, 21), registry.get(3));
}

test "a loop must be woken from begin_sleep to end_sleep, and no other loop with it" {
    var memory: [pair_bytes]u8 align(layout.memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    for (0..pair_loops) |id| try testing.expect(!registry.must_wake(@intCast(id)));
    registry.begin_sleep(2);
    for (0..pair_loops) |id| try testing.expectEqual(id == 2, registry.must_wake(@intCast(id)));
    registry.end_sleep(2);
    for (0..pair_loops) |id| try testing.expect(!registry.must_wake(@intCast(id)));
    // A loop that found a message after `begin_sleep` ends the sleep without blocking, and a
    // loop that is awake may end a sleep it never began.
    registry.begin_sleep(2);
    registry.end_sleep(2);
    registry.end_sleep(2);
    registry.begin_sleep(2);
    try testing.expect(registry.must_wake(2));
}

test "memory_bytes grows with the square of the loops and not with loops_max" {
    // Slack, header, the wakes in whole lines, the entries, the rings.
    const two = Registry.memory_bytes(2);
    try testing.expectEqual(@as(usize, 64 + 128 + 128 + 2 * 128 + 4 * 4352), two);
    try testing.expectEqual(@as(usize, 64 + 128 + 128 + 5 * 128 + 25 * 4352), pair_bytes);
    const most = Registry.memory_bytes(constants.loops_max);
    try testing.expectEqual(@as(usize, 64 + 128 + 2048 + 256 * 128 + 65536 * 4352), most);
}
