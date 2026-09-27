//! The halt scenario of decision 15's question 2, which each backend's scenarios run on its own
//! loop: two datagram groups of different shapes on one loop. The loop reads every datagram at the
//! offset one shape gives, so the second group would move where the first group's datagrams are
//! read.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const buffer_count = 2;

/// A larger control reserve than the default one the first group takes.
const other_shape: core.datagram.GroupOptions = .{
    .control_reserve = core.datagram.control_reserve_default + 64,
};

/// Room in each buffer for the larger prefix and a small payload, so both groups pass the check
/// that a buffer is larger than its prefix.
const buffer_bytes = core.datagram.prefix_bytes(other_shape) + 64;

/// The scenario for a backend whose `Loop` and `buffers` module are given.
pub fn Scenario(comptime Loop: type, comptime buffers: type) type {
    return struct {
        const alignment = buffers.group_alignment;
        const group_bytes = buffers.group_bytes(buffer_count, buffer_bytes);
        var first_memory: [group_bytes + alignment]u8 align(alignment) = undefined;
        var second_memory: [group_bytes + alignment]u8 align(alignment) = undefined;

        /// Provides group 0 with the default shape, then group 1 with `other_shape`. With the
        /// check deleted, the second group is made and the scenario returns.
        pub fn provide_two_shapes(loop: *Loop) void {
            const first = aligned(&first_memory);
            loop.provide_datagram_buffers(0, first, buffer_count, buffer_bytes, .{}) catch return;
            const second = aligned(&second_memory);
            scenario.reached_violation();
            loop.provide_datagram_buffers(1, second, buffer_count, buffer_bytes, other_shape) catch {};
        }

        /// The memory aligned forward at run time, so the scenario does not depend on the
        /// alignment this platform gives a static.
        fn aligned(memory: []u8) []align(alignment) u8 {
            const base = std.mem.alignForward(usize, @intFromPtr(memory.ptr), alignment);
            const start: [*]align(alignment) u8 = @ptrFromInt(base);
            return start[0..group_bytes];
        }
    };
}
