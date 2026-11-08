//! The cross-core call of decision 32 on every backend, in the scenarios that need more than one
//! thread or more than two loops: a call that wakes a target that sleeps, and an answer that wakes
//! the caller; four loops on four threads that call each other with deadlines while one stops
//! serving, which the race gate runs under ThreadSanitizer; and calls in two named groups at shares
//! 100 and 300, which run their handlers in the ratio of decision 30.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const call_scenarios = @import("conformance_call.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const LoopId = core.LoopId;
const constants = core.constants;
const Call = call_scenarios.Call;
const Client = call_scenarios.Client;
const Declared = call_scenarios.Declared;
const Echo = call_scenarios.Echo;
const EchoService = call_scenarios.EchoService;
const Tally = call_scenarios.Tally;
const View = call_scenarios.View;

/// A wait that a tick must not take to its end when a wake comes.
const long_wait_ns = 2 * constants.ns_per_s;
/// The most a woken tick may wait in all.
const woken_wait_ns_max = constants.ns_per_s / 2;
const pause_ns = constants.ns_per_ms;
const attempts_max = 2000;

/// Owns loop 1 on its own thread: serves the echo service, and sleeps in its tick until one call
/// arrives. Then it stops serving and ends.
const Sleeper = struct {
    registry: *backend.Registry,
    service: *EchoService,
    echo: Echo = .{},
    waited_ns: u64 = 0,
    failure: ?anyerror = null,

    fn run(sleeper: *Sleeper) void {
        sleeper.serve() catch |err| {
            sleeper.failure = err;
        };
    }

    fn serve(sleeper: *Sleeper) !void {
        var harness: Harness = undefined;
        try harness.init(1, sleeper.registry);
        defer harness.deinit();
        const shared = harness.loop.shared();
        // It serves before its first tick, so no call reaches a station that never served.
        sleeper.service.serve(shared, &sleeper.echo);
        defer sleeper.service.stop_serving(shared);
        var events: [4]Event = undefined;
        var rounds: u32 = 0;
        while (sleeper.echo.handled == 0 and rounds < 8) : (rounds += 1) {
            const started_ns = backend.testing.monotonic_ns();
            _ = try harness.tick(&events, long_wait_ns);
            sleeper.waited_ns = backend.testing.monotonic_ns() - started_ns;
        }
        if (sleeper.echo.handled != 1) return error.NoCallArrived;
    }
};

test "a call wakes a target that sleeps in its tick, and the answer wakes the caller" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    var registry_memory: [backend.Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, 2);
    defer life.end();
    var harness: Harness = undefined;
    try harness.init(0, &registry);
    defer harness.deinit();
    var service: EchoService = .init;
    var sleeper: Sleeper = .{ .registry = &registry, .service = &service };
    const thread = try std.Thread.spawn(.{}, Sleeper.run, .{&sleeper});
    var joined = false;
    defer if (!joined) thread.join();

    var tally: Tally = .{};
    var client: Client = .{ .service = &service, .shared = harness.loop.shared(), .target = 1, .tally = &tally };
    var sent = false;
    var attempt: u32 = 0;
    while (!sent and attempt < attempts_max) : (attempt += 1) {
        try harness.pause(pause_ns);
        if (registry.get(1) < 0 or !registry.must_wake(1)) continue;
        try harness.pause(pause_ns);
        try client.send();
        sent = true;
    }
    try testing.expect(sent);
    // This loop sleeps in a long wait too: only the answer's wake ends it early.
    var events: [4]Event = undefined;
    const started_ns = backend.testing.monotonic_ns();
    var rounds: u32 = 0;
    while (tally.replied == 0 and rounds < 8) : (rounds += 1) _ = try harness.tick(&events, long_wait_ns);
    const caller_waited_ns = backend.testing.monotonic_ns() - started_ns;
    thread.join();
    joined = true;
    try testing.expectEqual(@as(?anyerror, null), sleeper.failure);
    try testing.expectEqual(@as(u32, 1), tally.replied);
    try testing.expect(sleeper.waited_ns < woken_wait_ns_max);
    try testing.expect(caller_waited_ns < woken_wait_ns_max);
}

/// The loops of the scenario of four threads, and the records each holds.
const four = 4;
const clients_per_loop = 12;
/// The calls each loop sends in all.
const calls_per_loop = 1500;
/// The loop that stops serving. It stops after it has handled `stop_after` calls, or after it has
/// sent half its own calls. A record sends its next call to the same target, so the order of the
/// threads decides how many calls reach this loop. The second bound makes the stop happen in every
/// order.
const stopping_loop: LoopId = 3;
const stop_after = 200;
const ticks_max = 1_000_000;

/// What the four threads share.
const Four = struct {
    registry: *backend.Registry,
    service: *EchoService,
    /// The threads that reached each barrier.
    arrived: [3]std.atomic.Value(u32) = @splat(.init(0)),
    /// For each loop: true while it has no call out and no task queued, after it stopped sending.
    settled: [four]std.atomic.Value(bool) = @splat(.init(false)),
    /// True once the loop `stopping_loop` stopped serving.
    stopped: std.atomic.Value(bool) = .init(false),

    fn barrier(shared: *Four, index: usize) void {
        _ = shared.arrived[index].fetchAdd(1, .acq_rel);
        while (shared.arrived[index].load(.acquire) < four) std.Thread.yield() catch {};
    }

    fn all_settled(shared: *const Four) bool {
        for (&shared.settled) |*flag| if (!flag.load(.acquire)) return false;
        return true;
    }
};

/// One loop of the four, on its own thread.
const Member = struct {
    four: *Four,
    id: LoopId,
    echo: Echo = .{},
    tally: Tally = .{ .left = calls_per_loop },
    clients: [clients_per_loop]Client = undefined,
    /// The call that the loop sends to the loop `stopping_loop` after that loop stops serving.
    late: Client = undefined,
    late_tally: Tally = .{},
    random: core.random.Random = .init(0),
    serving: bool = false,
    failure: ?anyerror = null,

    fn run(member: *Member) void {
        member.serve() catch |err| {
            member.failure = err;
        };
    }

    fn serve(member: *Member) !void {
        var harness: Harness = undefined;
        try harness.init(member.id, member.four.registry);
        defer harness.deinit();
        const shared = harness.loop.shared();
        const service = member.four.service;
        service.serve(shared, &member.echo);
        member.serving = true;
        defer if (member.serving) service.stop_serving(shared);
        member.random = .init(member.id + 1);
        for (&member.clients) |*client| {
            client.* = .{ .service = service, .shared = shared, .target = 0, .tally = &member.tally };
        }
        // Every loop serves before any call is sent.
        member.four.barrier(0);
        var events: [16]Event = undefined;
        var ticks: u32 = 0;
        while (member.tally.left != 0 and ticks < ticks_max) : (ticks += 1) {
            member.send_idle(shared);
            _ = try harness.tick(&events, 0);
            member.stop_when_due(shared);
        }
        member.tally.left = 0;
        // Settle: each loop ticks until every loop sent its late call, and no loop has a call out
        // or a task queued.
        while (!member.four.all_settled() and ticks < ticks_max) : (ticks += 1) {
            _ = try harness.tick(&events, 0);
            member.stop_when_due(shared);
            try member.send_late(shared);
            const out = calls_out(&member.tally) + calls_out(&member.late_tally);
            const settled = member.late_tally.accepted == 1 and out == 0 and harness.loop.tasks_queued() == 0;
            member.four.settled[member.id].store(settled, .release);
        }
        member.four.barrier(1);
        if (!member.four.all_settled()) return error.CallsNotSettled;
    }

    /// The loop `stopping_loop` stops serving once it handled `stop_after` calls, or once it sent
    /// half its own calls.
    fn stop_when_due(member: *Member, shared: *View) void {
        if (!member.serving or member.id != stopping_loop) return;
        if (member.echo.handled < stop_after and member.tally.left > calls_per_loop / 2) return;
        member.four.service.stop_serving(shared);
        member.serving = false;
        member.four.stopped.store(true, .release);
    }

    /// Sends one call to the loop `stopping_loop` after that loop stopped serving. The call must
    /// end `target_stopped`: the loop `stopping_loop` takes it through no ring, and every other
    /// loop through its ring. A full ring refuses the send, and the next tick sends it again.
    fn send_late(member: *Member, shared: *View) !void {
        if (member.late_tally.accepted != 0 or !member.four.stopped.load(.acquire)) return;
        member.late = .{ .service = member.four.service, .shared = shared, .target = stopping_loop, .tally = &member.late_tally };
        member.late.send() catch |err| switch (err) {
            error.MailboxFull => return,
            else => return err,
        };
    }

    fn calls_out(tally: *const Tally) u32 {
        return tally.accepted - tally.replied - tally.expired - tally.stopped;
    }

    /// Sends a call from each idle record to a random loop, with a deadline now and then.
    fn send_idle(member: *Member, shared: *View) void {
        for (&member.clients) |*client| {
            if (client.call.is_out() or member.tally.left == 0) continue;
            client.target = @intCast(member.random.below(four));
            const deadline_ns = if (member.random.chance(1, 8)) shared.now_ns() + member.random.below(50_000) else 0;
            client.request = member.tally.accepted * 1000 + 7;
            member.four.service.send(shared, client.target, &client.call, &client.request, .{
                .group = .default,
                .deadline_ns = deadline_ns,
            }) catch continue;
            member.tally.accepted += 1;
            member.tally.left -= 1;
        }
    }
};

test "four loops on four threads call each other with deadlines while one stops serving" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    var registry_memory: [backend.Registry.memory_bytes(four)]u8 align(core.layout.memory_alignment) = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, four);
    defer life.end();
    var service: EchoService = .init;
    var shared: Four = .{ .registry = &registry, .service = &service };
    var members: [four]Member = undefined;
    var threads: [four]std.Thread = undefined;
    for (&members, &threads, 0..) |*member, *thread, id| {
        member.* = .{ .four = &shared, .id = @intCast(id) };
        thread.* = try std.Thread.spawn(.{}, Member.run, .{member});
    }
    for (&threads) |*thread| thread.join();
    for (&members) |*member| try testing.expectEqual(@as(?anyerror, null), member.failure);
    try testing.expect(!members[stopping_loop].serving);
    for (&members) |*member| {
        // Each loop's late call reached a station that had stopped. How many of the other calls
        // got `target_stopped` depends on the order of the threads, so the test does not count them.
        try testing.expectEqual(@as(u32, 1), member.late_tally.accepted);
        try testing.expectEqual(@as(u32, 1), member.late_tally.stopped);
        try testing.expect(!member.late.call.is_out());
        const tally = member.tally;
        // Each accepted call ended once: replied, expired or stopped.
        try testing.expectEqual(tally.accepted, tally.replied + tally.expired + tally.stopped);
        try testing.expectEqual(@as(u32, 0), tally.wrong);
        try testing.expectEqual(@as(u32, calls_per_loop), tally.accepted);
        for (&member.clients) |*client| try testing.expect(!client.call.is_out());
    }
}

/// The callers of the scenario at shares 100 and 300, and the calls each keeps out.
const callers = 4;
const warm_ticks = 8;
const measured_ticks = 32;

test "calls in two named groups at shares 100 and 300 run their handlers 1 to 3" {
    if (conformance.unsupported()) return error.SkipZigTest;
    const loops = callers + 1;
    var registry: backend.Registry = undefined;
    var registry_memory: [backend.Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, loops);
    defer life.end();
    var harnesses: [loops]Harness = undefined;
    var pointers: [loops]*Harness = undefined;
    var started: usize = 0;
    defer for (harnesses[0..started]) |*harness| harness.deinit();
    for (&harnesses, &pointers, 0..) |*harness, *pointer, id| {
        try call_scenarios.init_loop(harness, @intCast(id), &registry, &Declared.table);
        started += 1;
        pointer.* = harness;
    }
    // Loop 0 serves, and loops 1 to 4 call it: two in `low` and two in `high`.
    var service: EchoService = .init;
    var echo: Echo = .{};
    service.serve(harnesses[0].loop.shared(), &echo);
    defer service.stop_serving(harnesses[0].loop.shared());
    var tally: Tally = .{ .left = std.math.maxInt(u32) };
    var clients: [callers][constants.calls_per_pair_max]Client = undefined;
    for (&clients, 1..) |*row, id| {
        const group = if (id <= callers / 2) Declared.group(.low) else Declared.group(.high);
        for (row) |*client| {
            client.* = .{ .service = &service, .shared = harnesses[id].loop.shared(), .target = 0, .group = group, .tally = &tally };
            try client.send();
        }
    }
    for (0..warm_ticks) |_| _ = try call_scenarios.tick_all(&pointers);
    const low_before = echo.by_group[1];
    const high_before = echo.by_group[2];
    for (0..measured_ticks) |_| _ = try call_scenarios.tick_all(&pointers);
    const low = echo.by_group[1] - low_before;
    const high = echo.by_group[2] - high_before;
    // G3: each group's units differ from its share by less than a charge of the largest cost.
    // Every task costs 1 here, so the handlers run 1 to 3.
    const expected_high = 3 * low;
    const gap = if (high > expected_high) high - expected_high else expected_high - high;
    try testing.expect(low >= measured_ticks);
    try testing.expect(gap < constants.task_charge_max);
    // Every call that is out ends: the callers stop sending and the loops tick until the last
    // `finish` ran.
    tally.left = 0;
    var ticks: u32 = 0;
    while (tally.replied < tally.accepted and ticks < call_scenarios.ticks_max) : (ticks += 1) {
        _ = try call_scenarios.tick_all(&pointers);
    }
    try testing.expectEqual(tally.accepted, tally.replied);
    try testing.expectEqual(@as(u32, 0), tally.wrong);
}
