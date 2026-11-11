//! rotor's public API: the one module a consumer imports, and the whole of what rotor supports.
//!
//! What a consumer needs is a `Loop`, the types it takes and returns, and the helpers that open a
//! socket and size the memory it hands a loop. That is what this file names, and nothing else of
//! the tree is reachable through it. The build registers this module alone, so a dependent package
//! cannot name a backend, and the types below carry exactly the surface `core/surface.zig` lists,
//! which the tests at the bottom hold them to. A backend's other public functions exist for its own
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
const service_module = @import("rotor_service.zig");

const linux = builtin.os.tag == .linux;

// The types a caller builds operations from and reads events with.
pub const Address = core.Address;
pub const Code = core.Code;
pub const Delivery = core.Delivery;
pub const Descriptor = core.Descriptor;
pub const Error = core.Error;
pub const Event = core.Event;
pub const Completion = core.Completion;
pub const Poller = core.Poller;
pub const WaitLimit = core.WaitLimit;
pub const BufferGroup = core.BufferGroup;
pub const Task = core.Task;
/// A task queue with shares on one loop (decision 30). `Loop.reserve_scheduling_group` makes one,
/// and `NamedSchedulingGroup.scheduling_group` gives one of the program's named groups.
pub const SchedulingGroup = core.SchedulingGroup;
/// A group that is the same group on every loop of the program: one of the names of the root
/// file's `rotor_scheduling_groups` (decision 30). A cross-core call names one (decision 32).
pub const NamedSchedulingGroup = core.NamedSchedulingGroup;
/// The program's names, from the root file's `rotor_scheduling_groups`: `enum { quic, dns }` for
/// `.{ .quic = 400, .dns = 100 }`. Empty when the root declares none.
pub const SchedulingGroupName = loop_module.root_groups.Name;
pub const Handle = core.Handle;
pub const LoopId = core.LoopId;
pub const Message = core.Message;
pub const Operation = core.Operation;

pub const Service = service_module.Service; // The cross-core call (decision 32).
pub const CallRecord = service_module.CallRecord;
pub const Answer = service_module.Answer;
pub const CallResult = service_module.CallResult;
pub const CallOptions = service_module.CallOptions;
pub const CallError = service_module.CallError;
pub const CallLink = core.call.CallLink;
pub const CallStation = core.call.CallStation;

/// Every named limit (CLAUDE.md, non-negotiable 1).
pub const constants = core.constants;

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
    return loop_module.named_scheduling_group(name);
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

/// The loop as the program hands it to a library (decision 28). `Loop.shared` returns it. A library
/// keeps it, and may submit, cancel, post, schedule tasks in its group, add pollers and use buffer
/// groups on it. `tick`, `drain`, `deinit`, `cancel_all` and `discard_tasks` fail to compile on it,
/// with a message that states the rule: only the program ticks a shared loop (decision 27, ruling
/// 1). So do `schedule`, `reserve_scheduling_group` and `set_scheduling_group_shares`: a library
/// names its group in each `schedule_in`, and only the program sets the groups (decision 30).
pub const SharedLoop = loop_module.SharedLoop;

/// The reactor over a loop (decision 33): a program that wants records with callbacks, pollers,
/// tasks, scheduling groups, cross-core calls or libraries that share its loop makes a
/// `Reactor(Loop)` in place of a `Loop`, and passes the loop's options as `.loop`. Each call does
/// what the loop's call of the same name does. `Reactor(Loop)` is the host's reactor, and its
/// functions are in `rotor_reactor.zig`. Any other type is a twin of decision 10, which declares the
/// core's surface and the port of decision 33: the build names each declaration that it lacks.
pub fn Reactor(comptime Base: type) type {
    if (Base == Loop) return struct {
        /// The loop that the reactor runs, held by value, so `Reactor(T)` holds a `T`. No call
        /// gives it out: a call on it would skip the reactor's part of that call.
        loop: Loop,

        /// This type. The file declares `SharedLoop` and `CallRecord` too, so a name of the
        /// reactor's own is written through it.
        const Host = @This();
        const calls = reactor_calls;

        /// What `init` takes. `loop` has no default, because `Loop.Options.operations` has none.
        pub const Options = struct { loop: Loop.Options };
        /// The reactor as the program hands it to a library (decision 28). `shared` returns it.
        pub const SharedLoop = core.shared_loop.SharedLoop(Host);
        /// One kind of cross-core call over this reactor's view (decision 32).
        pub fn Service(
            comptime Context: type,
            comptime Request: type,
            comptime Reply: type,
            comptime handler: fn (context: *Context, record: *Host.CallRecord(Request, Reply)) core.call.Answer(Reply),
        ) type {
            return core.call.Service(Host.SharedLoop, Context, Request, Reply, handler);
        }
        /// The caller's record of one call over this reactor's view (decision 32).
        pub fn CallRecord(comptime Request: type, comptime Reply: type) type {
            return core.call.CallRecord(Host.SharedLoop, Request, Reply);
        }

        // The error sets of `Loop`, the same on the reactor.
        pub const InitError = Loop.InitError;
        pub const TickError = Loop.TickError;
        pub const DrainError = Loop.DrainError;
        pub const RegisterError = Loop.RegisterError;
        pub const ProvideError = Loop.ProvideError;
        pub const PostError = Loop.PostError;
        pub const AddPollerError = Loop.AddPollerError;
        pub const ScheduleError = Loop.ScheduleError;
        pub const ReserveSchedulingGroupError = Loop.ReserveSchedulingGroupError;
        pub const CallError = Loop.CallError;

        // Each name of `Loop`, in `rotor_reactor.zig`.
        pub const memory_bytes = calls.memory_bytes;
        pub const init = calls.init;
        pub const deinit = calls.deinit;
        pub const dropped_wakes = calls.dropped_wakes;
        pub const submit = calls.submit;
        pub const cancel = calls.cancel;
        pub const post = calls.post;
        pub const tick = calls.tick;
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

const testing = std.testing;

/// The declarations of `Loop` beyond the surface: its error sets, and nothing else.
const loop_error_sets = [_][]const u8{
    "InitError",                   "TickError", "DrainError",     "RegisterError",
    "ProvideError",                "PostError", "AddPollerError", "ScheduleError",
    "ReserveSchedulingGroupError", "CallError",
};
const remote_error_sets = [_][]const u8{ "InitError", "PostError" };
const registry_declarations = [_][]const u8{
    "memory_bytes", "init", "loop_count", "GroupError", "AttachError", "init_group", "attach", "release",
    "deinit",
};

fn named(comptime T: type, comptime lists: []const []const []const u8) bool {
    inline for (@typeInfo(T).@"struct".decls) |declaration| {
        var found = false;
        inline for (lists) |list| {
            for (list) |name| {
                if (std.mem.eql(u8, name, declaration.name)) found = true;
            }
        }
        if (!found) return false;
    }
    return true;
}

test "the public types carry the surface and their error sets, and nothing else" {
    const surface = core.surface;
    try testing.expect(named(Loop, &.{ &surface.loop_declarations, &loop_error_sets }));
    try testing.expectEqual(surface.loop_declarations.len + loop_error_sets.len, @typeInfo(Loop).@"struct".decls.len);
    try testing.expect(named(Remote, &.{ &surface.remote_declarations, &remote_error_sets }));
    try testing.expectEqual(surface.remote_declarations.len + remote_error_sets.len, @typeInfo(Remote).@"struct".decls.len);
    try testing.expect(named(Registry, &.{&registry_declarations}));
    try testing.expectEqual(registry_declarations.len, @typeInfo(Registry).@"struct".decls.len);
    // One field each: what is wrapped, and no state of this file's own.
    try testing.expectEqual(1, @typeInfo(Loop).@"struct".fields.len);
    try testing.expectEqual(1, @typeInfo(Remote).@"struct".fields.len);
    try testing.expectEqual(1, @typeInfo(Registry).@"struct".fields.len);
}

/// The declarations of the host's reactor beyond the surface and the error sets of `Loop`.
const reactor_types = [_][]const u8{ "SharedLoop", "Service", "CallRecord" };

test "the host's reactor carries the loop's surface, its error sets and its view, and nothing else" {
    const Host = Reactor(Loop);
    try testing.expect(named(Host, &.{ &core.surface.loop_declarations, &loop_error_sets, &reactor_types }));
    const count = core.surface.loop_declarations.len + loop_error_sets.len + reactor_types.len;
    try testing.expectEqual(count, @typeInfo(Host).@"struct".decls.len);
    // One field: what it holds, and at step 2 of decision 33 no state of its own.
    try testing.expectEqual(1, @typeInfo(Host).@"struct".fields.len);
    comptime core.shared_loop.check(Host.SharedLoop);
}

const test_operations = 4;
const test_options: Loop.Options = .{ .operations = test_operations };
const test_timer_ns = constants.ns_per_ms;
const test_wait_ms = 50;
const test_wait_ns = test_wait_ms * constants.ns_per_ms;

test "a loop built through the public module runs, cancels, drains and counts" {
    if (!supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &test_options);
    defer loop.deinit();
    var handles = [_]Handle{.none};
    var events: [4]Event = undefined;

    // A timer fires, with its user data, inside one waiting tick. No clock is read before the first
    // tick, and the tick that hands the fire over read at least the timer's wait.
    try testing.expectEqual(0, loop.now_ns());
    try testing.expectEqual(1, loop.submit(&.{Operation.timer(7, test_timer_ns, 0)}, &handles));
    try testing.expect(handles[0] != Handle.none);
    try testing.expectEqual(1, loop.in_flight());
    try testing.expectEqual(1, try loop.tick(&events, test_wait_ns));
    try testing.expect(loop.now_ns() >= test_timer_ns);
    try testing.expectEqual(7, events[0].user_data);
    try testing.expectEqual(0, try events[0].outcome());
    try testing.expectEqual(0, loop.in_flight());
    // The statistics are reachable; what they hold is sampled and decision 9's to define.
    try testing.expect(loop.statistics().sample_mask >= 1);

    // A cancelled timer ends with Canceled, and drain leaves nothing in flight.
    _ = loop.submit(&.{Operation.timer(8, constants.ns_per_s, 0)}, &handles);
    loop.cancel(handles[0]);
    try testing.expectEqual(1, try loop.tick(&events, test_wait_ns));
    try testing.expectError(error.Canceled, events[0].outcome());
    _ = loop.submit(&.{Operation.timer(9, constants.ns_per_s, 0)}, &.{});
    loop.cancel_all();
    try loop.drain(&events);
    loop.assert_empty();
}

test "a registry and a remote work through the public module" {
    if (!supported) return error.SkipZigTest;
    // Three slots: the loop, the remote, and one that runs nothing.
    var registry_memory: [Registry.memory_bytes(3)]u8 align(memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&registry_memory, 3);
    defer registry.deinit();
    try testing.expectEqual(3, registry.loop_count());
    var memory: [Loop.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    var options = test_options;
    options.registry = &registry;
    try loop.init(&memory, &options);
    defer loop.deinit();
    var remote: Remote = undefined;
    try remote.init(&registry, 1);
    defer remote.deinit();

    try remote.post(0, .{ .payload = 41, .tag = 3 });
    var events: [4]Event = undefined;
    try testing.expectEqual(1, try loop.tick(&events, test_wait_ns));
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(41, events[0].user_data);
    try testing.expectEqual(3, events[0].result);
    try testing.expectError(error.LoopNotFound, remote.post(2, .{ .payload = 0, .tag = 0 }));
}

test "a loop posts to another loop through the public module, with no event of its own" {
    if (!supported) return error.SkipZigTest;
    // Two loops on this thread, and a third id that runs nothing.
    var registry_memory: [Registry.memory_bytes(3)]u8 align(memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&registry_memory, 3);
    defer registry.deinit();
    var options = test_options;
    options.registry = &registry;
    var sender_memory: [Loop.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var sender: Loop = undefined;
    try sender.init(&sender_memory, &options);
    defer sender.deinit();
    options.id = 1;
    var receiver_memory: [Loop.memory_bytes(&test_options)]u8 align(memory_alignment) = undefined;
    var receiver: Loop = undefined;
    try receiver.init(&receiver_memory, &options);
    defer receiver.deinit();

    try sender.post(1, .{ .payload = 41, .tag = 3 });
    try testing.expectError(error.LoopNotFound, sender.post(2, .{ .payload = 0, .tag = 0 }));
    var events: [4]Event = undefined;
    try testing.expectEqual(0, try sender.tick(&events, 0));
    try testing.expectEqual(1, try receiver.tick(&events, test_wait_ns));
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(41, events[0].user_data);
    try testing.expectEqual(3, events[0].result);
}

test {
    _ = loop_module;
    _ = @import("rotor_loop_backend.zig");
    _ = @import("rotor_loop_registry.zig");
    _ = @import("rotor_loop_test.zig");
    _ = @import("rotor_test.zig");
}
