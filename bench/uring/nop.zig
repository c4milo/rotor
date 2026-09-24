//! The loop's own cost, measured with operations that do nothing in the kernel: what rows C7, C8
//! and C9 of docs/costs.md ask for, and the workload of decision 8's assertion experiment.
//!
//! For each batch size it times `samples` rounds of: submit a batch of `nop`, then tick until
//! every event is back. It prints the median and the p99 of a round, and the median per
//! operation. `(t32 - t1) / 31` is the cost of one more operation in a batch: one more entry
//! submitted and one more completion reaped, C8 plus C9 together.
//!
//! The build makes two of these: `uring_nop_safe`, in ReleaseSafe, the mode rotor ships in, and
//! `uring_nop_fast`, in ReleaseFast, which exists only here. ReleaseFast removes every assertion
//! and every bounds and overflow check, so the difference between the two is an upper bound on
//! what decision 8's class A and B assertions cost together.
//!
//! A number from a virtual machine describes the virtual machine. It may guide work; it does not
//! go in docs/costs.md (rule 1 there).
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const core = @import("core");
const uring = @import("uring");

const Loop = uring.Loop;

/// Slots and submission entries: enough for the largest batch in one tick.
const operations = 1024;
const entries = 256;
const batch_sizes = [_]u32{ 1, 8, 32, 64, 128 };
const batch_max = 128;
/// Rounds timed per batch size, after `warmup` rounds that are not.
const samples = 20_000;
const warmup = 2_000;
const p99_per_mille = 990;
const per_mille = 1000;

const options: Loop.Options = .{ .operations = operations, .entries = entries };

var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
var loop: Loop align(@alignOf(Loop)) = undefined;
var batch: [batch_max]core.Operation align(@alignOf(core.Operation)) = undefined;
var events: [batch_max]core.Event align(@alignOf(core.Event)) = undefined;
var round_ns: [samples]u64 = undefined;

fn now_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * core.constants.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// One round: a batch submitted, and ticks until every one of its events is back.
fn round(size: u32) !void {
    const taken = loop.submit(batch[0..size], &.{});
    std.debug.assert(taken == size);
    var back: u32 = 0;
    while (back < size) back += try loop.tick(events[0..size], 0);
}

pub fn main() !void {
    if (builtin.os.tag != .linux) return error.NeedsLinux;
    try loop.init(&memory, options);
    defer loop.deinit();
    for (&batch, 0..) |*operation, index| operation.* = .{ .user_data = index, .kind = .nop };

    const mode = @tagName(builtin.mode);
    std.debug.print("uring nop, {s}, {d} samples per batch size\n", .{ mode, samples });
    std.debug.print("| batch | round median ns | round p99 ns | per operation ns |\n", .{});
    std.debug.print("|---|---|---|---|\n", .{});
    for (batch_sizes) |size| {
        for (0..warmup) |_| try round(size);
        for (&round_ns) |*sample| {
            const before = now_ns();
            try round(size);
            sample.* = now_ns() - before;
        }
        std.mem.sort(u64, &round_ns, {}, std.sort.asc(u64));
        const median = round_ns[samples / 2];
        const p99 = round_ns[samples * p99_per_mille / per_mille];
        std.debug.print("| {d} | {d} | {d} | {d} |\n", .{ size, median, p99, median / size });
    }
}
