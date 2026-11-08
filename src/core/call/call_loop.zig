//! The calls of decision 32 that every backend's `Loop` exports, written once: `call`, `answer`,
//! `serve` and `stop_serving`. Only `Service` and `CallRecord` call them. `Loop` has a
//! `tables: Tables` field and an `inbox: Inbox` field, and a `wake_target` function that makes
//! the backend's own wake of a loop that sleeps, as its `post` does.
const std = @import("std");
const constants = @import("../constants.zig");
const call_module = @import("call.zig");
const call_take = @import("call_take.zig");

const CallError = call_module.CallError;
const CallLink = call_module.CallLink;
const CallStation = call_module.CallStation;

pub fn Calls(comptime Loop: type) type {
    return struct {
        /// Sends the call of `link`, which `CallLink.prepare` wrote (decision 32). Each call checks
        /// that the loop's own thread makes it (decision 8, class B).
        pub fn call(loop: *Loop, link: *CallLink) CallError!void {
            loop.tables.assert_owner();
            const tables = &loop.tables;
            const wake = try call_module.call(loop.inbox.registry, tables.id, &tables.dispatch, tables.groups, link);
            const descriptor = wake orelse return;
            loop.wake_target(link.target, descriptor);
        }

        /// Answers the call of `link`, which this loop holds, with the outcome the link holds.
        pub fn answer(loop: *Loop, link: *CallLink) void {
            loop.tables.assert_owner();
            const tables = &loop.tables;
            // The answer pushes the return, so the origin is read first.
            const origin = link.origin;
            const wake = call_take.answer(loop.inbox.registry, tables.id, &tables.dispatch, tables.groups, link);
            const descriptor = wake orelse return;
            loop.wake_target(origin, descriptor);
        }

        /// This loop serves the service of `stations`, and returns its station.
        pub fn serve(loop: *Loop, stations: *[constants.loops_max]CallStation) *CallStation {
            loop.tables.assert_owner();
            return call_module.serve(loop.inbox.registry, loop.tables.id, loop.tables.groups, stations);
        }

        /// This loop stops the service of `stations`.
        pub fn stop_serving(loop: *Loop, stations: *[constants.loops_max]CallStation) void {
            loop.tables.assert_owner();
            call_module.stop_serving(loop.tables.id, loop.tables.groups, stations);
        }

        /// The callbacks that the loop still owes: operations with a record, tasks queued, calls out
        /// and calls held. `drain` ticks until it is 0 (decision 32).
        pub fn callbacks_outstanding(loop: *const Loop) u32 {
            loop.tables.assert_owner();
            return loop.tables.dispatch.callbacks_outstanding;
        }
    };
}
