//! The seeded property test of the cross-core call (decision 32, unit test 8). Two model loops on
//! one thread draw a random mix of steps: posts, calls in random groups, calls to self, `.now` and
//! `.later` answers, deadlines, `stop_serving` and `serve` again, and ticks with small event
//! arrays. A failure prints the seed that replays it.
//!
//! The invariants:
//!
//! - A return push never fails: `answer` halts when it does.
//! - Each count of a pair stays at `calls_per_pair_max` or less.
//! - The queued tasks of calls on each loop stay at or below the bound of "The task queue and the
//!   fair tick" for two loops and one service.
//! - Each accepted call gets one `finish` and at most one handler run, both in the call's group.
//! - Every count of outstanding callbacks is 0 at the end.
const std = @import("std");
const testing = std.testing;
const constants = @import("../constants.zig");
const fixture = @import("call_test_fixture.zig");
const Random = @import("../random.zig").Random;
const NamedSchedulingGroup = @import("../scheduling/scheduling.zig").NamedSchedulingGroup;

const Model = fixture.Model;
const Event = fixture.Event;
const LoopId = fixture.LoopId;
const Declared = fixture.Declared;

const seeds = 48;
const steps = 1500;
/// The records of each loop: more than a pair's count, so `CallsFull` comes.
const clients_per_loop = constants.calls_per_pair_max + 8;
/// The calls one loop may hold `.later` at a time: every record of both loops.
const held_max = 2 * clients_per_loop;
/// The ticks that the end may take to settle every call.
const settle_ticks_max = 4096;
/// The bound of the queued tasks of calls on one loop of two, with one service.
const queued_calls_max = (2 * (2 - 1) + 1) * constants.calls_per_pair_max;

/// The context of the service: what the handler of one loop saw, and the calls it holds.
const Server = struct {
    model: *Model,
    run: *Run,
    held: [held_max]*Call = undefined,
    held_len: u32 = 0,

    fn handle(server: *Server, call: *Call) fixture.Answer(u64) {
        const client: *Client = @alignCast(@fieldParentPtr("call", call));
        client.handled += 1;
        if (client.handled > client.accepted) server.run.failures += 1;
        if (server.model.running_group() != @intFromEnum(call.link.group)) server.run.failures += 1;
        if (server.run.random.chance(1, 3)) {
            server.held[server.held_len] = call;
            server.held_len += 1;
            return .later;
        }
        return .{ .now = call.request_of().* + 1 };
    }

    fn answer_one(server: *Server, index: u32) void {
        const call = server.held[index];
        server.held[index] = server.held[server.held_len - 1];
        server.held_len -= 1;
        call.answer(server.model, &(call.request_of().* + 1));
    }
};

const Call = @import("call.zig").CallRecord(Model, u64, u64);
const Service = @import("call.zig").Service(Model, Server, u64, u64, Server.handle);

const Client = struct {
    call: Call = .init(Client, "call", finished),
    model: *Model,
    run: *Run,
    accepted: u32 = 0,
    finishes: u32 = 0,
    handled: u32 = 0,
    last_request: u64 = 0,

    fn finished(client: *Client, result: fixture.CallResult(u64)) void {
        client.finishes += 1;
        if (client.finishes != client.accepted) client.run.failures += 1;
        if (client.model.running_group() != @intFromEnum(client.call.link.group)) client.run.failures += 1;
        switch (result) {
            .replied => |reply| {
                if (reply.* != client.last_request + 1) client.run.failures += 1;
            },
            .expired, .target_stopped => {},
        }
    }
};

const Run = struct {
    random: Random,
    failures: u32 = 0,
    pair: *Pair,
    clients: *[2][clients_per_loop]Client,
    servers: *[2]Server,
    next_request: u64 = 1,

    fn step(run: *Run) !void {
        const loop: LoopId = @intCast(run.random.below(2));
        switch (run.random.below(10)) {
            0, 1, 2 => try run.send(loop),
            3 => run.post(loop),
            4, 5, 6 => run.tick(loop),
            7 => run.answer(loop),
            8 => run.pair.loops[loop].clock_ns += run.random.below(50),
            else => run.toggle_serving(loop),
        }
    }

    fn send(run: *Run, loop: LoopId) !void {
        const client = &run.clients[loop][run.random.below(clients_per_loop)];
        if (client.call.is_out()) return;
        const target: LoopId = @intCast(run.random.below(2));
        const group: NamedSchedulingGroup = @enumFromInt(run.random.below(Declared.table.count + 1));
        const deadline_ns = if (run.random.chance(1, 4)) run.pair.loops[target].clock_ns + run.random.below(60) else 0;
        const station = &run.pair.service.stations[target];
        // A call to a loop that never served halts, and each loop served at init.
        try testing.expect(station.state != .unused);
        client.last_request = run.next_request;
        run.next_request += 1;
        const model = &run.pair.loops[loop];
        run.pair.service.send(model, target, &client.call, &client.last_request, .{
            .group = group,
            .deadline_ns = deadline_ns,
        }) catch |err| switch (err) {
            error.CallsFull, error.MailboxFull => return,
            error.LoopNotFound => return error.TestUnexpectedResult,
        };
        client.accepted += 1;
    }

    fn post(run: *Run, loop: LoopId) void {
        const other: LoopId = 1 - loop;
        _ = run.pair.registry.mailbox(loop, other).push_post(.{ .payload = 0, .tag = 1 });
    }

    fn tick(run: *Run, loop: LoopId) void {
        var events: [8]Event = undefined;
        const room = run.random.between(1, events.len);
        _ = run.pair.loops[loop].tick(events[0..room]);
    }

    fn answer(run: *Run, loop: LoopId) void {
        const server = &run.servers[loop];
        if (server.held_len == 0) return;
        server.answer_one(@intCast(run.random.below(server.held_len)));
    }

    fn toggle_serving(run: *Run, loop: LoopId) void {
        const model = &run.pair.loops[loop];
        if (run.pair.service.stations[loop].state == .serving) {
            run.pair.service.stop_serving(model);
        } else {
            run.pair.service.serve(model, &run.servers[loop]);
        }
    }

    fn check(run: *Run) !void {
        for (0..2) |origin| {
            for (0..2) |target| {
                try testing.expect(run.pair.calls_out(@intCast(origin), @intCast(target)) <= constants.calls_per_pair_max);
            }
            try testing.expect(run.pair.service.stations[origin].self_out <= constants.calls_per_pair_max);
            try testing.expect(run.pair.loops[origin].queued() <= queued_calls_max);
        }
        try testing.expectEqual(@as(u32, 0), run.failures);
    }

    /// Answers every held call and ticks both loops until every call has ended.
    fn settle(run: *Run) !void {
        var events: [8]Event = undefined;
        for (0..settle_ticks_max) |_| {
            for (run.servers) |*server| {
                while (server.held_len != 0) server.answer_one(server.held_len - 1);
            }
            for (&run.pair.loops) |*model| _ = model.tick(&events);
            if (run.pair.loops[0].dispatch.callbacks_outstanding == 0 and
                run.pair.loops[1].dispatch.callbacks_outstanding == 0) return;
        }
        return error.CallsNotSettled;
    }
};

/// Two model loops on one registry, and this test's service.
const Pair = struct {
    memory: [fixture.Registry.memory_bytes(2)]u8 align(@import("../layout.zig").memory_alignment),
    registry: fixture.Registry,
    loops: [2]Model,
    service: Service,

    fn calls_out(pair: *Pair, origin: LoopId, target: LoopId) u32 {
        return pair.registry.mailbox(origin, target).calls_out;
    }
};

fn property_run(seed: u64) !void {
    errdefer std.debug.print("call property failed: seed {d}\n", .{seed});
    var pair: Pair = undefined;
    pair.registry.init(&pair.memory, 2);
    for (&pair.loops, 0..) |*model, id| model.init(&pair.registry, @intCast(id), &Declared.table);
    pair.service = .init;
    var clients: [2][clients_per_loop]Client = undefined;
    var servers: [2]Server = undefined;
    var run: Run = .{ .random = .init(seed), .pair = &pair, .clients = &clients, .servers = &servers };
    for (&servers, &pair.loops, 0..) |*server, *model, loop| {
        server.* = .{ .model = model, .run = &run };
        for (&clients[loop]) |*client| client.* = .{ .model = model, .run = &run };
        pair.service.serve(model, server);
    }
    for (0..steps) |_| {
        try run.step();
        try run.check();
    }
    try run.settle();
    try run.check();
    for (clients) |loop_clients| {
        for (loop_clients) |client| {
            try testing.expect(!client.call.is_out());
            try testing.expectEqual(client.accepted, client.finishes);
            try testing.expect(client.handled <= client.accepted);
        }
    }
    for (0..2) |origin| {
        for (0..2) |target| try testing.expectEqual(@as(u32, 0), pair.calls_out(@intCast(origin), @intCast(target)));
    }
}

test "seeded calls between two model loops keep every invariant of decision 32" {
    for (0..seeds) |seed| try property_run(seed);
}
