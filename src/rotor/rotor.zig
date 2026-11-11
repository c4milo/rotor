//! rotor's public API: the one module a consumer imports, and the whole of what rotor supports.
//!
//! What a consumer needs is a `Loop`, or a `Reactor(Loop)` for records with callbacks, pollers,
//! tasks, scheduling groups, cross-core calls and libraries that share it (decision 33), the types
//! they take and return, and the helpers that open a socket and size the memory it hands a loop.
//! That is what this file names, and nothing else of the tree is reachable through it. The build
//! registers this module alone, so a dependent package cannot name a backend, and `Loop` carries
//! exactly the surface `core/surface.zig` lists, which `rotor_loop_test.zig` holds it to. A backend's other public functions exist for its own
//! files, the benchmarks and the conformance suite, which live in this tree: they are not API, and
//! no dependent package can reach them (Camilo's ruling of 2026-09-22).
//!
//! The backend is this host's. On Darwin it is `kqueue`. On Linux it is `uring` where the kernel
//! gives the process a ring and `epoll` where the kernel refuses one, chosen once per process and
//! reported by `backend()` (decision 20, open question 5; `rotor_loop_backend.zig` says how). A
//! process that cannot take whichever the kernel allows names one first, with `require_backend`
//! (decision 23). Every backend carries the surface (decision 1), so what a consumer writes is the
//! same whichever runs. A consumer that needs a backend of its own, such as a deterministic twin
//! for replay (decision 10), writes a module carrying this surface and imports it instead of this
//! one.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
const uring = @import("uring");
const epoll = @import("epoll");
const kqueue = @import("kqueue");
const reactor = @import("reactor");
const loop_module = @import("rotor_loop.zig");
const reactor_calls = @import("rotor_reactor.zig");

const linux = builtin.os.tag == .linux;

// The types a caller builds operations from and reads events with.
pub const Address = core.Address;
pub const Code = core.Code;
pub const Delivery = core.Delivery;
pub const Descriptor = core.Descriptor;
pub const Error = core.Error;
pub const Event = core.Event;
pub const WaitLimit = core.WaitLimit;
pub const BufferGroup = core.BufferGroup;
pub const Handle = core.Handle;
pub const LoopId = core.LoopId;
pub const Message = core.Message;
pub const Operation = core.Operation;
/// A task queue with shares on one reactor (decision 30). `reserve_scheduling_group` makes one, and
/// `NamedSchedulingGroup.group` gives one of the program's named groups.
pub const SchedulingGroup = core.SchedulingGroup;

// The reactor's types (decision 33), which name no view, so a twin's program writes them too.
pub const Completion = reactor.Completion;
pub const Poller = reactor.Poller;
pub const Task = reactor.Task;
/// A group that is the same group on every reactor of the program: one of the names of the root
/// file's `rotor_scheduling_groups` (decision 30). A cross-core call names one (decision 32).
pub const NamedSchedulingGroup = reactor.NamedSchedulingGroup;
/// The program's names, from the root file's `rotor_scheduling_groups`: `enum { quic, dns }` for
/// `.{ .quic = 400, .dns = 100 }`. Empty when the root declares none.
pub const SchedulingGroupName = reactor.root_groups.Name;
pub const Answer = reactor.Answer; // The cross-core call (decision 32).
pub const CallResult = reactor.CallResult;
pub const CallOptions = reactor.CallOptions;
pub const CallError = reactor.CallError;
pub const CallLink = reactor.CallLink;
pub const CallStation = reactor.CallStation;
/// One kind of cross-core call over the host's reactor, and the caller's record of one call.
pub const Service = Reactor(Loop).Service;
pub const CallRecord = Reactor(Loop).CallRecord;

/// Every named limit (CLAUDE.md, non-negotiable 1): the core's and the reactor's.
pub const constants = @import("rotor_constants.zig");

/// The alignment of every block of memory a caller hands a loop or a registry.
pub const memory_alignment = core.layout.memory_alignment;

/// Datagrams (decision 15): what a received one carries, how one is sent, and how a group is
/// laid out.
pub const datagram = struct {
    pub const Ecn = core.datagram.Ecn;
    pub const Received = core.datagram.Received;
    pub const Outbound = core.datagram.Outbound;
    pub const GroupOptions = core.datagram.GroupOptions;
    pub const prefix_bytes = core.datagram.prefix_bytes;
    pub const payload_capacity = core.datagram.payload_capacity;
};

/// The caller's threads, which a loop hands a blocking file operation to (decision 18).
/// `Offload.memory_bytes(workers)` sizes the memory of its rings, `Loop.Options.offload_memory`. On
/// Linux it is what epoll needs, and what io_uring checks for although it uses none of it; a caller
/// sizes it before the choice is made.
pub const Offload = core.offload.Offload;

/// Files on a backend whose file operations block (decision 18): what the loop does with one, and
/// what one worker runs.
pub const offload = struct {
    pub const FilePolicy = core.offload.FilePolicy;
    pub const Work = core.offload.Work;
};

/// What a loop counts about itself: sampled latencies (decision 9), and exact stalls (decision 9,
/// rule 7, and decision 28). `Loop.statistics` returns it.
pub const Statistics = core.statistics.Statistics;

/// The parts of `Statistics`: how often a loop samples, and what it keeps of its last stall.
pub const statistics = struct {
    pub const Options = core.statistics.Options;
    pub const Stall = core.statistics.Stall;
};

/// Which backend a process runs, as `backend()` reports it.
pub const Backend = loop_module.Backend;

/// The backend this process runs. On Linux the first call asks the kernel for an io_uring ring, the
/// way a loop would, and the answer holds for the life of the process: `uring` where the kernel
/// gives one, `epoll` where it refuses, as Docker's default seccomp profile does. On Darwin it is
/// `kqueue`. Whatever needs the choice first makes it, so `sync`, a `Registry` and a `Loop` all
/// agree.
pub fn backend() Backend {
    return switch (loop_module.chosen()) {
        inline else => |tag| @field(Backend, @tagName(tag)),
    };
}

/// The named group `name` of the program's root declaration, `rotor_scheduling_groups`. The program
/// calls it, and hands each library its group at init. An undeclared name fails to compile.
pub fn named_scheduling_group(comptime name: SchedulingGroupName) NamedSchedulingGroup {
    return reactor.root_groups.group(name);
}

/// Why `require_backend` left the process's backend as it was: `Unsupported` when this host cannot
/// run the backend asked for, and `OtherBackendChosen` when the process already runs another.
pub const RequireError = loop_module.RequireError;

/// Makes `wanted` the backend this process runs, for a caller that cannot take whichever backend
/// the kernel allows (decision 23). A program that sleeps in a wait of its own, with a loop inside
/// it, needs a loop with a descriptor that wait can hold (`Loop.wait_descriptor`). io_uring's loop
/// has none, so on Linux such a program calls `require_backend(.epoll)`.
///
/// Call it before anything else of this module: `sync`, a `Registry`, a `Loop` and `backend` each
/// make the choice when none is made, and it holds for the life of the process. It stores the
/// choice when none is stored and succeeds when the process already runs `wanted`. It answers
/// `OtherBackendChosen` when the process already runs another backend, and `Unsupported` when this
/// host cannot run `wanted`: `epoll` or `uring` on Darwin, `kqueue` on Linux, and `uring` where the
/// kernel refuses this process a ring. It never falls back, because the caller named the backend:
/// an error stores nothing, and `backend()` reports the choice as before.
pub fn require_backend(wanted: Backend) RequireError!void {
    return loop_module.require(wanted);
}

/// Opening, closing and naming a socket or a file: the calls a caller makes before it has a loop,
/// and the ones a loop does not make for it. The same twenty-four names on every backend. On Linux
/// they are in `rotor_sync.zig`.
pub const sync = if (linux) @import("rotor_sync.zig") else kqueue.sync;

/// Sizing the memory of a provided-buffer group. Every backend lays a group out the same way,
/// `core/buffer_group.zig`'s.
pub const buffers = struct {
    pub const group_alignment = loop_module.group_alignment;
    pub const group_bytes = core.buffer_group.group_bytes;
};

/// Whether a loop's file operations may block the loop thread, which is what decides whether
/// `Loop.Options.file_policy` and an offload mean anything (decision 18). On Linux it is true: a
/// process that runs epoll makes those calls itself, and io_uring checks the policy and ignores it,
/// so a caller that sets one is right on both. `backend()` says which one runs.
pub const files_block = if (linux) uring.files_block or epoll.files_block else kqueue.files_block;

/// Whether a `post` may be refused for lack of room at the target, from a loop or from a `Remote`:
/// what a caller may assume of `mailbox_full` and `MailboxFull` (decision 4). True on every backend
/// since 2026-09-25, when io_uring's posts moved to the mailbox rings every backend shares. A post
/// sees `constants.mailbox_posts_max` slots of each, and the rest wait for the returns of the calls
/// of decision 32.
pub const post_bounded = if (linux)
    uring.post_bounded or epoll.post_bounded
else
    kqueue.post_bounded;

/// True when a kernel this module can run on is the one running. False in a cross build.
pub const supported = if (linux) uring.supported or epoll.supported else kqueue.supported;

/// The registry a group of loops shares, for `post` between them (decision 4).
pub const Registry = loop_module.Registry;

/// What a thread that owns no loop holds to post with (decision 4).
pub const Remote = loop_module.Remote;

/// The loop. One belongs to one thread, holds no lock and starts no thread (decision 4).
pub const Loop = loop_module.Loop;

/// The loop's heartbeat as the program hands it to a thread it starts (decision 28):
/// `Loop.heartbeat` returns it. It declares only `watch`, and the types `Watch` and `Stuck`. `core`
/// names it `HeartbeatView`, because `core.Heartbeat` is what the loop writes.
pub const Heartbeat = core.HeartbeatView;

/// The host's reactor as the program hands it to a library (decision 28). `shared` returns it. A
/// library keeps it, and may submit, cancel, post, schedule tasks in its group, add pollers and use
/// buffer groups on it. `tick`, `drain`, `deinit`, `cancel_all` and `discard_tasks` fail to compile
/// on it, with a message that states the rule: only the program ticks a shared loop (decision 27,
/// ruling 1). So do `schedule`, `reserve_scheduling_group` and `set_scheduling_group_shares`: a
/// library names its group in each `schedule_in`, and only the program sets the groups (decision
/// 30). So does `wait_until`: a library bounds the wait with a poller (decision 33).
pub const SharedLoop = Reactor(Loop).SharedLoop;

/// The reactor over a loop (decision 33): a program that wants records with callbacks, pollers,
/// tasks, scheduling groups, cross-core calls or libraries that share its loop makes a
/// `Reactor(Loop)` in place of a `Loop`, and passes the loop's options as `.loop`. Each call of the
/// loop's does what the loop's call of the same name does, and the reactor's part of it. A reactor
/// bounds its wait with a poller, so `wait_until` fails to compile on it. `Reactor(Loop)` is the
/// host's reactor, and its functions are in `rotor_reactor.zig`. Any other type is a twin of
/// decision 10, which declares the core's surface and the port of decision 33: the build names
/// each declaration that it lacks.
pub fn Reactor(comptime Base: type) type {
    if (Base == Loop) return struct {
        /// The reactor's state: its pollers, its tasks and its scheduling groups. It comes before
        /// the loop, as in `reactor.Reactor(Loop)`.
        dispatch: reactor.Dispatch,
        /// The loop that the reactor runs, held by value, so `Reactor(T)` holds a `T`. No call
        /// gives it out: a call on it would skip the reactor's part of that call.
        loop: Loop,

        /// This type. The file declares `SharedLoop` and `CallRecord` too, so a name of the
        /// reactor's own is written through it.
        const Host = @This();
        const calls = reactor_calls;
        const shared_module = reactor.shared;

        /// What `init` takes. `loop` has no default, because `Loop.Options.operations` has none.
        pub const Options = struct {
            loop: Loop.Options,
            /// The groups that `init` reserves as ids 1 to n (decision 30).
            named_groups: reactor.scheduling.NamedTable = reactor.root_groups.table,
        };

        // The error sets of the loop, and the four of the reactor's own calls.
        pub const InitError = Loop.InitError;
        pub const TickError = Loop.TickError;
        pub const DrainError = TickError || error{ StillInFlight, TasksStillQueued };
        pub const RegisterError = Loop.RegisterError;
        pub const ProvideError = Loop.ProvideError;
        pub const PostError = Loop.PostError;
        pub const AddPollerError = reactor.AddPollerError;
        pub const ScheduleError = reactor.ScheduleError;
        pub const ReserveSchedulingGroupError = reactor.ReserveSchedulingGroupError;
        pub const CallError = reactor.CallError;

        /// The view of a library: `reactor_shared.zig` of the module `reactor`.
        pub const SharedLoop = opaque {
            const library = shared_module.Library(Host, @This());
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
            comptime handler: fn (context: *Context, record: *Host.CallRecord(Request, Reply)) Answer(Reply),
        ) type {
            return struct {
                /// One station for each loop, indexed by `LoopId`. Program memory, 128 B each.
                stations: [constants.loops_max]CallStation,

                const service = reactor.call.service.Service(@This(), Host.SharedLoop, Context, Request, Reply, handler);
                /// Every station unused.
                pub const init: @This() = .{ .stations = @splat(CallStation.unused) };
                pub const Call = Host.CallRecord(Request, Reply);
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

                const record = reactor.call.service.CallRecord(@This(), Host.SharedLoop, Request, Reply);
                pub const init = record.init;
                pub const is_out = record.is_out;
                pub const request_of = record.request_of;
                pub const answer = record.answer;
            };
        }

        // The core's surface, in `rotor_reactor.zig`.
        pub const memory_bytes = calls.memory_bytes;
        pub const init = calls.init;
        pub const deinit = calls.deinit;
        pub const dropped_wakes = calls.dropped_wakes;
        pub const submit = calls.submit;
        pub const cancel = calls.cancel;
        pub const post = calls.post;
        pub const tick = calls.tick;
        pub const heartbeat = calls.heartbeat;
        pub const in_flight = calls.in_flight;
        pub const now_ns = calls.now_ns;
        pub const wait_descriptor = calls.wait_descriptor;
        pub const statistics = calls.statistics;
        pub const cancel_all = calls.cancel_all;
        pub const drain = calls.drain;
        pub const assert_empty = calls.assert_empty;
        pub const register_buffers = calls.register_buffers;
        pub const register_descriptors = calls.register_descriptors;
        pub const provide_buffers = calls.provide_buffers;
        pub const provide_datagram_buffers = calls.provide_datagram_buffers;
        pub const datagram = calls.datagram;
        pub const give_back_buffer = calls.give_back_buffer;
        pub const release_buffers = calls.release_buffers;
        pub const provided_buffer = calls.provided_buffer;
        pub const reserve_buffer_group = calls.reserve_buffer_group;
        pub const wait_limit = calls.wait_limit;
        /// A reactor bounds its wait with a poller, so it refuses the plain loop's call.
        pub const wait_until = shared_module.refusals.reactor_wait_until;
        // The calls of the reactor, in `rotor_reactor.zig`.
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
    return reactor.Reactor(Base);
}

comptime {
    // The wrapped types carry the surface every backend must (decision 1). The backends check
    // this for themselves; checking it here as well is what makes this file's promise its own.
    core.surface.check(Loop);
    core.surface.check_remote(Remote);
}

test {
    _ = loop_module;
    _ = @import("rotor_loop_backend.zig");
    _ = @import("rotor_loop_registry.zig");
    _ = @import("rotor_loop_test.zig");
    _ = @import("rotor_test.zig");
    _ = @import("rotor_reactor_test.zig");
}
