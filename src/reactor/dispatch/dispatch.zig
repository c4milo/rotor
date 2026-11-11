//! The reactor's state (decisions 26 and 33): its pollers, its task queue and its scheduling
//! groups. An operation may name a `Completion`, a record in the library's own memory, and the tick
//! calls it for each event of that operation. A library may also add a `Poller`, which the reactor
//! calls once in each tick. An event whose operation named no record goes back to the caller of
//! `tick`, as on a plain loop.
//!
//! Each function takes the state and the loop as two arguments (decision 33, open question 16,
//! form H). It reaches the loop through the core's surface and the port: `outstanding` for the word
//! that takes a tick off the fast path, `stored_limit` for the limit of the pollers,
//! `heartbeat_line` for the names of the callbacks, `push_reserved` for a call, and `assert_owner`.
//! So a test drives it with a loop of its own that declares those names.
//!
//! The records and the pollers live in memory the library owns, so the reactor allocates nothing.
//! The reactor calls through a record's address and never decides anything from its value
//! (non-negotiable 2). The callbacks run in the order of the events.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const assert_class_a = core.assertion_class.assert_class_a;
const constants = @import("../constants.zig");
const reactor_module = @import("../reactor.zig");
const tasks_module = @import("../tasks.zig");
const scheduling = @import("../scheduling/scheduling.zig");
const scheduling_run = @import("../scheduling/scheduling_run.zig");
const calls = @import("dispatch_calls.zig");
const tick_module = @import("../reactor_tick.zig");
const shutdown = @import("../reactor_shutdown.zig");
const call_loop = @import("../call/call_loop.zig");

const Event = core.Event;
const Groups = scheduling.Groups;
const LoopId = core.LoopId;
const Poller = reactor_module.Poller;
const Tasks = tasks_module.Tasks;
const WaitLimit = core.WaitLimit;

pub const AddPollerError = error{PollersFull};

/// Where a tick is (decision 30). One byte, where decision 26 held two flags.
pub const Phase = enum(u8) {
    /// Between ticks.
    idle,
    /// `begin` calls the pollers: a poller that adds or removes a poller halts, because the reactor
    /// is walking the table.
    polling,
    /// From the end of the pollers to the end of `end`, decision 27's run of `.default` included.
    /// A callback may add or remove a poller. That run stores no phase of its own: `tasks.left`
    /// is above 0 only inside a task's call, which is what `charge_task` checks.
    records,
    /// The run of the groups by DRR (decision 30).
    group_tasks,
};

/// What `start` copies from the loop's options and from the reactor's.
pub const Start = struct {
    /// The loop's id in its registry, which a call names.
    id: LoopId,
    /// True when the loop's registry is a decision 21 group's, where no call goes.
    in_group: bool,
    /// The groups that `start` reserves as ids 1 to n (decision 30).
    named_groups: *const scheduling.NamedTable,
};

/// The reactor's state, which each reactor holds beside its loop. Size 104 B, alignment 8: the
/// bytes of the `Dispatch` that `Tables` held at v0.10.0, less the count of outstanding callbacks
/// and the stored limit, which the core's `Tables` holds now, and with the pointer to the groups,
/// the loop's id and whether its registry is a group's.
pub const Dispatch = struct {
    pollers: [constants.pollers_max]*Poller,
    /// The task queue of `.default` (decision 27).
    tasks: Tasks,
    /// The reactor's scheduling groups, carved from the end of its memory (decision 30). A tick
    /// reads it only while a group other than `.default` holds a task.
    groups: *Groups,
    poller_count: u8,
    /// Not `.idle` from `begin` to `end`: a callback or a poller that calls `tick` halts.
    phase: Phase,
    /// The ready mask of groups 1 to 15: bit `g` is set while group `g` holds a task (decision 30).
    /// Bit 0 stays clear: `tasks.count` says whether `.default` holds one. While it is 0, `end`
    /// runs decision 27's run and touches no line of `Groups`.
    groups_ready: u16,
    /// The loop's id in its registry, which a call names (decision 32).
    id: LoopId,
    /// True when the loop's registry is a decision 21 group's: a call there halts (class B).
    in_group: bool,

    /// The state of a reactor that has not started: `start` writes `groups`, `id` and `in_group`.
    pub const empty: Dispatch = .{
        .pollers = undefined,
        .tasks = .empty,
        .groups = undefined,
        .poller_count = 0,
        .phase = .idle,
        .groups_ready = 0,
        .id = 0,
        .in_group = false,
    };

    /// Starts the state of a reactor whose loop `init` started: no poller, no task, and the groups
    /// of `start.named_groups`, in `groups`.
    pub fn start(dispatch: *Dispatch, groups: *Groups, options: Start) void {
        dispatch.* = .empty;
        groups.init(options.named_groups);
        dispatch.groups = groups;
        dispatch.id = options.id;
        dispatch.in_group = options.in_group;
    }

    /// Halts unless `start` ran on this state (class C). The hook checks it on the cold path,
    /// because the drain hands the hook only the context that `attach_reserved` stored.
    pub fn assert_started(dispatch: *const Dispatch) void {
        dispatch.groups.assert_initialized();
    }

    /// Adds `poller`, which the reactor calls once in each tick (decision 26), and names the first
    /// poller on the loop's heartbeat line, for a stall of one poller (decision 33).
    pub fn add_poller(dispatch: *Dispatch, loop: anytype, poller: *Poller) AddPollerError!void {
        loop.assert_owner();
        assert(dispatch.phase != .polling);
        assert(dispatch.poller_count <= constants.pollers_max);
        for (dispatch.pollers[0..dispatch.poller_count]) |added| assert(added != poller);
        if (dispatch.poller_count == constants.pollers_max) return error.PollersFull;
        dispatch.pollers[dispatch.poller_count] = poller;
        dispatch.poller_count += 1;
        loop.heartbeat_line().name_poller(&dispatch.pollers[0].call.name);
    }

    /// Removes `poller`, which must have been added. The pollers after it keep their order. A
    /// removal that empties the table writes `.none` in the stored limit (decision 29), and names
    /// no poller on the heartbeat line.
    pub fn remove_poller(dispatch: *Dispatch, loop: anytype, poller: *Poller) void {
        loop.assert_owner();
        assert(dispatch.phase != .polling);
        const count = dispatch.poller_count;
        const found = std.mem.indexOfScalar(*Poller, dispatch.pollers[0..count], poller);
        assert(found != null);
        const index = found orelse return;
        const after = dispatch.pollers[index + 1 .. count];
        std.mem.copyForwards(*Poller, dispatch.pollers[index .. count - 1], after);
        dispatch.poller_count = count - 1;
        const line = loop.heartbeat_line();
        if (dispatch.poller_count != 0) return line.name_poller(&dispatch.pollers[0].call.name);
        line.name_poller(null);
        loop.stored_limit().* = .none;
    }

    /// Halts inside a tick, or when a poller is still added or a task is still queued: what
    /// `deinit` checks, because each is memory the library owns and may free once the reactor has
    /// ended (decision 8, class C). A record, a poller or a task that ends the reactor halts at once
    /// (decision 28).
    pub fn assert_empty(dispatch: *const Dispatch) void {
        assert(dispatch.phase == .idle);
        assert(dispatch.poller_count == 0);
        assert(dispatch.tasks.count == 0);
        assert(dispatch.groups_ready == 0);
    }

    /// The start of a tick: halts inside another tick, then calls every poller once and stores the
    /// least of their limits in the loop's stored limit (decision 29). Returns the wait the tick may
    /// block for: 0 when that limit is `.now` or a task is queued, and `wait_ns` otherwise. The
    /// loop's tick bounds that wait at the stored limit later, in `Tables.wait_bound`. A task queued
    /// now runs in this tick's `end`, so the tick must not sleep first. The loop's heartbeat line
    /// names each poller while it runs (decision 28).
    pub fn begin(dispatch: *Dispatch, loop: anytype, wait_ns: u64) u64 {
        assert_class_a(dispatch.phase == .idle);
        dispatch.phase = .polling;
        const line = loop.heartbeat_line();
        var least: u64 = @intFromEnum(WaitLimit.none);
        // A poller cannot add or remove one, so the count read here is the count it calls.
        const polled = dispatch.poller_count;
        for (dispatch.pollers[0..polled]) |poller| {
            line.enter(&poller.call.name);
            least = @min(least, @intFromEnum(poller.call.function(poller)));
        }
        // A `begin` with no poller leaves the heartbeat as it is: `running` is null already.
        if (polled != 0) line.leave_polling(polled);
        dispatch.phase = .records;
        const limit: WaitLimit = @enumFromInt(least);
        loop.stored_limit().* = limit;
        const queued = dispatch.tasks.count | dispatch.groups_ready;
        return if (limit == .now or queued != 0) 0 else wait_ns;
    }

    /// The end of a tick: calls the record of each event that has one, and moves the other events
    /// to the front of `events`, in order. Then it runs the tasks queued so far, so a task that a
    /// record or a poller queued runs in this tick (decision 27). Returns how many events are at
    /// the front. `phase` stays not `.idle` while the tasks run, so a task that ticks halts. While
    /// no group other than `.default` holds a task, it runs decision 27's run and touches no line
    /// of the groups (decision 30).
    pub fn end(dispatch: *Dispatch, loop: anytype, events: []Event) u32 {
        assert_class_a(dispatch.phase == .records);
        defer dispatch.phase = .idle;
        const line = loop.heartbeat_line();
        const outstanding = loop.outstanding();
        const kept = call_records(line, outstanding, events);
        // Each subtraction's overflow check halts on a callback the count never saw. While a task
        // is queued, a stray final event lowers the count without an underflow, and the halt comes
        // at the latest when the queue empties. `run` is called first and its count subtracted
        // after: a task that schedules a task adds to the count during the run, and a compound
        // `-=` would read the count before the call and lose that addition.
        const ran = if (dispatch.groups_ready == 0)
            dispatch.tasks.run(line)
        else
            dispatch.run_groups(line, outstanding.*);
        outstanding.* -= ran;
        // A record or a task can change what a poller would answer, so a host that reads the limit
        // now does not sleep (decision 29). The next `begin` writes the limit again before any
        // `wait_bound` reads it, so only `wait_limit` reads this store.
        const called = kept != events.len or ran != 0;
        if (called and dispatch.poller_count != 0) loop.stored_limit().* = .now;
        return kept;
    }

    /// Ends a tick that failed, so the next tick may begin.
    pub fn abandon(dispatch: *Dispatch) void {
        assert(dispatch.phase != .idle);
        dispatch.phase = .idle;
    }

    /// The run of the groups by DRR, in a tick where a group other than `.default` holds a task
    /// (decision 30). It checks the shape of each ready lane first (class B, once in each run).
    fn run_groups(dispatch: *Dispatch, line: anytype, outstanding: u32) u32 {
        dispatch.phase = .group_tasks;
        const groups = dispatch.groups;
        groups.assert_ready_shape(&dispatch.tasks, dispatch.groups_ready, outstanding);
        return scheduling_run.run(groups, &dispatch.tasks, &dispatch.groups_ready, line);
    }

    /// Calls the record of each event of `events` that names one, and moves the other events to the
    /// front, in order. Returns how many it moved. The final event of a record lowers `outstanding`.
    fn call_records(line: anytype, outstanding: *u32, events: []Event) u32 {
        var kept: u32 = 0;
        for (events) |event| {
            if (!event.flags.dispatched) {
                events[kept] = event;
                kept += 1;
                continue;
            }
            const record: *reactor_module.Completion = @ptrFromInt(event.user_data);
            line.enter(&record.call.name);
            record.call.function(record, event);
            // After the call: inside the last record's callback the count is still above 0, so a
            // `tick` there leaves the fast path and halts in `begin`.
            if (!event.flags.more) outstanding.* -= 1;
        }
        assert(kept <= events.len);
        // Every event with a record called its record, and `kept` are the others. A batch that
        // called no record leaves the heartbeat as it is: `running` is null since `begin`.
        const called = events.len - kept;
        if (called != 0) line.leave(called);
        return kept;
    }

    // The calls of decisions 26 to 30 on the reactor's state and its loop: `dispatch_calls.zig`.
    pub const submit = calls.submit;
    pub const schedule = calls.schedule;
    pub const schedule_in = calls.schedule_in;
    pub const schedule_call = calls.schedule_call;
    pub const charge_task = calls.charge_task;
    pub const task_budget_left = calls.task_budget_left;
    pub const tasks_queued = calls.tasks_queued;
    pub const is_scheduled = calls.is_scheduled;
    pub const discard_tasks = calls.discard_tasks;
    pub const reserve_scheduling_group = calls.reserve_scheduling_group;
    pub const set_scheduling_group_shares = calls.set_scheduling_group_shares;
    pub const wait_limit = calls.wait_limit;
    pub const assert_calls_ended = calls.assert_calls_ended;
    // The tick of a reactor: `reactor_tick.zig`.
    pub const tick = tick_module.tick;
    // The drain of a reactor that is shutting down: `reactor_shutdown.zig`.
    pub const drain = shutdown.drain;
    pub const drain_within = shutdown.drain_within;
    // The cross-core calls of decision 32, and the hook of the reserved tags: `call_loop.zig`.
    pub const call = call_loop.call;
    pub const answer = call_loop.answer;
    pub const serve = call_loop.serve;
    pub const stop_serving = call_loop.stop_serving;
    pub const take_reserved = call_loop.take_reserved;
};

comptime {
    assert(@sizeOf(Dispatch) == 104);
    assert(@alignOf(Dispatch) == 8);
}

/// The error set of `LoopPointer`'s `tick_backend`, which a reactor's tick returns.
pub fn TickError(comptime LoopPointer: type) type {
    const Loop = @typeInfo(LoopPointer).pointer.child;
    const Returned = @typeInfo(@TypeOf(Loop.tick_backend)).@"fn".return_type.?;
    return @typeInfo(Returned).error_union.error_set;
}
