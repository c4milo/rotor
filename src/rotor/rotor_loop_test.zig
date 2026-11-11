//! The public `Loop` under test, through the public module: the surface it carries, a loop that
//! runs, a registry and a remote, posts, the descriptor a host waits on (decision 23), and the wakes
//! a `deinit` dropped (decision 4). Split from `rotor.zig` for the 500-line limit.
const std = @import("std");
const core = @import("core");
const rotor = @import("rotor.zig");

const Event = rotor.Event;
const Handle = rotor.Handle;
const Loop = rotor.Loop;
const Operation = rotor.Operation;
const Registry = rotor.Registry;
const Remote = rotor.Remote;
const backend = rotor.backend;
const constants = rotor.constants;
const memory_alignment = rotor.memory_alignment;
const supported = rotor.supported;

const testing = std.testing;

test "a loop names a descriptor a host can wait on, on every backend but io_uring" {
    if (!supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &test_options);
    defer loop.deinit();
    // The conformance suite holds each backend to what a host sees on this descriptor. This holds
    // the public `Loop` to its backend's answer (decision 23).
    try testing.expectEqual(backend() == .uring, loop.wait_descriptor() == null);
}

test "a loop reads the wakes its backend dropped" {
    if (!supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &test_options);
    loop.deinit();
    try testing.expectEqual(0, loop.dropped_wakes());
    // A count above 2^32 shows that no backend narrows it. This holds the public `Loop` to its
    // backend's count (decision 4, fourth amendment of 2026-11-06).
    const count: u64 = (1 << 32) + 3;
    switch (loop.inner) {
        inline else => |*inner| inner.dropped_wake_count = count,
    }
    try testing.expectEqual(count, loop.dropped_wakes());
}

/// The declarations of `Loop` beyond the surface: its error sets, and nothing else.
pub const loop_error_sets = [_][]const u8{
    "InitError", "TickError", "DrainError", "RegisterError", "ProvideError", "PostError",
};
const remote_error_sets = [_][]const u8{ "InitError", "PostError" };
const registry_declarations = [_][]const u8{
    "memory_bytes", "init", "loop_count", "GroupError", "AttachError", "init_group", "attach", "release",
    "deinit",
};

pub fn named(comptime T: type, comptime lists: []const []const []const u8) bool {
    inline for (@typeInfo(T).@"struct".decls) |declaration| {
        var found = false;
        inline for (lists) |list| {
            for (list) |name| {
                if (std.mem.eql(u8, name, declaration.name)) found = true;
            }
        }
        if (!found) return false;
    }
    return true;
}

test "the public types carry the surface and their error sets, and nothing else" {
    const surface = core.surface;
    // The 28 names of decision 33, and the 6 error sets: the reactor's 4 sets left with its names.
    try testing.expectEqual(28, surface.loop_declarations.len);
    try testing.expectEqual(6, loop_error_sets.len);
    try testing.expect(named(Loop, &.{ &surface.loop_declarations, &loop_error_sets }));
    try testing.expectEqual(surface.loop_declarations.len + loop_error_sets.len, @typeInfo(Loop).@"struct".decls.len);
    try testing.expect(named(Remote, &.{ &surface.remote_declarations, &remote_error_sets }));
    try testing.expectEqual(surface.remote_declarations.len + remote_error_sets.len, @typeInfo(Remote).@"struct".decls.len);
    try testing.expect(named(Registry, &.{&registry_declarations}));
    try testing.expectEqual(registry_declarations.len, @typeInfo(Registry).@"struct".decls.len);
    // One field each: what is wrapped, and no state of this file's own.
    try testing.expectEqual(1, @typeInfo(Loop).@"struct".fields.len);
    try testing.expectEqual(1, @typeInfo(Remote).@"struct".fields.len);
    try testing.expectEqual(1, @typeInfo(Registry).@"struct".fields.len);
}

const test_operations = 4;
const test_options: Loop.Options = .{ .operations = test_operations };
const test_timer_ns = constants.ns_per_ms;
const test_wait_ms = 50;
const test_wait_ns = test_wait_ms * constants.ns_per_ms;

test "a loop built through the public module runs, cancels, drains and counts" {
    if (!supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &test_options);
    defer loop.deinit();
    var handles = [_]Handle{.none};
    var events: [4]Event = undefined;

    // A timer fires, with its user data, inside one waiting tick. No clock is read before the first
    // tick, and the tick that hands the fire over read at least the timer's wait.
    try testing.expectEqual(0, loop.now_ns());
    try testing.expectEqual(1, loop.submit(&.{Operation.timer(7, test_timer_ns, 0)}, &handles));
    try testing.expect(handles[0] != Handle.none);
    try testing.expectEqual(1, loop.in_flight());
    try testing.expectEqual(1, try loop.tick(&events, test_wait_ns));
    try testing.expect(loop.now_ns() >= test_timer_ns);
    try testing.expectEqual(7, events[0].user_data);
    try testing.expectEqual(0, try events[0].outcome());
    try testing.expectEqual(0, loop.in_flight());
    // The statistics are reachable; what they hold is sampled and decision 9's to define.
    try testing.expect(loop.statistics().sample_mask >= 1);

    // A cancelled timer ends with Canceled, and drain leaves nothing in flight.
    _ = loop.submit(&.{Operation.timer(8, constants.ns_per_s, 0)}, &handles);
    loop.cancel(handles[0]);
    try testing.expectEqual(1, try loop.tick(&events, test_wait_ns));
    try testing.expectError(error.Canceled, events[0].outcome());
    _ = loop.submit(&.{Operation.timer(9, constants.ns_per_s, 0)}, &.{});
    loop.cancel_all();
    try loop.drain(&events);
    loop.assert_empty();
}

test "a registry and a remote work through the public module" {
    if (!supported) return error.SkipZigTest;
    // Three slots: the loop, the remote, and one that runs nothing.
    var registry_memory: [Registry.memory_bytes(3)]u8 align(memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&registry_memory, 3);
    defer registry.deinit();
    try testing.expectEqual(3, registry.loop_count());
    var memory: [Loop.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    var options = test_options;
    options.registry = &registry;
    try loop.init(&memory, &options);
    defer loop.deinit();
    var remote: Remote = undefined;
    try remote.init(&registry, 1);
    defer remote.deinit();

    try remote.post(0, .{ .payload = 41, .tag = 3 });
    var events: [4]Event = undefined;
    try testing.expectEqual(1, try loop.tick(&events, test_wait_ns));
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(41, events[0].user_data);
    try testing.expectEqual(3, events[0].result);
    try testing.expectError(error.LoopNotFound, remote.post(2, .{ .payload = 0, .tag = 0 }));
}

test "a loop posts to another loop through the public module, with no event of its own" {
    if (!supported) return error.SkipZigTest;
    // Two loops on this thread, and a third id that runs nothing.
    var registry_memory: [Registry.memory_bytes(3)]u8 align(memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&registry_memory, 3);
    defer registry.deinit();
    var options = test_options;
    options.registry = &registry;
    var sender_memory: [Loop.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var sender: Loop = undefined;
    try sender.init(&sender_memory, &options);
    defer sender.deinit();
    options.id = 1;
    var receiver_memory: [Loop.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var receiver: Loop = undefined;
    try receiver.init(&receiver_memory, &options);
    defer receiver.deinit();

    try sender.post(1, .{ .payload = 41, .tag = 3 });
    try testing.expectError(error.LoopNotFound, sender.post(2, .{ .payload = 0, .tag = 0 }));
    var events: [4]Event = undefined;
    try testing.expectEqual(0, try sender.tick(&events, 0));
    try testing.expectEqual(1, try receiver.tick(&events, test_wait_ns));
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(41, events[0].user_data);
    try testing.expectEqual(3, events[0].result);
}
