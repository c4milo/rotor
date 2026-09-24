//! `Statistics`: what a loop counts about itself (decision 9). Sampled, never unconditional: an
//! operation is sampled when `operation_sequence & sample_mask == sample_phase`, which is one AND
//! and one compare on a value `submit` already holds. The decision is a function of what the
//! caller submitted and of nothing else, so the same calls give the same samples, on any host
//! and at any speed.
//!
//! The loop writes here and never reads: no control flow anywhere depends on a statistic
//! (rule 1). The caller reads, and scales a count by `scale()` for an estimate of the whole.
//!
//! A latency runs from the clock the loop held when the operation was submitted to the clock it
//! held when the final event was handed over. Both are the tick's clock, so a latency has the
//! resolution of a tick and costs no clock read of its own (rule 4).
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("assertion_class.zig").assert_class_a;
const constants = @import("constants.zig");
const operation_module = @import("operation.zig");
const slot_module = @import("slot.zig");

const Code = operation_module.Operation.Code;
const Slot = slot_module.Slot;

pub const kinds = @typeInfo(Code).@"enum".fields.len;
pub const buckets = constants.latency_buckets;

pub const Options = struct {
    /// One operation in `sample_mask + 1` is sampled: a power of two, minus one.
    sample_mask: u32 = constants.sample_mask_default,
    /// Which one of them: at most `sample_mask`. A configuration value, never drawn from an
    /// entropy source (rule 2).
    sample_phase: u32 = 0,
};

pub const Statistics = struct {
    sample_mask: u64,
    sample_phase: u64,
    /// Sampled operations, by kind.
    sampled: [kinds]u64,
    /// Sampled operations that have had their final event, by kind and by latency: bucket `b`
    /// holds the latencies from 2^b nanoseconds up to 2^(b+1), the first holds 0 as well, and
    /// the last holds everything above it. A multishot operation has no latency: what it has
    /// is a lifetime.
    latency: [kinds][buckets]u32,
    /// The loop's clock when each sampled operation in flight was submitted, by slot index.
    starts: []u64,

    pub fn init(statistics: *Statistics, options: Options, starts: []u64) void {
        assert(std.math.isPowerOfTwo(@as(u64, options.sample_mask) + 1));
        assert(options.sample_phase <= options.sample_mask);
        assert(starts.len >= 1);
        statistics.* = .{
            .sample_mask = options.sample_mask,
            .sample_phase = options.sample_phase,
            .sampled = @splat(0),
            .latency = @splat(@splat(0)),
            .starts = starts,
        };
    }

    /// What a sampled count is multiplied by for an estimate of every operation.
    pub fn scale(statistics: *const Statistics) u64 {
        return statistics.sample_mask + 1;
    }

    /// `submit` accepted the operation numbered `sequence` into the slot at `index`.
    pub fn submitted(
        statistics: *Statistics,
        sequence: u64,
        index: u32,
        slot: *Slot,
        now_ns: u64,
    ) void {
        assert_class_a(!slot.flags.sampled);
        if (sequence & statistics.sample_mask != statistics.sample_phase) return;
        slot.flags.sampled = true;
        statistics.sampled[@intFromEnum(slot.code)] += 1;
        statistics.starts[index] = now_ns;
    }

    /// The final event of the sampled operation in the slot at `index` is being handed over.
    pub fn finished(statistics: *Statistics, index: u32, slot: *const Slot, now_ns: u64) void {
        assert_class_a(slot.flags.sampled);
        if (slot.flags.multishot) return;
        const start_ns = statistics.starts[index];
        assert_class_a(now_ns >= start_ns);
        statistics.latency[@intFromEnum(slot.code)][bucket_of(now_ns - start_ns)] += 1;
    }
};

/// The latency bucket of `latency_ns`: the position of its highest set bit, capped at the last.
pub fn bucket_of(latency_ns: u64) u32 {
    if (latency_ns == 0) return 0;
    return @min(std.math.log2_int(u64, latency_ns), buckets - 1);
}
