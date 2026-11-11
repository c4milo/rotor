//! Tests of `Reactor(Loop)` at step 2 of decision 33, over a twin of decision 10 that notes each
//! call it takes. Each call of the reactor must reach the loop's call of the same name, with its
//! arguments, and return what that call returns. Split from `reactor.zig` for the 500-line limit.
const std = @import("std");
const core = @import("core");
const reactor_module = @import("reactor.zig");
const check_module = @import("reactor_check.zig");

const testing = std.testing;

const CallLink = core.call.CallLink;
const CallStation = core.call.CallStation;
const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const group_alignment = core.buffer_group.group_alignment;

/// A line that takes each call of the reactor and stores nothing, as a twin for replay may.
const Line = struct {
    pub fn enter(_: *Line, _: *const [:0]const u8) void {}
    pub fn leave(_: *Line, _: u64) void {}
    pub fn leave_polling(_: *Line, _: u32) void {}
    pub fn leave_tasks(_: *Line, _: u64) void {}
    pub fn leave_group_tasks(_: *Line, _: u64, _: u8) void {}
};

/// A twin with each name of the core's surface and of the port. A call that may change the loop
/// stores its name in `last` and one of its arguments in `argument`. A call that only reads the
/// loop returns a value made from `argument`, so a test sees that the call ran.
const Twin = struct {
    last: []const u8 = "",
    argument: u64 = 0,
    line: Line = .{},
    word: u32 = 0,
    limit: core.WaitLimit = .none,
    bytes: [8]u8 = @splat(0),
    stations: [1]CallStation = @splat(CallStation.unused),

    pub const Options = struct { operations: u32 };

    /// The error sets of the twin's own, which the reactor returns as they are.
    pub const InitError = error{InitRefused};
    pub const TickError = error{TickRefused};

    fn note(twin: *Twin, name: []const u8, argument: u64) void {
        twin.last = name;
        twin.argument = argument;
    }

    pub fn memory_bytes(options: *const Options) usize {
        return options.operations * 8;
    }
    pub fn init(twin: *Twin, memory: []align(core.layout.memory_alignment) u8, options: *const Options) InitError!void {
        twin.* = .{};
        if (options.operations == 0) return error.InitRefused;
        twin.note("init", memory.len + options.operations);
    }
    pub fn deinit(twin: *Twin) void {
        twin.note("deinit", 0);
    }
    pub fn dropped_wakes(twin: *const Twin) u64 {
        return twin.argument + 1;
    }
    pub fn submit(twin: *Twin, operations: []const Operation, handles: []Handle) u32 {
        twin.note("submit", handles.len);
        return @intCast(operations.len);
    }
    pub fn cancel(twin: *Twin, handle: Handle) void {
        twin.note("cancel", handle.generation);
    }
    pub fn post(twin: *Twin, target: core.LoopId, message: core.Message) error{MailboxFull}!void {
        twin.note("post", target + message.payload);
        if (target == 0) return error.MailboxFull;
    }
    pub fn tick(twin: *Twin, events: []Event, wait_ns: u64) TickError!u32 {
        twin.note("tick", wait_ns);
        if (wait_ns == 0) return error.TickRefused;
        return @intCast(events.len);
    }
    pub fn add_poller(twin: *Twin, _: *core.Poller) error{PollersFull}!void {
        twin.note("add_poller", 0);
    }
    pub fn remove_poller(twin: *Twin, _: *core.Poller) void {
        twin.note("remove_poller", 0);
    }
    pub fn schedule(twin: *Twin, _: *core.Task) error{TasksFull}!void {
        twin.note("schedule", 0);
    }
    pub fn is_scheduled(twin: *const Twin, _: *const core.Task) bool {
        return twin.argument == 7;
    }
    pub fn tasks_queued(twin: *const Twin) u32 {
        return @intCast(twin.argument + 2);
    }
    pub fn task_budget_left(twin: *const Twin) u32 {
        return @intCast(twin.argument + 3);
    }
    pub fn discard_tasks(twin: *Twin) u32 {
        twin.note("discard_tasks", 0);
        return 4;
    }
    pub fn schedule_in(twin: *Twin, group: core.SchedulingGroup, _: *core.Task) error{TasksFull}!void {
        twin.note("schedule_in", @intFromEnum(group));
    }
    pub fn charge_task(twin: *Twin, units: u16) void {
        twin.note("charge_task", units);
    }
    pub fn reserve_scheduling_group(twin: *Twin, shares: u16) error{SchedulingGroupsFull}!core.SchedulingGroup {
        twin.note("reserve_scheduling_group", shares);
        return @enumFromInt(5);
    }
    pub fn set_scheduling_group_shares(twin: *Twin, group: core.SchedulingGroup, shares: u16) void {
        twin.note("set_scheduling_group_shares", @as(u64, @intFromEnum(group)) * 1000 + shares);
    }
    pub fn shared(twin: *Twin) *Twin {
        twin.note("shared", 0);
        return twin;
    }
    pub fn heartbeat(twin: *Twin) *Line {
        twin.note("heartbeat", 0);
        return &twin.line;
    }
    pub fn in_flight(twin: *const Twin) u32 {
        return @intCast(twin.argument + 5);
    }
    pub fn now_ns(twin: *const Twin) u64 {
        return twin.argument + 6;
    }
    pub fn wait_descriptor(twin: *const Twin) ?core.Descriptor {
        return @intCast(twin.argument + 7);
    }
    pub fn statistics(twin: *const Twin) *const u64 {
        return &twin.argument;
    }
    pub fn cancel_all(twin: *Twin) void {
        twin.note("cancel_all", 0);
    }
    pub fn drain(twin: *Twin, scratch: []Event) error{StillInFlight}!void {
        twin.note("drain", scratch.len);
        if (scratch.len == 0) return error.StillInFlight;
    }
    pub fn assert_empty(twin: *const Twin) void {
        std.debug.assert(twin.argument != 9);
    }
    pub fn register_buffers(twin: *Twin, blocks: []const []u8) error{RegisterRefused}!void {
        twin.note("register_buffers", blocks.len);
    }
    pub fn register_descriptors(twin: *Twin, descriptors: []const core.Descriptor) error{RegisterRefused}!void {
        twin.note("register_descriptors", descriptors.len);
    }
    pub fn reserve_buffer_group(twin: *Twin) error{BufferGroupsFull}!core.BufferGroup {
        twin.note("reserve_buffer_group", 0);
        return @enumFromInt(3);
    }
    pub fn provide_buffers(twin: *Twin, group: core.BufferGroup, memory: []align(group_alignment) u8, count: u16, buffer_bytes: u32) error{ProvideRefused}!void {
        twin.note("provide_buffers", @intFromEnum(group) + memory.len + count + buffer_bytes);
    }
    pub fn provide_datagram_buffers(twin: *Twin, group: core.BufferGroup, memory: []align(group_alignment) u8, count: u16, buffer_bytes: u32, options: core.datagram.GroupOptions) error{ProvideRefused}!void {
        twin.note("provide_datagram_buffers", @intFromEnum(group) + memory.len + count + buffer_bytes + options.name_reserve);
    }
    pub fn datagram(twin: *const Twin, group: core.BufferGroup, event: Event) core.Delivery {
        _ = event;
        return .{ .from = std.mem.zeroes(core.datagram.Received), .bytes = @constCast(twin.bytes[0..@intFromEnum(group)]) };
    }
    pub fn give_back_buffer(twin: *Twin, group: core.BufferGroup, buffer_id: u16) void {
        twin.note("give_back_buffer", @as(u64, @intFromEnum(group)) * 1000 + buffer_id);
    }
    pub fn release_buffers(twin: *Twin, group: core.BufferGroup) void {
        twin.note("release_buffers", @intFromEnum(group));
    }
    pub fn provided_buffer(twin: *const Twin, group: core.BufferGroup, buffer_id: u16) []u8 {
        return @constCast(twin.bytes[@intFromEnum(group)..buffer_id]);
    }
    pub fn wait_limit(twin: *Twin) core.WaitLimit {
        twin.note("wait_limit", 0);
        return twin.limit;
    }
    pub fn call(twin: *Twin, link: *CallLink) error{LoopNotFound}!void {
        twin.note("call", link.target);
    }
    pub fn answer(twin: *Twin, link: *CallLink) void {
        twin.note("answer", link.target);
    }
    pub fn serve(twin: *Twin, stations: *[core.constants.loops_max]CallStation) *CallStation {
        twin.note("serve", @intFromEnum(stations[0].state));
        return &twin.stations[0];
    }
    pub fn stop_serving(twin: *Twin, stations: *[core.constants.loops_max]CallStation) void {
        twin.note("stop_serving", @intFromEnum(stations[0].state));
    }

    // The port of decision 33. The reactor of step 2 calls none of them.
    pub fn tick_backend(twin: *Twin, events: []Event, wait_ns: u64) TickError!u32 {
        return twin.tick(events, wait_ns);
    }
    pub fn take_kept_error(_: *Twin) TickError!void {}
    pub fn outstanding(twin: *Twin) *u32 {
        return &twin.word;
    }
    pub fn stored_limit(twin: *Twin) *core.WaitLimit {
        return &twin.limit;
    }
    pub fn heartbeat_line(twin: *Twin) *Line {
        return &twin.line;
    }
    pub fn push_reserved(_: *Twin, _: core.LoopId, _: core.Message) error{ LoopNotFound, CallsFull, MailboxFull }!*u32 {
        return error.LoopNotFound;
    }
    pub fn assert_owner(_: *const Twin) void {}
};

const Reactor = reactor_module.Reactor(Twin);

/// Fails unless the twin's last call that may change it was `name`, with `argument`.
fn expect_last(reactor: *const Reactor, name: []const u8, argument: u64) !void {
    try testing.expectEqualStrings(name, reactor.loop.last);
    try testing.expectEqual(argument, reactor.loop.argument);
}

test "a twin with each name passes the check" {
    try testing.expectEqual(null, comptime check_module.message(Twin));
}

test "the reactor takes the loop's memory and options, and returns the loop's errors" {
    var reactor: Reactor = undefined;
    try testing.expectEqual(24, Reactor.memory_bytes(&.{ .loop = .{ .operations = 3 } }));
    var memory: [16]u8 align(core.layout.memory_alignment) = @splat(0);
    try reactor.init(&memory, &.{ .loop = .{ .operations = 3 } });
    try expect_last(&reactor, "init", 16 + 3);
    try testing.expectError(error.InitRefused, reactor.init(&memory, &.{ .loop = .{ .operations = 0 } }));
    reactor.deinit();
    try expect_last(&reactor, "deinit", 0);
}

test "each call of the core's surface reaches the loop, with its arguments" {
    var reactor: Reactor = .{ .loop = .{} };
    var events: [3]Event = undefined;
    var handles: [2]Handle = @splat(.none);
    try testing.expectEqual(1, reactor.submit(&.{Operation.timer(0, 1, 0)}, &handles));
    try expect_last(&reactor, "submit", 2);
    reactor.cancel(.{ .index = 1, .generation = 4 });
    try expect_last(&reactor, "cancel", 4);
    try reactor.post(2, .{ .payload = 40, .tag = 0 });
    try expect_last(&reactor, "post", 42);
    try testing.expectError(error.MailboxFull, reactor.post(0, .{ .payload = 0, .tag = 0 }));
    try testing.expectEqual(3, try reactor.tick(&events, 11));
    try expect_last(&reactor, "tick", 11);
    try testing.expectError(error.TickRefused, reactor.tick(&events, 0));
    reactor.cancel_all();
    try expect_last(&reactor, "cancel_all", 0);
    try reactor.drain(&events);
    try expect_last(&reactor, "drain", 3);
    try testing.expectError(error.StillInFlight, reactor.drain(events[0..0]));
    try testing.expectEqual(core.WaitLimit.none, reactor.wait_limit());
    try expect_last(&reactor, "wait_limit", 0);
    reactor.loop.argument = 100;
    try testing.expectEqual(101, reactor.dropped_wakes());
    try testing.expectEqual(105, reactor.in_flight());
    try testing.expectEqual(106, reactor.now_ns());
    try testing.expectEqual(107, reactor.wait_descriptor());
    try testing.expectEqual(&reactor.loop.argument, reactor.statistics());
    reactor.assert_empty();
    try testing.expectEqual(&reactor.loop.line, reactor.heartbeat());
    try expect_last(&reactor, "heartbeat", 0);
}

test "each call of the buffers reaches the loop, with its arguments" {
    var reactor: Reactor = .{ .loop = .{} };
    var block: [4]u8 = @splat(0);
    try reactor.register_buffers(&.{&block});
    try expect_last(&reactor, "register_buffers", 1);
    try reactor.register_descriptors(&.{ 1, 2 });
    try expect_last(&reactor, "register_descriptors", 2);
    const group = try reactor.reserve_buffer_group();
    try testing.expectEqual(3, @intFromEnum(group));
    try expect_last(&reactor, "reserve_buffer_group", 0);
    var memory: [64]u8 align(group_alignment) = @splat(0);
    try reactor.provide_buffers(group, &memory, 2, 32);
    try expect_last(&reactor, "provide_buffers", 3 + 64 + 2 + 32);
    try reactor.provide_datagram_buffers(group, &memory, 2, 32, .{ .name_reserve = 100 });
    try expect_last(&reactor, "provide_datagram_buffers", 3 + 64 + 2 + 32 + 100);
    try testing.expectEqual(3, reactor.datagram(group, undefined).bytes.len);
    try testing.expectEqual(2, reactor.provided_buffer(group, 5).len);
    reactor.give_back_buffer(group, 6);
    try expect_last(&reactor, "give_back_buffer", 3006);
    reactor.release_buffers(group);
    try expect_last(&reactor, "release_buffers", 3);
}

fn ran(_: *core.Task) void {}

const ran_call: core.Task.Call = .{ .name = "ran", .function = ran };

fn polled(_: *core.Poller) core.WaitLimit {
    return .none;
}

const polled_call: core.Poller.Call = .{ .name = "polled", .function = polled };

test "each call of the pollers, the tasks and the groups reaches the loop, with its arguments" {
    var reactor: Reactor = .{ .loop = .{} };
    var task: core.Task = .{ .call = &ran_call };
    var poller: core.Poller = .{ .call = &polled_call };
    try reactor.add_poller(&poller);
    try expect_last(&reactor, "add_poller", 0);
    reactor.remove_poller(&poller);
    try expect_last(&reactor, "remove_poller", 0);
    try reactor.schedule(&task);
    try expect_last(&reactor, "schedule", 0);
    try reactor.schedule_in(@enumFromInt(2), &task);
    try expect_last(&reactor, "schedule_in", 2);
    reactor.charge_task(9);
    try expect_last(&reactor, "charge_task", 9);
    try testing.expectEqual(5, @intFromEnum(try reactor.reserve_scheduling_group(300)));
    try expect_last(&reactor, "reserve_scheduling_group", 300);
    reactor.set_scheduling_group_shares(@enumFromInt(5), 40);
    try expect_last(&reactor, "set_scheduling_group_shares", 5040);
    try testing.expectEqual(4, reactor.discard_tasks());
    try expect_last(&reactor, "discard_tasks", 0);
    reactor.loop.argument = 7;
    try testing.expect(reactor.is_scheduled(&task));
    try testing.expectEqual(9, reactor.tasks_queued());
    try testing.expectEqual(10, reactor.task_budget_left());
}

test "the view is the reactor's, and the loop's shared makes the owner check" {
    var reactor: Reactor = .{ .loop = .{} };
    const shared = reactor.shared();
    try expect_last(&reactor, "shared", 0);
    try testing.expectEqual(@intFromPtr(&reactor), @intFromPtr(shared));
    comptime core.shared_loop.check(Reactor.SharedLoop);
    // A library's call on the view reaches the reactor, and through it the loop.
    try testing.expectEqual(1, shared.submit(&.{Operation.timer(0, 1, 0)}, &.{}));
    try expect_last(&reactor, "submit", 0);
}

test "each cross-core call reaches the loop, with its link and its stations" {
    var reactor: Reactor = .{ .loop = .{} };
    var stations: [core.constants.loops_max]CallStation = @splat(CallStation.unused);
    stations[0].state = .stopped;
    const station = reactor.serve(&stations);
    try testing.expectEqual(&reactor.loop.stations[0], station);
    try expect_last(&reactor, "serve", @intFromEnum(CallStation.StationState.stopped));
    reactor.stop_serving(&stations);
    try expect_last(&reactor, "stop_serving", @intFromEnum(CallStation.StationState.stopped));
    var link: CallLink = .idle(&ran_call);
    link.target = 12;
    try reactor.call(&link);
    try expect_last(&reactor, "call", 12);
    reactor.answer(&link);
    try expect_last(&reactor, "answer", 12);
}

test "the reactor holds its loop at its own address, and nothing else" {
    try testing.expectEqual(@sizeOf(Twin), @sizeOf(Reactor));
    try testing.expectEqual(0, @offsetOf(Reactor, "loop"));
}
