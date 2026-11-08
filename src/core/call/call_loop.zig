//! The calls of decision 32 that every backend's `Loop` exports, written once: `call`, `answer`,
//! `serve` and `stop_serving`. Only `Service` and `CallRecord` call them. `Loop` has a
//! `tables: Tables` field and an `inbox: Inbox` field, and a `wake_target` function that makes
//! the backend's own wake of a loop that sleeps, as its `post` does.
const std = @import("std");
const constants = @import("../constants.zig");
const call_module = @import("call.zig");
const call_take = @import("call_take.zig");
const event = @import("../event.zig");
const inbox_module = @import("../inbox.zig");
const operation = @import("../operation.zig");

const CallError = call_module.CallError;
const CallLink = call_module.CallLink;
const CallStation = call_module.CallStation;
const Descriptor = operation.Descriptor;
const Event = event.Event;
const Inbox = inbox_module.Inbox;
const LoopId = operation.LoopId;

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

        /// The slow path of the loop's drain (`Inbox.TakeReserved`): `Inbox.take_reserved` with the
        /// loop's dispatch, groups and wake. A backend calls it from its own `take_reserved`, which
        /// keeps it out of the tick (decision 7).
        pub fn take_reserved(inbox: *Inbox, receiver: LoopId, events: []Event, first: LoopId, written: u32) u32 {
            const loop: *Loop = @alignCast(@fieldParentPtr("inbox", inbox));
            const tables = &loop.tables;
            const waker: call_take.Waker = .{ .context = loop, .wake = wake_erased };
            return inbox_module.take_reserved(inbox, receiver, events, first, written, &tables.dispatch, tables.groups, waker);
        }

        /// `wake_target`, through a `Waker`'s context.
        fn wake_erased(context: *anyopaque, target: LoopId, descriptor: Descriptor) void {
            const loop: *Loop = @ptrCast(@alignCast(context));
            loop.wake_target(target, descriptor);
        }

        /// The callbacks that the loop still owes: operations with a record, tasks queued, calls out
        /// and calls held. `drain` ticks until it is 0 (decision 32).
        pub fn callbacks_outstanding(loop: *const Loop) u32 {
            loop.tables.assert_owner();
            return loop.tables.dispatch.callbacks_outstanding;
        }
    };
}
