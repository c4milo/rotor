//! Halt scenarios for a loop that several libraries share (decision 26). Each backend's `tick`,
//! `add_poller` and `remove_poller` hand their checks to `core.dispatch.Dispatch`, so a scenario
//! reaches them through its own calls and enters no kernel. Split from `core_scenarios.zig` for
//! the 500-line limit.
const core = @import("core");
const scenario = @import("scenario.zig");

const Dispatch = core.dispatch.Dispatch;

var dispatch: Dispatch align(@alignOf(Dispatch)) = .empty;

fn polled(_: *core.Poller) bool {
    return false;
}

var poller: core.Poller align(@alignOf(core.Poller)) = .{ .poll = polled };

/// A tick inside a tick: what a callback or a poller that calls `tick` does. With the check
/// deleted, the second `begin` returns the wait.
fn begin_a_tick_inside_a_tick() void {
    dispatch = .empty;
    _ = dispatch.begin(0);
    scenario.reached_violation();
    _ = dispatch.begin(0);
}

/// The end of a tick that never began. With the check deleted, `end` hands the events back.
fn end_a_tick_that_never_began() void {
    dispatch = .empty;
    scenario.reached_violation();
    _ = dispatch.end(&.{});
}

/// A failed tick abandoned twice. With the check deleted, the second call clears a clear flag.
fn abandon_a_tick_that_never_began() void {
    dispatch = .empty;
    scenario.reached_violation();
    dispatch.abandon();
}

/// One poller added twice: the loop would call it twice in each tick. With the check deleted, it
/// takes a second entry.
fn add_one_poller_twice() void {
    dispatch = .empty;
    dispatch.add_poller(&poller) catch return;
    scenario.reached_violation();
    dispatch.add_poller(&poller) catch {};
}

/// A poller removed that was never added. With the check deleted, the removal finds nothing and
/// returns.
fn remove_a_poller_never_added() void {
    dispatch = .empty;
    scenario.reached_violation();
    dispatch.remove_poller(&poller);
}

fn removing(_: *core.Poller) bool {
    dispatch.remove_poller(&poller);
    return false;
}

var remover: core.Poller align(@alignOf(core.Poller)) = .{ .poll = removing };

/// A poller that removes a poller while the loop walks the table. With the check deleted, the
/// removal shifts the table and the tick goes on.
fn remove_a_poller_from_a_poller() void {
    dispatch = .empty;
    dispatch.add_poller(&poller) catch return;
    dispatch.add_poller(&remover) catch return;
    scenario.reached_violation();
    _ = dispatch.begin(0);
}

fn adding(_: *core.Poller) bool {
    dispatch.add_poller(&poller) catch {};
    return false;
}

var adder: core.Poller align(@alignOf(core.Poller)) = .{ .poll = adding };

/// A poller that adds a poller while the loop walks the table. With the check deleted, the table
/// grows and the tick goes on.
fn add_a_poller_from_a_poller() void {
    dispatch = .empty;
    dispatch.add_poller(&adder) catch return;
    scenario.reached_violation();
    _ = dispatch.begin(0);
}

/// A loop that ends with a poller still added. With the check deleted, the check returns.
fn end_a_loop_with_a_poller() void {
    dispatch = .empty;
    dispatch.add_poller(&poller) catch return;
    scenario.reached_violation();
    dispatch.assert_empty();
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "dispatch: remove a poller from a poller", .run = remove_a_poller_from_a_poller },
    .{ .name = "dispatch: add a poller from a poller", .run = add_a_poller_from_a_poller },
    .{ .name = "dispatch: end a loop with a poller", .run = end_a_loop_with_a_poller },
    .{ .name = "dispatch: begin a tick inside a tick", .run = begin_a_tick_inside_a_tick },
    .{ .name = "dispatch: end a tick that never began", .run = end_a_tick_that_never_began },
    .{ .name = "dispatch: abandon a tick that never began", .run = abandon_a_tick_that_never_began },
    .{ .name = "dispatch: add one poller twice", .run = add_one_poller_twice },
    .{ .name = "dispatch: remove a poller never added", .run = remove_a_poller_never_added },
};
