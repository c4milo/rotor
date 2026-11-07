//! The public `Loop` and `Remote`, which wrap the backend this process runs.
//! `rotor_loop_backend.zig` says how a process comes to run one, `rotor_loop_registry.zig` holds
//! the public `Registry`, and `rotor_loop_buffers.zig` holds the calls of a loop's buffers.
//!
//! Each type below wraps a tagged union with one member per backend this build carries. On Darwin
//! that is kqueue alone, so a call there has no branch to take.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
const uring = @import("uring");
const epoll = @import("epoll");
const kqueue = @import("kqueue");
const backend_module = @import("rotor_loop_backend.zig");
const buffers = @import("rotor_loop_buffers.zig");

const constants = core.constants;

const linux = builtin.os.tag == .linux;

// The choice of backend, which every file of this module reaches through this one.
pub const Backend = backend_module.Backend;
pub const Tag = backend_module.Tag;
pub const module = backend_module.module;
pub const chosen = backend_module.chosen;
pub const RequireError = backend_module.RequireError;
pub const require = backend_module.require;

pub const Registry = @import("rotor_loop_registry.zig").Registry;

/// What a thread that owns no loop holds to post with (decision 4). It takes one slot of the
/// registry, sends, and never receives.
pub const Remote = struct {
    inner: Inner,

    const Inner = if (linux)
        union(Tag) { uring: uring.Remote, epoll: epoll.Remote }
    else
        union(Tag) { kqueue: kqueue.Remote };

    pub const InitError = core.remote.InitError;
    pub const PostError = core.remote.PostError;

    /// Claims `id` for the calling thread. Must run on the thread that will post.
    pub fn init(remote: *Remote, registry: *Registry, id: core.LoopId) InitError!void {
        switch (registry.inner) {
            inline else => |*inner, tag| {
                remote.inner = @unionInit(Inner, @tagName(tag), undefined);
                return @field(remote.inner, @tagName(tag)).init(inner, id);
            },
        }
    }

    pub fn deinit(remote: *Remote) void {
        switch (remote.inner) {
            inline else => |*inner| inner.deinit(),
        }
    }

    /// Sends one message to the loop `target` runs, or says why it could not.
    pub fn post(remote: *Remote, target: core.LoopId, message: core.Message) PostError!void {
        return switch (remote.inner) {
            inline else => |*inner| inner.post(target, message),
        };
    }

    /// The wakes the kernel refused since `init`, or that found no room to be sent. It stays
    /// readable after `deinit`, until the next `init`. Each message is in its target's mailbox,
    /// and the target reads it when its wait ends (decision 4, third amendment of 2026-11-06).
    pub fn dropped_wakes(remote: *const Remote) u64 {
        return switch (remote.inner) {
            inline else => |*inner| inner.dropped_wakes(),
        };
    }
};

/// The loop as the program hands it to a library (decision 28): `core/shared_loop.zig`.
pub const SharedLoop = core.shared_loop.SharedLoop(Loop);

/// The loop. One belongs to one thread, holds no lock and starts no thread (decision 4).
/// `docs/using.md` says what it promises and what it needs.
pub const Loop = struct {
    inner: Inner,

    const Inner = if (linux)
        union(Tag) { uring: uring.Loop, epoll: epoll.Loop }
    else
        union(Tag) { kqueue: kqueue.Loop };

    pub const InitError = if (linux) uring.InitError || epoll.InitError else kqueue.InitError;
    pub const TickError = if (linux) uring.TickError || epoll.TickError else kqueue.TickError;
    pub const DrainError = TickError || error{ StillInFlight, TasksStillQueued };
    pub const RegisterError = if (linux)
        uring.buffers.RegisterError || uring.descriptors.RegisterError ||
            epoll.buffers.RegisterError || epoll.descriptors_module.RegisterError
    else
        kqueue.buffers.RegisterError || kqueue.descriptors_module.RegisterError;
    pub const ProvideError = if (linux)
        uring.buffers.ProvideError || epoll.buffers.ProvideError
    else
        kqueue.buffers.ProvideError;
    /// Why `post` sent nothing: the same on every backend.
    pub const PostError = core.remote.SendError;

    pub const Options = struct {
        /// The most operations in flight, which is the slots in the table:
        /// [1, constants.operations_max].
        operations: u32,
        /// Submission ring entries on io_uring, a power of two in [1, 32768], or 0 for the
        /// default: `operations` rounded up to a power of two and capped at that most. kqueue and
        /// epoll take it and size nothing by it.
        entries: u16 = 0,
        /// How often the loop measures an operation (decision 9).
        sampling: core.statistics.Options = .{},
        /// How long a tick polls without waiting before it blocks, in nanoseconds, at most
        /// `constants.spin_budget_ns_max` (decision 13). 0, the default, never polls. A loop with a
        /// budget answers a message that comes inside it without being woken, and spends the budget
        /// in CPU on every wait that outlasts it. On macOS a message that comes after the budget
        /// also arrives about 11 µs later than with no budget: 12.5 to 14.5 µs against 1.0 to 3.5,
        /// measured on 2026-09-25 (decision 13, "kqueue").
        spin_budget_ns: u64 = 0,
        /// A turn of the loop at or above this, in nanoseconds, counts as a stall in
        /// `statistics()`, and null counts none (decision 28). A turn runs from one tick's first
        /// clock stamp to the next tick's, and holds no kernel wait. A host that sleeps in its
        /// own wait sets null, because its sleep reads as one long turn (decision 23).
        stall_turn_ns: ?u64 = constants.stall_turn_ns_default,
        /// This loop's id among the loops of `registry`.
        id: core.LoopId = 0,
        /// Where loops find each other, for `post`. Null for a loop that posts to none and that
        /// none posts to.
        registry: ?*Registry = null,
        /// What the loop does with `read`, `write`, `fdatasync` and `fsync` on a backend whose file
        /// operations block (decision 18). io_uring checks it as epoll does, and then ignores it.
        file_policy: core.offload.FilePolicy = .refuse,
        /// The caller's threads, required when `file_policy` is `offload` and refused otherwise.
        offload: ?core.offload.Offload = null,
        /// Memory for the offload's rings, of `offload_memory_bytes(offload.?.workers)` bytes. The
        /// caller owns it because its own threads write it.
        offload_memory: []align(core.layout.memory_alignment) u8 = &.{},

        /// These options for the backend `tag` names. The registry is that backend's own, which is
        /// the member its union holds: every registry and loop of a process follow one choice.
        fn lower(options: Options, comptime tag: Tag) module(tag).Loop.Options {
            var lowered = options.sizing(tag);
            if (options.registry) |registry| {
                lowered.registry = &@field(registry.inner, @tagName(tag));
            }
            return lowered;
        }

        /// These options for sizing memory for the backend `tag` names, which reads no registry.
        fn sizing(options: Options, comptime tag: Tag) module(tag).Loop.Options {
            return .{
                .operations = options.operations,
                .entries = options.entries,
                .sampling = options.sampling,
                .spin_budget_ns = options.spin_budget_ns,
                .stall_turn_ns = options.stall_turn_ns,
                .id = options.id,
                .registry = null,
                .file_policy = options.file_policy,
                .offload = options.offload,
                .offload_memory = options.offload_memory,
            };
        }
    };

    /// The bytes of memory `init` needs for `options`, aligned to `memory_alignment`: the most any
    /// backend this build carries needs, because the memory is sized before the choice is made.
    pub fn memory_bytes(options: Options) usize {
        var most: usize = 0;
        inline for (comptime std.enums.values(Tag)) |tag| {
            most = @max(most, module(tag).Loop.memory_bytes(options.sizing(tag)));
        }
        return most;
    }

    /// Must run on the thread that will own the loop (decision 4). Runs the backend this process
    /// chose, which `rotor.backend()` reports.
    pub fn init(
        loop: *Loop,
        memory: []align(core.layout.memory_alignment) u8,
        options: Options,
    ) InitError!void {
        switch (chosen()) {
            inline else => |tag| {
                loop.inner = @unionInit(Inner, @tagName(tag), undefined);
                return @field(loop.inner, @tagName(tag)).init(memory, options.lower(tag));
            },
        }
    }

    /// Requires an empty loop: `cancel_all` and `drain` first.
    pub fn deinit(loop: *Loop) void {
        switch (loop.inner) {
            inline else => |*inner| inner.deinit(),
        }
    }

    /// The wakes the loop dropped since `init`, on every backend. It stays readable after
    /// `deinit`, until the next `init` (decision 4, fourth amendment of 2026-11-06). A wake is
    /// dropped when the kernel refuses it, in `post`, in a tick that sends the wakes of post
    /// operations, or in `deinit`. On io_uring `deinit` also drops a wake it found no room to
    /// send. A target that stopped refuses its wake, so a normal shutdown can leave the count
    /// above 0. Each message is in its target's mailbox, and the target reads it when its wait
    /// ends, at most `wait_ns_max` later.
    pub fn dropped_wakes(loop: *const Loop) u64 {
        return switch (loop.inner) {
            inline else => |*inner| inner.dropped_wakes(),
        };
    }

    /// Takes a batch of operations, at most `constants.batch_max`, and returns how many it took.
    /// `handles` is empty or one per operation.
    pub fn submit(loop: *Loop, operations: []const core.Operation, handles: []core.Handle) u32 {
        return switch (loop.inner) {
            inline else => |*inner| inner.submit(operations, handles),
        };
    }

    /// Asks for the operation's final event to come early (decision 5, rule 2).
    pub fn cancel(loop: *Loop, handle: core.Handle) void {
        switch (loop.inner) {
            inline else => |*inner| inner.cancel(handle),
        }
    }

    /// Sends `message` to loop `target` now, with no operation, so no slot and no event (decision
    /// 4, amended 2026-09-29): `LoopNotFound` for an id that runs no loop, `MailboxFull` when the
    /// ring to it has no room. The message is in the target's ring when this returns. A target that
    /// sleeps is woken at once on kqueue and epoll, and by this loop's next tick on io_uring, whose
    /// submit carries the wake. When `deinit` comes before that tick, `deinit` sends the wake
    /// (decision 4, amended 2026-11-06). Post operations wake each target once per flush, which is
    /// cheaper for a burst to one loop.
    pub fn post(loop: *Loop, target: core.LoopId, message: core.Message) PostError!void {
        return switch (loop.inner) {
            inline else => |*inner| inner.post(target, message),
        };
    }

    /// Delivers events and returns how many. `wait_ns` of 0 polls; otherwise the tick blocks until
    /// an event is ready or the wait passes, at most `constants.wait_ns_max`.
    pub fn tick(loop: *Loop, events: []core.Event, wait_ns: u64) TickError!u32 {
        return switch (loop.inner) {
            inline else => |*inner| inner.tick(events, wait_ns),
        };
    }

    /// Adds `poller`, which the loop calls once in each tick (decision 26).
    pub fn add_poller(loop: *Loop, poller: *core.Poller) core.dispatch.AddPollerError!void {
        return switch (loop.inner) {
            inline else => |*inner| inner.add_poller(poller),
        };
    }

    /// Removes `poller`, which must have been added.
    pub fn remove_poller(loop: *Loop, poller: *core.Poller) void {
        switch (loop.inner) {
            inline else => |*inner| inner.remove_poller(poller),
        }
    }

    /// Asks the loop to call `task.run` once, later (decision 27).
    pub fn schedule(loop: *Loop, task: *core.Task) core.ScheduleError!void {
        return switch (loop.inner) {
            inline else => |*inner| inner.schedule(task),
        };
    }

    /// True while `task` is queued on this loop.
    pub fn is_scheduled(loop: *const Loop, task: *const core.Task) bool {
        return switch (loop.inner) {
            inline else => |*inner| inner.is_scheduled(task),
        };
    }

    /// The tasks queued now.
    pub fn tasks_queued(loop: *const Loop) u32 {
        return switch (loop.inner) {
            inline else => |*inner| inner.tasks_queued(),
        };
    }

    /// `tasks_per_tick_max` less the tasks the current run started, and 0 outside a run.
    pub fn task_budget_left(loop: *const Loop) u32 {
        return switch (loop.inner) {
            inline else => |*inner| inner.task_budget_left(),
        };
    }

    /// Unlinks every queued task without a call, after `drain` returned `TasksStillQueued`.
    pub fn discard_tasks(loop: *Loop) u32 {
        return switch (loop.inner) {
            inline else => |*inner| inner.discard_tasks(),
        };
    }

    /// Operations that have not had their final event.
    pub fn in_flight(loop: *const Loop) u32 {
        return switch (loop.inner) {
            inline else => |*inner| inner.in_flight(),
        };
    }

    /// The monotonic clock in nanoseconds, as the last `tick` read it, which timers expire
    /// against. A timer submitted now runs its `after_ns` from this reading, so it is due at this
    /// plus its `after_ns`, and fires no earlier (decision 14, rule 6). 0 until the first tick.
    pub fn now_ns(loop: *const Loop) u64 {
        return switch (loop.inner) {
            inline else => |*inner| inner.now_ns(),
        };
    }

    /// The descriptor a host that owns the wait sleeps on, or null when this loop has none
    /// (decision 23). Some programs cannot block inside `tick`, because other things must wake
    /// them too. Such a host sleeps in a wait of its own, with this descriptor among what it waits
    /// on, and ticks the loop when the descriptor is readable.
    ///
    /// On kqueue it is the loop's kqueue, and on epoll the loop's epoll instance. It is readable
    /// when a descriptor an operation of this loop waits on is ready. On io_uring there is none:
    /// the kernel posts a completion only when the loop's thread enters the ring, so nothing wakes
    /// that thread while it sleeps elsewhere. A host that must sleep elsewhere calls
    /// `rotor.require_backend(.epoll)` first on Linux.
    ///
    /// What the host does, in a cycle (decision 29):
    /// - It ticks with a wait of 0.
    /// - It calls `wait_limit` as its last call before it sleeps. On `.now` it ticks again.
    /// - It sleeps in its own wait, with this descriptor among what it waits on. On `.at(t)` it
    ///   sleeps for `t -| now_ns()` at most. On `.none` its own wait bounds the sleep.
    /// - It ticks that way after it submits or cancels too, before it waits: an operation reaches
    ///   the kernel in a tick.
    /// - It gives every tick a wait of 0. A tick that blocks arms the loop's wait timer, which
    ///   makes the descriptor readable later for no operation.
    /// - It does nothing else to the descriptor. It does not read it, close it, or change what it
    ///   holds, and it stops waiting on it before `deinit`, which closes it.
    ///
    /// What does not make it readable, so the host wakes for it by its own means: a timer, a
    /// poller's limit or an operation's deadline that comes due, which `wait_limit` reports; and a
    /// message or a `Message.wake` another loop or a `Remote` posts, or an offload worker's result,
    /// because only a loop that blocks in `tick` asks to be woken for those.
    ///
    /// While an operation of the loop waits on a descriptor, this one is not readable after a tick
    /// that delivers nothing. While none waits, a tick with a wait of 0 asks the kernel nothing,
    /// so readiness the kernel holds for no operation stays, and the descriptor stays readable
    /// until an operation waits again (decision 23, open question 3).
    pub fn wait_descriptor(loop: *const Loop) ?core.Descriptor {
        return switch (loop.inner) {
            inline else => |*inner| inner.wait_descriptor(),
        };
    }

    /// The host's last call before it sleeps in its own wait (decision 29). Returns how long it may
    /// sleep, on the loop's clock: `.now` while a task is queued, an operation waits to be
    /// submitted, a result waits to be handed over, a ring holds a message or a worker's result,
    /// the last tick kept a kernel error, or the nearest timer or poller limit is due. A poller that returned `.now`, a wake the last tick took, and a record
    /// or a task the last tick called each give `.now`. Otherwise `.at` of the nearest limit, or
    /// `.none`. It reads no clock and changes no state. Only the program calls it, on the loop's
    /// thread, between ticks: inside a tick it halts. `SharedLoop` does not declare it.
    pub fn wait_limit(loop: *Loop) core.WaitLimit {
        return switch (loop.inner) {
            inline else => |*inner| inner.wait_limit(),
        };
    }

    pub fn statistics(loop: *const Loop) *const core.statistics.Statistics {
        return switch (loop.inner) {
            inline else => |*inner| inner.statistics(),
        };
    }

    /// The view that the program hands to each library at init (decision 28). Its address is this
    /// loop's, and it declares only the calls a library may make: `tick`, `drain`, `deinit`,
    /// `cancel_all` and `discard_tasks` fail to compile on it. Only the program calls this, on the
    /// loop's thread.
    pub fn shared(loop: *Loop) *SharedLoop {
        switch (loop.inner) {
            inline else => |*inner| inner.assert_owner(),
        }
        return @ptrCast(loop);
    }

    /// The loop's heartbeat, for a thread that the program starts (decision 28). That thread
    /// calls `watch` on it, then `check` once in each period it chooses, and `Watch.end` before
    /// this loop's `deinit`, which halts while a watch reads it. Only the program calls this, on
    /// the loop's thread.
    pub fn heartbeat(loop: *Loop) *core.Heartbeat {
        return switch (loop.inner) {
            inline else => |*inner| inner.heartbeat(),
        };
    }

    /// Asks every operation in flight to end.
    pub fn cancel_all(loop: *Loop) void {
        switch (loop.inner) {
            inline else => |*inner| inner.cancel_all(),
        }
    }

    /// Ticks until nothing is in flight, using `scratch` for the events.
    pub fn drain(loop: *Loop, scratch: []core.Event) DrainError!void {
        return switch (loop.inner) {
            inline else => |*inner| inner.drain(scratch),
        };
    }

    /// Halts when an operation is still in flight (decision 5, rule 7), or inside a tick.
    pub fn assert_empty(loop: *const Loop) void {
        switch (loop.inner) {
            inline else => |*inner| inner.assert_empty(),
        }
    }

    // The buffers of decisions 3, 12 and 29: `rotor_loop_buffers.zig`.
    pub const register_buffers = buffers.register_buffers;
    pub const register_descriptors = buffers.register_descriptors;
    pub const reserve_buffer_group = buffers.reserve_buffer_group;
    pub const provide_buffers = buffers.provide_buffers;
    pub const provide_datagram_buffers = buffers.provide_datagram_buffers;
    pub const datagram = buffers.datagram;
    pub const give_back_buffer = buffers.give_back_buffer;
    pub const release_buffers = buffers.release_buffers;
    pub const provided_buffer = buffers.provided_buffer;
};

/// The alignment of a provided-buffer group's memory. Every backend asks for io_uring's figure, so
/// one declaration in a caller's code serves whichever runs: all three take it from `core`.
pub const group_alignment = core.buffer_group.group_alignment;

const testing = std.testing;

test "the memory a loop and a registry ask for fits whichever backend runs" {
    const options: Loop.Options = .{ .operations = 8 };
    inline for (comptime std.enums.values(Tag)) |tag| {
        const needed = module(tag).Loop.memory_bytes(options.sizing(tag));
        try testing.expect(Loop.memory_bytes(options) >= needed);
        try testing.expect(Registry.memory_bytes(4) >= module(tag).Registry.memory_bytes(4));
    }
}
