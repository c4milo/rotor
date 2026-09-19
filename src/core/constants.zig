//! Every named limit of the `core` module. A limit two modules share lives here; a comptime
//! assert stays with the constant it pins.
const std = @import("std");

/// The size in bytes docs/decisions/0003-speed-sources.md proposes for one `Completion`: one
/// cache line of the x86-64 servers rotor targets, and half of one on Apple silicon, which
/// reports 128. It is a proposal until that record is accepted; the comptime assert that holds
/// the struct to it lands with the struct.
pub const completion_bytes: u32 = 64;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(completion_bytes));
}

test "completion_bytes is one x86-64 cache line" {
    try std.testing.expectEqual(64, completion_bytes);
}
