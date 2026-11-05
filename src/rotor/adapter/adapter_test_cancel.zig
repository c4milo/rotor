//! The adapter's cancellation (decision 22, check 3): a cancel ends the wait a task blocks in, the
//! next cancel point returns `error.Canceled` once, and protection holds a cancel back.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const adapter_module = @import("adapter.zig");
const fixtures = @import("adapter_test.zig");
const Fixture = fixtures.Fixture;
const millisecond_ns = fixtures.millisecond_ns;

const Outcome = struct {
    first: Io.Cancelable!void,
    second: Io.Cancelable!void,
};

/// Sleeps twice, each sleep a cancel point, and reports how each ended.
fn sleep_twice(io: Io, first_ns: u64, second_ns: u64) Outcome {
    const first = io.sleep(.fromNanoseconds(@intCast(first_ns)), .awake);
    const second = io.sleep(.fromNanoseconds(@intCast(second_ns)), .awake);
    return .{ .first = first, .second = second };
}

test "a cancel ends a sleep with Canceled, and the next cancel point does not return it again" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var future = io.async(sleep_twice, .{ io, 10_000 * millisecond_ns, 2 * millisecond_ns });
    // Let the task block in its first sleep.
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    const before = Io.Clock.awake.now(io);
    const outcome = future.cancel(io);
    try testing.expectError(error.Canceled, outcome.first);
    try outcome.second;
    // The first sleep ended early and the second ran in full.
    const elapsed = Io.Clock.awake.now(io).nanoseconds - before.nanoseconds;
    try testing.expect(elapsed >= 2 * millisecond_ns);
    try testing.expect(elapsed < 1000 * millisecond_ns);
}

fn sleep_forever(io: Io) Io.Cancelable!void {
    const forever: Io.Timeout = .none;
    return forever.sleep(io);
}

test "a cancel ends a sleep with no timeout" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var future = io.async(sleep_forever, .{io});
    // The task blocks with nothing in flight, so the main context gives the loop a timer to wait on.
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    try testing.expectError(error.Canceled, future.cancel(io));
}

fn protected_sleep(io: Io) Outcome {
    const old = io.swapCancelProtection(.blocked);
    const first = io.sleep(.fromNanoseconds(2 * millisecond_ns), .awake);
    _ = io.swapCancelProtection(old);
    const second = io.checkCancel();
    return .{ .first = first, .second = second };
}

test "protection holds a cancel back until the first cancel point after it" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var future = io.async(protected_sleep, .{io});
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    const outcome = future.cancel(io);
    try outcome.first;
    try testing.expectError(error.Canceled, outcome.second);
}

fn recancel_twice(io: Io) Outcome {
    const first = io.checkCancel();
    io.recancel();
    const second = io.checkCancel();
    return .{ .first = first, .second = second };
}

test "recancel makes the next cancel point return Canceled again" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    // The task has not run when the cancel comes, so its first cancel point sees it.
    var future = io.async(recancel_twice, .{io});
    const outcome = future.cancel(io);
    try testing.expectError(error.Canceled, outcome.first);
    try testing.expectError(error.Canceled, outcome.second);
}

fn futex_canceled(io: Io, word: *u32, timed: bool) Io.Cancelable!void {
    const timeout: Io.Timeout = if (timed) .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } } else .none;
    return io.vtable.futexWait(io.userdata, word, 0, timeout);
}

test "a cancel ends a futex wait, with a timer and without one" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var word: u32 = 0;
    var untimed = io.async(futex_canceled, .{ io, &word, false });
    var timed = io.async(futex_canceled, .{ io, &word, true });
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    try testing.expectError(error.Canceled, untimed.cancel(io));
    try testing.expectError(error.Canceled, timed.cancel(io));
    try testing.expectEqual(0, fixture.loop.in_flight());
    try testing.expectEqual(adapter_module.index_none, fixture.adapter.futex_head);
}

fn member(io: Io, ended: *u32) Io.Cancelable!void {
    defer ended.* += 1;
    try io.sleep(.fromSeconds(10), .awake);
}

test "a group cancel ends every member's wait, and the group waits for them all" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var ended: u32 = 0;
    var group: Io.Group = .init;
    for (0..fixtures.fiber_count) |_| try group.concurrent(io, member, .{ io, &ended });
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    const before = Io.Clock.awake.now(io);
    group.cancel(io);
    try testing.expectEqual(fixtures.fiber_count, ended);
    // The members' sleeps were ten seconds long, and the cancel ended them.
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - before.nanoseconds < 1000 * millisecond_ns);
    try testing.expect(group.token.raw == null);
}

fn await_group(io: Io, ended: *u32) (Io.Cancelable || Io.ConcurrentError)!void {
    var group: Io.Group = .init;
    try group.concurrent(io, member, .{ io, ended });
    try group.concurrent(io, member, .{ io, ended });
    return group.await(io);
}

test "a cancel of a task that awaits a group goes on to the members" {
    if (!adapter_module.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(null);
    defer fixture.deinit();
    const io = fixture.io();
    var ended: u32 = 0;
    var future = try io.concurrent(await_group, .{ io, &ended });
    try io.sleep(.fromNanoseconds(millisecond_ns), .awake);
    const before = Io.Clock.awake.now(io);
    try testing.expectError(error.Canceled, future.cancel(io));
    try testing.expectEqual(2, ended);
    try testing.expect(Io.Clock.awake.now(io).nanoseconds - before.nanoseconds < 1000 * millisecond_ns);
}
