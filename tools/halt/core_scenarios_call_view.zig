//! Halt scenarios for the checks of the cross-core call (decision 32) that the review of
//! 2026-11-08 added: the count of a station in its loop's groups, the typed `Service` and
//! `CallRecord` over a made-up view, the record's task, and the slow path of the drain. Each
//! reaches its check through the function's own parameters, or through a state that the scenario
//! sets by hand. With the check deleted, each scenario returns, and says how.
const core = @import("core");
const scenario = @import("scenario.zig");
const fixture = @import("core_scenarios_call.zig");

const call = core.call;
const take = call.take;
const CallStation = call.CallStation;
const Groups = core.scheduling.Groups;
const LoopId = core.LoopId;
const Task = core.Task;
const constants = core.constants;
const loops_max = constants.loops_max;

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

fn ran(_: *Task) void {}

/// A `finish` entry that does not mark a call's task, which `CallRecord.init` never writes.
const plain_finish: Task.Call = .{ .name = "plain", .function = ran };

/// A call to self whose `finish` entry does not mark a call's task, so `discard_tasks` would not
/// halt on it. With the check deleted, the task is queued and the answer returns.
fn answer_a_call_whose_finish_is_not_a_call() void {
    fixture.start();
    fixture.link = .idle(&plain_finish);
    fixture.link.prepare(&fixture.stations, &fixture.entry_call, 0, .{ .group = .default });
    fixture.link.origin = 0;
    fixture.link.state = .held;
    fixture.stations[0].held = 1;
    fixture.dispatch.callbacks_outstanding = call.self_call_callbacks;
    scenario.reached_violation();
    _ = take.answer(null, 0, &fixture.dispatch, &fixture.groups, &fixture.link);
}

/// The task of a call that is out, which the target owns. With the check deleted, the caller
/// queues the task and `schedule_link` returns.
fn schedule_the_task_of_a_call_that_is_out() void {
    fixture.prepared(.default);
    scenario.reached_violation();
    take.schedule_link(&fixture.dispatch, &fixture.groups, &fixture.link);
}

/// A slow path that names the receiver as the ring's sender, with a message in the ring from loop 1
/// to itself, which no loop pushes. With the check deleted, the drain skips that ring, finds the
/// other ring empty, and returns.
fn take_the_reserved_tags_of_the_receiver() void {
    fixture.start();
    _ = fixture.registry.mailbox(1, 1).push(.{ .payload = 0, .tag = 1 });
    var inbox = core.inbox.Inbox.init(&fixture.registry, &.{}, null);
    var events: [4]core.Event = undefined;
    scenario.reached_violation();
    _ = core.inbox.take_reserved(&inbox, 1, &events, 1, 0, &fixture.dispatch, &fixture.groups, null);
}

/// A slow path that names a ring that holds nothing. With the check deleted, the drain finds the
/// ring empty and returns.
fn take_the_reserved_tags_of_an_empty_ring() void {
    fixture.start();
    var inbox = core.inbox.Inbox.init(&fixture.registry, &.{}, null);
    var events: [4]core.Event = undefined;
    scenario.reached_violation();
    _ = core.inbox.take_reserved(&inbox, 1, &events, 0, 0, &fixture.dispatch, &fixture.groups, null);
}

/// A wake of the loop that makes it. With the check deleted, the check returns.
fn wake_the_loop_that_makes_the_call() void {
    scenario.reached_violation();
    call.loop.assert_wake(3, 3, 7);
}

/// A wake through a descriptor that names no loop. With the check deleted, the check returns.
fn wake_through_no_descriptor() void {
    scenario.reached_violation();
    call.loop.assert_wake(3, 4, -1);
}

/// A made-up view: what its `serve` returns, and whether its `is_scheduled` reads true. Its
/// `answer` and `call` do nothing.
const View = struct {
    station: *CallStation,
    scheduled: bool,

    pub fn serve(view: *View, _: *[loops_max]CallStation) *CallStation {
        return view.station;
    }
    pub fn stop_serving(_: *View, _: *[loops_max]CallStation) void {}
    pub fn call(_: *View, _: *core.call.CallLink) core.call.CallError!void {}
    pub fn answer(_: *View, _: *core.call.CallLink) void {}
    pub fn now_ns(_: *const View) u64 {
        return 0;
    }
    pub fn is_scheduled(view: *const View, _: *const Task) bool {
        return view.scheduled;
    }
};

const Context = struct {
    fn handle(_: *Context, _: *call.CallRecord(View, u64, u64)) call.Answer(u64) {
        return .{ .now = 0 };
    }
};
const Echo = call.Service(View, Context, u64, u64, Context.handle);
var service: Echo align(@alignOf(Echo)) = undefined;
var context: Context align(@alignOf(Context)) = .{};
var lone_station: CallStation align(@alignOf(CallStation)) = undefined;

/// A view whose `serve` hands back a station that does not serve. With the check deleted,
/// `Service.serve` writes it and returns.
fn serve_through_a_view_that_returns_a_station_that_does_not_serve() void {
    service = .init;
    var view: View = .{ .station = &service.stations[0], .scheduled = false };
    scenario.reached_violation();
    service.serve(&view, &context);
}

/// A view whose `serve` hands back a station of no service of this type. With the check deleted,
/// `Service.serve` writes it and returns.
fn serve_through_a_view_that_returns_a_station_of_another_service() void {
    service = .init;
    lone_station = .unused;
    lone_station.state = .serving;
    var view: View = .{ .station = &lone_station, .scheduled = false };
    scenario.reached_violation();
    service.serve(&view, &context);
}

/// A send to an id that no loop may hold. With the check deleted, the link names it and the view's
/// `call` returns.
fn send_to_an_id_past_the_loops() void {
    service = .init;
    var view: View = .{ .station = &service.stations[0], .scheduled = false };
    var record: Echo.Call = .{ .link = .idle(&fixture.finish_call), .request = 0, .reply = 0 };
    scenario.reached_violation();
    service.send(&view, loops_max, &record, &@as(u64, 1), .{ .group = .default }) catch return;
}

/// The service's entry run by the task of another entry: a held call to a stopped station. With the
/// check deleted, the run answers `target_stopped` through the view and returns.
fn run_the_entry_of_a_service_with_another_task() void {
    service = .init;
    service.stations[1].state = .stopped;
    var view: View = .{ .station = &service.stations[1], .scheduled = false };
    service.stations[1].loop = &view;
    var record: Echo.Call = .{ .link = .idle(&fixture.finish_call), .request = 0, .reply = 0 };
    record.link.prepare(&service.stations, &fixture.entry_call, 1, .{ .group = .default });
    record.link.state = .held;
    scenario.reached_violation();
    Echo.entry.function(&record.link.task);
}

/// An answer through a view whose loop still queues the call's task. With the check deleted, the
/// view's `answer` returns.
fn answer_a_record_whose_task_is_queued() void {
    var view: View = .{ .station = &lone_station, .scheduled = true };
    var record: Echo.Call = .{ .link = .idle(&fixture.finish_call), .request = 0, .reply = 0 };
    record.link.state = .held;
    scenario.reached_violation();
    record.answer(&view, &@as(u64, 1));
}

/// An answer to a record that its loop does not hold. With the check deleted, the reply is written
/// and the view's `answer` returns.
fn answer_a_record_that_is_not_held() void {
    var view: View = .{ .station = &lone_station, .scheduled = false };
    var record: Echo.Call = .{ .link = .idle(&fixture.finish_call), .request = 0, .reply = 0 };
    scenario.reached_violation();
    record.answer(&view, &@as(u64, 1));
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "call: serve a station that another loop counts", .run = serve_a_station_that_another_loop_counts },
    .{ .name = "call: stop a station that its groups do not count", .run = stop_a_station_that_its_groups_do_not_count },
    .{ .name = "call: end a loop that counts a station", .run = end_a_loop_that_counts_a_station },
    .{ .name = "call: answer a call whose finish is not a call", .run = answer_a_call_whose_finish_is_not_a_call },
    .{ .name = "call: schedule the task of a call that is out", .run = schedule_the_task_of_a_call_that_is_out },
    .{ .name = "call: take the reserved tags of the receiver", .run = take_the_reserved_tags_of_the_receiver },
    .{ .name = "call: take the reserved tags of an empty ring", .run = take_the_reserved_tags_of_an_empty_ring },
    .{ .name = "call: wake the loop that makes the call", .run = wake_the_loop_that_makes_the_call },
    .{ .name = "call: wake through no descriptor", .run = wake_through_no_descriptor },
    .{
        .name = "call: serve through a view that returns a station that does not serve",
        .run = serve_through_a_view_that_returns_a_station_that_does_not_serve,
    },
    .{
        .name = "call: serve through a view that returns a station of another service",
        .run = serve_through_a_view_that_returns_a_station_of_another_service,
    },
    .{ .name = "call: send to an id past the loops", .run = send_to_an_id_past_the_loops },
    .{
        .name = "call: run the entry of a service with another task",
        .run = run_the_entry_of_a_service_with_another_task,
    },
    .{ .name = "call: answer a record whose task is queued", .run = answer_a_record_whose_task_is_queued },
    .{ .name = "call: answer a record that is not held", .run = answer_a_record_that_is_not_held },
};
