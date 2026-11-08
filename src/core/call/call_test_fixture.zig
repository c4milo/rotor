//! What the tests of the cross-core call share (decision 32): a model loop with no kernel, a pair
//! of them on one registry, and one service that answers with its request plus one. A model loop
//! is the `View` of `call_service.zig`: it has `call`, `answer`, `serve`, `stop_serving` and
//! `now_ns`. Its tick drains its mailboxes and runs its tasks, on this thread.
const std = @import("std");
const testing = std.testing;
const constants = @import("../constants.zig");
const call_module = @import("call.zig");
const call_take = @import("call_take.zig");
const event = @import("../event.zig");
const inbox_module = @import("../inbox.zig");
const take_reserved = inbox_module.take_reserved;
const layout = @import("../layout.zig");
const mailbox = @import("../mailbox.zig");
const operation = @import("../operation.zig");
const scheduling = @import("../scheduling/scheduling.zig");
const stall = @import("../stall.zig");

pub const Dispatch = @import("../dispatch/dispatch.zig").Dispatch;
pub const Groups = scheduling.Groups;
pub const Heartbeat = stall.Heartbeat;
pub const Event = event.Event;
pub const LoopId = operation.LoopId;
pub const Registry = mailbox.Registry;
pub const NamedTable = scheduling.NamedTable;
pub const CallLink = call_module.CallLink;
pub const CallStation = call_module.CallStation;
pub const CallError = call_module.CallError;
pub const CallResult = call_module.CallResult;
pub const Answer = call_module.Answer;

/// The named groups of the tests that need n > 0 (decision 30, "How tests name groups").
pub const Declared = scheduling.Named(.{ .low = 100, .high = 300 });

/// A loop with no kernel: the parts of a `Tables` and an `Inbox` that a call reaches.
pub const Model = struct {
    registry: ?*Registry,
    id: LoopId,
    dispatch: Dispatch,
    groups: Groups,
    heartbeat: Heartbeat,
    inbox: inbox_module.Inbox,
    /// The loop clock that a call's deadline is compared with.
    clock_ns: u64,
    /// The wakes that a call or an answer asked for.
    wakes: u32,

    pub fn init(model: *Model, registry: ?*Registry, id: LoopId, table: *const NamedTable) void {
        model.* = .{
            .registry = registry,
            .id = id,
            .dispatch = .empty,
            .groups = undefined,
            .heartbeat = .init(null),
            .inbox = .init(registry, &.{}, null),
            .clock_ns = 0,
            .wakes = 0,
        };
        model.groups.init(table);
        // A loop publishes a descriptor at init, so another loop finds it.
        if (registry) |known| known.set(id, 100 + @as(operation.Descriptor, id));
    }

    pub fn call(model: *Model, link: *CallLink) CallError!void {
        const wake = try call_module.call(model.registry, model.id, &model.dispatch, &model.groups, link);
        if (wake != null) model.wakes += 1;
    }

    pub fn answer(model: *Model, link: *CallLink) void {
        const wake = call_take.answer(model.registry, model.id, &model.dispatch, &model.groups, link);
        if (wake != null) model.wakes += 1;
    }

    pub fn serve(model: *Model, stations: *[constants.loops_max]CallStation) *CallStation {
        return call_module.serve(model.registry, model.id, &model.groups, stations);
    }

    pub fn stop_serving(model: *Model, stations: *[constants.loops_max]CallStation) void {
        call_module.stop_serving(model.id, &model.groups, stations);
    }

    pub fn now_ns(model: *const Model) u64 {
        return model.clock_ns;
    }

    /// One tick with no kernel: the drain of the mailboxes into `events`, then the tasks. Returns
    /// the events that the drain wrote.
    pub fn tick(model: *Model, events: []Event) u32 {
        // A loop's first stamp of a tick zeroes the turn, and a run of tasks adds to its counts.
        model.heartbeat.turn = .zero;
        _ = model.dispatch.begin(&model.heartbeat, 0);
        const produced = model.inbox.drain_mailboxes(model.id, events, &model.dispatch, &model.groups, take_reserved);
        const kept = model.dispatch.end(&model.heartbeat, &model.groups, events[0..produced]);
        model.groups.assert_lanes(model.dispatch.groups_ready);
        model.dispatch.tasks.assert_queue();
        return kept;
    }

    /// One tick with no room for an event.
    pub fn turn(model: *Model) void {
        var events: [4]Event = undefined;
        _ = model.tick(&events);
    }

    /// The group of the task that runs now: `.default` on the path with one group, and the visit's
    /// group on the groups path (decision 30).
    pub fn running_group(model: *const Model) u8 {
        if (model.dispatch.phase != .group_tasks) return 0;
        return model.groups.cursor;
    }

    /// The tasks queued in every group.
    pub fn queued(model: *const Model) u32 {
        return model.dispatch.tasks_queued(&model.groups);
    }
};

/// What the echo service's handler does with a call.
pub const Mode = enum { now, later };

/// The context of the echo service: what its handler saw.
pub const Echo = struct {
    mode: Mode = .now,
    handled: u32 = 0,
    /// The group of the last call that the handler ran in, read from the dispatch.
    last_group: u8 = 0,
    /// The calls answered `.later`, in order, which the test answers.
    later: [constants.calls_per_pair_max * 2]*EchoCall = undefined,
    later_len: u32 = 0,
    model: *Model,

    fn handle(echo: *Echo, call: *EchoCall) Answer(u64) {
        echo.handled += 1;
        echo.last_group = echo.model.running_group();
        if (echo.mode == .later) {
            echo.later[echo.later_len] = call;
            echo.later_len += 1;
            return .later;
        }
        return .{ .now = call.request_of().* + 1 };
    }

    /// Answers the oldest call held `.later` with its request plus one.
    pub fn answer_oldest(echo: *Echo) void {
        std.debug.assert(echo.later_len >= 1);
        const call = echo.later[0];
        std.mem.copyForwards(*EchoCall, echo.later[0 .. echo.later_len - 1], echo.later[1..echo.later_len]);
        echo.later_len -= 1;
        call.answer(echo.model, call.request_of().* + 1);
    }
};

/// The record of one call of the echo service. A handler names it, and not `EchoService.Call`,
/// which would depend on the handler.
pub const EchoCall = call_module.CallRecord(Model, u64, u64);
pub const EchoService = call_module.Service(Model, Echo, u64, u64, Echo.handle);

/// One caller's record, and what its `finish` saw.
pub const Client = struct {
    call: EchoCall = .init(Client, "call", finished),
    finishes: u32 = 0,
    replied: u32 = 0,
    expired: u32 = 0,
    stopped: u32 = 0,
    last_reply: u64 = 0,
    /// The group of the last `finish`, read from the caller's dispatch.
    last_group: u8 = 0,
    model: ?*Model = null,

    fn finished(client: *Client, result: CallResult(u64)) void {
        std.debug.assert(!client.call.is_out());
        client.finishes += 1;
        if (client.model) |model| client.last_group = model.running_group();
        switch (result) {
            .replied => |reply| {
                client.replied += 1;
                client.last_reply = reply.*;
            },
            .expired => client.expired += 1,
            .target_stopped => client.stopped += 1,
        }
    }
};

/// The bytes of a registry of `loops` loops.
pub fn registry_bytes(comptime loops: u16) usize {
    return Registry.memory_bytes(loops);
}

/// Two model loops, 0 and 1, on one registry of `loop_count` loops, and the echo service on each.
pub fn Pair(comptime loop_count: u16) type {
    return struct {
        const This = @This();
        memory: [Registry.memory_bytes(loop_count)]u8 align(layout.memory_alignment),
        registry: Registry,
        loops: [2]Model,
        service: EchoService,
        echoes: [2]Echo,

        pub fn init(pair: *This, table: *const NamedTable) void {
            pair.registry.init(&pair.memory, loop_count);
            for (&pair.loops, 0..) |*model, id| model.init(&pair.registry, @intCast(id), table);
            pair.service = .init;
            for (&pair.echoes, &pair.loops) |*echo, *model| {
                echo.* = .{ .model = model };
                pair.service.serve(model, echo);
            }
        }

        /// The count of the ring from `origin` to `target`.
        pub fn calls_out(pair: *This, origin: LoopId, target: LoopId) u32 {
            return pair.registry.mailbox(origin, target).calls_out;
        }

        /// Both loops stop serving, so the end checks hold.
        pub fn stop(pair: *This) void {
            for (&pair.loops) |*model| pair.service.stop_serving(model);
        }
    };
}

test "a link is 64 B and a station 128 B" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(CallLink));
    try testing.expectEqual(@as(usize, 128), @sizeOf(CallStation));
}
