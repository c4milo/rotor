//! `Handle`, the caller's name for one in-flight operation (decision 1): a slot index and the
//! generation the slot had when the operation claimed it. The caller holds no pointer into the
//! loop. A backend writes the same 64 bits as the kernel's `user_data`, so a completion names its
//! slot by index, and a completion for a slot that was freed since carries a generation that no
//! longer matches (decision 5, rule 1).
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// 8 bytes, the alignment of a `u64`. `index` is the low half.
pub const Handle = packed struct(u64) {
    index: u32,
    generation: u32,

    /// The handle that names no operation. Every slot's generation starts at
    /// `constants.generation_first` and never becomes 0, so no claimed slot has this handle.
    pub const none: Handle = .{ .index = 0, .generation = 0 };

    pub fn is_none(handle: Handle) bool {
        return handle.generation == 0;
    }

    /// The 64 bits a backend writes as the kernel's `user_data`. Never 0 for a claimed slot.
    pub fn to_bits(handle: Handle) u64 {
        assert(!handle.is_none());
        return @bitCast(handle);
    }

    pub fn from_bits(bits: u64) Handle {
        const handle: Handle = @bitCast(bits);
        assert(handle.index == @as(u32, @truncate(bits)));
        return handle;
    }

    /// The generation that follows `generation`, skipping 0 when 32 bits wrap.
    pub fn next_generation(generation: u32) u32 {
        assert(generation >= constants.generation_first);
        const next = generation +% 1;
        return if (next == 0) constants.generation_first else next;
    }
};

comptime {
    assert(@sizeOf(Handle) == @sizeOf(u64));
    assert(@alignOf(Handle) == @alignOf(u64));
}

const testing = std.testing;

test "a handle round-trips through the kernel's user_data with the index in the low half" {
    const handle: Handle = .{ .index = 0xAABBCCDD, .generation = 7 };
    try testing.expectEqual(@as(u64, 0x0000_0007_AABB_CCDD), handle.to_bits());
    try testing.expectEqual(handle, Handle.from_bits(handle.to_bits()));
}

test "the none handle is all zero bits and no generation reaches it" {
    try testing.expect(Handle.none.is_none());
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(Handle.none)));
    try testing.expect(!(Handle{ .index = 0, .generation = constants.generation_first }).is_none());
    try testing.expectEqual(@as(u32, 8), Handle.next_generation(7));
    const wrapped = Handle.next_generation(std.math.maxInt(u32));
    try testing.expectEqual(constants.generation_first, wrapped);
}
