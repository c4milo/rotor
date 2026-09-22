//! The nearest-rank percentile of an exactly kept sample, which five bench programs each carried a
//! copy of: `rotor_timers`, `libxev_timers`, `std_io_timers`, `rotor_datagram` and `rotor_reads`.
//!
//! `histogram.zig` answers the same question for a bucketed sample and overstates by up to 0.78 per
//! cent, which `bench/alternatives/README.md` records. A program that keeps every sample in an array
//! wants the exact answer, and this is it.
//!
//! One definition, so two candidates of one workload cannot disagree about what p99 means. libuv's
//! programs are in C and cannot import this, so each carries the same arithmetic and says so.
const std = @import("std");
const assert = std.debug.assert;

/// Parts the rank is expressed in. Ten thousand and not a thousand, because p9999 has no whole
/// number of parts per mille: the tail a regression baseline watches would be unsayable.
pub const per_ten_thousand: u64 = 10_000;

pub const p50: u64 = 5_000;
pub const p99: u64 = 9_900;
pub const p999: u64 = 9_990;
pub const p9999: u64 = 9_999;

/// The value at `parts` of `sorted`, by the nearest-rank rule. `sorted` must be sorted ascending;
/// an empty sample answers 0.
///
/// The rank rounds up, so p99 of 100 samples is the 99th and not the 98th, and the index is clamped
/// into the sample so no percentile can read past its end.
pub fn nearest_rank(sorted: []const u64, parts: u64) u64 {
    assert(parts <= per_ten_thousand);
    if (sorted.len == 0) return 0;
    const rank = (sorted.len * parts + per_ten_thousand - 1) / per_ten_thousand;
    const index = @min(@max(rank, 1) - 1, sorted.len - 1);
    assert(index < sorted.len);
    return sorted[index];
}

const testing = std.testing;

test "an empty sample has no percentile, and one sample is every percentile" {
    try testing.expectEqual(@as(u64, 0), nearest_rank(&.{}, p50));
    try testing.expectEqual(@as(u64, 0), nearest_rank(&.{}, p999));

    const one = [_]u64{7};
    try testing.expectEqual(@as(u64, 7), nearest_rank(&one, 0));
    try testing.expectEqual(@as(u64, 7), nearest_rank(&one, p50));
    try testing.expectEqual(@as(u64, 7), nearest_rank(&one, p999));
}

test "the rank rounds up, so a percentile never reads below the value it names" {
    // Ten samples: p99 is rank 9.9, which rounds to 10 and reads index 9. Rounding
    // down would report the 9th value as the 99th percentile, which understates every tail.
    const ten = [_]u64{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    try testing.expectEqual(@as(u64, 4), nearest_rank(&ten, p50));
    try testing.expectEqual(@as(u64, 9), nearest_rank(&ten, p99));
    try testing.expectEqual(@as(u64, 9), nearest_rank(&ten, p999));

    // A hundred samples separate the two: rank 99 is index 98.
    var hundred: [100]u64 = undefined;
    for (&hundred, 0..) |*value, index| value.* = index;
    try testing.expectEqual(@as(u64, 49), nearest_rank(&hundred, p50));
    try testing.expectEqual(@as(u64, 98), nearest_rank(&hundred, p99));
    try testing.expectEqual(@as(u64, 99), nearest_rank(&hundred, p999));
}

test "the lowest rank is a sample and not an index below the sample" {
    // A rank of 0 would index -1. The floor of 1 is what stops it.
    const ten = [_]u64{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 };
    try testing.expectEqual(@as(u64, 10), nearest_rank(&ten, 0));
    try testing.expectEqual(@as(u64, 10), nearest_rank(&ten, 1));
    try testing.expectEqual(@as(u64, 19), nearest_rank(&ten, per_ten_thousand));
}

test "p9999 has a rank of its own once the sample is large enough" {
    // Ten thousand samples: p999 is rank 9,990 and p9999 is rank 9,999, nine values apart. Below
    // ten thousand samples the two collapse, which is why a run's length is scaled to its payload.
    var many: [10_000]u64 = undefined;
    for (&many, 0..) |*value, index| value.* = index;
    try testing.expectEqual(@as(u64, 9_989), nearest_rank(&many, p999));
    try testing.expectEqual(@as(u64, 9_998), nearest_rank(&many, p9999));

    // A hundred samples put both ranks past the end, so both clamp to the largest value and p9999
    // says nothing p999 does not. That is the floor a run has to clear for the tail to mean
    // anything, and it is why `echo_runner` scales a run's length to its payload.
    const hundred = many[0..100];
    try testing.expectEqual(@as(u64, 99), nearest_rank(hundred, p999));
    try testing.expectEqual(@as(u64, 99), nearest_rank(hundred, p9999));
}

test "a repeated value is answered, not averaged" {
    // Nearest rank returns a sample that happened. A method that interpolated would invent a
    // latency no operation had.
    const same = [_]u64{ 5, 5, 5, 5 };
    try testing.expectEqual(@as(u64, 5), nearest_rank(&same, p50));

    const two = [_]u64{ 1, 1, 1, 9 };
    try testing.expectEqual(@as(u64, 1), nearest_rank(&two, p50));
    try testing.expectEqual(@as(u64, 9), nearest_rank(&two, p99));
}
