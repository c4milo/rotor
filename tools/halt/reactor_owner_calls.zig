//! The owner checks of the reactor's own calls (decisions 27, 28, 30, 32 and 33), from a thread
//! that does not own the loop under the reactor: `schedule`, `schedule_in`, `charge_task`,
//! `reserve_scheduling_group`, `set_scheduling_group_shares`, `shared`, `call`, `answer`, `serve`
//! and `stop_serving`. Each makes the check through the port's `assert_owner` of the backend's
//! `Loop`. Each backend's owner file adds these scenarios for its own `Loop`, so a scenario that
//! deletes the check of one backend fails there.
//!
//! The reactor is started by hand over the loop's tables, with no kernel, and calls itself, so no
//! registry is needed. With its owner check deleted, each call returns.
const std = @import("std");
const core = @import("core");
const reactor_module = @import("reactor");
const scenario = @import("scenario.zig");

const CallLink = reactor_module.CallLink;
const CallStation = reactor_module.CallStation;
const Task = reactor_module.Task;

fn ran(_: *Task) void {}

const finish_call: Task.Call = .{ .name = "finish", .function = ran, .call_record = true };
const entry_call: Task.Call = .{ .name = "entry", .function = ran, .call_record = true };
const ran_call: Task.Call = .{ .name = "ran", .function = ran };

const NamedTable = reactor_module.scheduling.NamedTable;

/// One named group, id 1, at the default shares.
const one_named: NamedTable = table: {
    var table = NamedTable.empty;
    table.count = 1;
    table.shares[0] = reactor_module.constants.scheduling_shares_default;
    break :table table;
};

/// The scenarios for a reactor over a backend's `Loop` with `options`, which name the loop's id.
pub fn Scenarios(comptime Loop: type, comptime options: Loop.Options) type {
    const Reactor = reactor_module.Reactor(Loop);
    return struct {
        var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
        var groups: reactor_module.Groups align(@alignOf(reactor_module.Groups)) = undefined;
        var reactor: Reactor align(@alignOf(Reactor)) = undefined;
        var stations: [core.constants.loops_max]CallStation align(@alignOf(CallStation)) = undefined;
        var link: CallLink align(@alignOf(CallLink)) = undefined;
        var task: Task align(@alignOf(Task)) = .{ .call = &ran_call };

        fn on_another_thread(comptime call: fn () void) void {
            const thread = std.Thread.spawn(.{}, call, .{}) catch return;
            thread.join();
        }

        /// The group that `schedule_in_on_this_thread` names.
        var group: core.SchedulingGroup align(@alignOf(core.SchedulingGroup)) = .default;

        /// The reactor over the loop's tables, with no kernel, started on the main thread.
        fn start() void {
            start_named(&.empty);
        }

        /// As `start`, with the named groups of `named` reserved as ids 1 to n.
        fn start_named(named: *const NamedTable) void {
            reactor.loop.init_tables(&memory, &options);
            reactor.dispatch.start(&groups, .{ .id = options.id, .in_group = false, .named_groups = named });
            task = .{ .call = &ran_call };
        }

        /// The reactor serves, and the link is ready for a call to self.
        fn begin(serving: bool) void {
            start();
            stations = @splat(CallStation.unused);
            if (serving) _ = reactor.serve(&stations);
            link = .idle(&finish_call);
            link.prepare(&stations, &entry_call, options.id, .{ .group = .default });
        }

        fn schedule_from_another_thread() void {
            start();
            on_another_thread(schedule_on_this_thread);
        }

        fn schedule_on_this_thread() void {
            scenario.reached_violation();
            reactor.schedule(&task) catch {};
        }

        fn schedule_in_from_another_thread() void {
            start();
            on_another_thread(schedule_in_on_this_thread);
        }

        fn schedule_in_on_this_thread() void {
            scenario.reached_violation();
            reactor.schedule_in(group, &task) catch {};
        }

        /// A group other than `.default` takes a path with no call of `schedule`. So only the check
        /// at the start of `schedule_in` halts this call.
        fn schedule_in_named_from_another_thread() void {
            start_named(&one_named);
            group = @enumFromInt(1);
            on_another_thread(schedule_in_on_this_thread);
        }

        /// While the loop's own thread is in a task's call: `tasks.left` is above 0 only there.
        fn charge_from_another_thread() void {
            start();
            reactor.dispatch.tasks.left = 1;
            on_another_thread(charge_on_this_thread);
        }

        fn charge_on_this_thread() void {
            scenario.reached_violation();
            reactor.charge_task(1);
        }

        fn reserve_from_another_thread() void {
            start();
            on_another_thread(reserve_on_this_thread);
        }

        fn reserve_on_this_thread() void {
            scenario.reached_violation();
            _ = reactor.reserve_scheduling_group(reactor_module.constants.scheduling_shares_default) catch {};
        }

        fn set_shares_from_another_thread() void {
            start();
            on_another_thread(set_shares_on_this_thread);
        }

        fn set_shares_on_this_thread() void {
            scenario.reached_violation();
            reactor.set_scheduling_group_shares(.default, reactor_module.constants.scheduling_shares_default);
        }

        fn shared_from_another_thread() void {
            start();
            on_another_thread(shared_on_this_thread);
        }

        fn shared_on_this_thread() void {
            scenario.reached_violation();
            _ = reactor.shared();
        }

        fn call_from_another_thread() void {
            begin(true);
            on_another_thread(call_on_this_thread);
        }

        fn call_on_this_thread() void {
            scenario.reached_violation();
            reactor.call(&link) catch {};
        }

        fn answer_from_another_thread() void {
            begin(true);
            reactor.call(&link) catch return;
            // The run of the call's task unlinks it, as the tick's run does.
            _ = reactor.dispatch.tasks.pop();
            on_another_thread(answer_on_this_thread);
        }

        fn answer_on_this_thread() void {
            scenario.reached_violation();
            reactor.answer(&link);
        }

        fn serve_from_another_thread() void {
            begin(false);
            on_another_thread(serve_on_this_thread);
        }

        fn serve_on_this_thread() void {
            scenario.reached_violation();
            _ = reactor.serve(&stations);
        }

        fn stop_serving_from_another_thread() void {
            begin(true);
            on_another_thread(stop_serving_on_this_thread);
        }

        fn stop_serving_on_this_thread() void {
            scenario.reached_violation();
            reactor.stop_serving(&stations);
        }

        pub const scenarios = [_]scenario.Scenario{
            .{ .name = "owner: schedule a task from another thread", .run = schedule_from_another_thread },
            .{ .name = "owner: schedule in a group from another thread", .run = schedule_in_from_another_thread },
            .{ .name = "owner: schedule in a named group from another thread", .run = schedule_in_named_from_another_thread },
            .{ .name = "owner: charge a task from another thread", .run = charge_from_another_thread },
            .{ .name = "owner: reserve a scheduling group from another thread", .run = reserve_from_another_thread },
            .{ .name = "owner: set the shares of a group from another thread", .run = set_shares_from_another_thread },
            .{ .name = "owner: hand out the view from another thread", .run = shared_from_another_thread },
            .{ .name = "owner: call from another thread", .run = call_from_another_thread },
            .{ .name = "owner: answer from another thread", .run = answer_from_another_thread },
            .{ .name = "owner: serve from another thread", .run = serve_from_another_thread },
            .{ .name = "owner: stop serving from another thread", .run = stop_serving_from_another_thread },
        };
    };
}
