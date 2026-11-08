//! The owner checks of the cross-core call of decision 32, which `core.call.loop.Calls` makes for
//! every backend: `call`, `answer`, `serve` and `stop_serving` from a thread that does not own the
//! loop. Each backend's owner file adds these four scenarios for its own `Loop`.
//!
//! The loop calls itself, so no registry and no kernel is needed. With its owner check deleted,
//! each call returns: `call` queues the call's task, `answer` queues it again, `serve` returns the
//! station and `stop_serving` stops it.
const std = @import("std");
const core = @import("core");
const scenario = @import("scenario.zig");

const CallLink = core.call.CallLink;
const CallStation = core.call.CallStation;
const Task = core.Task;

fn ran(_: *Task) void {}

const finish_call: Task.Call = .{ .name = "finish", .function = ran, .call_record = true };
const entry_call: Task.Call = .{ .name = "entry", .function = ran, .call_record = true };

/// The scenarios for a backend's `Loop`. `start` sets up `loop` on the main thread, with tables,
/// no kernel and the id `id`.
pub fn Scenarios(comptime Loop: type, comptime loop: *Loop, comptime start: fn () void, comptime id: core.LoopId) type {
    return struct {
        var stations: [core.constants.loops_max]CallStation align(@alignOf(CallStation)) = undefined;
        var link: CallLink align(@alignOf(CallLink)) = undefined;

        fn on_another_thread(comptime call: fn () void) void {
            const thread = std.Thread.spawn(.{}, call, .{}) catch return;
            thread.join();
        }

        /// The loop serves, and the link is ready for a call to self.
        fn begin(serving: bool) void {
            start();
            stations = @splat(CallStation.unused);
            if (serving) _ = loop.serve(&stations);
            link = .idle(&finish_call);
            link.prepare(&stations, &entry_call, id, .{ .group = .default });
        }

        fn call_from_another_thread() void {
            begin(true);
            on_another_thread(call_on_this_thread);
        }

        fn call_on_this_thread() void {
            scenario.reached_violation();
            loop.call(&link) catch {};
        }

        fn answer_from_another_thread() void {
            begin(true);
            loop.call(&link) catch return;
            // The run of the call's task unlinks it, as the tick's run does.
            _ = loop.tables.dispatch.tasks.pop();
            on_another_thread(answer_on_this_thread);
        }

        fn answer_on_this_thread() void {
            scenario.reached_violation();
            loop.answer(&link);
        }

        fn serve_from_another_thread() void {
            begin(false);
            on_another_thread(serve_on_this_thread);
        }

        fn serve_on_this_thread() void {
            scenario.reached_violation();
            _ = loop.serve(&stations);
        }

        fn stop_serving_from_another_thread() void {
            begin(true);
            on_another_thread(stop_serving_on_this_thread);
        }

        fn stop_serving_on_this_thread() void {
            scenario.reached_violation();
            loop.stop_serving(&stations);
        }

        pub const scenarios = [_]scenario.Scenario{
            .{ .name = "owner: call from another thread", .run = call_from_another_thread },
            .{ .name = "owner: answer from another thread", .run = answer_from_another_thread },
            .{ .name = "owner: serve from another thread", .run = serve_from_another_thread },
            .{ .name = "owner: stop serving from another thread", .run = stop_serving_from_another_thread },
        };
    };
}
