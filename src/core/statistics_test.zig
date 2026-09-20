//! The tests of `statistics.zig` (decision 9). They live apart because they pin the sampling
//! decision against a range of clock values, and those literals are the point of the test.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const slot_module = @import("slot.zig");
const statistics_module = @import("statistics.zig");

const Slot = slot_module.Slot;
const Statistics = statistics_module.Statistics;
const bucket_of = statistics_module.bucket_of;
const buckets = statistics_module.buckets;

test "a latency lands in the bucket of its highest bit, and the last bucket has no upper end" {
    try testing.expectEqual(@as(u32, 0), bucket_of(0));
    try testing.expectEqual(@as(u32, 0), bucket_of(1));
    try testing.expectEqual(@as(u32, 1), bucket_of(2));
    try testing.expectEqual(@as(u32, 1), bucket_of(3));
    try testing.expectEqual(@as(u32, 2), bucket_of(4));
    try testing.expectEqual(@as(u32, 9), bucket_of(1023));
    try testing.expectEqual(@as(u32, 10), bucket_of(1024));
    try testing.expectEqual(@as(u32, buckets - 1), bucket_of(@as(u64, 1) << (buckets - 1)));
    try testing.expectEqual(@as(u32, buckets - 2), bucket_of((@as(u64, 1) << (buckets - 1)) - 1));
    try testing.expectEqual(@as(u32, buckets - 1), bucket_of(std.math.maxInt(u64)));
}

/// A slot as `submit` hands it over: claimed, filled, not yet measured.
fn claimed_slot() Slot {
    var slot: Slot = std.mem.zeroes(Slot);
    slot.state = .queued;
    slot.generation = constants.generation_first;
    slot.code = .nop;
    return slot;
}

const decision_clocks = [_]u64{ 0, 7, 1 << 20, 3_000_000_001, std.math.maxInt(u64) / 3 };
const decision_sequences = 64;

test "the sampling decision reads the sequence and never the clock" {
    var starts: [1]u64 = undefined;
    var by_sequence: [decision_sequences]bool = undefined;
    var taken: u32 = 0;
    // Decision 9, rule 2: the same calls give the same samples, however long the host took to
    // make them. The clocks below differ in their low bits, which is where a mask reads.
    for (0..decision_sequences) |sequence| {
        for (decision_clocks, 0..) |now_ns, clock| {
            var statistics: Statistics = undefined;
            statistics.init(.{}, &starts);
            var slot = claimed_slot();
            statistics.submitted(sequence, 0, &slot, now_ns);
            if (clock == 0) {
                by_sequence[sequence] = slot.flags.sampled;
                taken += @intFromBool(slot.flags.sampled);
            } else {
                try testing.expectEqual(by_sequence[sequence], slot.flags.sampled);
            }
        }
    }
    // The default mask takes exactly one in 32, so 2 of these 64, and it takes the first.
    try testing.expectEqual(@as(u32, decision_sequences / 32), taken);
    try testing.expect(by_sequence[0] and by_sequence[32]);
    try testing.expect(!by_sequence[1] and !by_sequence[31]);
}

test "the default samples one operation in 32, and a count scales by as much" {
    var starts: [1]u64 = undefined;
    var statistics: Statistics = undefined;
    statistics.init(.{}, &starts);
    try testing.expectEqual(@as(u64, 32), statistics.scale());
    statistics.init(.{ .sample_mask = 0 }, &starts);
    try testing.expectEqual(@as(u64, 1), statistics.scale());
}
