//! A program declares a named group called `default`. This file is the root of its own program, so
//! the public module reads its `rotor_scheduling_groups`. `zig build test-compile-fail` requires it
//! to fail to compile (decision 30).
const rotor = @import("rotor");

pub const rotor_scheduling_groups = .{ .default = 100 };

pub fn main() void {
    _ = rotor.named_scheduling_group(.default);
}
