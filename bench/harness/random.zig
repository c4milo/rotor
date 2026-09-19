//! `Random`, the seeded generator the harness tests draw from, so a failing test names a seed that
//! replays it. It is a copy of splitmix64 from src/core/random.zig, which holds the original and
//! the reasons for writing it out. bench/harness is a root of its own, build/bench.zig gives it no
//! import, and a module is never reached by path (CLAUDE.md, Layout), so the few lines live here
//! too. The published values in the test below hold both copies to the same sequence.
const std = @import("std");
const assert = std.debug.assert;

/// The odd increment of splitmix64: the 64-bit golden ratio.
const step: u64 = 0x9E37_79B9_7F4A_7C15;
const mix_multiplier_first: u64 = 0xBF58_476D_1CE4_E5B9;
const mix_multiplier_second: u64 = 0x94D0_49BB_1331_11EB;
const mix_shift_first: u6 = 30;
const mix_shift_second: u6 = 27;
const mix_shift_third: u6 = 31;

pub const Random = struct {
    /// The seed this generator was initialised with, kept so a failing test can name it.
    seed: u64,
    state: u64,

    pub fn init(seed: u64) Random {
        return .{ .seed = seed, .state = seed };
    }

    /// One uniform 64-bit value.
    pub fn next(random: *Random) u64 {
        random.state = random.state +% step;
        var mixed = random.state;
        mixed = (mixed ^ (mixed >> mix_shift_first)) *% mix_multiplier_first;
        mixed = (mixed ^ (mixed >> mix_shift_second)) *% mix_multiplier_second;
        return mixed ^ (mixed >> mix_shift_third);
    }

    /// A value in `[low, high]`. The modulo biases the low values by at most one part in
    /// 2^64 / (high - low + 1), which no span a test uses comes close to needing.
    pub fn between(random: *Random, low: u64, high: u64) u64 {
        assert(low <= high);
        const span = high - low;
        if (span == std.math.maxInt(u64)) return random.next();
        const value = low + random.next() % (span + 1);
        assert(value >= low and value <= high);
        return value;
    }
};

const testing = std.testing;

test "the first values of seed 0 are splitmix64's published ones" {
    // The same three values src/core/random.zig pins, so the two copies cannot drift apart.
    var random = Random.init(0);
    try testing.expectEqual(@as(u64, 0xE220A8397B1DCDAF), random.next());
    try testing.expectEqual(@as(u64, 0x6E789E6AA1B965F4), random.next());
    try testing.expectEqual(@as(u64, 0x06C45D188009454F), random.next());
    try testing.expectEqual(@as(u64, 0), random.seed);
}

test "between stays inside its bounds, the widest span included" {
    var random = Random.init(7);
    for (0..1024) |_| {
        const value = random.between(10, 12);
        try testing.expect(value >= 10 and value <= 12);
    }
    try testing.expectEqual(@as(u64, 5), random.between(5, 5));
    _ = random.between(0, std.math.maxInt(u64));
}
