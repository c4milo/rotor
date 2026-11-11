//! `Statistics`: what a loop counts about itself (decision 9). Latencies are sampled, never
//! unconditional: an operation is sampled when `operation_sequence & sample_mask == sample_phase`,
//! which is one AND and one compare on a value `submit` already holds. The decision is a function
//! of what the caller submitted and of nothing else, so the same calls give the same samples, on
//! any host and at any speed.
//!
//! The loop writes here and never reads: no control flow anywhere depends on a statistic
//! (rule 1). The caller reads, and scales a count by `scale()` for an estimate of the whole.
//!
//! Stalls are exact, by decision 9, rule 7: `stall.zig` counts each turn of the loop at or above a
//! threshold, with one compare in each tick (decision 28). No control flow reads them either.
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

const SchedulingGroup = @import("core.zig").SchedulingGroup;
const Tag = operation_module.Operation.Tag;
const Slot = slot_module.Slot;

pub const kinds = @typeInfo(Tag).@"enum".fields.len;
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
    /// The turns at or above `Options.stall_turn_ns`: exact, and not sampled (decision 9, rule 7).
    stalls: u64,
    /// The longest stall, in nanoseconds, or 0 while `stalls` is 0.
    stall_ns_max: u64,
    /// The last stall. All zero while `stalls` is 0.
    last_stall: Stall,

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
            .stalls = 0,
            .stall_ns_max = 0,
            .last_stall = .none,
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
        statistics.sampled[@intFromEnum(slot.tag)] += 1;
        statistics.starts[index] = now_ns;
    }

    /// The final event of the sampled operation in the slot at `index` is being handed over.
    pub fn finished(statistics: *Statistics, index: u32, slot: *const Slot, now_ns: u64) void {
        assert_class_a(slot.flags.sampled);
        if (slot.flags.multishot) return;
        const start_ns = statistics.starts[index];
        assert_class_a(now_ns >= start_ns);
        statistics.latency[@intFromEnum(slot.tag)][bucket_of(now_ns - start_ns)] += 1;
    }
};

/// One stall: a turn of the loop at or above its threshold (decision 28). A turn runs from one
/// clock stamp of a tick to the next tick's first stamp, and holds no kernel wait. Size 32 B,
/// alignment 8.
pub const Stall = struct {
    /// The stamp that ended the turn.
    end_ns: u64,
    span_ns: u64,
    /// The callbacks that the loop called in the turn: records, pollers and tasks.
    callbacks: u32,
    /// The callback's name when `callbacks` is 1, and null otherwise. It is static data
    /// (`Completion.Call`), so it stays valid after a library frees its record.
    name: ?[*:0]const u8,
    /// The task's scheduling group when `callbacks` is 1 and that callback was a task, and null
    /// otherwise (decision 30). It fills padding, so `Stall` stays 32 B.
    group: ?SchedulingGroup,

    pub const none: Stall = .{ .end_ns = 0, .span_ns = 0, .callbacks = 0, .name = null, .group = null };
};

comptime {
    assert(@sizeOf(Stall) == 32);
    assert(@alignOf(Stall) == 8);
}

/// The latency bucket of `latency_ns`: the position of its highest set bit, capped at the last.
pub fn bucket_of(latency_ns: u64) u32 {
    if (latency_ns == 0) return 0;
    return @min(std.math.log2_int(u64, latency_ns), buckets - 1);
}
