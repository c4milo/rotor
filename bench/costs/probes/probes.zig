//! Every probe this target can run, in the order of docs/costs.md.
//!
//! A probe file exports `probes`, a list of `measure.Probe`. The rows every target has come from
//! the files imported by name below. The rows only one kernel has come from the file selected by
//! `builtin.os.tag`: probes_kqueue.zig on macOS, probes_linux.zig on Linux. Adding the Linux rows
//! means filling probes_linux.zig and touching nothing else.
//!
//! probes_linux.zig exists today as an empty list, because Zig 0.16 resolves every `@import` of a
//! file path when it parses the importing file: a path to a missing file fails the build even
//! inside a branch that is never analysed.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const measure = @import("../measure.zig");
const Probe = measure.Probe;

const portable = @import("probes_memory.zig").probes ++
    @import("probes_cpu.zig").probes ++
    @import("probes_syscall.zig").probes ++
    @import("probes_socket.zig").probes ++
    @import("probes_cross_core.zig").probes ++
    @import("probes_cross_process.zig").probes;

const one_kernel_only = switch (builtin.os.tag) {
    .macos => @import("probes_kqueue.zig").probes,
    .linux => @import("probes_linux.zig").probes,
    else => [_]Probe{},
};

/// The letter a row id starts with: row 14 is "C14".
pub const id_prefix = 'C';

/// Every probe of this target, sorted by row.
pub const all = sorted(portable ++ one_kernel_only);

/// An insertion sort at comptime, which also refuses a row that two probes claim.
fn sorted(comptime list: anytype) [list.len]Probe {
    var result: [list.len]Probe = list;
    for (1..result.len) |unsorted| {
        var position = unsorted;
        while (position > 0) : (position -= 1) {
            const left = result[position - 1].row;
            const right = result[position].row;
            if (left == right) @compileError("two probes claim one row of docs/costs.md");
            if (left < right) break;
            std.mem.swap(Probe, &result[position - 1], &result[position]);
        }
    }
    return result;
}

/// The probe of the row with this id, "C14", or null when the id is malformed or this target has
/// no such row.
pub fn find(id: []const u8) ?*const Probe {
    if (id.len < 2 or id[0] != id_prefix) return null;
    const row = std.fmt.parseInt(u32, id[1..], 10) catch return null;
    for (&all) |*probe| {
        if (probe.row == row) return probe;
    }
    return null;
}

test "the list is sorted by row and find reads an id" {
    comptime var previous: u32 = 0;
    inline for (all) |probe| {
        try std.testing.expect(probe.row > previous);
        previous = probe.row;
    }
    try std.testing.expectEqual(@as(u32, 1), find("C1").?.row);
    try std.testing.expectEqual(@as(u32, 21), find("C21").?.row);
    try std.testing.expect(find("C99") == null);
    try std.testing.expect(find("c1") == null);
    try std.testing.expect(find("C") == null);
}
