//! Scheduling groups (decision 30): task queues with shares, on one loop. The loop serves them by
//! deficit round robin (DRR) in cost units that each task states, and never by time, because a
//! charge by run time would read the clock (non-negotiable 2).
//!
//! This file holds the named groups and the root's declaration of them. `scheduling_groups.zig`
//! holds the table of one reactor, and `scheduling_run.zig` holds the rule. The rest of it is
//! pure: it takes no `*Loop` and reads no clock. The core keeps the id `SchedulingGroup`, and the
//! root of `reactor` declares `NamedSchedulingGroup` (decision 33, "Where each type is declared").
//! The core never reads the program's root file. This module reads `rotor_scheduling_groups`
//! there, and each reactor type takes those names by default (decision 30, ruling items 5 and 7;
//! decision 33, "The public module").
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("../constants.zig");
const reactor_module = @import("../reactor.zig");

/// The table of one loop's groups: `scheduling_groups.zig`.
pub const groups = @import("scheduling_groups.zig");
pub const Groups = groups.Groups;
pub const Lane = groups.Lane;
/// The rule, DRR in cost units: `scheduling_run.zig`.
pub const rule = @import("scheduling_run.zig");

const SchedulingGroup = core.SchedulingGroup;
const NamedSchedulingGroup = reactor_module.NamedSchedulingGroup;

/// What `reserve_scheduling_group` returns when every id of the reactor is reserved.
pub const ReserveSchedulingGroupError = error{SchedulingGroupsFull};

/// The same id as a `SchedulingGroup` of the reactor that calls it, for `schedule_in`:
/// `NamedSchedulingGroup.group`. Every reactor reserves the named groups at init, so the id names
/// that group on each reactor. v0.10.0 named it `scheduling_group` (decision 33, open question 14).
pub fn group_of(group: NamedSchedulingGroup) SchedulingGroup {
    // Only `Named(...).group` makes an id other than `.default`, and its ids fit the table.
    assert(@intFromEnum(group) < constants.scheduling_groups_max);
    return @enumFromInt(@intFromEnum(group));
}

/// The program's declaration, or none when its root file declares no `rotor_scheduling_groups`.
const root = @import("root");
const root_declaration = if (@hasDecl(root, "rotor_scheduling_groups")) root.rotor_scheduling_groups else .{};

/// The program's named groups, which `Named` checks at compile time. Each reactor type takes them
/// by default, the host's and a twin's alike (decision 33, "The public module").
pub const root_groups = Named(root_declaration);

/// What a loop's `init` reserves: n, and the shares of ids 1 to n. A backend's `Loop.Options`
/// carries it. The public module sets it from the program's root file. Size 32 B, alignment 2.
pub const NamedTable = struct {
    count: u8,
    shares: [constants.scheduling_groups_max - 1]u16,

    /// The table of a program that declares no named group.
    pub const empty: NamedTable = .{ .count = 0, .shares = @splat(0) };
};

comptime {
    assert(@sizeOf(SchedulingGroup) == 1);
    assert(@sizeOf(NamedSchedulingGroup) == 1);
    assert(@sizeOf(NamedTable) == 32);
    assert(@alignOf(NamedTable) == 2);
}

/// The named groups of `declaration`, a struct literal such as `.{ .quic = 400, .dns = 100 }`. The
/// field order is the id order, and each value is the group's shares at init. It refuses the name
/// `default`, shares of 0 or above `scheduling_shares_max`, and more than
/// `scheduling_groups_max - 1` names, with a compile error.
pub fn Named(comptime declaration: anytype) type {
    const fields = @typeInfo(@TypeOf(declaration)).@"struct".fields;
    if (fields.len > constants.scheduling_groups_max - 1) {
        @compileError("a program declares at most scheduling_groups_max - 1 named groups");
    }
    var shares: [constants.scheduling_groups_max - 1]u16 = @splat(0);
    for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, "default")) {
            @compileError("the name 'default' is the group every loop has: name the group otherwise");
        }
        const value = @field(declaration, field.name);
        if (value < 1 or value > constants.scheduling_shares_max) {
            @compileError("the shares of the named group '" ++ field.name ++
                "' are not in 1 to scheduling_shares_max");
        }
        shares[index] = value;
    }
    const frozen = shares;
    return struct {
        /// The names, in the order of the declaration: `enum { quic, dns }`.
        pub const Name = std.meta.FieldEnum(@TypeOf(declaration));
        /// The count n and the shares of ids 1 to n, for a loop's options.
        pub const table: NamedTable = .{ .count = fields.len, .shares = frozen };

        /// The id is 1 plus the name's place in the declaration.
        pub fn group(comptime name: Name) NamedSchedulingGroup {
            return @enumFromInt(@as(u8, @intFromEnum(name)) + 1);
        }
    };
}

const testing = std.testing;

test "named groups take ids 1 to n in the order of the declaration, with their shares" {
    const Declared = Named(.{ .low = 100, .high = 300, .tail = 1000 });
    try testing.expectEqual(@as(u8, 3), Declared.table.count);
    try testing.expectEqualSlices(u16, &.{ 100, 300, 1000 }, Declared.table.shares[0..3]);
    for (Declared.table.shares[3..]) |unused| try testing.expectEqual(@as(u16, 0), unused);
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Declared.group(.low)));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Declared.group(.tail)));
    const id: SchedulingGroup = Declared.group(.high).group();
    try testing.expectEqual(@as(u8, 2), @intFromEnum(id));
}

test "a declaration with no name gives the empty table" {
    const Declared = Named(.{});
    try testing.expectEqual(NamedTable.empty.count, Declared.table.count);
    try testing.expectEqual(@as(usize, 0), @typeInfo(Declared.Name).@"enum".fields.len);
    try testing.expectEqual(SchedulingGroup.default, NamedSchedulingGroup.default.group());
}
