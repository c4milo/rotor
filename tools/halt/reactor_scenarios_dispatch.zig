//! Halt scenarios for a reactor that several libraries share (decisions 26, 28 and 33). A
//! reactor's `tick`, `deinit`, `add_poller` and `remove_poller` hand their checks to
//! `reactor.Dispatch`, so a scenario reaches them through its own calls, over a loop of the port of
//! decision 33 alone, and enters no kernel. The checks of the heartbeat are the core's, in
//! `core_scenarios_heartbeat.zig`.
const std = @import("std");
const core = @import("core");
const reactor = @import("reactor");
const scenario = @import("scenario.zig");

const Dispatch = reactor.Dispatch;

var dispatch: Dispatch align(@alignOf(Dispatch)) = .empty;

fn polled(_: *reactor.Poller) core.WaitLimit {
    return .none;
}

const polled_call: reactor.Poller.Call = .{ .name = "polled", .function = polled };
var poller: reactor.Poller align(@alignOf(reactor.Poller)) = .{ .call = &polled_call };

/// A tick inside a tick: what a callback or a poller that calls `tick` does. With the check
/// deleted, the second `begin` returns the wait.
fn begin_a_tick_inside_a_tick() void {
    start();
    _ = dispatch.begin(&port, 0);
    scenario.reached_violation();
    _ = dispatch.begin(&port, 0);
}

/// A host's `wait_limit` inside a tick: what a callback or a poller that calls it does
/// (decision 29). With the check deleted, the call returns the limit.
fn read_the_wait_limit_inside_a_tick() void {
    start();
    _ = dispatch.begin(&port, 0);
    scenario.reached_violation();
    _ = dispatch.wait_limit(&port);
}

/// The end of a tick that never began. With the check deleted, `end` hands the events back.
fn end_a_tick_that_never_began() void {
    start();
    scenario.reached_violation();
    _ = dispatch.end(&port, &.{});
}

/// A failed tick abandoned twice. With the check deleted, the second call clears a clear flag.
fn abandon_a_tick_that_never_began() void {
    start();
    scenario.reached_violation();
    dispatch.abandon();
}

/// One poller added twice: the loop would call it twice in each tick. With the check deleted, it
/// takes a second entry.
fn add_one_poller_twice() void {
    start();
    dispatch.add_poller(&port, &poller) catch return;
    scenario.reached_violation();
    dispatch.add_poller(&port, &poller) catch {};
}

/// A poller removed that was never added. With the check deleted, the removal finds nothing and
/// returns.
fn remove_a_poller_never_added() void {
    start();
    scenario.reached_violation();
    dispatch.remove_poller(&port, &poller);
}

fn removing(_: *reactor.Poller) core.WaitLimit {
    dispatch.remove_poller(&port, &poller);
    return .none;
}

const removing_call: reactor.Poller.Call = .{ .name = "removing", .function = removing };
var remover: reactor.Poller align(@alignOf(reactor.Poller)) = .{ .call = &removing_call };

/// A poller that removes a poller while the loop walks the table. With the check deleted, the
/// removal shifts the table and the tick goes on.
fn remove_a_poller_from_a_poller() void {
    start();
    dispatch.add_poller(&port, &poller) catch return;
    dispatch.add_poller(&port, &remover) catch return;
    scenario.reached_violation();
    _ = dispatch.begin(&port, 0);
}

fn adding(_: *reactor.Poller) core.WaitLimit {
    dispatch.add_poller(&port, &poller) catch {};
    return .none;
}

const adding_call: reactor.Poller.Call = .{ .name = "adding", .function = adding };
var adder: reactor.Poller align(@alignOf(reactor.Poller)) = .{ .call = &adding_call };

/// A poller that adds a poller while the loop walks the table. With the check deleted, the table
/// grows and the tick goes on.
fn add_a_poller_from_a_poller() void {
    start();
    dispatch.add_poller(&port, &adder) catch return;
    scenario.reached_violation();
    _ = dispatch.begin(&port, 0);
}

/// A loop that ends with a poller still added. With the check deleted, the check returns.
fn end_a_loop_with_a_poller() void {
    start();
    dispatch.add_poller(&port, &poller) catch return;
    scenario.reached_violation();
    dispatch.assert_empty();
}

/// What a reactor's `tick` does first: a reactor with no poller and no callback outstanding takes
/// the fast path and never reaches `begin`.
fn tick_as_a_backend_does() void {
    if ((dispatch.poller_count == 0 and port.word == 0)) return;
    _ = dispatch.begin(&port, 0);
}

fn ticking_record(_: *reactor.Completion, _: core.Event) void {
    scenario.reached_violation();
    tick_as_a_backend_does();
}

const ticking_call: reactor.Completion.Call = .{ .name = "ticking", .function = ticking_record };
var ticking_completion: reactor.Completion align(@alignOf(reactor.Completion)) =
    .{ .call = &ticking_call };

/// The callback of the last record outstanding calls `tick`. With the count lowered before the
/// call, the loop looks idle inside it, the tick takes the fast path, and nothing halts.
fn tick_inside_the_last_record() void {
    start();
    port.word += 1;
    _ = dispatch.begin(&port, 0);
    var events = [_]core.Event{.{
        .user_data = @intFromPtr(&ticking_completion),
        .result = 0,
        .flags = .{ .dispatched = true },
    }};
    _ = dispatch.end(&port, &events);
}

fn ending_record(_: *reactor.Completion, _: core.Event) void {
    scenario.reached_violation();
    dispatch.assert_empty();
}

const ending_call: reactor.Completion.Call = .{ .name = "ending", .function = ending_record };
var ending_completion: reactor.Completion align(@alignOf(reactor.Completion)) = .{ .call = &ending_call };

/// A record that ends the loop it runs on: what the program's own record does when it calls
/// `deinit` on its `*Loop` (decision 28). The loop has no poller and no task, so with the check
/// deleted, `assert_empty` returns and the tick goes on.
fn end_a_loop_inside_a_record() void {
    start();
    port.word += 1;
    _ = dispatch.begin(&port, 0);
    var events = [_]core.Event{.{
        .user_data = @intFromPtr(&ending_completion),
        .result = 0,
        .flags = .{ .dispatched = true },
    }};
    _ = dispatch.end(&port, &events);
}

/// The loop's groups (decision 30). No scenario here queues a task in a group other than
/// `.default`, so `end` never reads them.
var groups: reactor.Groups align(@alignOf(reactor.Groups)) = undefined;
/// The loop under the reactor's state.
var port: Port align(@alignOf(Port)) = .{};
const Port = @import("reactor_scenarios_call.zig").Port;

/// A reactor's state with no poller and no task, over a port with nothing outstanding.
fn start() void {
    port = .{};
    dispatch.start(&groups, .{ .id = 0, .in_group = false, .named_groups = &.empty });
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "dispatch: end a loop inside a record", .run = end_a_loop_inside_a_record },
    .{ .name = "dispatch: tick inside the last record", .run = tick_inside_the_last_record },
    .{ .name = "dispatch: remove a poller from a poller", .run = remove_a_poller_from_a_poller },
    .{ .name = "dispatch: add a poller from a poller", .run = add_a_poller_from_a_poller },
    .{ .name = "dispatch: end a loop with a poller", .run = end_a_loop_with_a_poller },
    .{ .name = "dispatch: begin a tick inside a tick", .run = begin_a_tick_inside_a_tick },
    .{
        .name = "dispatch: read the wait limit inside a tick",
        .run = read_the_wait_limit_inside_a_tick,
    },
    .{ .name = "dispatch: end a tick that never began", .run = end_a_tick_that_never_began },
    .{ .name = "dispatch: abandon a tick that never began", .run = abandon_a_tick_that_never_began },
    .{ .name = "dispatch: add one poller twice", .run = add_one_poller_twice },
    .{ .name = "dispatch: remove a poller never added", .run = remove_a_poller_never_added },
};
