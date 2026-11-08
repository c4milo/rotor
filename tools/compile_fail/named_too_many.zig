//! A program declares 16 named groups, one more than the ids it has. This file is the root of its own program, so
//! the public module reads its `rotor_scheduling_groups`. `zig build test-compile-fail` requires it
//! to fail to compile (decision 30).
const rotor = @import("rotor");

pub const rotor_scheduling_groups = .{ .g0 = 100, .g1 = 100, .g2 = 100, .g3 = 100, .g4 = 100, .g5 = 100, .g6 = 100, .g7 = 100, .g8 = 100, .g9 = 100, .g10 = 100, .g11 = 100, .g12 = 100, .g13 = 100, .g14 = 100, .g15 = 100 };

pub fn main() void {
    _ = rotor.named_scheduling_group(.g0);
}
