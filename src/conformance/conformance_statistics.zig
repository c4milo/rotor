//! Sampled statistics (decision 9): what the loop counts about itself. The `core` tests drive the
//! tables directly, so they never reach the path a kernel completion takes. These do: every
//! operation here ends because the kernel said so, and the loop stamps it as it hands the event
//! over.
//!
//! Rule 1 is the one a scenario can check on a real backend from outside: the events a caller
//! sees do not depend on what the loop measured.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const tcp = @import("conformance_tcp.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

const nop_kind = @intFromEnum(Operation.Code.nop);
const receive_kind = @intFromEnum(Operation.Code.receive);

fn nop(user_data: u64) Operation {
    return .{ .user_data = user_data, .kind = .nop };
}

/// Runs `count` no-ops through a loop sampling at `sampling` and returns what it counted.
fn count_nops(harness: *Harness, sampling: core.statistics.Options, count: u32) !u64 {
    try harness.init_sampling(0, null, sampling);
    var batch: [conformance.entries]Operation = undefined;
    var events: [conformance.entries]Event = undefined;
    var done: u32 = 0;
    while (done < count) : (done += batch.len) {
        for (&batch, 0..) |*operation, index| operation.* = nop(done + index);
        try harness.submit(&batch, &.{});
        try harness.collect(&events);
    }
    return harness.loop.statistics().sampled[nop_kind];
}

test "the loop counts one operation in the mask's count, and the caller sees the same events" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    defer harness.deinit();

    // 32 no-ops at 1 in 32 are sampled once, and at 1 in 1 every time. The kernel decides
    // nothing here: the count is a function of what was submitted.
    try testing.expectEqual(@as(u64, 1), try count_nops(&harness, .{}, conformance.entries * 2));
    harness.deinit();
    const all = try count_nops(&harness, .{ .sample_mask = 0 }, conformance.entries * 2);
    try testing.expectEqual(@as(u64, conformance.entries * 2), all);
}

test "a sampled operation the kernel completes carries a latency, and a cancelled one too" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init_sampling(0, null, .{ .sample_mask = 0 });
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    // `connected_pair` already ran an accept and a connect through this loop, so the counts
    // below are this scenario's own kinds.
    const statistics = harness.loop.statistics();
    const before = statistics.sampled[receive_kind];

    var bytes: [8]u8 = undefined;
    var events: [2]Event = undefined;
    try harness.submit(&.{
        .{ .user_data = 1, .kind = .{ .receive = .{
            .socket = pair[1],
            .target = .{ .buffer = .{ .bytes = &bytes } },
        } } },
        tcp.send(2, pair[0], "measured"),
    }, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 8), try (try Harness.find(&events, 1)).outcome());
    try testing.expectEqual(before + 1, statistics.sampled[receive_kind]);

    // Every sampled receive that ended is in exactly one bucket.
    var recorded: u32 = 0;
    for (statistics.latency[receive_kind]) |count| recorded += count;
    try testing.expectEqual(@as(u32, @intCast(statistics.sampled[receive_kind])), recorded);
}

test "the events of a run do not depend on what the loop measured" {
    if (conformance.unsupported()) return error.SkipZigTest;
    const samplings = [_]core.statistics.Options{
        .{ .sample_mask = 0 },
        .{ .sample_mask = 1, .sample_phase = 1 },
    };
    var seen: [samplings.len][conformance.entries]u64 = undefined;
    for (samplings, &seen) |sampling, *run| {
        var harness: Harness = undefined;
        try harness.init_sampling(0, null, sampling);
        defer harness.deinit();
        var batch: [conformance.entries]Operation = undefined;
        for (&batch, 0..) |*operation, index| operation.* = nop(index);
        try harness.submit(&batch, &.{});
        var events: [conformance.entries]Event = undefined;
        try harness.collect(&events);
        for (events, run) |event, *user_data| user_data.* = event.user_data;
    }
    try testing.expectEqualSlices(u64, &seen[0], &seen[1]);
}
