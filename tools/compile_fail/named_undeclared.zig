//! A program names a group that its root file does not declare. This file is the root of its own
//! program, so the public module reads its `rotor_scheduling_groups`. `zig build
//! test-compile-fail` requires it to fail to compile (decision 30). The declaration has a named
//! type, so the compiler's message names it the same way on each build.
const rotor = @import("rotor");

const Declared = struct { quic: u16 };

pub const rotor_scheduling_groups: Declared = .{ .quic = 400 };

pub fn main() void {
    _ = rotor.named_scheduling_group(.dns);
}
