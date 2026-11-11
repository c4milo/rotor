//! The cross-core call of decision 32 on every backend, with every loop on the test's thread:
//! 10,000 calls with checked replies, the 33rd call to one target, the posts that fill their share
//! of a ring while 32 calls are out, a `.later` answer after a timer, a past deadline, a call to
//! self, an id that a second loop claims and serves, and an id that a loop claims and does not
//! serve. `conformance_call_threads.zig` holds the scenarios
//! with threads, and the calls in two named groups.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const ReactorHarness = conformance.ReactorHarness;
const Event = core.Event;
const Operation = core.Operation;
const LoopId = core.LoopId;
const constants = core.constants;

/// The reactor as a library holds it, which a service takes.
pub const View = conformance.Reactor.SharedLoop;
/// The record of one call of the echo service.
pub const Call = core.call.CallRecord(View, u64, u64);
pub const EchoService = core.call.Service(View, Echo, u64, u64, Echo.handle);
pub const NamedSchedulingGroup = core.NamedSchedulingGroup;

/// The named groups of the scenario at shares 100 and 300 (decision 30, "How tests name groups").
pub const Declared = core.scheduling.Named(.{ .low = 100, .high = 300 });

/// Ticks a scenario may take: each one waits 0, so they are short.
pub const ticks_max = 100_000;

pub const Mode = enum { now, later };

/// The context of the echo service: it answers with the request plus one.
pub const Echo = struct {
    mode: Mode = .now,
    handled: u32 = 0,
    /// The handler runs of each group id: `.default`, `low` and `high`.
    by_group: [3]u32 = @splat(0),
    held: [2 * constants.calls_per_pair_max]*Call = undefined,
    held_len: u32 = 0,

    fn handle(echo: *Echo, call: *Call) core.call.Answer(u64) {
        echo.handled += 1;
        echo.by_group[@intFromEnum(call.link.group)] += 1;
        if (echo.mode == .later) {
            echo.held[echo.held_len] = call;
            echo.held_len += 1;
            return .later;
        }
        return .{ .now = call.request_of().* + 1 };
    }

    /// Answers every call held `.later`, each with its request plus one.
    pub fn answer_all(echo: *Echo, shared: *View) void {
        for (echo.held[0..echo.held_len]) |call| call.answer(shared, &(call.request_of().* + 1));
        echo.held_len = 0;
    }
};

/// What the clients of one scenario share: the calls left to send, and what came back.
pub const Tally = struct {
    left: u32 = 0,
    accepted: u32 = 0,
    replied: u32 = 0,
    expired: u32 = 0,
    stopped: u32 = 0,
    wrong: u32 = 0,
};

/// One caller's record. Its `finish` checks the reply, and sends again while the tally has calls
/// left.
pub const Client = struct {
    call: Call = .init(Client, "call", finished),
    service: *EchoService,
    shared: *View,
    target: LoopId,
    group: NamedSchedulingGroup = .default,
    tally: *Tally,
    request: u64 = 0,

    fn finished(client: *Client, result: core.call.CallResult(u64)) void {
        switch (result) {
            .replied => |reply| {
                client.tally.replied += 1;
                if (reply.* != client.request + 1) client.tally.wrong += 1;
            },
            .expired => client.tally.expired += 1,
            .target_stopped => client.tally.stopped += 1,
        }
        if (client.tally.left != 0) client.send() catch {};
    }

    /// Sends one call, with a request that no other call of the scenario carries.
    pub fn send(client: *Client) core.call.CallError!void {
        client.request = client.tally.accepted * 1000 + 7;
        try client.service.send(client.shared, client.target, &client.call, &client.request, .{ .group = client.group });
        client.tally.accepted += 1;
        client.tally.left -|= 1;
    }
};

/// A reactor on `registry` whose loop reserves the named groups of `table` at `init` (decision 30).
pub fn init_reactor(harness: *ReactorHarness, id: LoopId, registry: ?*backend.Registry, table: *const core.scheduling.NamedTable) !void {
    try harness.reactor.init(&harness.memory, &.{ .loop = .{
        .operations = conformance.operations,
        .entries = conformance.entries,
        .id = id,
        .registry = registry,
        .spin_budget_ns = conformance.spin_budget_ns(),
        .named_groups = table.*,
    } });
}

/// Ticks each loop of `harnesses` once with no wait, and returns the events they handed over.
pub fn tick_all(harnesses: []const *ReactorHarness) !u32 {
    var events: [64]Event = undefined;
    var count: u32 = 0;
    for (harnesses) |harness| count += try harness.tick(&events, 0);
    return count;
}

/// Two loops, 0 and 1, on one registry, each serving the echo service.
const Two = struct {
    registry: backend.Registry,
    memory: [backend.Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment),
    harnesses: [2]ReactorHarness,
    service: EchoService,
    echoes: [2]Echo,

    fn start(two: *Two, table: *const core.scheduling.NamedTable) !conformance.RegistryLife {
        const life = try conformance.RegistryLife.start(&two.registry, &two.memory, 2);
        two.service = .init;
        for (&two.harnesses, &two.echoes, 0..) |*harness, *echo, id| {
            try init_reactor(harness, @intCast(id), &two.registry, table);
            echo.* = .{};
            two.service.serve(harness.reactor.shared(), echo);
        }
        return life;
    }

    fn shared(two: *Two, id: LoopId) *View {
        return two.harnesses[id].reactor.shared();
    }

    fn tick(two: *Two) !u32 {
        return tick_all(&.{ &two.harnesses[0], &two.harnesses[1] });
    }

    fn end(two: *Two) void {
        for (&two.harnesses) |*harness| {
            two.service.stop_serving(harness.reactor.shared());
            harness.deinit();
        }
    }
};

fn client_of(two: *Two, tally: *Tally, target: LoopId) Client {
    return .{ .service = &two.service, .shared = two.shared(0), .target = target, .tally = tally };
}

test "10,000 calls between two loops each come back once, with the request plus one" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var two: Two = undefined;
    const life = try two.start(&.empty);
    defer life.end();
    defer two.end();
    const total = 10_000;
    var tally: Tally = .{ .left = total };
    var clients: [constants.calls_per_pair_max]Client = undefined;
    for (&clients) |*client| {
        client.* = client_of(&two, &tally, 1);
        try client.send();
    }
    var ticks: u32 = 0;
    while (tally.replied < total and ticks < ticks_max) : (ticks += 1) _ = try two.tick();
    try testing.expectEqual(@as(u32, total), tally.accepted);
    try testing.expectEqual(@as(u32, total), tally.replied);
    try testing.expectEqual(@as(u32, 0), tally.wrong);
    try testing.expectEqual(@as(u32, total), two.echoes[1].handled);
}

test "the 33rd call to one target is refused with CallsFull, and nothing is sent" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var two: Two = undefined;
    const life = try two.start(&.empty);
    defer life.end();
    defer two.end();
    var tally: Tally = .{};
    var clients: [constants.calls_per_pair_max + 1]Client = undefined;
    for (&clients) |*client| client.* = client_of(&two, &tally, 1);
    for (clients[0..constants.calls_per_pair_max]) |*client| try client.send();
    const extra = &clients[constants.calls_per_pair_max];
    try testing.expectError(error.CallsFull, extra.send());
    try testing.expect(!extra.call.is_out());
    var ticks: u32 = 0;
    while (tally.replied < constants.calls_per_pair_max and ticks < ticks_max) : (ticks += 1) _ = try two.tick();
    try testing.expectEqual(@as(u32, constants.calls_per_pair_max), tally.replied);
    // The finish of each call lowered the count, so the record goes out now.
    try extra.send();
    while (tally.replied < constants.calls_per_pair_max + 1 and ticks < ticks_max) : (ticks += 1) _ = try two.tick();
    try testing.expectEqual(@as(u32, constants.calls_per_pair_max + 1), tally.replied);
}

test "a ring that holds 224 posts still takes the returns of 32 calls" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var two: Two = undefined;
    const life = try two.start(&.empty);
    defer life.end();
    defer two.end();
    var tally: Tally = .{};
    var clients: [constants.calls_per_pair_max]Client = undefined;
    for (&clients) |*client| {
        client.* = client_of(&two, &tally, 1);
        try client.send();
    }
    // The target fills its ring to the caller with posts, and the next post is refused.
    const target = &two.harnesses[1].reactor;
    for (0..constants.mailbox_posts_max) |payload| try target.post(0, .{ .payload = payload, .tag = 5 });
    try testing.expectError(error.MailboxFull, target.post(0, .{ .payload = 0, .tag = 5 }));
    var events: [64]Event = undefined;
    var ticks: u32 = 0;
    while (two.echoes[1].handled < constants.calls_per_pair_max and ticks < ticks_max) : (ticks += 1) {
        _ = try two.harnesses[1].tick(&events, 0);
    }
    // Every return found a slot: the caller gets the 224 posts as events and 32 finishes.
    var messages: u32 = 0;
    while ((messages < constants.mailbox_posts_max or tally.replied < constants.calls_per_pair_max) and
        ticks < ticks_max) : (ticks += 1)
    {
        messages += try two.harnesses[0].tick(&events, 0);
    }
    try testing.expectEqual(constants.mailbox_posts_max, messages);
    try testing.expectEqual(@as(u32, constants.calls_per_pair_max), tally.replied);
    try testing.expectEqual(@as(u32, 0), tally.wrong);
}

test "a handler that answers later, after a timer, returns the reply once" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var two: Two = undefined;
    const life = try two.start(&.empty);
    defer life.end();
    defer two.end();
    two.echoes[1].mode = .later;
    var tally: Tally = .{};
    var client = client_of(&two, &tally, 1);
    try client.send();
    var ticks: u32 = 0;
    while (two.echoes[1].held_len == 0 and ticks < ticks_max) : (ticks += 1) _ = try two.tick();
    try testing.expectEqual(@as(u32, 1), two.echoes[1].held_len);
    try two.harnesses[1].submit(&.{Operation.timer(9, constants.ns_per_ms, 0)}, &.{});
    var events: [1]Event = undefined;
    try two.harnesses[1].collect(&events);
    try testing.expectEqual(@as(u64, 9), events[0].user_data);
    // The call is still out: the target holds it.
    try testing.expect(client.call.is_out());
    two.echoes[1].answer_all(two.shared(1));
    while (tally.replied == 0 and ticks < ticks_max) : (ticks += 1) _ = try two.tick();
    try testing.expectEqual(@as(u32, 1), tally.replied);
    try testing.expectEqual(@as(u32, 0), tally.wrong);
}

test "a deadline at or before the target's clock ends the call expired, with no handler run" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var two: Two = undefined;
    const life = try two.start(&.empty);
    defer life.end();
    defer two.end();
    // The target reads its clock in each tick, so after one tick its clock is past 1 ns.
    _ = try two.tick();
    var tally: Tally = .{};
    var client = client_of(&two, &tally, 1);
    try two.service.send(two.shared(0), 1, &client.call, &@as(u64, 1), .{ .group = .default, .deadline_ns = 1 });
    var ticks: u32 = 0;
    while (tally.expired == 0 and ticks < ticks_max) : (ticks += 1) _ = try two.tick();
    try testing.expectEqual(@as(u32, 1), tally.expired);
    try testing.expectEqual(@as(u32, 0), two.echoes[1].handled);
}

/// A wait that a tick which takes a call must not take.
const long_wait_ns = 2 * constants.ns_per_s;

test "a tick that takes a call does not block before the handler runs" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var two: Two = undefined;
    const life = try two.start(&.empty);
    defer life.end();
    defer two.end();
    var tally: Tally = .{};
    var client = client_of(&two, &tally, 1);
    try client.send();
    // The target has nothing outstanding, so its tick takes the call on the fast path, and its
    // next tick runs the handler. Neither may wait for its wait to end.
    var events: [4]Event = undefined;
    const started_ns = backend.testing.monotonic_ns();
    var ticks: u32 = 0;
    while (two.echoes[1].handled == 0 and ticks < 4) : (ticks += 1) {
        _ = try two.harnesses[1].tick(&events, long_wait_ns);
    }
    const waited_ns = backend.testing.monotonic_ns() - started_ns;
    try testing.expectEqual(@as(u32, 1), two.echoes[1].handled);
    try testing.expect(waited_ns < long_wait_ns / 4);
    while (tally.replied == 0 and ticks < ticks_max) : (ticks += 1) _ = try two.tick();
    try testing.expectEqual(@as(u32, 1), tally.replied);
}

test "a call to self takes no ring, on a loop with no registry" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: ReactorHarness = undefined;
    try init_reactor(&harness, 0, null, &.empty);
    defer harness.deinit();
    var service: EchoService = .init;
    var echo: Echo = .{};
    const shared = harness.reactor.shared();
    service.serve(shared, &echo);
    defer service.stop_serving(shared);
    var tally: Tally = .{ .left = 100 };
    var client: Client = .{ .service = &service, .shared = shared, .target = 0, .tally = &tally };
    try client.send();
    var ticks: u32 = 0;
    while (tally.replied < 100 and ticks < ticks_max) : (ticks += 1) _ = try tick_all(&.{&harness});
    try testing.expectEqual(@as(u32, 100), tally.replied);
    try testing.expectEqual(@as(u32, 0), tally.wrong);
    try testing.expectEqual(@as(u32, 100), echo.handled);
    // Every call to self ran its `finish`, so the station's count is 0.
    try testing.expectEqual(@as(u32, 0), service.stations[0].self_out);
}

test "a call that waits in the ring of a loop that left is served by the loop that claims its id" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var two: Two = undefined;
    const life = try two.start(&.empty);
    defer life.end();
    defer two.end();
    // The target stops and ends with the call still in its ring: it never ticks after the send.
    var tally: Tally = .{};
    var client = client_of(&two, &tally, 1);
    two.service.stop_serving(two.shared(1));
    try client.send();
    two.harnesses[1].deinit();
    var refused = client_of(&two, &tally, 1);
    try testing.expectError(error.LoopNotFound, refused.send());
    try testing.expect(!refused.call.is_out());
    // A second loop claims id 1, serves, and takes the call that waited.
    try init_reactor(&two.harnesses[1], 1, &two.registry, &.empty);
    two.service.serve(two.shared(1), &two.echoes[1]);
    var ticks: u32 = 0;
    while (tally.replied == 0 and ticks < ticks_max) : (ticks += 1) _ = try two.tick();
    try testing.expectEqual(@as(u32, 1), tally.replied);
    try testing.expectEqual(@as(u32, 1), two.echoes[1].handled);
}

test "a loop that claims the id of a loop that stopped serving, and does not serve, answers stopped" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var two: Two = undefined;
    const life = try two.start(&.empty);
    defer life.end();
    // Loop 1 stops serving and ends. Its station still names it.
    two.service.stop_serving(two.shared(1));
    two.harnesses[1].deinit();
    // A second loop, at another address, claims id 1 and does not serve.
    var claimer: ReactorHarness = undefined;
    try init_reactor(&claimer, 1, &two.registry, &.empty);
    defer claimer.deinit();
    defer {
        two.service.stop_serving(two.shared(0));
        two.harnesses[0].deinit();
    }
    var tally: Tally = .{};
    var client = client_of(&two, &tally, 1);
    try client.send();
    var ticks: u32 = 0;
    while (tally.stopped == 0 and ticks < ticks_max) : (ticks += 1) _ = try tick_all(&.{ &two.harnesses[0], &claimer });
    try testing.expectEqual(@as(u32, 1), tally.stopped);
    try testing.expectEqual(@as(u32, 0), two.echoes[1].handled);
    // The claimer owes nothing: its drain answered the call, and no task of it is queued.
    try testing.expectEqual(@as(u32, 0), claimer.reactor.loop.callbacks_outstanding());
}
