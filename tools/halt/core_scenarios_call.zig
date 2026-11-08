//! Halt scenarios for the caller's side of the cross-core call of decision 32: `core.call`. Each
//! reaches its check through the function's own parameters, or through a state that the scenario
//! sets by hand, and enters no kernel. With the check deleted, each scenario returns, and says how.
//! `core_scenarios_call_take.zig` holds the target's side and the drain.
const core = @import("core");
const scenario = @import("scenario.zig");

const call = core.call;
const CallLink = call.CallLink;
const CallStation = call.CallStation;
const Dispatch = core.dispatch.Dispatch;
const Groups = core.scheduling.Groups;
const Registry = core.mailbox.Registry;
const Task = core.Task;

fn ran(_: *Task) void {}

/// A `finish` entry, and the entry of a service, written by hand.
pub const finish_call: Task.Call = .{ .name = "finish", .function = ran, .call_record = true };
pub const entry_call: Task.Call = .{ .name = "entry", .function = ran, .call_record = true };

const loops = 2;
pub var registry_memory: [Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) = undefined;
pub var registry: Registry align(@alignOf(Registry)) = undefined;
pub var stations: [core.constants.loops_max]CallStation align(@alignOf(CallStation)) = undefined;
pub var dispatch: Dispatch align(@alignOf(Dispatch)) = .empty;
pub var groups: Groups align(@alignOf(Groups)) = undefined;
pub var link: CallLink align(@alignOf(CallLink)) = undefined;
pub var count: u32 = 0;

/// Two loops on a registry, both of whose stations serve, and an idle link.
pub fn start() void {
    registry.init(&registry_memory, loops);
    registry.set(0, 100);
    registry.set(1, 101);
    stations = @splat(CallStation.unused);
    stations[0].state = .serving;
    stations[1].state = .serving;
    dispatch = .empty;
    groups.init(&.empty);
    link = .idle(&finish_call);
}

/// A link that `prepare` wrote for a call from loop 0 to loop 1.
pub fn prepared(group: core.NamedSchedulingGroup) void {
    start();
    link.prepare(&stations, &entry_call, 1, .{ .group = group });
}

/// With the check deleted, `prepare` writes the link again and returns.
fn send_a_record_that_is_out() void {
    prepared(.default);
    scenario.reached_violation();
    link.prepare(&stations, &entry_call, 1, .{ .group = .default });
}

/// A link that `prepare` wrote, and that is idle again. With the check deleted, the call is pushed
/// and `call` returns.
fn call_with_a_link_that_prepare_did_not_write() void {
    prepared(.default);
    link.state = .idle;
    scenario.reached_violation();
    _ = call.call(&registry, 0, &dispatch, &groups, &link) catch return;
}

/// A forged id above the caller's named groups, which are none. With the check deleted, the call
/// is pushed and `call` returns.
fn call_with_a_forged_group_id() void {
    prepared(@enumFromInt(1));
    scenario.reached_violation();
    _ = call.call(&registry, 0, &dispatch, &groups, &link) catch return;
}

/// With the check deleted, the call is pushed into a ring of shared memory and `call` returns.
fn call_in_a_registry_of_a_group() void {
    prepared(.default);
    registry.group = true;
    scenario.reached_violation();
    _ = call.call(&registry, 0, &dispatch, &groups, &link) catch return;
}

/// A call to self on a loop whose station never served. With the check deleted, the call's task
/// is queued and `call` returns.
fn call_self_on_a_station_that_never_served() void {
    start();
    stations[0].state = .unused;
    link.prepare(&stations, &entry_call, 0, .{ .group = .default });
    scenario.reached_violation();
    _ = call.call(&registry, 0, &dispatch, &groups, &link) catch return;
}

/// A loop that holds `services_max` stations already. With the check deleted, `serve` counts one
/// more and returns.
fn serve_more_services_than_the_limit() void {
    start();
    groups.stations = core.constants.services_max;
    stations[0].state = .unused;
    scenario.reached_violation();
    _ = call.serve(&registry, 0, &groups, &stations);
}

/// With the check deleted, `serve` serves again and returns.
fn serve_a_station_that_serves() void {
    start();
    scenario.reached_violation();
    _ = call.serve(&registry, 0, &groups, &stations);
}

/// With the check deleted, `serve` serves in shared memory and returns.
fn serve_in_a_registry_of_a_group() void {
    start();
    stations[0].state = .unused;
    registry.group = true;
    scenario.reached_violation();
    _ = call.serve(&registry, 0, &groups, &stations);
}

/// With the check deleted, the station stops twice, the count of serving stations falls to 0, and
/// `stop_serving` returns.
fn stop_a_station_that_does_not_serve() void {
    start();
    stations[0].state = .stopped;
    groups.serving = 1;
    scenario.reached_violation();
    call.stop_serving(0, &groups, &stations);
}

/// A station that serves while the loop counts none. With the check deleted, the count wraps, and
/// `stop_serving` returns.
fn stop_serving_with_no_station_counted() void {
    start();
    groups.serving = 0;
    scenario.reached_violation();
    call.stop_serving(0, &groups, &stations);
}

/// The caller's task of a link that is not back. With the check deleted, the count falls and
/// `end_call` returns.
fn end_a_call_that_is_not_back() void {
    prepared(.default);
    count = 1;
    link.calls_out = &count;
    scenario.reached_violation();
    _ = call.end_call(&link);
}

/// A made-up record whose count is 0. With the check deleted, the count wraps, and `end_call`
/// returns.
fn end_a_call_whose_count_is_zero() void {
    prepared(.default);
    link.state = .back;
    count = 0;
    link.calls_out = &count;
    scenario.reached_violation();
    _ = call.end_call(&link);
}

/// `discard_tasks` with a call's task queued in `.default`. With the check deleted, the task is
/// unlinked and the discard returns.
fn discard_a_queued_task_of_a_call() void {
    prepared(.default);
    link.state = .held;
    call.take.schedule_link(&dispatch, &groups, &link);
    scenario.reached_violation();
    _ = dispatch.discard_tasks(&groups);
}

/// The same, with the task in a group other than `.default`. With the check deleted, the lane is
/// emptied and the discard returns.
fn discard_a_task_of_a_call_in_a_group() void {
    start();
    groups.init(&core.scheduling.Named(.{ .low = 100 }).table);
    link.prepare(&stations, &entry_call, 1, .{ .group = @enumFromInt(1) });
    link.state = .held;
    call.take.schedule_link(&dispatch, &groups, &link);
    scenario.reached_violation();
    _ = dispatch.discard_tasks(&groups);
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "call: send a record that is out", .run = send_a_record_that_is_out },
    .{ .name = "call: call with a link that prepare did not write", .run = call_with_a_link_that_prepare_did_not_write },
    .{ .name = "call: call with a forged group id", .run = call_with_a_forged_group_id },
    .{ .name = "call: call in a registry of a group", .run = call_in_a_registry_of_a_group },
    .{ .name = "call: call self on a station that never served", .run = call_self_on_a_station_that_never_served },
    .{ .name = "call: serve more services than the limit", .run = serve_more_services_than_the_limit },
    .{ .name = "call: serve a station that serves", .run = serve_a_station_that_serves },
    .{ .name = "call: serve in a registry of a group", .run = serve_in_a_registry_of_a_group },
    .{ .name = "call: stop a station that does not serve", .run = stop_a_station_that_does_not_serve },
    .{ .name = "call: stop serving with no station counted", .run = stop_serving_with_no_station_counted },
    .{ .name = "call: end a call that is not back", .run = end_a_call_that_is_not_back },
    .{ .name = "call: end a call whose count is zero", .run = end_a_call_whose_count_is_zero },
    .{ .name = "call: discard a queued task of a call", .run = discard_a_queued_task_of_a_call },
    .{ .name = "call: discard a task of a call in a group", .run = discard_a_task_of_a_call_in_a_group },
} ++ @import("core_scenarios_call_take.zig").scenarios;
