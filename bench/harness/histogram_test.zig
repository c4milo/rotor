//! The tests of `histogram.zig`, in a file of their own because the two together passed the
//! 500-line limit of CLAUDE.md on 2026-09-22. Every name below is that file's; nothing here is
//! reachable from the harness except through it.
//!
//! `harness.zig` imports this file in its `test` block, which is how these run.
const std = @import("std");
const testing = std.testing;
const Random = @import("random.zig").Random;
const histogram_module = @import("histogram.zig");

const sub_bucket_bits = histogram_module.sub_bucket_bits;
const sub_bucket_count = histogram_module.sub_bucket_count;
const range_bits = histogram_module.range_bits;
const value_ns_max = histogram_module.value_ns_max;
const bucket_count = histogram_module.bucket_count;
const totals_bytes = histogram_module.totals_bytes;
const parts_per_million_whole = histogram_module.parts_per_million_whole;
const p50 = histogram_module.p50;
const p99 = histogram_module.p99;
const p999 = histogram_module.p999;
const p9999 = histogram_module.p9999;
const Histogram = histogram_module.Histogram;
const rank_of = histogram_module.rank_of;
const bucket_index = histogram_module.bucket_index;
const bucket_lower_ns = histogram_module.bucket_lower_ns;
const bucket_upper_ns = histogram_module.bucket_upper_ns;

/// Values drawn per power of two in the seeded tests. 10,000 makes the exact ranks of all four
/// percentiles the whole numbers below, so the oracle needs no rounding rule of its own. 1,000
/// would give p9999 the rank of the largest value and check nothing p999 does not.
const samples_per_magnitude = 10_000;
const rank_p50 = 5_000;
const rank_p99 = 9_900;
const rank_p999 = 9_990;
const rank_p9999 = 9_999;

/// One whole, in percent: the error the harness promises is 1 of these.
const percent_whole = 100;

fn record_all(histogram: *Histogram, values: []const u64) void {
    for (values) |value| histogram.record(value);
}

fn expect_same(expected: *const Histogram, actual: *const Histogram) !void {
    try testing.expectEqualSlices(u64, &expected.counts, &actual.counts);
    try testing.expectEqual(expected.value_count, actual.value_count);
    try testing.expectEqual(expected.overflow, actual.overflow);
    try testing.expectEqual(expected.sum_ns, actual.sum_ns);
    try testing.expectEqual(expected.min(), actual.min());
    try testing.expectEqual(expected.max(), actual.max());
}

test "a histogram is 30,848 bytes aligned to 128, and the all-zero one is empty" {
    try testing.expectEqual(30_848, @sizeOf(Histogram));
    try testing.expectEqual(128, @alignOf(Histogram));
    try testing.expectEqual(48, @offsetOf(Histogram, "counts"));
    try testing.expectEqual(3840, bucket_count);
    try testing.expectEqual(@as(u64, 68_719_476_735), value_ns_max);
    const totals = std.mem.asBytes(&Histogram.empty)[0..totals_bytes];
    try testing.expect(std.mem.allEqual(u8, totals, 0));
    try testing.expect(std.mem.allEqual(u64, &Histogram.empty.counts, 0));
}

test "an empty histogram reports zeros and does not crash" {
    const histogram: Histogram = .empty;
    try testing.expectEqual(@as(u64, 0), histogram.percentile(p50));
    try testing.expectEqual(@as(u64, 0), histogram.percentile(p999));
    try testing.expectEqual(@as(u64, 0), histogram.percentile(parts_per_million_whole));
    try testing.expectEqual(@as(u64, 0), histogram.count());
    try testing.expectEqual(@as(u64, 0), histogram.min());
    try testing.expectEqual(@as(u64, 0), histogram.max());
    try testing.expectEqual(@as(u64, 0), histogram.mean());
    try testing.expectEqual(@as(u64, 0), histogram.overflow);
}

test "the buckets tile the range: each maps back to itself and meets the next" {
    try testing.expectEqual(@as(u64, 0), bucket_lower_ns(0));
    try testing.expectEqual(value_ns_max, bucket_upper_ns(bucket_count - 1));
    for (0..bucket_count) |position| {
        const index: u32 = @intCast(position);
        const lower = bucket_lower_ns(index);
        const upper = bucket_upper_ns(index);
        try testing.expect(lower <= upper);
        try testing.expectEqual(index, bucket_index(lower));
        try testing.expectEqual(index, bucket_index(upper));
    }
    for (1..bucket_count) |position| {
        const index: u32 = @intCast(position);
        try testing.expectEqual(bucket_upper_ns(index - 1) + 1, bucket_lower_ns(index));
    }
}

test "a power of two opens a bucket and the value before it closes the last one" {
    try testing.expectEqual(@as(u32, 255), bucket_index(255));
    try testing.expectEqual(@as(u32, 256), bucket_index(256));
    try testing.expectEqual(@as(u32, 256), bucket_index(257));
    try testing.expectEqual(@as(u32, 257), bucket_index(258));
    for (sub_bucket_bits + 1..range_bits) |bit| {
        const power = @as(u64, 1) << @intCast(bit);
        const opens: u32 = @intCast((bit - sub_bucket_bits + 1) * sub_bucket_count);
        try testing.expectEqual(opens, bucket_index(power));
        try testing.expectEqual(opens - 1, bucket_index(power - 1));
        try testing.expectEqual(power, bucket_lower_ns(opens));
        try testing.expectEqual(power - 1, bucket_upper_ns(opens - 1));
    }
}

test "exact percentiles of small known data sets" {
    var hundred: Histogram = .empty;
    for (1..101) |value| hundred.record(value);
    try testing.expectEqual(@as(u64, 1), hundred.percentile(0));
    try testing.expectEqual(@as(u64, 50), hundred.percentile(p50));
    try testing.expectEqual(@as(u64, 90), hundred.percentile(900_000));
    try testing.expectEqual(@as(u64, 99), hundred.percentile(p99));
    try testing.expectEqual(@as(u64, 100), hundred.percentile(p999));
    try testing.expectEqual(@as(u64, 100), hundred.percentile(parts_per_million_whole));

    var repeated: Histogram = .empty;
    record_all(&repeated, &.{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 200 });
    try testing.expectEqual(@as(u64, 7), repeated.percentile(p50));
    try testing.expectEqual(@as(u64, 7), repeated.percentile(900_000));
    try testing.expectEqual(@as(u64, 200), repeated.percentile(p99));
}

test "the rank rounds up, never down" {
    var five: Histogram = .empty;
    record_all(&five, &.{ 10, 20, 30, 40, 50 });
    // 5 × 0.5 is 2.5, so the median is the third value.
    try testing.expectEqual(@as(u64, 30), five.percentile(p50));
    // 5 × 0.99 is 4.95, so p99 is the fifth value.
    try testing.expectEqual(@as(u64, 50), five.percentile(p99));

    var three: Histogram = .empty;
    record_all(&three, &.{ 10, 20, 30 });
    // 3 × 333,333 is one short of a whole, so the rank is 1; one part more makes it 2.
    try testing.expectEqual(@as(u64, 10), three.percentile(333_333));
    try testing.expectEqual(@as(u64, 20), three.percentile(333_334));
    try testing.expectEqual(@as(u64, 20), three.percentile(666_666));
    try testing.expectEqual(@as(u64, 30), three.percentile(666_667));

    const largest: u64 = std.math.maxInt(u64);
    try testing.expectEqual(@as(u64, 1), rank_of(1, 0));
    try testing.expectEqual(@as(u64, 999), rank_of(1000, p999));
    try testing.expectEqual(@as(u64, 1000), rank_of(1000, 999_001));
    try testing.expectEqual(largest, rank_of(largest, parts_per_million_whole));
}

test "a percentile reports its bucket's upper bound, and the maximum in the highest bucket" {
    var histogram: Histogram = .empty;
    // 300 sits in [300, 301], 1000 in [1000, 1003] and 70,000 in [69,632, 70,143].
    record_all(&histogram, &.{ 300, 1000, 70_000 });
    try testing.expectEqual(@as(u64, 301), histogram.percentile(333_333));
    try testing.expectEqual(@as(u64, 1003), histogram.percentile(p50));
    try testing.expectEqual(@as(u64, 1003), histogram.percentile(666_666));
    try testing.expectEqual(@as(u64, 70_000), histogram.percentile(p99));
    try testing.expectEqual(@as(u64, 70_000), histogram.percentile(parts_per_million_whole));

    // A second value in the highest bucket: the bucket still reports the recorded maximum.
    histogram.record(70_100);
    try testing.expectEqual(@as(u64, 70_100), histogram.percentile(p99));
    try testing.expectEqual(@as(u64, 1003), histogram.percentile(p50));
}

test "count, min, max and mean, with a sum wider than 64 bits" {
    var histogram: Histogram = .empty;
    record_all(&histogram, &.{ 20, 10, 40 });
    try testing.expectEqual(@as(u64, 3), histogram.count());
    try testing.expectEqual(@as(u64, 10), histogram.min());
    try testing.expectEqual(@as(u64, 40), histogram.max());
    // 70 / 3 is 23.3: the mean rounds down.
    try testing.expectEqual(@as(u64, 23), histogram.mean());

    var zero: Histogram = .empty;
    zero.record(0);
    try testing.expectEqual(@as(u64, 1), zero.count());
    try testing.expectEqual(@as(u64, 0), zero.min());
    try testing.expectEqual(@as(u64, 1), zero.counts[0]);

    var wide: Histogram = .empty;
    const largest = std.math.maxInt(u64);
    record_all(&wide, &.{ largest, largest, largest - 3 });
    try testing.expectEqual(@as(u64, largest - 1), wide.mean());
    try testing.expectEqual(@as(u64, largest - 3), wide.min());
}

test "a value above the range is clamped into the last bucket and counted in overflow" {
    var histogram: Histogram = .empty;
    histogram.record(value_ns_max);
    try testing.expectEqual(@as(u64, 0), histogram.overflow);
    histogram.record(value_ns_max + 1);
    try testing.expectEqual(@as(u64, 1), histogram.overflow);
    histogram.record(std.math.maxInt(u64));
    histogram.record(5);

    try testing.expectEqual(@as(u64, 2), histogram.overflow);
    try testing.expectEqual(@as(u64, 4), histogram.count());
    try testing.expectEqual(@as(u64, 3), histogram.counts[bucket_count - 1]);
    try testing.expectEqual(@as(u64, 1), histogram.counts[5]);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), histogram.max());
    try testing.expectEqual(@as(u64, 5), histogram.percentile(250_000));
    // The clamped tail reports the recorded maximum, not the range's limit.
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), histogram.percentile(p999));
}

test "the value a bucket reports is at most 1/128 above any value in it, at every magnitude" {
    var random = Random.init(0x0B5E_55ED);
    errdefer std.debug.print("seed {x}\n", .{random.seed});
    for (0..range_bits) |bit| {
        const low = @as(u64, 1) << @intCast(bit);
        for (0..samples_per_magnitude) |_| {
            const value = random.between(low, 2 * low - 1);
            const index = bucket_index(value);
            const reported = bucket_upper_ns(index);
            try testing.expect(bucket_lower_ns(index) <= value);
            try testing.expect(reported >= value);
            try testing.expect((reported - value) * sub_bucket_count <= value);
            try testing.expect((reported - value) * percent_whole <= value);
        }
    }
}

/// Records `samples_per_magnitude` seeded values of one power of two, then checks all four
/// percentiles against the exact values of the sorted samples: never below, at most 1 percent above.
fn expect_percentiles_near_exact(random: *Random, low: u64) !void {
    var histogram: Histogram = .empty;
    var samples: [samples_per_magnitude]u64 = undefined;
    for (&samples) |*sample| {
        sample.* = random.between(low, (low << 1) - 1);
        histogram.record(sample.*);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const cases = [_]struct { parts: u32, rank: u32 }{
        .{ .parts = p50, .rank = rank_p50 },
        .{ .parts = p99, .rank = rank_p99 },
        .{ .parts = p999, .rank = rank_p999 },
        .{ .parts = p9999, .rank = rank_p9999 },
    };
    for (cases) |case| {
        const exact = samples[case.rank - 1];
        const reported = histogram.percentile(case.parts);
        try testing.expect(reported >= exact);
        try testing.expect((reported - exact) * percent_whole <= exact);
    }
    try testing.expectEqual(samples[0], histogram.min());
    try testing.expectEqual(samples[samples_per_magnitude - 1], histogram.max());
}

test "seeded percentiles stay within 1 percent of the exact ones, at every magnitude" {
    var random = Random.init(0x5EED_0001);
    errdefer std.debug.print("seed {x}\n", .{random.seed});
    for (0..range_bits) |bit| {
        try expect_percentiles_near_exact(&random, @as(u64, 1) << @intCast(bit));
    }
}

test "merge equals recording everything into one histogram" {
    var random = Random.init(0x3E26_E000);
    errdefer std.debug.print("seed {x}\n", .{random.seed});
    var first: Histogram = .empty;
    var second: Histogram = .empty;
    var both: Histogram = .empty;
    for (0..4 * samples_per_magnitude) |position| {
        // About one value in 18 is above the range, so both halves carry an overflow count.
        const bit: u6 = @intCast(random.between(4, range_bits + 2));
        const value = random.between(16, (@as(u64, 2) << bit) - 1);
        const half = if (position % 2 == 0) &first else &second;
        half.record(value);
        both.record(value);
    }
    // `second` alone holds the smallest and the largest value, so a merge must take them from
    // the other histogram one way round and keep its own the other way round.
    record_all(&second, &.{ 3, std.math.maxInt(u64) });
    record_all(&both, &.{ 3, std.math.maxInt(u64) });
    try testing.expect(first.overflow >= 1 and second.overflow >= 2);
    try testing.expect(first.min() > second.min() and first.max() < second.max());

    var forward = first;
    forward.merge(&second);
    try expect_same(&both, &forward);
    try testing.expectEqual(both.percentile(p99), forward.percentile(p99));
    try testing.expectEqual(both.mean(), forward.mean());

    var backward = second;
    backward.merge(&first);
    try expect_same(&both, &backward);

    // Merging the empty histogram changes nothing, the minimum included.
    forward.merge(&.empty);
    try expect_same(&both, &forward);
}
