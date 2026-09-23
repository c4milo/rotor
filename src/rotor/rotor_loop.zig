//! The public `Loop`, `Registry` and `Remote`, and the choice of backend they follow (decision 20,
//! open question 5, which the owner ruled on 2026-09-22: a fallback at init).
//!
//! **On Linux a process runs one of two backends.** `uring` where the kernel gives it a ring, and
//! `epoll` where the kernel refuses one, as Docker's default seccomp profile does. The choice is
//! made once, the first time anything needs it, and kept for the life of the process. Once and not
//! per loop, because the sockets `sync` opens before any loop exists must suit the backend the
//! loops will run: uring's sockets block, since the ring does the waiting, and epoll's must not,
//! since its loop makes each call itself. It is the one value rotor keeps outside the memory a
//! caller hands it.
//!
//! **The choice is reported, not silent.** `uring_ring.zig` promises never to fall back to a slower
//! path without saying so; `rotor.backend()` says which one this process runs.
//!
//! Each type below wraps a tagged union with one member per backend this build carries. On Darwin
//! that is kqueue alone, so a call there has no branch to take.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
const uring = @import("uring");
const epoll = @import("epoll");
const kqueue = @import("kqueue");

const linux = builtin.os.tag == .linux;

comptime {
    if (!linux and !builtin.os.tag.isDarwin()) {
        @compileError("rotor has no backend for this operating system");
    }
}

/// A backend a process can run, as `rotor.backend()` reports it.
pub const Backend = enum { uring, epoll, kqueue };

/// The backends this build carries: one member of each union below per value.
pub const Tag = if (linux) enum { uring, epoll } else enum { kqueue };

/// The module of the backend `tag` names.
pub fn module(comptime tag: Tag) type {
    return @field(modules, @tagName(tag));
}

/// Each backend's module under its tag's name, for `module`. A module this build does not carry is
/// never named, so it is never analysed.
const modules = struct {
    const uring = @import("uring");
    const epoll = @import("epoll");
    const kqueue = @import("kqueue");
};

/// The process's choice, as a `Tag`'s value, or `undecided` before anything asked.
var linux_choice: std.atomic.Value(u8) = .init(undecided);
const undecided: u8 = std.math.maxInt(u8);

/// The backend this process runs. On Linux it asks the kernel the first time, the way a uring loop
/// would ask, and keeps the answer; on Darwin there is nothing to ask.
///
/// Two threads that ask first at once both ask the kernel, and the first answer stored is the one
/// every thread gets, so no two loops of a process can disagree.
pub fn chosen() Tag {
    if (comptime !linux) return .kqueue;
    const known = linux_choice.load(.acquire);
    if (known != undecided) return @enumFromInt(known);
    const decided: Tag = if (uring.refused()) .epoll else .uring;
    const stored = linux_choice.cmpxchgStrong(undecided, @intFromEnum(decided), .acq_rel, .acquire);
    return @enumFromInt(stored orelse @intFromEnum(decided));
}

/// The registry a group of loops shares, for `post` between them (decision 4). The application
/// owns its memory and hands it to every loop and remote of the group.
pub const Registry = struct {
    inner: Inner,

    const Inner = if (linux)
        union(Tag) { uring: uring.Registry, epoll: epoll.Registry }
    else
        union(Tag) { kqueue: kqueue.Registry };

    /// The bytes `init` needs for `loop_count` loops and remotes: the most any backend this build
    /// carries needs, because the memory is sized before the choice is made.
    pub fn memory_bytes(loop_count: u16) usize {
        var most: usize = 0;
        inline for (comptime std.enums.values(Tag)) |tag| {
            most = @max(most, module(tag).Registry.memory_bytes(loop_count));
        }
        return most;
    }

    pub fn init(
        registry: *Registry,
        memory: []align(core.layout.memory_alignment) u8,
        loop_count: u16,
    ) void {
        switch (chosen()) {
            inline else => |tag| {
                registry.inner = @unionInit(Inner, @tagName(tag), undefined);
                @field(registry.inner, @tagName(tag)).init(memory, loop_count);
            },
        }
    }

    /// How many loops and remotes the registry was sized for.
    pub fn loops(registry: *const Registry) u16 {
        return switch (registry.inner) {
            inline else => |*inner| inner.loops(),
        };
    }
};

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
};

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
    pub const DrainError = TickError || error{StillInFlight};
    pub const RegisterError = if (linux)
        uring.buffers.RegisterError || uring.descriptors.RegisterError ||
            epoll.buffers.RegisterError || epoll.descriptors_module.RegisterError
    else
        kqueue.buffers.RegisterError || kqueue.descriptors_module.RegisterError;
    pub const ProvideError = if (linux)
        uring.buffers.ProvideError || epoll.buffers.ProvideError
    else
        kqueue.buffers.ProvideError;

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
        /// This loop's id among the loops of `registry`.
        id: core.LoopId = 0,
        /// Where loops find each other, for `post`. Null for a loop that posts to none and that
        /// none posts to.
        registry: ?*Registry = null,
        /// What the loop does with `read`, `write` and `fdatasync` on a backend whose file
        /// operations block (decision 18). io_uring takes it and ignores it.
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

    /// Delivers events and returns how many. `wait_ns` of 0 polls; otherwise the tick blocks until
    /// an event is ready or the wait passes, at most `constants.wait_ns_max`.
    pub fn tick(loop: *Loop, events: []core.Event, wait_ns: u64) TickError!u32 {
        return switch (loop.inner) {
            inline else => |*inner| inner.tick(events, wait_ns),
        };
    }

    /// Operations that have not had their final event.
    pub fn in_flight(loop: *const Loop) u32 {
        return switch (loop.inner) {
            inline else => |*inner| inner.in_flight(),
        };
    }

    pub fn statistics(loop: *const Loop) *const core.statistics.Statistics {
        return switch (loop.inner) {
            inline else => |*inner| inner.statistics(),
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

    /// Halts when an operation is still in flight (decision 5, rule 7).
    pub fn assert_empty(loop: *const Loop) void {
        switch (loop.inner) {
            inline else => |*inner| inner.assert_empty(),
        }
    }

    /// Registers buffers once, before an operation names one by index (decision 3, source 1).
    pub fn register_buffers(loop: *Loop, blocks: []const []u8) RegisterError!void {
        return switch (loop.inner) {
            inline else => |*inner| inner.register_buffers(blocks),
        };
    }

    /// Registers descriptors once, before an operation names one by index.
    pub fn register_descriptors(
        loop: *Loop,
        descriptors: []const core.Descriptor,
    ) RegisterError!void {
        return switch (loop.inner) {
            inline else => |*inner| inner.register_descriptors(descriptors),
        };
    }

    /// Makes group `group_id` out of `memory`: `count` buffers of `buffer_bytes`, in one block of
    /// `buffers.group_bytes(count, buffer_bytes)` bytes aligned to `buffers.group_alignment`.
    pub fn provide_buffers(
        loop: *Loop,
        group_id: u16,
        memory: []align(group_alignment) u8,
        count: u16,
        buffer_bytes: u32,
    ) ProvideError!void {
        return switch (loop.inner) {
            inline else => |*inner| inner.provide_buffers(group_id, memory, count, buffer_bytes),
        };
    }

    /// A buffer group for datagrams, with room in front of every buffer for what a datagram
    /// carries (decision 15). One loop serves one datagram shape.
    pub fn provide_datagram_buffers(
        loop: *Loop,
        group_id: u16,
        memory: []align(group_alignment) u8,
        count: u16,
        buffer_bytes: u32,
        group: core.datagram.GroupOptions,
    ) ProvideError!void {
        return switch (loop.inner) {
            inline else => |*inner| inner.provide_datagram_buffers(
                group_id,
                memory,
                count,
                buffer_bytes,
                group,
            ),
        };
    }

    /// The datagram an event of group `group_id` names: the only reader of such a buffer.
    pub fn datagram(loop: *const Loop, group_id: u16, event: core.Event) core.Delivery {
        return switch (loop.inner) {
            inline else => |*inner| inner.datagram(group_id, event),
        };
    }

    /// Returns a provided buffer to its group, after the caller has read it.
    pub fn give_back_buffer(loop: *Loop, group_id: u16, buffer_id: u16) void {
        switch (loop.inner) {
            inline else => |*inner| inner.give_back_buffer(group_id, buffer_id),
        }
    }

    /// The bytes of the provided buffer a receive event named.
    pub fn provided_buffer(loop: *const Loop, group_id: u16, buffer_id: u16) []u8 {
        return switch (loop.inner) {
            inline else => |*inner| inner.provided_buffer(group_id, buffer_id),
        };
    }
};

/// The alignment of a provided-buffer group's memory. Every backend asks for io_uring's figure, so
/// one declaration in a caller's code serves whichever runs; the comptime assert below holds them
/// to it.
pub const group_alignment = if (linux)
    uring.buffers.group_alignment
else
    kqueue.buffers.group_alignment;

comptime {
    if (linux) {
        std.debug.assert(uring.buffers.group_alignment == epoll.buffers.group_alignment);
        // Both lay a group out the same way, so a caller sizes one block for either.
        for ([_]u16{ 1, 64, 1024 }) |count| {
            std.debug.assert(uring.buffers.group_bytes(count, 2048) ==
                epoll.buffers.group_bytes(count, 2048));
        }
    }
}

const testing = std.testing;

test "a kept choice is what every later ask gets, whatever the kernel would say now" {
    if (comptime !linux) return error.SkipZigTest;
    // Asking the kernel again could split one process's loops and sockets between two backends if
    // its answer changed, as a seccomp filter installed later would change it. So the answer kept
    // is the answer. Planted here as the opposite of what this kernel says, then restored.
    const kernel_says = chosen();
    const planted: Tag = if (kernel_says == .uring) .epoll else .uring;
    linux_choice.store(@intFromEnum(planted), .release);
    defer linux_choice.store(@intFromEnum(kernel_says), .release);
    try testing.expectEqual(planted, chosen());
    try testing.expectEqual(planted, chosen());
}

test "the memory a loop and a registry ask for fits whichever backend runs" {
    const options: Loop.Options = .{ .operations = 8 };
    inline for (comptime std.enums.values(Tag)) |tag| {
        const needed = module(tag).Loop.memory_bytes(options.sizing(tag));
        try testing.expect(Loop.memory_bytes(options) >= needed);
        try testing.expect(Registry.memory_bytes(4) >= module(tag).Registry.memory_bytes(4));
    }
}

test "a kept choice is read, not asked again: a thousand asks cost far less than one probe" {
    if (comptime !linux) return error.SkipZigTest;
    // Every `sync` call that opens a socket asks, so asking the kernel each time would put several
    // system calls on each of them. The answer would not change, which is why only the cost shows.
    //
    // A kept answer is one atomic load, a few nanoseconds, so a burst of a thousand takes a few
    // microseconds. Asking the kernel again costs a refused `io_uring_setup` at the least, about a
    // microsecond under seccomp and far more where a ring is made and closed, so a burst that asked
    // every time takes a millisecond or more. The bound sits between, and the best of twenty bursts
    // decides, as the cost gates of `conformance_cost.zig` do: other work makes a burst slower and
    // never faster. The clock is the backend's test helper, because this module reads none.
    const asks = 1000;
    const attempts = 20;
    const bound_ns = 100 * core.constants.ns_per_us;
    const monotonic_ns = uring.testing.monotonic_ns;
    _ = chosen();
    var best_ns: u64 = std.math.maxInt(u64);
    for (0..attempts) |_| {
        const before = monotonic_ns();
        for (0..asks) |_| std.mem.doNotOptimizeAway(chosen());
        best_ns = @min(best_ns, monotonic_ns() - before);
    }
    try testing.expect(best_ns < bound_ns);
}
