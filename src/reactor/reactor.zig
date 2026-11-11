//! The module `reactor` of decision 33: the optional layer over a loop of the core. A program that
//! wants records with callbacks, pollers, tasks, scheduling groups, cross-core calls or libraries
//! that share its loop makes a `Reactor(Loop)` in place of a `Loop`. A program that wants none of
//! them makes a plain loop, and its binary holds no code of this module.
//!
//! A reactor holds its loop and its own state, `Dispatch`. Each function of the reactor takes the
//! state and the loop as two arguments, and reaches the loop through the core's surface and the
//! port of decision 33. So one copy of the code serves `Reactor(Loop)` here and the public
//! module's `rotor.Reactor(rotor.Loop)`, which switches once on its backend for each call (decision
//! 33, open question 16, form H).
//!
//! This file declares each type that a program can see, so the compiler prints `reactor.Completion`
//! and `reactor.Reactor(kqueue.Loop)` (decision 33, "Where each type is declared"). Each method is
//! an alias of a function in a split file. The module imports `core` alone (decision 1, "The module
//! graph"). The public module exports the generic as `rotor.Reactor(Loop)`.
const std = @import("std");
const core = @import("core");
pub const constants = @import("constants.zig");
pub const dispatch = @import("dispatch/dispatch.zig");
pub const scheduling = @import("scheduling/scheduling.zig");
pub const tasks = @import("tasks.zig");
const call_module = @import("call/call.zig");
pub const call = call_module;
const shared_module = @import("reactor_shared.zig");
pub const shared = shared_module;
const calls_module = @import("reactor_calls.zig");
const check_module = @import("reactor_check.zig");
const callbacks = @import("dispatch/dispatch_callbacks.zig");
const call_service = @import("call/call_service.zig");

const Event = core.Event;
const WaitLimit = core.WaitLimit;

/// The reactor's state, beside its loop: the pollers, the tasks, the scheduling groups.
pub const Dispatch = dispatch.Dispatch;
/// The table of one reactor's scheduling groups, carved from the end of its memory.
pub const Groups = scheduling.Groups;
/// The program's named groups, from its root file's `rotor_scheduling_groups`.
pub const root_groups = scheduling.root_groups;
pub const AddPollerError = dispatch.AddPollerError;
pub const ScheduleError = tasks.ScheduleError;
pub const ReserveSchedulingGroupError = scheduling.ReserveSchedulingGroupError;
pub const CallError = call.CallError;
/// The bytes of a reactor's memory for a loop of `loop_bytes`, and where its groups sit in them.
pub const memory_bytes = calls_module.memory_bytes;
pub const groups_in = calls_module.groups_in;

/// What an operation names to have the reactor call its function for each of its events
/// (decision 26). The library puts it inside its own struct. `init` points it at a static `Call`
/// that finds that struct again, and `mark` names it in an operation. Size 8 B, alignment 8.
pub const Completion = struct {
    call: *const Call,

    /// A static entry: the callback's name and its function (decision 28). `init` makes one,
    /// named `@typeName(Parent) ++ "." ++ field`. A `Call` written by hand is a container-level
    /// `const` with a literal name: another thread may read the name after a library frees its
    /// record, so it must be static data.
    pub const Call = struct {
        name: [:0]const u8,
        function: *const fn (completion: *Completion, event: Event) void,
    };

    pub const init = callbacks.completion_init;
    /// `operation` with its events sent to the record (decision 33, open question 5).
    pub const mark = callbacks.mark;
};

/// What a library adds to have the reactor call its function once in each tick, before the tick
/// waits (decision 26). The function returns a `WaitLimit`: `.now` when the tick must not block,
/// `.at(ns)` for a deadline on the loop's clock, and `.none` otherwise. The tick bounds its wait at
/// the least limit of all pollers (decision 29). Size 8 B, alignment 8.
pub const Poller = struct {
    call: *const Call,

    /// A static entry, as `Completion.Call` is.
    pub const Call = struct {
        name: [:0]const u8,
        function: *const fn (poller: *Poller) WaitLimit,
    };

    pub const init = callbacks.poller_init;
};

/// Work that a library asks the reactor to do once, later (decision 27). The library owns the
/// record and puts it inside its own struct, as it does with a `Completion`. Only the reactor
/// writes `next`. Size 16 B, alignment 8.
pub const Task = struct {
    call: *const Call,
    /// The task after this one in the queue, or null at the tail and while the task is not queued.
    next: ?*Task = null,

    /// A static entry, as `Completion.Call` is (decision 28). Size 32 B, alignment 8.
    pub const Call = struct {
        name: [:0]const u8,
        function: *const fn (task: *Task) void,
        /// The units that one run costs before any `charge_task`, in 1 to `task_charge_max`
        /// (decision 30). The groups path reads it beside `function`.
        cost: u16 = 1,
        /// True for the task of a cross-core call (decision 32, ruling item 12). Its caller waits
        /// for `finish`, so `discard_tasks` halts on such a task. It sits in the padding.
        call_record: bool = false,
    };

    pub const init = tasks.task_init;
    pub const init_cost = tasks.task_init_cost;
};

/// A group that is the same group on every reactor of the program: ids 1 to n are the names of the
/// program's declaration, in its order (decision 30). Only `Named(...).group` makes an id other
/// than `.default`, so a literal fails to compile. Size 1 B.
pub const NamedSchedulingGroup = enum(u8) {
    default = 0,
    _,

    /// The same id as a `core.SchedulingGroup` of the reactor that calls it, for `schedule_in`.
    pub const group = scheduling.group_of;
};

/// What a handler returns (decision 32). The compiler requires a choice, and a reply with `.now`.
pub fn Answer(comptime Reply: type) type {
    return union(enum) { now: Reply, later };
}

/// What `finish` receives (decision 32). The caller switches on it.
pub fn CallResult(comptime Reply: type) type {
    return union(enum) { replied: *const Reply, expired, target_stopped };
}

/// The options of one `send` (decision 32).
pub const CallOptions = struct {
    /// The group that the handler runs in on the target, and that `finish` runs in on the caller
    /// (decision 32, "Scheduling groups"). It has no default: a call that wants no group of its own
    /// writes `.default`.
    group: NamedSchedulingGroup,
    /// On the loop clock (`now_ns`), or 0 for none. The target compares it before the handler runs.
    deadline_ns: u64 = 0,
};

/// The part of a call that the reactors schedule and post (decision 32). It sits in the caller's
/// record. Size 64 B, alignment 8.
pub const CallLink = struct {
    /// Its `call` is the service's entry on the target, and the `finish` entry on the caller.
    task: Task,
    /// The service's stations. `send` writes it.
    stations: *[constants.loops_max]CallStation,
    /// A static entry named after the caller's field. `CallRecord.init` writes it.
    finish: *const Task.Call,
    /// The count of the ring from the origin to the target, or the station's `self_out`. `call`
    /// writes it, and the record's task on the caller lowers it before `finish`. The target never
    /// reads it.
    calls_out: *u32,
    /// On the loop clock, or 0 for none.
    deadline_ns: u64,
    /// Plus 1 for each `send`. The message's `reserved` carries it.
    generation: u32,
    origin: core.LoopId,
    target: core.LoopId,
    state: call.State,
    /// An `Outcome`, which `answer` reads.
    outcome: call.Outcome,
    /// The caller's choice. `send` writes it.
    group: NamedSchedulingGroup,
    /// True from `prepare` until `end_call`, or until `call` refuses the call. Only the caller's
    /// thread reads or writes it, so `is_out` reads no byte that the target writes. It sits in the
    /// padding.
    sent: bool,

    /// A link that no call has used, whose task runs `finish` on the caller.
    pub const idle = call.link_idle;
    /// The caller's part of `send`, before the reactor's `call`.
    pub const prepare = call.link_prepare;
};

/// One service on one reactor. Only that reactor's thread writes it. Size 128 B, alignment 128, so
/// two loops' stations never share a line on Apple silicon (decision 32, open question 6).
pub const CallStation = struct {
    /// What the handler receives. `serve` writes it.
    context: ?*anyopaque align(constants.mailbox_index_alignment),
    /// The reactor's view. `serve` writes it, and a call's task reads `now_ns` and answers through
    /// it.
    loop: ?*anyopaque,
    /// The calls this station holds: taken, and not yet answered.
    held: u32,
    /// The calls to self that have not yet run their `finish`.
    self_out: u32,
    /// The groups of the reactor that counts this station in `Groups.stations`, from its `serve`
    /// or its first call to self, until it stops serving and its last call to self ends. Null
    /// while no reactor counts it. So a reactor that ends counts none, and a later reactor of the
    /// id starts from none (decision 32).
    attached: ?*Groups,
    state: StationState,

    pub const StationState = enum(u8) { unused, serving, stopped };

    pub const unused: CallStation = .{
        .context = null,
        .loop = null,
        .held = 0,
        .self_out = 0,
        .attached = null,
        .state = .unused,
    };
};

/// A reactor over `Loop`: each backend's `Loop`, or a twin of decision 10 that declares the core's
/// surface and the port of decision 33. It holds its loop by value, and its state beside it. It
/// gives out no `*Loop`: a call on the loop inside would skip the reactor's part of that call.
/// `init` starts it in place, and it stays at that address until `deinit`, as a loop does.
///
/// The build stops with one error that names each declaration `Loop` lacks (`reactor_check.zig`).
/// The compiler prints this type as `reactor.Reactor(kqueue.Loop)`, the one repeat that the ruling
/// of 2026-11-09 accepts.
pub fn Reactor(comptime Loop: type) type {
    comptime check_module.check(Loop);
    return struct {
        /// The reactor's state. It comes before the loop, so a call that writes both the state and
        /// the loop's `outstanding` reaches each at a small offset from one address: the loop holds
        /// kilobytes of its own, and an offset past 4 KiB costs an instruction on arm64.
        dispatch: Dispatch,
        /// The loop that the reactor runs.
        loop: Loop,

        const This = @This();
        const calls = calls_module.Calls(This, Loop);

        /// What `init` takes. `loop` has no default, because a loop's options name the operations
        /// it holds, which have none. The reactor copies the named groups at `init`.
        pub const Options = struct {
            /// The loop's options. The reactor copies its id and whether its registry is a group's.
            loop: Loop.Options,
            /// The groups that `init` reserves as ids 1 to n (decision 30).
            named_groups: scheduling.NamedTable = root_groups.table,
        };

        // The error sets of the reactor: the loop's, and the four of the reactor's own calls.
        pub const TickError = calls.TickError;
        pub const DrainError = TickError || error{ StillInFlight, TasksStillQueued };
        pub const AddPollerError = dispatch.AddPollerError;
        pub const ScheduleError = tasks.ScheduleError;
        pub const ReserveSchedulingGroupError = scheduling.ReserveSchedulingGroupError;
        pub const CallError = call_module.CallError;

        /// The reactor as the program hands it to a library (decision 28). `shared` returns it. Its
        /// address is the reactor's. It declares only the calls a library may make, and each
        /// refused call as a compile error that states the rule (`reactor_shared.zig`).
        pub const SharedLoop = opaque {
            const library = shared_module.Library(This, @This());
            pub const submit = library.submit;
            pub const cancel = library.cancel;
            pub const post = library.post;
            pub const now_ns = library.now_ns;
            pub const schedule_in = library.schedule_in;
            pub const charge_task = library.charge_task;
            pub const is_scheduled = library.is_scheduled;
            pub const task_budget_left = library.task_budget_left;
            pub const add_poller = library.add_poller;
            pub const remove_poller = library.remove_poller;
            pub const provide_buffers = library.provide_buffers;
            pub const provide_datagram_buffers = library.provide_datagram_buffers;
            pub const datagram = library.datagram;
            pub const provided_buffer = library.provided_buffer;
            pub const give_back_buffer = library.give_back_buffer;
            pub const release_buffers = library.release_buffers;
            pub const reserve_buffer_group = library.reserve_buffer_group;
            pub const call = library.call;
            pub const answer = library.answer;
            pub const serve = library.serve;
            pub const stop_serving = library.stop_serving;
            pub const refused = shared_module.refused_calls;
            pub const tick = shared_module.refusals.tick;
            pub const drain = shared_module.refusals.drain;
            pub const deinit = shared_module.refusals.deinit;
            pub const cancel_all = shared_module.refusals.cancel_all;
            pub const discard_tasks = shared_module.refusals.discard_tasks;
            pub const schedule = shared_module.refusals.schedule;
            pub const reserve_scheduling_group = shared_module.refusals.reserve_scheduling_group;
            pub const set_scheduling_group_shares = shared_module.refusals.set_scheduling_group_shares;
            pub const wait_until = shared_module.refusals.wait_until;
        };

        /// One kind of cross-core call over this reactor's view (decision 32).
        pub fn Service(
            comptime Context: type,
            comptime Request: type,
            comptime Reply: type,
            comptime handler: fn (context: *Context, record: *CallRecord(Request, Reply)) Answer(Reply),
        ) type {
            return struct {
                /// One station for each loop, indexed by `LoopId`. Program memory, 128 B each.
                stations: [constants.loops_max]CallStation,

                const service = call_service.Service(@This(), SharedLoop, Context, Request, Reply, handler);
                /// Every station unused.
                pub const init: @This() = .{ .stations = @splat(CallStation.unused) };
                pub const Call = CallRecord(Request, Reply);
                /// The static entry that a call's task runs on the target.
                pub const entry: Task.Call = .{ .name = @typeName(@This()), .function = service.run, .call_record = true };
                pub const serve = service.serve;
                pub const stop_serving = service.stop_serving;
                pub const send = service.send;
            };
        }

        /// The caller's record of one call over this reactor's view (decision 32). Size 64 B plus
        /// `Request` and `Reply`.
        pub fn CallRecord(comptime Request: type, comptime Reply: type) type {
            return struct {
                link: CallLink,
                request: Request,
                reply: Reply,

                const record = call_service.CallRecord(@This(), SharedLoop, Request, Reply);
                pub const init = record.init;
                pub const is_out = record.is_out;
                pub const request_of = record.request_of;
                pub const answer = record.answer;
            };
        }

        // The core's surface: the seven calls that wrap the loop's, and the forwarders.
        pub const memory_bytes = calls.memory_bytes;
        pub const init = calls.init;
        pub const deinit = calls.deinit;
        pub const tick = calls.tick;
        pub const drain = calls.drain;
        pub const assert_empty = calls.assert_empty;
        pub const wait_limit = calls.wait_limit;
        pub const submit = calls.submit;
        pub const dropped_wakes = calls.dropped_wakes;
        pub const cancel = calls.cancel;
        pub const post = calls.post;
        pub const in_flight = calls.in_flight;
        pub const now_ns = calls.now_ns;
        pub const wait_descriptor = calls.wait_descriptor;
        pub const statistics = calls.statistics;
        pub const heartbeat = calls.heartbeat;
        pub const cancel_all = calls.cancel_all;
        pub const register_buffers = calls.register_buffers;
        pub const register_descriptors = calls.register_descriptors;
        pub const reserve_buffer_group = calls.reserve_buffer_group;
        pub const provide_buffers = calls.provide_buffers;
        pub const provide_datagram_buffers = calls.provide_datagram_buffers;
        pub const datagram = calls.datagram;
        pub const give_back_buffer = calls.give_back_buffer;
        pub const release_buffers = calls.release_buffers;
        pub const provided_buffer = calls.provided_buffer;
        /// A reactor bounds its wait with a poller, so it refuses the plain loop's call.
        pub const wait_until = shared_module.refusals.reactor_wait_until;
        // The names of the reactor: the pollers and the tasks (decisions 26 and 27), the
        // scheduling groups (decision 30), the view (decision 28) and the calls (decision 32).
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
    _ = constants;
    _ = check_module;
    _ = callbacks;
    _ = dispatch;
    _ = scheduling;
    _ = scheduling.groups;
    _ = scheduling.rule;
    _ = tasks;
    _ = call;
    _ = shared;
    _ = @import("dispatch/dispatch_calls.zig");
    _ = @import("dispatch/dispatch_test.zig");
    _ = @import("dispatch/dispatch_test_limit.zig");
    _ = @import("dispatch/dispatch_test_unit.zig");
    _ = @import("scheduling/scheduling_test.zig");
    _ = @import("scheduling/scheduling_test_unit.zig");
    _ = @import("tasks_test.zig");
    _ = @import("reactor_tick.zig");
    _ = @import("reactor_shutdown.zig");
    _ = @import("reactor_test.zig");
    _ = @import("reactor_test_names.zig");
}
