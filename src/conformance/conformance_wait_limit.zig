//! The wait limit of decision 29: a poller that bounds a tick's wait at a deadline, a
//! `Message.wake` that keeps a tick from blocking and reaches no one, and a host's `wait_limit`.
//!
//! The bounds of time here are loose, against noise: a tick that should end after 5 ms must end
//! before 500 ms, where a tick that ignored the limit would wait its whole second.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Event = core.Event;
const Harness = conformance.Harness;
const Operation = core.Operation;
const Remote = backend.Remote;
const WaitLimit = core.WaitLimit;
const now_ns = backend.testing.monotonic_ns;

const ms = core.constants.ns_per_ms;
/// The wait each tick asks for, which the limit or the wake must cut short.
const long_wait_ns = core.constants.ns_per_s;
/// The most a tick that the limit or the wake cut short may take.
const short_ns = 500 * ms;
/// The ticks a scenario may take before it calls the loop stuck.
const ticks_max = 64;

/// The loop's id, a remote's id, and a second loop's id.
const loop_id: core.LoopId = 0;
const remote_id: core.LoopId = 1;
const peer_id: core.LoopId = 2;
const ids: u16 = 3;
var registry_memory: [backend.Registry.memory_bytes(ids)]u8 align(core.layout.memory_alignment) =
    undefined;

/// A library's poller that answers a deadline until the loop's clock reaches it.
const Deadline = struct {
    poller: core.Poller = .init(Deadline, "poller", polled),
    loop: *backend.Loop,
    at_ns: u64,
    due: bool = false,

    fn polled(deadline: *Deadline) WaitLimit {
        if (deadline.loop.now_ns() >= deadline.at_ns) {
            deadline.due = true;
            return .none;
        }
        return .at(deadline.at_ns);
    }
};

test "a poller's limit ends a tick's wait, and a later poll sees its deadline due" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var events: [4]Event = undefined;
    _ = try harness.tick(&events, 0);
    var deadline: Deadline = .{ .loop = &harness.loop, .at_ns = harness.loop.now_ns() + 5 * ms };
    try harness.loop.add_poller(&deadline.poller);
    defer harness.loop.remove_poller(&deadline.poller);
    // A tick may wake a little before the deadline, and then waits again for what is left.
    const started_ns = now_ns();
    var ticks: u32 = 0;
    while (harness.loop.now_ns() < deadline.at_ns and ticks < ticks_max) : (ticks += 1) {
        try testing.expectEqual(@as(u32, 0), try harness.tick(&events, long_wait_ns));
    }
    try testing.expect(now_ns() - started_ns < short_ns);
    try testing.expect(!deadline.due);
    // The next tick's poll sees the deadline due.
    try testing.expectEqual(@as(u32, 0), try harness.tick(&events, 0));
    try testing.expect(deadline.due);
}

/// A library that another thread wakes: a flag the other thread stores, and a poller that reads it.
const Woken = struct {
    poller: core.Poller = .init(Woken, "poller", polled),
    flag: std.atomic.Value(bool) = .init(false),
    seen: bool = false,

    fn polled(woken: *Woken) WaitLimit {
        if (woken.flag.load(.acquire)) woken.seen = true;
        return .none;
    }

    /// What the other thread does: the flag first, then the wake.
    fn wake(woken: *Woken, remote: *Remote, count: u32) !void {
        woken.flag.store(true, .release);
        for (0..count) |_| try remote.post(loop_id, core.Message.wake);
    }
};

test "a wake posted before a tick keeps it from blocking, and hands no event over" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, ids);
    defer life.end();
    var harness: Harness = undefined;
    try harness.init(loop_id, &registry);
    defer harness.deinit();
    var remote: Remote = undefined;
    try remote.init(&registry, remote_id);
    defer remote.deinit();
    var woken: Woken = .{};
    try harness.loop.add_poller(&woken.poller);
    defer harness.loop.remove_poller(&woken.poller);

    try woken.wake(&remote, 1);
    var events: [4]Event = undefined;
    const started_ns = now_ns();
    // The poller answers `.none`, so only the wake the drain took keeps the tick from blocking.
    try testing.expectEqual(@as(u32, 0), try harness.tick(&events, long_wait_ns));
    try testing.expect(now_ns() - started_ns < short_ns);
    try testing.expect(woken.seen);
    try testing.expectEqual(WaitLimit.now, harness.loop.wait_limit());
}

/// The other thread of the sleep scenario: it waits until the loop says it sleeps, then wakes it
/// three times.
const Waker = struct {
    registry: *backend.Registry,
    woken: *Woken,
    failure: ?anyerror = null,

    fn run(waker: *Waker) void {
        waker.wake() catch |err| {
            waker.failure = err;
        };
    }

    fn wake(waker: *Waker) !void {
        var remote: Remote = undefined;
        try remote.init(waker.registry, remote_id);
        defer remote.deinit();
        var attempt: u32 = 0;
        while (!waker.registry.must_wake(loop_id)) : (attempt += 1) {
            if (attempt == sleep_attempts_max) return error.LoopNeverSlept;
            std.Thread.yield() catch {};
        }
        try waker.woken.wake(&remote, 3);
    }
};

/// Yields the waker makes before the loop says it sleeps, at most.
const sleep_attempts_max: u32 = 10_000_000;

test "wakes from another thread end a loop's sleep, reach no one, and the poller sees the flag" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, ids);
    defer life.end();
    var harness: Harness = undefined;
    try harness.init(loop_id, &registry);
    defer harness.deinit();
    var woken: Woken = .{};
    try harness.loop.add_poller(&woken.poller);
    defer harness.loop.remove_poller(&woken.poller);

    var waker: Waker = .{ .registry = &registry, .woken = &woken };
    const thread = try std.Thread.spawn(.{}, Waker.run, .{&waker});
    var events: [4]Event = undefined;
    var ticks: u32 = 0;
    while (!woken.seen and ticks < ticks_max) : (ticks += 1) {
        try testing.expectEqual(@as(u32, 0), try harness.tick(&events, long_wait_ns));
    }
    thread.join();
    try testing.expect(waker.failure == null);
    try testing.expect(woken.seen);
    // The three wakes are gone, and none reached the program.
    try testing.expectEqual(@as(u32, 0), try harness.tick(&events, 0));
    try testing.expectEqual(@as(u32, 0), try harness.tick(&events, 0));
}

test "a post operation that sends a wake hands no event to the loop it reaches" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, ids);
    defer life.end();
    var harness: Harness = undefined;
    try harness.init(loop_id, &registry);
    defer harness.deinit();
    var peer: Harness = undefined;
    try peer.init(peer_id, &registry);
    defer peer.deinit();

    try peer.submit(&.{Operation.post(7, loop_id, core.Message.wake)}, &.{});
    var sent: [1]Event = undefined;
    try peer.collect(&sent);
    try testing.expectEqual(@as(u32, 0), try sent[0].outcome());
    var events: [4]Event = undefined;
    for (0..3) |_| try testing.expectEqual(@as(u32, 0), try harness.tick(&events, ms));
}

test "a wake to a loop with no poller hands no event over, and the next tick blocks" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, ids);
    defer life.end();
    var harness: Harness = undefined;
    try harness.init(loop_id, &registry);
    defer harness.deinit();
    var remote: Remote = undefined;
    try remote.init(&registry, remote_id);
    defer remote.deinit();

    try remote.post(loop_id, core.Message.wake);
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.tick(&events, 0));
    // No poller, so the wake stored nothing, and the tick waits.
    const wait_ns = 20 * ms;
    const started_ns = now_ns();
    try testing.expectEqual(@as(u32, 0), try harness.tick(&events, wait_ns));
    try testing.expect(now_ns() - started_ns >= wait_ns / 2);
}

/// A record that counts its calls.
const Counted = struct {
    completion: core.Completion = .init(Counted, "completion", called),
    calls: u32 = 0,

    fn called(counted: *Counted, event: Event) void {
        _ = event;
        counted.calls += 1;
    }
};

test "a host reads now with a message waiting, after a record or a wake, then a timer's limit" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, ids);
    defer life.end();
    var harness: Harness = undefined;
    try harness.init(loop_id, &registry);
    defer harness.deinit();
    var remote: Remote = undefined;
    try remote.init(&registry, remote_id);
    defer remote.deinit();
    var woken: Woken = .{};
    try harness.loop.add_poller(&woken.poller);
    defer harness.loop.remove_poller(&woken.poller);
    const loop = &harness.loop;

    // A message in the loop's ring, which no tick took yet.
    var events: [4]Event = undefined;
    _ = try harness.tick(&events, 0);
    try testing.expectEqual(WaitLimit.none, loop.wait_limit());
    try remote.post(loop_id, .{ .payload = 1, .tag = 1 });
    try testing.expectEqual(WaitLimit.now, loop.wait_limit());
    try testing.expectEqual(@as(u32, 1), try harness.tick(&events, 0));
    try testing.expectEqual(WaitLimit.none, loop.wait_limit());

    // A tick that called a record.
    var counted: Counted = .{};
    try harness.submit(&.{Operation.timer(1, ms, 0).completion(&counted.completion)}, &.{});
    var ticks: u32 = 0;
    while (counted.calls == 0 and ticks < ticks_max) : (ticks += 1) _ = try harness.tick(&events, 10 * ms);
    try testing.expectEqual(@as(u32, 1), counted.calls);
    try testing.expectEqual(WaitLimit.now, loop.wait_limit());
    _ = try harness.tick(&events, 0);
    try testing.expectEqual(WaitLimit.none, loop.wait_limit());

    // A tick that took a wake.
    try remote.post(loop_id, core.Message.wake);
    _ = try harness.tick(&events, 0);
    try testing.expectEqual(WaitLimit.now, loop.wait_limit());
    _ = try harness.tick(&events, 0);
    try testing.expectEqual(WaitLimit.none, loop.wait_limit());

    // A timer armed: the limit is its deadline, ahead of the loop's clock.
    var handles: [1]core.Handle = undefined;
    try harness.submit(&.{Operation.timer(2, long_wait_ns, 0)}, &handles);
    try testing.expectEqual(WaitLimit.now, loop.wait_limit());
    _ = try harness.tick(&events, 0);
    const limit = loop.wait_limit();
    try testing.expect(limit != .now and limit != .none);
    try testing.expect(@intFromEnum(limit) > loop.now_ns());
    loop.cancel(handles[0]);
    try harness.drain(&events);
}
