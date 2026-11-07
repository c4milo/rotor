//! The public `Loop`'s own calls under test, through the public module: the view a library holds
//! (decision 28), the descriptor a host waits on (decision 23), and the wakes a `deinit` dropped
//! (decision 4). Split from `rotor.zig` for the 500-line limit.
const std = @import("std");
const core = @import("core");
const rotor = @import("rotor.zig");

const Event = rotor.Event;
const Loop = rotor.Loop;
const Operation = rotor.Operation;
const SharedLoop = rotor.SharedLoop;
const backend = rotor.backend;
const constants = rotor.constants;
const memory_alignment = rotor.memory_alignment;
const supported = rotor.supported;

const testing = std.testing;

/// The loop of each test, as `rotor.zig`'s tests size theirs.
const test_operations = 4;
const test_options: Loop.Options = .{ .operations = test_operations };
const test_timer_ns = constants.ns_per_ms;
const test_wait_ms = 50;
const test_wait_ns = test_wait_ms * constants.ns_per_ms;

test "a library's calls on the view reach the loop, and its address is the loop's" {
    if (!supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, test_options);
    defer loop.deinit();
    const shared = loop.shared();
    try testing.expectEqual(@intFromPtr(&loop), @intFromPtr(shared));
    comptime core.shared_loop.check(SharedLoop);
    var events: [4]Event = undefined;
    try testing.expectEqual(1, shared.submit(&.{Operation.timer(7, test_timer_ns, 0)}, &.{}));
    try testing.expectEqual(1, loop.in_flight());
    try testing.expectEqual(1, try loop.tick(&events, test_wait_ns));
    try testing.expectEqual(loop.now_ns(), shared.now_ns());
    try testing.expectEqual(0, shared.task_budget_left());
}

test "a loop names a descriptor a host can wait on, on every backend but io_uring" {
    if (!supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, test_options);
    defer loop.deinit();
    // The conformance suite holds each backend to what a host sees on this descriptor. This holds
    // the public `Loop` to its backend's answer (decision 23).
    try testing.expectEqual(backend() == .uring, loop.wait_descriptor() == null);
}

test "a loop reads the wakes its backend dropped" {
    if (!supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, test_options);
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
