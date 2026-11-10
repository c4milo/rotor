//! `wait_until` of decision 33 on every backend: the program's bound on the wait of each tick. The
//! loop has no poller, because until step 3 the pollers' limit uses the same word.
//!
//! The bounds of time here are loose, against noise: a tick that should end after 5 ms must end
//! before 500 ms, where a tick that ignored the limit would wait its whole second.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const conformance = @import("conformance.zig");

const Event = core.Event;
const Harness = conformance.Harness;
const Operation = core.Operation;
const WaitLimit = core.WaitLimit;
const now_ns = @import("backend").testing.monotonic_ns;

const ms = core.constants.ns_per_ms;
/// The wait each tick asks for, which the limit must cut short.
const long_wait_ns = core.constants.ns_per_s;
/// The most a tick that the limit cut short may take.
const short_ns = 500 * ms;
/// The wait of a tick under `.none`, and the least time that such a tick may take.
const none_wait_ns = 20 * ms;
const none_least_ns = 10 * ms;
/// The ticks a scenario may take before it calls the loop stuck.
const ticks_max = 64;

/// One tick that asks for `wait_ns`, and how long it took. It must hand no event over.
fn timed_tick(harness: *Harness, wait_ns: u64) !u64 {
    var events: [4]Event = undefined;
    const started_ns = now_ns();
    try testing.expectEqual(@as(u32, 0), try harness.tick(&events, wait_ns));
    return now_ns() - started_ns;
}

test "wait_until bounds each tick that would block, until the program writes it again" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const loop = &harness.loop;
    _ = try timed_tick(&harness, 0);
    const limit_ns = loop.now_ns() + 5 * ms;
    loop.wait_until(.at(limit_ns));
    try testing.expectEqual(WaitLimit.at(limit_ns), loop.wait_limit());
    // A tick may wake a little before the limit, and then waits again for what is left.
    const started_ns = now_ns();
    var ticks: u32 = 0;
    while (loop.now_ns() < limit_ns and ticks < ticks_max) : (ticks += 1) {
        _ = try timed_tick(&harness, long_wait_ns);
    }
    try testing.expect(now_ns() - started_ns < short_ns);
    try testing.expect(loop.now_ns() >= limit_ns);
    // The limit stays: each later tick finds it passed, and does not block.
    try testing.expect(try timed_tick(&harness, long_wait_ns) < short_ns);
    try testing.expect(try timed_tick(&harness, long_wait_ns) < short_ns);
    try testing.expectEqual(WaitLimit.now, loop.wait_limit());
    // `.none` gives each tick the wait it asks for.
    loop.wait_until(.none);
    try testing.expect(try timed_tick(&harness, none_wait_ns) >= none_least_ns);
    try testing.expectEqual(WaitLimit.none, loop.wait_limit());
}

test "wait_until with now keeps every tick from blocking" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    harness.loop.wait_until(.now);
    for (0..3) |_| try testing.expect(try timed_tick(&harness, long_wait_ns) < short_ns);
    try testing.expectEqual(WaitLimit.now, harness.loop.wait_limit());
}

test "a timer before the limit ends the wait first" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const loop = &harness.loop;
    _ = try timed_tick(&harness, 0);
    loop.wait_until(.at(loop.now_ns() + long_wait_ns));
    try harness.submit(&.{Operation.timer(3, 5 * ms, 0)}, &.{});
    var events: [1]Event = undefined;
    const started_ns = now_ns();
    var produced: u32 = 0;
    var ticks: u32 = 0;
    while (produced == 0 and ticks < ticks_max) : (ticks += 1) {
        produced = try harness.tick(&events, long_wait_ns);
    }
    try testing.expect(now_ns() - started_ns < short_ns);
    try testing.expectEqual(@as(u32, 1), produced);
    try testing.expectEqual(@as(u64, 3), events[0].user_data);
}
