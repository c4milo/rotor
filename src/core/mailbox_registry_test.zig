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
const Wake = registry_module.Wake;
const Mailbox = @import("mailbox.zig").Mailbox;

const pair_loops = 5;
const pair_bytes = Registry.memory_bytes(pair_loops);

/// The first made-up descriptor a test hands `init_group`.
const made_up_descriptor_first: usize = 100;

/// Wakes a test hands `init_group`: two made-up descriptors per loop, all distinct. Nothing here
/// calls the kernel with them.
fn made_up_wakes() [pair_loops]Wake {
    var wakes: [pair_loops]Wake = undefined;
    var next: usize = made_up_descriptor_first;
    for (&wakes) |*made| {
        made.* = .{ .send = @intCast(next), .watch = @intCast(next + 1) };
        next += @sizeOf(Wake) / @sizeOf(Descriptor);
    }
    return wakes;
}

/// A distinct message for the ring from `sender` to `receiver`.
fn pair_message(sender: usize, receiver: usize) Message {
    return .{ .payload = sender * constants.loops_max + receiver, .tag = @intCast(sender) };
}

test "every ordered pair of loops has a mailbox of its own" {
    var memory: [pair_bytes]u8 align(layout.memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    try testing.expectEqual(@as(u16, pair_loops), registry.loop_count());
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

// Moved here from `mailbox_registry.zig` on 2026-11-06 for the 500-line limit.
test "a registry for one process starts with no wakes, and one for a group has the creator's" {
    var memory: [pair_bytes]u8 align(128) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    try testing.expect(!registry.group);
    for (0..pair_loops) |id| try testing.expectEqual(@as(?Wake, null), registry.wake(@intCast(id)));

    // Two made-up descriptors per loop, all distinct. Nothing here calls the kernel with them.
    var wakes: [pair_loops]Wake = undefined;
    for (&wakes, 0..) |*made, id| {
        const first: Descriptor = @intCast(made_up_descriptor_first + 2 * id);
        made.* = .{ .send = first, .watch = first + 1 };
    }
    registry.init_group(&memory, pair_loops, &wakes);
    try testing.expect(registry.group);
    for (wakes, 0..) |made, id| try testing.expectEqual(made, registry.wake(@intCast(id)).?);
    for (0..pair_loops) |id| try testing.expectEqual(descriptor_none, registry.get(@intCast(id)));
}

test "a registry of one process keeps the wake an id's first loop made, until it closes it" {
    // Records each descriptor it is given. Closing one twice would need a second entry, so the log
    // has room for one and a second close halts on the bound.
    const CloseLog = struct {
        threadlocal var closed: [1]Descriptor align(@alignOf(Descriptor)) = undefined;
        threadlocal var count: usize = 0;

        fn close(descriptor: Descriptor) void {
            closed[count] = descriptor;
            count += 1;
        }
    };
    var memory: [pair_bytes]u8 align(layout.memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    try testing.expectEqual(@as(?Wake, null), registry.wake(2));
    const kept: Wake = .{ .send = 40, .watch = 40 };
    registry.keep_wake(2, kept);
    registry.set(2, kept.send);
    registry.clear(2);
    // The next loop of the id finds the same wake, and so would one on another thread.
    try testing.expectEqual(kept, registry.wake(2).?);
    try testing.expectEqual(@as(?Wake, null), registry.wake(3));

    CloseLog.count = 0;
    registry.close_kept_wakes(CloseLog.close);
    try testing.expectEqual(@as(usize, 1), CloseLog.count);
    try testing.expectEqual(kept.send, CloseLog.closed[0]);
    // It forgets what it closed, so a second teardown closes nothing.
    try testing.expectEqual(@as(?Wake, null), registry.wake(2));
    registry.close_kept_wakes(CloseLog.close);
    try testing.expectEqual(@as(usize, 1), CloseLog.count);
}

test "a process that attaches sees the rings, the entries and the wakes the creator made" {
    var memory: [pair_bytes]u8 align(@alignOf(Mailbox)) = undefined;
    var creator: Registry = undefined;
    const wakes = made_up_wakes();
    creator.init_group(&memory, pair_loops, &wakes);
    creator.set(1, wakes[1].send);
    try testing.expect(creator.mailbox(1, 3).push(pair_message(1, 3)));

    var member: Registry = undefined;
    try member.attach(&memory);
    try testing.expect(member.group);
    try testing.expectEqual(@as(u16, pair_loops), member.loop_count());
    try testing.expectEqual(wakes[4], member.wake(4).?);
    try testing.expectEqual(wakes[1].send, member.get(1));
    var out: [2]Message = undefined;
    try testing.expectEqual(@as(u32, 1), member.mailbox(1, 3).pop_into(&out));
    try testing.expectEqual(pair_message(1, 3).payload, out[0].payload);

    // A survivor releases the loop of a process that died, and the id is free to claim again.
    member.release(1);
    try testing.expectEqual(descriptor_none, creator.get(1));
    creator.set(1, wakes[1].send);
}

test "a loop takes calls from its mark until it withdraws, and a later loop of the id does not" {
    var memory: [pair_bytes]u8 align(layout.memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    registry.set(1, 41);
    try testing.expect(!registry.takes_calls(1));
    registry.mark_calls(1);
    try testing.expect(registry.takes_calls(1));
    try testing.expect(!registry.takes_calls(2));
    registry.clear(1);
    try testing.expect(!registry.takes_calls(1));
    registry.set(1, 41);
    try testing.expect(!registry.takes_calls(1));
}
