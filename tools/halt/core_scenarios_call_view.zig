//! Halt scenarios for the checks of the cross-core call (decision 32) that the review of
//! 2026-11-08 added: the count of a station in its loop's groups. Each reaches its check through
//! the function's own parameters, or through a state that the scenario sets by hand. With the
//! check deleted, each scenario returns, and says how.
const core = @import("core");
const scenario = @import("scenario.zig");
const fixture = @import("core_scenarios_call.zig");

const call = core.call;
const CallStation = call.CallStation;
const Groups = core.scheduling.Groups;

/// The groups of a loop that ended, which a station may still name.
var other_groups: Groups align(@alignOf(Groups)) = undefined;

/// A station that the groups of another loop count. With the check deleted, `serve` counts nothing
/// and returns.
fn serve_a_station_that_another_loop_counts() void {
    fixture.start();
    fixture.stations[0].state = .unused;
    other_groups.init(&.empty);
    fixture.stations[0].attached = &other_groups;
    scenario.reached_violation();
    _ = call.serve(&fixture.registry, 0, &fixture.groups, &fixture.stations);
}

/// A station that its groups count, while they count none. With the check deleted, the count
/// wraps, and `stop_serving` returns.
fn stop_a_station_that_its_groups_do_not_count() void {
    fixture.start();
    fixture.groups.serving = 1;
    fixture.stations[0].attached = &fixture.groups;
    fixture.groups.stations = 0;
    scenario.reached_violation();
    call.stop_serving(0, &fixture.groups, &fixture.stations);
}

/// A loop that ends while its groups count a station. With the check deleted, the loop ends with
/// a station that names its groups.
fn end_a_loop_that_counts_a_station() void {
    fixture.start();
    fixture.groups.stations = 1;
    scenario.reached_violation();
    core.Tables.assert_calls_ended(&fixture.dispatch, &fixture.groups, false);
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "call: serve a station that another loop counts", .run = serve_a_station_that_another_loop_counts },
    .{ .name = "call: stop a station that its groups do not count", .run = stop_a_station_that_its_groups_do_not_count },
    .{ .name = "call: end a loop that counts a station", .run = end_a_loop_that_counts_a_station },
};
