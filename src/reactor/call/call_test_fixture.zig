//! What the tests of the cross-core call share (decision 32): a model loop with no kernel, a pair
//! of them on one registry, and one service that answers with its request plus one. A model loop
//! is a reactor's state over a loop of the port of decision 33 alone: the words, the heartbeat
//! line, the hook and `push_reserved`. It is also the `View` of `call_service.zig`: it has `call`,
//! `answer`, `serve`, `stop_serving` and `now_ns`. Its tick drains its mailboxes into its hook and
//! runs its tasks, on this thread.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const constants = @import("../constants.zig");
const call_module = @import("call.zig");
const call_service = @import("call_service.zig");
const reactor_module = @import("../reactor.zig");
const scheduling = @import("../scheduling/scheduling.zig");
const inbox_module = core.inbox;
const layout = core.layout;
const operation = core.operation;

pub const Dispatch = reactor_module.Dispatch;
pub const Groups = scheduling.Groups;
pub const Heartbeat = core.Heartbeat;
pub const Event = core.Event;
pub const LoopId = core.LoopId;
pub const Registry = core.mailbox.Registry;
pub const NamedTable = scheduling.NamedTable;
pub const CallLink = reactor_module.CallLink;
pub const CallStation = reactor_module.CallStation;
pub const CallError = call_module.CallError;
pub const CallResult = reactor_module.CallResult;
pub const Answer = reactor_module.Answer;

/// The named groups of the tests that need n > 0 (decision 30, "How tests name groups").
pub const Declared = scheduling.Named(.{ .low = 100, .high = 300 });

/// A loop with no kernel, and a reactor's state beside it: the parts of a `Tables` and an `Inbox`
/// that a call reaches, and the port's names over them.
pub const Model = struct {
    registry: ?*Registry,
    id: LoopId,
    dispatch: Dispatch,
    groups: Groups,
    heartbeat: Heartbeat,
    inbox: inbox_module.Inbox,
    /// The hook that the model's drain hands each reserved message, as a loop's `Tables` holds it.
    hook: core.reserved.Hook,
    /// The loop's `outstanding` and stored limit.
    word: u32,
    limit: core.WaitLimit,
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
            .hook = .{ .take = take_reserved, .context = model },
            .word = 0,
            .limit = .none,
            .clock_ns = 0,
            .wakes = 0,
        };
        model.dispatch.start(&model.groups, .{ .id = id, .in_group = false, .named_groups = table });
        // A loop publishes a descriptor at init, so another loop finds it, and a reactor's loop
        // takes calls.
        if (registry) |known| {
            known.set(id, 100 + @as(operation.Descriptor, id));
            known.mark_calls(id);
        }
    }

    // The port of decision 33, with no kernel.

    pub fn outstanding(model: *Model) *u32 {
        return &model.word;
    }

    pub fn stored_limit(model: *Model) *core.WaitLimit {
        return &model.limit;
    }

    pub fn heartbeat_line(model: *Model) *Heartbeat {
        return &model.heartbeat;
    }

    pub fn assert_owner(_: *const Model) void {}

    /// The core's push, and a wake counted where a loop would make it.
    pub fn push_reserved(model: *Model, target: LoopId, message: core.Message) CallError!*u32 {
        const pushed = try core.reserved.push(model.registry, model.id, target, message);
        if (pushed.wake != core.reserved.no_wake) model.wakes += 1;
        return pushed.calls_out;
    }

    // The view of a library.

    pub fn call(model: *Model, link: *CallLink) CallError!void {
        return model.dispatch.call(model, link);
    }

    pub fn answer(model: *Model, link: *CallLink) void {
        model.dispatch.answer(model, link);
    }

    pub fn serve(model: *Model, stations: *[constants.loops_max]CallStation) *CallStation {
        return model.dispatch.serve(model, stations);
    }

    pub fn stop_serving(model: *Model, stations: *[constants.loops_max]CallStation) void {
        model.dispatch.stop_serving(model, stations);
    }

    pub fn now_ns(model: *const Model) u64 {
        return model.clock_ns;
    }

    pub fn is_scheduled(model: *const Model, task: *const reactor_module.Task) bool {
        return model.dispatch.tasks.holds(task);
    }

    /// The slow path of the model's drain: the core's, with the model's hook.
    pub const take = inbox_module.TestTake(Model).take;

    /// The hook: the reactor's, through the context that `init` stored.
    fn take_reserved(context: *anyopaque, sender: LoopId, message: core.Message) void {
        const model: *Model = @ptrCast(@alignCast(context));
        model.dispatch.take_reserved(model, sender, message);
    }

    /// One tick with no kernel: the drain of the mailboxes into `events`, then the tasks. Returns
    /// the events that the drain wrote.
    pub fn tick(model: *Model, events: []Event) u32 {
        // A loop's first stamp of a tick zeroes the turn, and a run of tasks adds to its counts.
        model.heartbeat.turn = .zero;
        _ = model.dispatch.begin(model, 0);
        const produced = model.inbox.drain_mailboxes(model.id, events, take);
        const kept = model.dispatch.end(model, events[0..produced]);
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
        return model.dispatch.tasks_queued(model);
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
        call.answer(echo.model, &(call.request_of().* + 1));
    }
};

/// The record of one call of the echo service. A handler names it, and not `EchoService.Call`,
/// which would depend on the handler.
pub const EchoCall = TestRecord(u64, u64);
pub const EchoService = TestService(Echo, u64, u64, Echo.handle);

/// A record of one call over the model loop, as a reactor declares its own over its view.
pub fn TestRecord(comptime Request: type, comptime Reply: type) type {
    return struct {
        link: CallLink,
        request: Request,
        reply: Reply,

        const record = call_service.CallRecord(@This(), Model, Request, Reply);
        pub const init = record.init;
        pub const is_out = record.is_out;
        pub const request_of = record.request_of;
        pub const answer = record.answer;
    };
}

/// One kind of call over the model loop, as a reactor declares its own over its view.
pub fn TestService(
    comptime Context: type,
    comptime Request: type,
    comptime Reply: type,
    comptime handler: fn (context: *Context, record: *TestRecord(Request, Reply)) Answer(Reply),
) type {
    return struct {
        stations: [constants.loops_max]CallStation,

        const service = call_service.Service(@This(), Model, Context, Request, Reply, handler);
        pub const init: @This() = .{ .stations = @splat(CallStation.unused) };
        pub const Call = TestRecord(Request, Reply);
        pub const entry: reactor_module.Task.Call = .{ .name = @typeName(@This()), .function = service.run, .call_record = true };
        pub const serve = service.serve;
        pub const stop_serving = service.stop_serving;
        pub const send = service.send;
    };
}

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
