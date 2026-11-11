//! Halt scenarios for the public module, `rotor`: the checks that `src/rotor/` makes itself, and
//! not through a backend's call. The host reactor's `shared` casts itself to its own view, and makes
//! the check through the backend's `assert_owner` itself (decisions 28 and 33).
//!
//! A scenario starts the host's reactor over a loop of the host's backend on the main thread, and
//! calls into it from a second thread, or with a forged group id. With its check deleted, each call
//! returns, and each scenario says how.
const std = @import("std");
const rotor = @import("rotor");
const scenario = @import("scenario.zig");

const Loop = rotor.Loop;

/// This file is the root of its executable, so the public module reads this declaration and each
/// loop reserves `quic` as id 1 at init (decision 30).
pub const rotor_scheduling_groups = .{ .quic = 400 };

const options: Loop.Options = .{ .operations = 4 };

/// Runs `call` on a second thread and waits for it. A scenario whose thread cannot start returns
/// without the marker, and the check counts that as a failure.
fn on_another_thread(comptime call: fn () void) void {
    const thread = std.Thread.spawn(.{}, call, .{}) catch return;
    thread.join();
}

/// The host's reactor of decision 33, which hands out a view of its own.
const Reactor = rotor.Reactor(Loop);
const reactor_options: Reactor.Options = .{ .loop = options };

var reactor_memory: [Reactor.memory_bytes(&reactor_options)]u8 align(rotor.memory_alignment) = undefined;
var reactor: Reactor align(@alignOf(Reactor)) = undefined;

/// The reactor's `shared` from a second thread. The check is the backend's, which the reactor's call
/// makes. With the reactor's call to it deleted, the call returns the view.
fn hand_out_the_reactor_view_from_another_thread() void {
    reactor.init(&reactor_memory, &reactor_options) catch return;
    on_another_thread(hand_out_the_reactor_view_on_this_thread);
}

fn hand_out_the_reactor_view_on_this_thread() void {
    scenario.reached_violation();
    _ = reactor.shared();
}

fn ran(_: *rotor.Task) void {}

const ran_call: rotor.Task.Call = .{ .name = "ran", .function = ran };
var tasks: [2]rotor.Task align(@alignOf(rotor.Task)) = @splat(.{ .call = &ran_call });

/// A forged id one past the program's named groups: the reactor reserved `quic` alone at init.
/// With the check deleted, the task is queued in that lane and the call returns.
fn queue_a_task_one_past_the_named_groups() void {
    reactor.init(&reactor_memory, &reactor_options) catch return;
    const quic = rotor.named_scheduling_group(.quic).group();
    reactor.schedule_in(quic, &tasks[0]) catch return;
    scenario.reached_violation();
    reactor.schedule_in(@enumFromInt(@intFromEnum(quic) + 1), &tasks[1]) catch return;
}

/// What the service of the scenario below answers: nothing, because its handler never runs.
const Context = struct {
    fn handle(_: *Context, _: *rotor.CallRecord(u64, u64)) rotor.Answer(u64) {
        return .{ .now = 0 };
    }
};

const Echo = rotor.Service(Context, u64, u64, Context.handle);

const Caller = struct {
    call: rotor.CallRecord(u64, u64) = .init(Caller, "call", finished),

    fn finished(_: *Caller, _: rotor.CallResult(u64)) void {}
};

var service: Echo align(@alignOf(Echo)) = .init;
var context: Context align(@alignOf(Context)) = .{};
var caller: Caller align(@alignOf(Caller)) = .{};

/// A call to the reactor itself in a group id one past the program's named groups (decision 32).
/// The reactor reserves a group of its own at that id, so the push of the call's task takes it.
/// With the check deleted, the call's task is queued and `send` returns.
fn send_a_call_one_past_the_named_groups() void {
    reactor.init(&reactor_memory, &reactor_options) catch return;
    _ = reactor.reserve_scheduling_group(rotor.constants.scheduling_shares_default) catch return;
    const shared = reactor.shared();
    service.serve(shared, &context);
    const quic = rotor.named_scheduling_group(.quic);
    scenario.reached_violation();
    service.send(shared, 0, &caller.call, &@as(u64, 1), .{ .group = @enumFromInt(@intFromEnum(quic) + 1) }) catch return;
}

const scenarios = [_]scenario.Scenario{
    .{
        .name = "rotor: send a call one past the named groups",
        .run = send_a_call_one_past_the_named_groups,
    },
    .{
        .name = "rotor: hand out the reactor's view from another thread",
        .run = hand_out_the_reactor_view_from_another_thread,
    },
    .{
        .name = "rotor: queue a task one past the named groups",
        .run = queue_a_task_one_past_the_named_groups,
    },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
