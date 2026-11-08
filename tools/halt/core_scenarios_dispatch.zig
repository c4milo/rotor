//! Halt scenarios for a loop that several libraries share (decisions 26 and 28). Each backend's
//! `tick`, `deinit`, `add_poller` and `remove_poller` hand their checks to `core.dispatch.Dispatch`
//! and its heartbeat, so a scenario reaches them through its own calls and enters no kernel. Split
//! from `core_scenarios.zig` for
//! the 500-line limit.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const Dispatch = core.dispatch.Dispatch;

var dispatch: Dispatch align(@alignOf(Dispatch)) = .empty;

fn polled(_: *core.Poller) core.WaitLimit {
    return .none;
}

const polled_call: core.Poller.Call = .{ .name = "polled", .function = polled };
var poller: core.Poller align(@alignOf(core.Poller)) = .{ .call = &polled_call };

/// A tick inside a tick: what a callback or a poller that calls `tick` does. With the check
/// deleted, the second `begin` returns the wait.
fn begin_a_tick_inside_a_tick() void {
    dispatch = .empty;
    _ = dispatch.begin(&heartbeat, 0);
    scenario.reached_violation();
    _ = dispatch.begin(&heartbeat, 0);
}

/// A host's `wait_limit` inside a tick: what a callback or a poller that calls it does
/// (decision 29). With the check deleted, the call returns the limit.
fn read_the_wait_limit_inside_a_tick() void {
    dispatch = .empty;
    _ = dispatch.begin(&heartbeat, 0);
    scenario.reached_violation();
    _ = dispatch.limit_between_ticks();
}

/// The end of a tick that never began. With the check deleted, `end` hands the events back.
fn end_a_tick_that_never_began() void {
    dispatch = .empty;
    scenario.reached_violation();
    _ = dispatch.end(&heartbeat, &groups, &.{});
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

fn removing(_: *core.Poller) core.WaitLimit {
    dispatch.remove_poller(&poller);
    return .none;
}

const removing_call: core.Poller.Call = .{ .name = "removing", .function = removing };
var remover: core.Poller align(@alignOf(core.Poller)) = .{ .call = &removing_call };

/// A poller that removes a poller while the loop walks the table. With the check deleted, the
/// removal shifts the table and the tick goes on.
fn remove_a_poller_from_a_poller() void {
    dispatch = .empty;
    dispatch.add_poller(&poller) catch return;
    dispatch.add_poller(&remover) catch return;
    scenario.reached_violation();
    _ = dispatch.begin(&heartbeat, 0);
}

fn adding(_: *core.Poller) core.WaitLimit {
    dispatch.add_poller(&poller) catch {};
    return .none;
}

const adding_call: core.Poller.Call = .{ .name = "adding", .function = adding };
var adder: core.Poller align(@alignOf(core.Poller)) = .{ .call = &adding_call };

/// A poller that adds a poller while the loop walks the table. With the check deleted, the table
/// grows and the tick goes on.
fn add_a_poller_from_a_poller() void {
    dispatch = .empty;
    dispatch.add_poller(&adder) catch return;
    scenario.reached_violation();
    _ = dispatch.begin(&heartbeat, 0);
}

/// A loop that ends with a poller still added. With the check deleted, the check returns.
fn end_a_loop_with_a_poller() void {
    dispatch = .empty;
    dispatch.add_poller(&poller) catch return;
    scenario.reached_violation();
    dispatch.assert_empty();
}

/// What each backend's `tick` does first: a loop with no callback outstanding takes the fast path
/// and never reaches `begin`.
fn tick_as_a_backend_does() void {
    if (dispatch.idle()) return;
    _ = dispatch.begin(&heartbeat, 0);
}

fn ticking_record(_: *core.Completion, _: core.Event) void {
    scenario.reached_violation();
    tick_as_a_backend_does();
}

const ticking_call: core.Completion.Call = .{ .name = "ticking", .function = ticking_record };
var ticking_completion: core.Completion align(@alignOf(core.Completion)) =
    .{ .call = &ticking_call };

/// The callback of the last record outstanding calls `tick`. With the count lowered before the
/// call, the loop looks idle inside it, the tick takes the fast path, and nothing halts.
fn tick_inside_the_last_record() void {
    dispatch = .empty;
    dispatch.note_submitted(1);
    _ = dispatch.begin(&heartbeat, 0);
    var events = [_]core.Event{.{
        .user_data = @intFromPtr(&ticking_completion),
        .result = 0,
        .flags = .{ .dispatched = true },
    }};
    _ = dispatch.end(&heartbeat, &groups, &events);
}

fn ending_record(_: *core.Completion, _: core.Event) void {
    scenario.reached_violation();
    dispatch.assert_empty();
}

const ending_call: core.Completion.Call = .{ .name = "ending", .function = ending_record };
var ending_completion: core.Completion align(@alignOf(core.Completion)) = .{ .call = &ending_call };

/// A record that ends the loop it runs on: what the program's own record does when it calls
/// `deinit` on its `*Loop` (decision 28). The loop has no poller and no task, so with the check
/// deleted, `assert_empty` returns and the tick goes on.
fn end_a_loop_inside_a_record() void {
    dispatch = .empty;
    dispatch.note_submitted(1);
    _ = dispatch.begin(&heartbeat, 0);
    var events = [_]core.Event{.{
        .user_data = @intFromPtr(&ending_completion),
        .result = 0,
        .flags = .{ .dispatched = true },
    }};
    _ = dispatch.end(&heartbeat, &groups, &events);
}

var heartbeat: core.Heartbeat align(@alignOf(core.Heartbeat)) = .init(null);
/// The loop's groups (decision 30). No scenario here queues a task in a group other than
/// `.default`, so `end` never reads them.
var groups: core.scheduling.Groups align(@alignOf(core.scheduling.Groups)) = undefined;

/// A loop that ends while a watch reads its heartbeat (decision 28). With the check deleted, the
/// check returns.
fn end_a_loop_that_a_watch_reads() void {
    heartbeat = .init(null);
    _ = core.stall_watch.view_of(&heartbeat).watch();
    scenario.reached_violation();
    heartbeat.assert_unwatched();
}

/// A watch that ends twice: the count of watchers would wrap, and a `deinit` would pass while the
/// first watch still reads. With the check deleted, the count wraps and the call returns.
fn end_one_watch_twice() void {
    heartbeat = .init(null);
    var watch = core.stall_watch.view_of(&heartbeat).watch();
    watch.end();
    scenario.reached_violation();
    watch.end();
}

/// A threshold of 0 ns: every turn would be a stall, a wait included, because a wait spans 0 ns.
/// With the check deleted, the heartbeat is made and the call returns.
fn count_stalls_from_a_threshold_of_nothing() void {
    scenario.reached_violation();
    heartbeat = .init(0);
}

/// A clock stamp after a wait that is the value the heartbeat keeps for a wait: a watch would
/// take the open turn for a wait. With the check deleted, the stamp is stored and the call returns.
fn wake_at_the_stamp_of_a_wait() void {
    heartbeat = .init(null);
    scenario.reached_violation();
    heartbeat.note_woken(core.stall.asleep);
}

/// One watch more than the count holds: the count would wrap to 0, and a `deinit` would pass while
/// every watch still reads. With the check deleted, the count wraps and the call returns.
fn watch_a_heartbeat_whose_count_is_full() void {
    heartbeat = .init(null);
    heartbeat.watchers.store(std.math.maxInt(u32), .release);
    scenario.reached_violation();
    _ = core.stall_watch.view_of(&heartbeat).watch();
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "dispatch: end a loop inside a record", .run = end_a_loop_inside_a_record },
    .{
        .name = "heartbeat: count stalls from a threshold of 0 ns",
        .run = count_stalls_from_a_threshold_of_nothing,
    },
    .{ .name = "heartbeat: wake at the stamp of a wait", .run = wake_at_the_stamp_of_a_wait },
    .{
        .name = "heartbeat: watch a heartbeat whose count is full",
        .run = watch_a_heartbeat_whose_count_is_full,
    },
    .{ .name = "heartbeat: end a loop that a watch reads", .run = end_a_loop_that_a_watch_reads },
    .{ .name = "heartbeat: end one watch twice", .run = end_one_watch_twice },
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
