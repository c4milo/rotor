//! The module `reactor` of decision 33: the optional layer over a loop of the core. A program that
//! wants records with callbacks, pollers, tasks, scheduling groups, cross-core calls or libraries
//! that share its loop makes a `Reactor(Loop)` in place of a `Loop`. A program that wants none of
//! them makes a plain loop, and its binary holds no code of this module.
//!
//! This is step 2 of decision 33: the reactor is a forwarder. Each call of the reactor makes the
//! call of the same name on the loop that it holds (`reactor_calls.zig`), and the loop still holds
//! the reactor's state. Step 3 moves that state and its code from `core` into this module.
//!
//! The module imports `core` alone (decision 1, "The module graph"). The public module exports the
//! generic as `rotor.Reactor(Loop)`, and no other name of this module.
const std = @import("std");
const core = @import("core");
const calls_module = @import("reactor_calls.zig");
const check_module = @import("reactor_check.zig");

/// A reactor over `Loop`: each backend's `Loop`, or a twin of decision 10 that declares the core's
/// surface and the port of decision 33. It holds its loop by value, and nothing else at step 2. It
/// gives out no `*Loop`: a call on the loop inside would skip the reactor's part of that call.
///
/// The build stops with one error that names each declaration `Loop` lacks
/// (`reactor_check.zig`). The compiler prints this type as `reactor.Reactor(kqueue.Loop)`, the one
/// repeat that the ruling of 2026-11-09 accepts.
pub fn Reactor(comptime Loop: type) type {
    comptime check_module.check(Loop);
    return struct {
        /// The loop that the reactor runs.
        loop: Loop,

        const calls = calls_module.Calls(@This(), Loop);

        comptime {
            // At step 2 the reactor holds the loop and nothing else, so it takes no more memory
            // than the loop, and starts at the loop's address.
            std.debug.assert(@sizeOf(@This()) == @sizeOf(Loop));
            std.debug.assert(@alignOf(@This()) == @alignOf(Loop));
            std.debug.assert(@offsetOf(@This(), "loop") == 0);
        }

        /// What `init` takes. `loop` has no default, because the loop's options name the
        /// operations it holds, which have none.
        pub const Options = struct {
            /// The loop's options. The reactor keeps nothing of them.
            loop: Loop.Options,
        };

        /// The reactor as the program hands it to a library (decision 28). `shared` returns it.
        pub const SharedLoop = core.shared_loop.SharedLoop(@This());

        /// One kind of cross-core call over this reactor's view (decision 32).
        pub fn Service(
            comptime Context: type,
            comptime Request: type,
            comptime Reply: type,
            comptime handler: fn (context: *Context, record: *CallRecord(Request, Reply)) core.call.Answer(Reply),
        ) type {
            return core.call.Service(SharedLoop, Context, Request, Reply, handler);
        }

        /// The caller's record of one call over this reactor's view (decision 32).
        pub fn CallRecord(comptime Request: type, comptime Reply: type) type {
            return core.call.CallRecord(SharedLoop, Request, Reply);
        }

        // The core's surface, each the loop's call of the same name: `reactor_calls.zig`.
        pub const memory_bytes = calls.memory_bytes;
        pub const init = calls.init;
        pub const deinit = calls.deinit;
        pub const dropped_wakes = calls.dropped_wakes;
        pub const submit = calls.submit;
        pub const cancel = calls.cancel;
        pub const post = calls.post;
        pub const tick = calls.tick;
        pub const in_flight = calls.in_flight;
        pub const now_ns = calls.now_ns;
        pub const wait_descriptor = calls.wait_descriptor;
        pub const wait_limit = calls.wait_limit;
        pub const statistics = calls.statistics;
        pub const heartbeat = calls.heartbeat;
        pub const cancel_all = calls.cancel_all;
        pub const drain = calls.drain;
        pub const assert_empty = calls.assert_empty;
        pub const register_buffers = calls.register_buffers;
        pub const register_descriptors = calls.register_descriptors;
        pub const reserve_buffer_group = calls.reserve_buffer_group;
        pub const provide_buffers = calls.provide_buffers;
        pub const provide_datagram_buffers = calls.provide_datagram_buffers;
        pub const datagram = calls.datagram;
        pub const give_back_buffer = calls.give_back_buffer;
        pub const release_buffers = calls.release_buffers;
        pub const provided_buffer = calls.provided_buffer;
        // The names that leave `rotor.Loop` at step 3: the pollers and the tasks (decisions 26
        // and 27), the scheduling groups (decision 30), the view (decision 28) and the calls
        // (decision 32).
        pub const add_poller = calls.add_poller;
        pub const remove_poller = calls.remove_poller;
        pub const schedule = calls.schedule;
        pub const is_scheduled = calls.is_scheduled;
        pub const tasks_queued = calls.tasks_queued;
        pub const task_budget_left = calls.task_budget_left;
        pub const discard_tasks = calls.discard_tasks;
        pub const schedule_in = calls.schedule_in;
        pub const charge_task = calls.charge_task;
        pub const reserve_scheduling_group = calls.reserve_scheduling_group;
        pub const set_scheduling_group_shares = calls.set_scheduling_group_shares;
        pub const shared = calls.shared;
        pub const call = calls.call;
        pub const answer = calls.answer;
        pub const serve = calls.serve;
        pub const stop_serving = calls.stop_serving;
    };
}

test {
    _ = check_module;
    _ = @import("reactor_test.zig");
}
