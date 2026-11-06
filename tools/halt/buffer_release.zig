//! The halt scenarios of `release_buffers` (rotor issue 13), which each backend's scenarios run on
//! its own loop. The caller gives the loop a loop that has tables, and a ring where the backend
//! needs one.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const buffer_count = 2;
const buffer_bytes = 64;

/// The scenarios for a backend whose `Loop` and `buffers` module are given.
pub fn Scenario(comptime Loop: type, comptime buffers: type) type {
    return struct {
        const alignment = buffers.group_alignment;
        const group_bytes = buffers.group_bytes(buffer_count, buffer_bytes);
        var group_memory: [group_bytes + alignment]u8 align(alignment) = undefined;

        /// A receive from group 0 in flight, then the release of group 0: the loop would receive
        /// into memory that is the caller's again. The slot is claimed and filled as `submit` fills
        /// it, so the scenario enters no kernel before the release. With the check deleted, the
        /// group is taken back and the scenario returns.
        pub fn release_a_group_in_use(loop: *Loop) void {
            loop.provide_buffers(0, aligned(&group_memory), buffer_count, buffer_bytes) catch return;
            const index = loop.tables.table.claim() orelse return;
            loop.tables.table.at(index).fill(&core.Operation.receive_from(1, 0, 0));
            scenario.reached_violation();
            loop.release_buffers(0);
        }

        /// The release of a group that was never provided. With the check deleted, the readiness
        /// backends store an empty group over an empty group and the scenario returns.
        pub fn release_a_group_never_provided(loop: *Loop) void {
            scenario.reached_violation();
            loop.release_buffers(0);
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
