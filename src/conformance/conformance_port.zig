//! The port of decision 33 on every backend: the type of each name, and what each name does. The
//! reactor calls these names, and a program does not.
//!
//! The call scenario sends a call with `push_reserved`, as the reactor's `call` does, and the target
//! reactor's hook takes it, and its `answer` answers it. The tasks of the call are written by hand,
//! with no `Service`.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const reactor_module = @import("reactor");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const CallLink = reactor_module.CallLink;
const CallStation = reactor_module.CallStation;
const Event = core.Event;
const Harness = conformance.Harness;
const ReactorHarness = conformance.ReactorHarness;
const Loop = backend.Loop;
const LoopId = core.LoopId;
const Operation = core.Operation;
const Task = reactor_module.Task;
const WaitLimit = core.WaitLimit;

/// The ticks a scenario may take: each one waits 0, so they are short.
const ticks_max = 100_000;

test "each name of the port has the type of decision 33" {
    const PushError = error{ LoopNotFound, CallsFull, MailboxFull };
    try testing.expect(@TypeOf(Loop.tick_backend) == fn (*Loop, []Event, u64) backend.TickError!u32);
    try testing.expect(@TypeOf(Loop.take_kept_error) == fn (*Loop) backend.TickError!void);
    try testing.expect(@TypeOf(Loop.outstanding) == fn (*Loop) *u32);
    try testing.expect(@TypeOf(Loop.stored_limit) == fn (*Loop) *WaitLimit);
    try testing.expect(@TypeOf(Loop.heartbeat_line) == fn (*Loop) *core.Heartbeat);
    try testing.expect(@TypeOf(Loop.attach_reserved) == fn (*Loop, *anyopaque, *const core.reserved.Take) void);
    try testing.expect(@TypeOf(Loop.push_reserved) == fn (*Loop, LoopId, core.Message) PushError!*u32);
    try testing.expect(@TypeOf(Loop.assert_owner) == fn (*const Loop) void);
    try testing.expect(@TypeOf(Loop.wait_until) == fn (*Loop, WaitLimit) void);
}

test "the port's tick hands a timer over, and its words are the loop's own" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const loop = &harness.loop;
    loop.assert_owner();
    // No error is kept, nothing is outstanding, and nothing bounds the wait.
    try loop.take_kept_error();
    try testing.expectEqual(@as(u32, 0), loop.outstanding().*);
    try testing.expectEqual(WaitLimit.none, loop.stored_limit().*);
    try testing.expectEqual(@intFromPtr(loop.heartbeat()), @intFromPtr(loop.heartbeat_line()));
    // `wait_until` writes the word that `stored_limit` names.
    loop.wait_until(.at(7));
    try testing.expectEqual(WaitLimit.at(7), loop.stored_limit().*);
    loop.wait_until(.none);
    // The port's tick hands the timer's event over, as `tick` does for a loop with no record.
    try harness.submit(&.{Operation.timer(5, 1, 0)}, &.{});
    var events: [4]Event = undefined;
    var produced: u32 = 0;
    var ticks: u32 = 0;
    while (produced == 0 and ticks < ticks_max) : (ticks += 1) produced = try loop.tick_backend(&events, 0);
    try testing.expectEqual(@as(u32, 1), produced);
    try testing.expectEqual(@as(u64, 5), events[0].user_data);
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}

fn ignore_reserved(_: *anyopaque, _: LoopId, _: core.Message) void {}

test "attach_reserved stores the hook and marks the loop in its registry as one that takes calls" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, ids);
    defer life.end();
    var harness: Harness = undefined;
    try harness.init(target_id, &registry);
    defer harness.deinit();
    try testing.expect(!registry.takes_calls(target_id));
    var context: u8 = 0;
    harness.loop.attach_reserved(&context, ignore_reserved);
    try testing.expect(registry.takes_calls(target_id));
    try testing.expectEqual(@as(*anyopaque, &context), harness.loop.tables.hook.context);
}

/// One call from reactor 0 to reactor 1, and what its two tasks saw.
const Round = struct {
    link: CallLink,
    target: *conformance.Reactor,
    handled: u32 = 0,
    finished: u32 = 0,

    /// The call's task on the target: it answers at once, through the reactor's `answer`.
    fn handle(task: *Task) void {
        const link: *CallLink = @fieldParentPtr("task", task);
        const round: *Round = @fieldParentPtr("link", link);
        round.handled += 1;
        round.target.answer(link);
    }

    /// The call's task on the caller: the link is idle again, and the count of the pair falls.
    fn finish(task: *Task) void {
        const link: *CallLink = @fieldParentPtr("task", task);
        const round: *Round = @fieldParentPtr("link", link);
        round.finished += 1;
        _ = reactor_module.call.end_call(link);
    }
};

const handle_call: Task.Call = .{ .name = "handle", .function = Round.handle, .call_record = true };
const finish_call: Task.Call = .{ .name = "finish", .function = Round.finish, .call_record = true };

const caller_id: LoopId = 0;
const target_id: LoopId = 1;
/// An id of the registry that runs no loop.
const absent_id: LoopId = 2;
const ids: u16 = 3;
var registry_memory: [backend.Registry.memory_bytes(ids)]u8 align(core.layout.memory_alignment) =
    undefined;
var stations: [core.constants.loops_max]CallStation align(@alignOf(CallStation)) = undefined;

/// Ticks `harness` with no wait until `done` reads `count`, or fails.
fn tick_until(harness: *ReactorHarness, done: *const u32, count: u32) !void {
    var events: [4]Event = undefined;
    var ticks: u32 = 0;
    while (done.* != count and ticks < ticks_max) : (ticks += 1) {
        try testing.expectEqual(@as(u32, 0), try harness.tick(&events, 0));
    }
    try testing.expectEqual(count, done.*);
}

test "a call that push_reserved sends runs on the target, and its return lowers the count it gave" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, ids);
    defer life.end();
    var caller: ReactorHarness = undefined;
    try caller.init(caller_id, &registry);
    defer caller.deinit();
    var target: ReactorHarness = undefined;
    try target.init(target_id, &registry);
    defer target.deinit();
    stations = @splat(CallStation.unused);
    _ = target.reactor.serve(&stations);
    defer target.reactor.stop_serving(&stations);

    // What the reactor's `call` does before and after its push, by hand.
    var round: Round = .{ .link = .idle(&finish_call), .target = &target.reactor };
    round.link.prepare(&stations, &handle_call, target_id, .{ .group = .default });
    round.link.origin = caller_id;
    const message: core.Message = .{
        .payload = @intFromPtr(&round.link),
        .tag = core.constants.message_tag_call,
        .reserved = round.link.generation,
    };
    const caller_loop = &caller.reactor.loop;
    try testing.expectError(error.LoopNotFound, caller_loop.push_reserved(absent_id, message));
    const calls_out = try caller_loop.push_reserved(target_id, message);
    try testing.expectEqual(&registry.mailbox(caller_id, target_id).calls_out, calls_out);
    try testing.expectEqual(@as(u32, 0), calls_out.*);
    round.link.calls_out = calls_out;
    calls_out.* += 1;
    caller_loop.outstanding().* += 1;

    try tick_until(&target, &round.handled, 1);
    try tick_until(&caller, &round.finished, 1);
    try testing.expectEqual(@as(u32, 0), calls_out.*);
    try testing.expectEqual(@as(u32, 0), caller_loop.outstanding().*);
    try testing.expectEqual(@as(u32, 0), target.reactor.loop.outstanding().*);
}
