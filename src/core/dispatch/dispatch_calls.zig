//! The calls of decisions 26 to 29 that every backend's `Loop` exports, written once: the
//! pollers, the tasks, the view a library holds, and the heartbeat. Split from `dispatch.zig` for
//! the 500-line limit.
const dispatch_module = @import("dispatch.zig");
const stall_watch = @import("../stall_watch.zig");
const HeartbeatView = stall_watch.HeartbeatView;
const SharedLoop = @import("../shared_loop.zig").SharedLoop;
const tasks_module = @import("../tasks.zig");

const AddPollerError = dispatch_module.AddPollerError;
const Poller = dispatch_module.Poller;
const WaitLimit = dispatch_module.WaitLimit;
const ScheduleError = tasks_module.ScheduleError;
const Task = tasks_module.Task;

/// The calls of decisions 26 to 29 that every backend's `Loop` exports, written once. `Loop` has
/// a `tables: Tables` field, an `inbox: Inbox` field and a `kept_error` field, a `tick_error.Kept`.
/// Each call checks that the loop's own thread makes it (decision 8, class B).
pub fn Calls(comptime Loop: type) type {
    return struct {
        /// Adds `poller`, which the loop calls once in each tick (decision 26).
        pub fn add_poller(loop: *Loop, poller: *Poller) AddPollerError!void {
            loop.tables.assert_owner();
            return loop.tables.dispatch.add_poller(poller);
        }

        /// Removes `poller`, which must have been added.
        pub fn remove_poller(loop: *Loop, poller: *Poller) void {
            loop.tables.assert_owner();
            loop.tables.dispatch.remove_poller(poller);
        }

        /// Asks the loop to call `task.run` once, later (decision 27). The order is the order of
        /// the calls. A task queued by the program between ticks, by a poller or by a record runs
        /// in the `end` of the next tick to reach it; a task queued by a task runs one tick later.
        /// A task belongs to this loop while it is queued: do not schedule it on another loop.
        pub fn schedule(loop: *Loop, task: *Task) ScheduleError!void {
            loop.tables.assert_owner();
            return loop.tables.dispatch.schedule(task);
        }

        /// True while `task` is queued on this loop.
        pub fn is_scheduled(loop: *const Loop, task: *const Task) bool {
            loop.tables.assert_owner();
            return loop.tables.dispatch.tasks.holds(task);
        }

        /// The tasks queued now. A host that sleeps in its own wait reads it before it sleeps
        /// (decision 23), and a program reads it before `deinit`.
        pub fn tasks_queued(loop: *const Loop) u32 {
            loop.tables.assert_owner();
            return loop.tables.dispatch.tasks.count;
        }

        /// `tasks_per_tick_max` less the tasks the current run started, the task that reads it
        /// included, and 0 outside a run. A long task that splits its work does at most this many
        /// slices plus one in one call, then schedules itself again. It counts, and never reads the
        /// clock.
        pub fn task_budget_left(loop: *const Loop) u32 {
            loop.tables.assert_owner();
            return loop.tables.dispatch.tasks.left;
        }

        /// Unlinks every queued task without a call, and returns the count (decision 27,
        /// "Shutdown"). Only the program calls it, between ticks, after `drain` returned
        /// `TasksStillQueued`. Halts inside a tick.
        pub fn discard_tasks(loop: *Loop) u32 {
            loop.tables.assert_owner();
            return loop.tables.dispatch.discard_tasks();
        }

        /// The host's last call before it sleeps in its own wait (decision 29). Returns how long it
        /// may sleep: `.now` while work is left, `.at` the nearest timer or poller limit, and
        /// `.none` when neither exists. It reads no clock and changes no state. Program only, and
        /// it halts inside a tick (class B). A kept tick error is work left: the next tick returns
        /// it, and a host that slept first would not see it (decision 5, amendment of 2026-11-06).
        pub fn wait_limit(loop: *Loop) WaitLimit {
            loop.tables.assert_owner();
            if (loop.kept_error.failure != null) return .now;
            const limit = loop.tables.wait_limit();
            if (limit == .now) return .now;
            if (loop.inbox.holds_messages(loop.tables.id)) return .now;
            return limit;
        }

        /// The view that the program hands to each library (decision 28). Its address is the
        /// loop's, and it declares only the calls a library may make. Program only.
        pub fn shared(loop: *Loop) *SharedLoop(Loop) {
            loop.tables.assert_owner();
            return @ptrCast(loop);
        }

        /// The loop's heartbeat, for a thread that the program starts (decision 28). It is valid
        /// until `deinit`, which halts while a watch reads it. Program only.
        pub fn heartbeat(loop: *Loop) *HeartbeatView {
            loop.tables.assert_owner();
            return stall_watch.view_of(loop.tables.heartbeat);
        }
    };
}
