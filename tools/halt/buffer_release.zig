//! The halt scenarios of `release_buffers` (rotor issue 13) and of a provide with a group that no
//! caller reserved (decision 29), which each backend's scenarios run on its own loop. The caller
//! gives a loop that has tables, and a ring where the backend needs one.
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

        /// A receive from a group in flight, then the release of that group: the loop would
        /// receive into memory that is the caller's again. The slot is claimed and filled as
        /// `submit` fills it, so the scenario enters no kernel before the release. With the check
        /// deleted, the group is taken back and the scenario returns.
        pub fn release_a_group_in_use(loop: *Loop) void {
            const group = loop.reserve_buffer_group() catch return;
            loop.provide_buffers(group, aligned(&group_memory), buffer_count, buffer_bytes) catch return;
            const index = loop.tables.table.claim() orelse return;
            loop.tables.table.at(index).fill(&core.Operation.receive_from(1, 0, group));
            scenario.reached_violation();
            loop.release_buffers(group);
        }

        /// The release of a group that was reserved and never provided. With the check deleted,
        /// the readiness backends store an empty group over an empty group and the scenario
        /// returns.
        pub fn release_a_group_never_provided(loop: *Loop) void {
            const group = loop.reserve_buffer_group() catch return;
            scenario.reached_violation();
            loop.release_buffers(group);
        }

        /// A provide with a group that no caller reserved: a cast of a literal, which compiles, as
        /// a library that names another library's group would write it. Group 1 is not reserved,
        /// and group 0 is, so the check reads the bit of the group and not only the mask. With the
        /// check deleted, the group is made and the scenario returns.
        pub fn provide_a_group_never_reserved(loop: *Loop) void {
            _ = loop.reserve_buffer_group() catch return;
            const forged: core.BufferGroup = @enumFromInt(1);
            scenario.reached_violation();
            loop.provide_buffers(forged, aligned(&group_memory), buffer_count, buffer_bytes) catch {};
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
