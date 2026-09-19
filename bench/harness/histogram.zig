//! `Histogram`, the latency record of one worker thread of the benchmark harness. The counters are
//! a fixed array inside the struct, so one histogram per thread sits in static memory, recording
//! allocates nothing, and one `record` touches two cache lines: the line of totals and the line of
//! one counter.
//!
//! The buckets are log-linear, as HdrHistogram's are. A value keeps its leading bit and the
//! `sub_bucket_bits` bits below it; the bits below those are dropped. So every value under 2^8 has
//! a bucket of its own, and every power of two from 2^8 up is cut into 128 equal buckets. A bucket
//! is at most 1/128 of its lower bound wide, so the value a bucket reports is at most 0.79 percent
//! above any value it holds, at every magnitude.
//!
//! Size: 30,848 bytes, aligned to 128. The 3,840 counters of 8 bytes are 30,720 bytes, the totals
//! are 48, and the alignment rounds 30,768 up. That is acceptable for three reasons:
//!
//! - A run touches little of it. One power of two is 128 counters, 1 KiB. A workload whose
//!   latencies span four powers of two, 16 to 256 microseconds for example, touches 4 KiB of
//!   counters and the line of totals, which an L1 data cache holds (64 KiB on `mac`,
//!   docs/costs.md).
//! - The all-zero histogram is the empty one. Static histograms sit in zero-fill memory, and a page
//!   no value lands in is never touched.
//! - A 32-bit counter would halve the size and would wrap after 4.3 × 10^9 values in one bucket,
//!   which the merged histogram of a many-core run can reach. A 64-bit counter cannot wrap.
//!
//! A percentile reports the upper bound of the bucket that holds the value at its rank, so a
//! reported latency is never below the recorded one. `percentile` states the one refinement.
const std = @import("std");
const assert = std.debug.assert;

/// Bits of a value kept below its leading bit. 7 bits make a bucket at most 1/128 of its lower
/// bound wide, 0.79 percent, inside the 1 percent the harness promises. 6 bits would make it 1/64,
/// 1.57 percent, outside it.
pub const sub_bucket_bits: u6 = 7;

/// Buckets per power of two, from 2^(sub_bucket_bits + 1) up.
pub const sub_bucket_count: u32 = 1 << sub_bucket_bits;

/// Bits of the largest value that has a bucket. 2^36 ns is 68.7 s, the first power of two past
/// the 60 s the harness must cover. One more bit would add 128 counters, 1 KiB.
pub const range_bits: u6 = 36;

/// The largest value recorded as itself, in nanoseconds: 68,719,476,735. `record` clamps a larger
/// value to it and counts that value in `overflow`.
pub const value_ns_max: u64 = (1 << range_bits) - 1;

/// The longest latency the range must hold, in nanoseconds: 60 s.
const covered_ns: u64 = 60_000_000_000;

/// Counters in one histogram: 256 for the values below 2^8, each exact, and 128 for each of the
/// 28 powers of two from 2^8 to 2^35.
pub const bucket_count: u32 = @as(u32, range_bits - sub_bucket_bits + 1) * sub_bucket_count;

/// The largest value that has a bucket of its own. OR-ing it into a value puts the leading bit at
/// bit `sub_bucket_bits` or above, which is what lets `bucket_index` run without a branch.
const exact_ns_max: u64 = (1 << (sub_bucket_bits + 1)) - 1;

/// The bit number of the leading bit of a `u64`.
const leading_bit_max: u32 = 63;

/// The alignment of a histogram in bytes: the cache line of Apple silicon and two lines of x86-64
/// (docs/costs.md, Machines), so the histograms of two threads that sit side by side in an array
/// never share a line.
pub const alignment_bytes = 128;

/// The size of a histogram in bytes. The file header shows the arithmetic.
pub const histogram_bytes = 30_848;

/// The bytes of totals that precede the counters: they share the histogram's first cache line.
const totals_bytes = 48;

/// One whole, in the unit `percentile` takes: parts per million. The unit is an integer so that a
/// rank is computed without floating point.
pub const parts_per_million_whole: u32 = 1_000_000;

/// The three percentiles the harness reports, in parts per million.
pub const p50: u32 = 500_000;
pub const p99: u32 = 990_000;
pub const p999: u32 = 999_000;

pub const Histogram = extern struct {
    /// The sum of every value recorded, before clamping. A `u64` count of `u64` values cannot
    /// overflow 128 bits.
    sum_ns: u128 align(alignment_bytes),
    /// Values recorded, the clamped ones included.
    value_count: u64,
    /// Values above `value_ns_max`. Each one was clamped into the last bucket, so a run that
    /// reports a non-zero `overflow` says its tail went past the range.
    overflow: u64,
    /// The bitwise complement of the smallest value recorded. Stored complemented so that the
    /// all-zero histogram is the empty one and `record` needs no first-value branch.
    min_inverted_ns: u64,
    /// The largest value recorded, before clamping.
    max_ns: u64,
    counts: [bucket_count]u64,

    /// The histogram that holds no value: every byte zero.
    pub const empty: Histogram = std.mem.zeroes(Histogram);

    /// Records one latency. This is the hot function: one compare, one count-leading-zeros, two
    /// shifts, and additions and selects. It divides nothing and branches on nothing but the
    /// checks that halt the process. Read from the ReleaseSafe code for aarch64 on 2026-09-19: a
    /// straight line in which every branch leads to a panic.
    pub fn record(histogram: *Histogram, value_ns: u64) void {
        const index = bucket_index(@min(value_ns, value_ns_max));
        histogram.counts[index] += 1;
        histogram.value_count += 1;
        histogram.overflow += @intFromBool(value_ns > value_ns_max);
        histogram.sum_ns += value_ns;
        histogram.min_inverted_ns = @max(histogram.min_inverted_ns, ~value_ns);
        histogram.max_ns = @max(histogram.max_ns, value_ns);
        assert(histogram.overflow <= histogram.value_count);
        assert(histogram.max_ns >= ~histogram.min_inverted_ns);
    }

    /// Adds everything `other` recorded, so the histograms of a run's threads combine into one.
    pub fn merge(histogram: *Histogram, other: *const Histogram) void {
        assert(histogram != other);
        assert(other.overflow <= other.value_count);
        for (&histogram.counts, &other.counts) |*count_here, count_there| {
            count_here.* += count_there;
        }
        histogram.value_count += other.value_count;
        histogram.overflow += other.overflow;
        histogram.sum_ns += other.sum_ns;
        histogram.min_inverted_ns = @max(histogram.min_inverted_ns, other.min_inverted_ns);
        histogram.max_ns = @max(histogram.max_ns, other.max_ns);
        assert(histogram.value_count >= other.value_count);
        assert(histogram.overflow <= histogram.value_count);
    }

    /// The latency at `parts_per_million` of the values, by the nearest-rank rule: the value at
    /// rank `ceil(count × parts_per_million / 1,000,000)`, and at rank 1 when that is 0.
    ///
    /// It returns the upper bound of the bucket that holds that rank, so it never reports less
    /// than the value that was recorded, and at most 1/128 more. The highest occupied bucket
    /// reports `max` instead: `max` is the exact upper bound of what that bucket holds, and it
    /// stays true when values above the range were clamped into the last bucket.
    ///
    /// An empty histogram reports 0.
    pub fn percentile(histogram: *const Histogram, parts_per_million: u32) u64 {
        assert(parts_per_million <= parts_per_million_whole);
        if (histogram.value_count == 0) return 0;
        const rank = rank_of(histogram.value_count, parts_per_million);
        var cumulative: u64 = 0;
        for (&histogram.counts, 0..) |bucket, index| {
            cumulative += bucket;
            if (cumulative < rank) continue;
            if (cumulative == histogram.value_count) return histogram.max_ns;
            return bucket_upper_ns(@intCast(index));
        }
        // The counters sum to `value_count` and the rank is at most that, so the scan returned.
        unreachable;
    }

    /// Values recorded, the clamped ones included.
    pub fn count(histogram: *const Histogram) u64 {
        return histogram.value_count;
    }

    /// The smallest value recorded, or 0 when nothing was.
    pub fn min(histogram: *const Histogram) u64 {
        if (histogram.value_count == 0) return 0;
        return ~histogram.min_inverted_ns;
    }

    /// The largest value recorded, before clamping, or 0 when nothing was.
    pub fn max(histogram: *const Histogram) u64 {
        return histogram.max_ns;
    }

    /// The mean of the values recorded, before clamping, rounded down; 0 when nothing was.
    pub fn mean(histogram: *const Histogram) u64 {
        if (histogram.value_count == 0) return 0;
        const quotient = histogram.sum_ns / histogram.value_count;
        assert(quotient >= histogram.min());
        assert(quotient <= histogram.max_ns);
        return @intCast(quotient);
    }
};

comptime {
    assert(@sizeOf(Histogram) == histogram_bytes);
    assert(@alignOf(Histogram) == alignment_bytes);
    // No padding between fields: the counters start where the totals end.
    assert(@offsetOf(Histogram, "counts") == totals_bytes);
    assert(totals_bytes + @sizeOf(u64) * bucket_count <= histogram_bytes);
    assert(value_ns_max >= covered_ns);
    assert(bucket_index(value_ns_max) == bucket_count - 1);
    assert(p50 < p99 and p99 < p999 and p999 < parts_per_million_whole);
}

/// The 1-based rank `percentile` looks up: `ceil(value_count × parts_per_million / 1,000,000)`
/// in integers, and 1 when that is 0. Rounding down instead would report a lower latency than the
/// one the percentile names.
fn rank_of(value_count: u64, parts_per_million: u32) u64 {
    assert(value_count >= 1);
    assert(parts_per_million <= parts_per_million_whole);
    const product = @as(u128, value_count) * parts_per_million;
    const rounded_up = (product + (parts_per_million_whole - 1)) / parts_per_million_whole;
    const rank: u64 = @max(@as(u64, @intCast(rounded_up)), 1);
    assert(rank <= value_count);
    return rank;
}

/// The bucket of a value inside the range. `shift` is how many low bits the bucket drops: 0 for a
/// value up to `exact_ns_max`, and the leading bit's number less `sub_bucket_bits` above it.
pub fn bucket_index(value_ns: u64) u32 {
    assert(value_ns <= value_ns_max);
    const leading_bit = leading_bit_max - @as(u32, @clz(value_ns | exact_ns_max));
    const shift: u6 = @intCast(leading_bit - sub_bucket_bits);
    const kept: u32 = @intCast(value_ns >> shift);
    const index = (@as(u32, shift) << sub_bucket_bits) + kept;
    assert(index < bucket_count);
    return index;
}

/// How many low bits the values of bucket `index` dropped: the inverse of `bucket_index`'s shift.
fn bucket_shift(index: u32) u6 {
    assert(index < bucket_count);
    return @intCast(@max(index >> sub_bucket_bits, 1) - 1);
}

/// The smallest value bucket `index` holds.
pub fn bucket_lower_ns(index: u32) u64 {
    const shift = bucket_shift(index);
    const kept: u64 = index - (@as(u32, shift) << sub_bucket_bits);
    assert(kept <= exact_ns_max);
    return kept << shift;
}

/// The largest value bucket `index` holds: the value `percentile` reports for the bucket.
pub fn bucket_upper_ns(index: u32) u64 {
    const upper = bucket_lower_ns(index) + (@as(u64, 1) << bucket_shift(index)) - 1;
    assert(upper <= value_ns_max);
    return upper;
}

const testing = std.testing;
const Random = @import("random.zig").Random;

/// Values drawn per power of two in the seeded tests. 1,000 makes the exact ranks of p50, p99 and
/// p999 the whole numbers below, so the oracle needs no rounding rule of its own.
const samples_per_magnitude = 1000;
const rank_p50 = 500;
const rank_p99 = 990;
const rank_p999 = 999;

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

/// Records `samples_per_magnitude` seeded values of one power of two, then checks p50, p99 and
/// p999 against the exact values of the sorted samples: never below, and at most 1 percent above.
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
