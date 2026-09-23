//! `Random`, the seeded generator rotor's property tests draw from, so a failing test names a seed
//! that replays it. No production path draws a random value: a loop's behaviour is a function of
//! what the caller submits and what the kernel answers.
//!
//! The generator is splitmix64: one 64-bit state, one addition and three mixing steps per value,
//! all wrapping integer arithmetic. It is written out here rather than taken from `std.Random`,
//! which `core` may not name (tools/lint determinism), so a Zig upgrade cannot change what a seed
//! replays.
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
    state: u64,

    pub fn init(seed: u64) Random {
        return .{ .state = seed };
    }

    /// One uniform 64-bit value.
    pub fn next(random: *Random) u64 {
        random.state = random.state +% step;
        var mixed = random.state;
        mixed = (mixed ^ (mixed >> mix_shift_first)) *% mix_multiplier_first;
        mixed = (mixed ^ (mixed >> mix_shift_second)) *% mix_multiplier_second;
        return mixed ^ (mixed >> mix_shift_third);
    }

    /// A value in `[0, bound)`. The modulo biases the low values by at most one part in
    /// 2^64 / bound, which no bound a test uses comes close to needing.
    pub fn below(random: *Random, bound: u64) u64 {
        assert(bound >= 1);
        const value = random.next() % bound;
        assert(value < bound);
        return value;
    }

    /// A value in `[low, high]`.
    pub fn between(random: *Random, low: u64, high: u64) u64 {
        assert(low <= high);
        const value = low + random.below(high - low + 1);
        assert(value >= low and value <= high);
        return value;
    }

    /// True on `numerator` draws in `denominator`.
    pub fn chance(random: *Random, numerator: u64, denominator: u64) bool {
        assert(denominator >= 1);
        assert(numerator <= denominator);
        return random.below(denominator) < numerator;
    }
};

const testing = std.testing;

test "one seed replays the same values and two seeds differ" {
    var first = Random.init(0xC0FFEE);
    var second = Random.init(0xC0FFEE);
    var other = Random.init(0xC0FFEF);
    var differences: u32 = 0;
    for (0..256) |_| {
        const value = first.next();
        try testing.expectEqual(value, second.next());
        if (value != other.next()) differences += 1;
    }
    try testing.expectEqual(@as(u32, 256), differences);
}

test "the first values of seed 0 are splitmix64's published ones" {
    // The reference implementation's output for seed 0, so a change to a constant or a shift
    // fails here and not in whichever property test happens to notice.
    var random = Random.init(0);
    try testing.expectEqual(@as(u64, 0xE220A8397B1DCDAF), random.next());
    try testing.expectEqual(@as(u64, 0x6E789E6AA1B965F4), random.next());
    try testing.expectEqual(@as(u64, 0x06C45D188009454F), random.next());
}

test "below, between and chance stay inside their bounds" {
    var random = Random.init(1);
    for (0..1024) |_| {
        try testing.expect(random.below(7) < 7);
        const value = random.between(10, 12);
        try testing.expect(value >= 10 and value <= 12);
        try testing.expect(!random.chance(0, 5));
        try testing.expect(random.chance(5, 5));
    }
    try testing.expectEqual(@as(u64, 0), random.below(1));
}
