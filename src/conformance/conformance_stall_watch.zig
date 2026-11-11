//! The scenarios of the heartbeat of decision 28, on every backend: a watch on another thread names
//! the callback that holds the loop, and reports nothing while the loop waits in the kernel. Split
//! from `conformance_stall.zig`, which holds the fixture and the threshold they share.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const stall = @import("conformance_stall.zig");

const Event = core.Event;
const Fixture = stall.Fixture;
const ReactorFixture = stall.ReactorFixture;
const clock_ns = backend.testing.monotonic_ns;
const ns_per_ms = core.constants.ns_per_ms;
const stall_turn_ns = stall.stall_turn_ns;

/// The period of the watch, and the most checks it makes before it gives up.
const watch_period_ns = 10 * ns_per_ms;
const watch_checks_max = 500;
/// The most a record that spins holds the loop when no watch releases it: past the watch's checks.
const spin_ns_max = 10 * core.constants.ns_per_s;

/// A record that holds the loop until another thread sets `release`.
const Spinning = struct {
    completion: core.Completion = .init(Spinning, "completion", completed),
    release: std.atomic.Value(bool) = .init(false),
    released: bool = false,

    fn completed(spinning: *Spinning, event: Event) void {
        _ = event;
        const started_ns = clock_ns();
        while (clock_ns() - started_ns < spin_ns_max) {
            if (spinning.release.load(.acquire)) {
                spinning.released = true;
                return;
            }
            std.atomic.spinLoopHint();
        }
    }
};

/// What the watch thread saw, and the record it releases.
const Watcher = struct {
    heartbeat: *core.HeartbeatView,
    spinning: *Spinning,
    name: ?[*:0]const u8 = null,
    checks: u32 = 0,

    /// Checks once in each period until a check names a callback, then releases the record.
    fn run(watcher: *Watcher) void {
        var watch = watcher.heartbeat.watch();
        defer watch.end();
        for (0..watch_checks_max) |_| {
            pause(watch_period_ns);
            const stuck = watch.check() orelse continue;
            watcher.checks = stuck.checks;
            watcher.name = stuck.name orelse continue;
            break;
        }
        watcher.spinning.release.store(true, .release);
    }
};

/// Gives the processor away until `span_ns` passed, as a program's watch thread sleeps one period.
fn pause(span_ns: u64) void {
    const started_ns = clock_ns();
    for (0..pause_rounds_max) |_| {
        if (clock_ns() - started_ns >= span_ns) return;
        std.Thread.yield() catch {};
    }
}

/// The most yields of one `pause`.
const pause_rounds_max = 1_000_000;

test "a watch on another thread names the callback that holds the loop" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var fixture: ReactorFixture = undefined;
    try fixture.init(stall_turn_ns);
    defer fixture.reactor.deinit();
    var spinning: Spinning = .{};
    var watcher: Watcher = .{ .heartbeat = fixture.reactor.heartbeat(), .spinning = &spinning };
    const thread = try std.Thread.spawn(.{}, Watcher.run, .{&watcher});
    const timer = core.Operation.timer(0, 0, 0).completion(&spinning.completion);
    try testing.expectEqual(@as(u32, 1), fixture.reactor.submit(&.{timer}, &.{}));
    var events: [4]Event = undefined;
    var round: u32 = 0;
    while (!spinning.released and round < conformance.collect_rounds_max) : (round += 1) {
        _ = try fixture.reactor.tick(&events, ns_per_ms);
    }
    thread.join();
    try testing.expect(spinning.released);
    const expected = @typeName(Spinning) ++ ".completion";
    try testing.expectEqualStrings(expected, std.mem.span(watcher.name.?));
    try testing.expect(watcher.checks >= 1);
    // The turn the record held is a stall of that record.
    _ = try fixture.reactor.tick(&events, 0);
    try testing.expectEqual(@as(u32, 1), fixture.reactor.statistics().last_stall.callbacks);
}

/// A watch that checks while its loop waits in the kernel, and keeps each report: the turn it named
/// and the clock before the check that named it.
const Sleeper = struct {
    heartbeat: *core.HeartbeatView,
    done: std.atomic.Value(bool) = .init(false),
    reports: [watch_checks_max]Report = undefined,
    reports_len: u32 = 0,

    const Report = struct { since_ns: u64, checked_ns: u64 };

    fn run(sleeper: *Sleeper) void {
        var watch = sleeper.heartbeat.watch();
        defer watch.end();
        for (0..watch_checks_max) |_| {
            if (sleeper.done.load(.acquire)) return;
            pause(watch_period_ns);
            const checked_ns = clock_ns();
            const stuck = watch.check() orelse continue;
            const report: Report = .{ .since_ns = stuck.since_ns, .checked_ns = checked_ns };
            sleeper.reports[sleeper.reports_len] = report;
            sleeper.reports_len += 1;
        }
    }
};

/// The wait of a tick that a watch checks: many periods of the watch.
const watched_wait_ns = 200 * ns_per_ms;

test "a watch reports nothing while the loop waits in the kernel" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init(stall_turn_ns);
    defer fixture.loop.deinit();
    var sleeper: Sleeper = .{ .heartbeat = fixture.loop.heartbeat() };
    const thread = try std.Thread.spawn(.{}, Sleeper.run, .{&sleeper});
    var events: [4]Event = undefined;
    const waited = fixture.loop.tick(&events, watched_wait_ns);
    sleeper.done.store(true, .release);
    thread.join();
    try testing.expectEqual(@as(u32, 0), try waited);
    // The turn after the wait starts at the stamp after the wait. The test's code holds it until
    // `done`, for as long as a busy machine makes, and a watch reports it, so the check skips it.
    // The turn before the wait ends when the loop says it sleeps. kqueue and epoll arm the wait's
    // bound after that, so that turn ends at least one wait before the stamp after the wait.
    // io_uring arms the bound from the tick's first stamp. There that turn ends half a wait before
    // the stamp, unless the thread loses its core for half a wait. A turn held through the wait is
    // reported until the stamp after the wait.
    const woken_ns = fixture.loop.now_ns();
    for (sleeper.reports[0..sleeper.reports_len]) |report| {
        if (report.since_ns == woken_ns) continue;
        try testing.expect(report.checked_ns < woken_ns - watched_wait_ns / 2);
    }
}
