//! rotor's public API: the one module a consumer imports, and the whole of what rotor supports.
//!
//! What a consumer needs is a `Loop`, the types it takes and returns, and the helpers that open a
//! socket and size the memory it hands a loop. That is what this file names, and nothing else of
//! the tree is reachable through it. The build registers this module alone, so a dependent package
//! cannot name a backend, and the types below carry exactly the surface `core/surface.zig` lists,
//! which the tests at the bottom hold them to. A backend's other public functions exist for its own
//! files, the benchmarks and the conformance suite, which live in this tree: they are not API, and
//! no dependent package can reach them (the owner's ruling of 2026-09-22).
//!
//! The backend is this host's: `uring` on Linux, `kqueue` on Darwin. Both carry the surface
//! (decision 1), so what a consumer writes is the same either way. A consumer that needs a backend
//! this host did not choose, such as a deterministic twin for replay (decision 10), writes a module
//! carrying this surface and imports it instead of this one.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
const uring = @import("uring");
const kqueue = @import("kqueue");

/// This host's backend. Private: a consumer reaches the parts of it named below, and nothing
/// else.
const backend = switch (builtin.os.tag) {
    .linux => uring,
    .macos, .ios, .tvos, .watchos, .visionos => kqueue,
    else => @compileError("rotor has no backend for this operating system"),
};

// The types a caller builds operations from and reads events with.
pub const Address = core.Address;
pub const Code = core.Code;
pub const Delivery = core.Delivery;
pub const Descriptor = core.Descriptor;
pub const Error = core.Error;
pub const Event = core.Event;
pub const Handle = core.Handle;
pub const LoopId = core.LoopId;
pub const Message = core.Message;
pub const Operation = core.Operation;

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

/// Files on a backend whose file operations block (decision 18): what the loop does with one, and
/// the caller's threads when it hands them out.
pub const offload = struct {
    pub const FilePolicy = core.offload.FilePolicy;
    pub const Offload = core.offload.Offload;
    pub const Work = core.offload.Work;
};

/// What a loop counts about itself, sampled (decision 9).
pub const statistics = struct {
    pub const Options = core.statistics.Options;
    pub const Statistics = core.statistics.Statistics;
};

/// Opening, closing and naming a socket or a file: the calls a caller makes before it has a loop,
/// and the ones a loop does not make for it. The same twenty names on both backends.
pub const sync = backend.sync;

/// Sizing the memory of a provided-buffer group.
pub const buffers = struct {
    pub const group_alignment = backend.buffers.group_alignment;
    pub const group_bytes = backend.buffers.group_bytes;
};

/// Whether this backend's file operations block the loop thread, which is what decides whether
/// `Loop.Options.file_policy` and an offload mean anything here (decision 18).
pub const files_block = backend.files_block;

/// Whether a `post` can be refused for lack of room at the target, from a loop or from a
/// `Remote`: what a caller may assume of `mailbox_full` and `MailboxFull` here (decision 4).
pub const post_bounded = backend.post_bounded;

/// True when this backend's kernel is the one running. False in a cross build.
pub const supported = backend.supported;

/// The bytes of memory `Loop.Options.offload_memory` needs for an offload of `workers` threads
/// (decision 18): the rings the workers answer through. 0 where `files_block` is false, because
/// that backend takes the option and ignores it.
pub fn offload_memory_bytes(workers: u16) usize {
    if (!@hasDecl(backend, "offload_module")) return 0;
    return backend.offload_module.memory_bytes(workers);
}

/// The registry a group of loops shares, for `post` between them (decision 4). The application
/// owns its memory and hands it to every loop and remote of the group.
pub const Registry = struct {
    inner: backend.Registry,

    /// The bytes `init` needs for `loop_count` loops and remotes.
    pub fn memory_bytes(loop_count: u16) usize {
        return backend.Registry.memory_bytes(loop_count);
    }

    pub fn init(registry: *Registry, memory: []align(memory_alignment) u8, loop_count: u16) void {
        registry.inner.init(memory, loop_count);
    }

    /// How many loops and remotes the registry was sized for.
    pub fn loops(registry: *const Registry) u16 {
        return registry.inner.loops();
    }
};

/// What a thread that owns no loop holds to post with (decision 4). It takes one slot of the
/// registry, sends, and never receives.
pub const Remote = struct {
    inner: backend.Remote,

    pub const InitError = core.remote.InitError;
    pub const PostError = core.remote.PostError;

    /// Claims `id` for the calling thread. Must run on the thread that will post.
    pub fn init(remote: *Remote, registry: *Registry, id: LoopId) InitError!void {
        return remote.inner.init(&registry.inner, id);
    }

    pub fn deinit(remote: *Remote) void {
        remote.inner.deinit();
    }

    /// Sends one message to the loop `target` runs, or says why it could not.
    pub fn post(remote: *Remote, target: LoopId, message: Message) PostError!void {
        return remote.inner.post(target, message);
    }
};

/// The loop. One belongs to one thread, holds no lock and starts no thread (decision 4).
/// `docs/using.md` says what it promises and what it needs.
pub const Loop = struct {
    inner: backend.Loop,

    pub const InitError = backend.InitError;
    pub const TickError = backend.TickError;
    pub const DrainError = backend.DrainError;
    pub const RegisterError = backend.buffers.RegisterError || backend.descriptors_module.RegisterError;
    pub const ProvideError = backend.buffers.ProvideError;

    pub const Options = struct {
        /// The most operations in flight, which is the slots in the table:
        /// [1, constants.operations_max].
        operations: u32,
        /// Submission ring entries on io_uring, a power of two in [1, 32768], or 0 for the
        /// default: `operations` rounded up to a power of two and capped at that most. kqueue
        /// takes it and sizes nothing by it.
        entries: u16 = 0,
        /// How often the loop measures an operation (decision 9).
        sampling: core.statistics.Options = .{},
        /// This loop's id among the loops of `registry`.
        id: LoopId = 0,
        /// Where loops find each other, for `post`. Null for a loop that posts to none and that
        /// none posts to.
        registry: ?*Registry = null,
        /// What the loop does with `read`, `write` and `fdatasync` on a backend whose file
        /// operations block (decision 18). io_uring takes it and ignores it.
        file_policy: offload.FilePolicy = .refuse,
        /// The caller's threads, required when `file_policy` is `offload` and refused otherwise.
        offload: ?offload.Offload = null,
        /// Memory for the offload's rings, of `offload_memory_bytes(offload.?.workers)` bytes. The
        /// caller owns it because its own threads write it.
        offload_memory: []align(memory_alignment) u8 = &.{},

        fn lower(options: Options) backend.Loop.Options {
            return .{
                .operations = options.operations,
                .entries = options.entries,
                .sampling = options.sampling,
                .id = options.id,
                .registry = if (options.registry) |registry| &registry.inner else null,
                .file_policy = options.file_policy,
                .offload = options.offload,
                .offload_memory = options.offload_memory,
            };
        }
    };

    /// The bytes of memory `init` needs for `options`, aligned to `memory_alignment`.
    pub fn memory_bytes(options: Options) usize {
        return backend.Loop.memory_bytes(options.lower());
    }

    /// Must run on the thread that will own the loop (decision 4).
    pub fn init(loop: *Loop, memory: []align(memory_alignment) u8, options: Options) InitError!void {
        return loop.inner.init(memory, options.lower());
    }

    /// Requires an empty loop: `cancel_all` and `drain` first.
    pub fn deinit(loop: *Loop) void {
        loop.inner.deinit();
    }

    /// Takes a batch of operations, at most `constants.batch_max`, and returns how many it took.
    /// `handles` is empty or one per operation.
    pub fn submit(loop: *Loop, operations: []const Operation, handles: []Handle) u32 {
        return loop.inner.submit(operations, handles);
    }

    /// Asks for the operation's final event to come early (decision 5, rule 2).
    pub fn cancel(loop: *Loop, handle: Handle) void {
        loop.inner.cancel(handle);
    }

    /// The loop's one system call: delivers events and returns how many. `wait_ns` of 0 polls;
    /// otherwise the tick blocks until an event is ready or the wait passes, at most
    /// `constants.wait_ns_max`.
    pub fn tick(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
        return loop.inner.tick(events, wait_ns);
    }

    /// Operations that have not had their final event.
    pub fn in_flight(loop: *const Loop) u32 {
        return loop.inner.in_flight();
    }

    pub fn statistics(loop: *const Loop) *const core.statistics.Statistics {
        return loop.inner.statistics();
    }

    /// Asks every operation in flight to end.
    pub fn cancel_all(loop: *Loop) void {
        loop.inner.cancel_all();
    }

    /// Ticks until nothing is in flight, using `scratch` for the events.
    pub fn drain(loop: *Loop, scratch: []Event) DrainError!void {
        return loop.inner.drain(scratch);
    }

    /// Halts when an operation is still in flight (decision 5, rule 7).
    pub fn assert_empty(loop: *const Loop) void {
        loop.inner.assert_empty();
    }

    /// Registers buffers once, before an operation names one by index (decision 3, source 1).
    pub fn register_buffers(loop: *Loop, blocks: []const []u8) RegisterError!void {
        return backend.buffers.register(&loop.inner, blocks);
    }

    /// Registers descriptors once, before an operation names one by index.
    pub fn register_descriptors(loop: *Loop, descriptors: []const Descriptor) RegisterError!void {
        return backend.descriptors_module.register(&loop.inner, descriptors);
    }

    /// Makes group `group_id` out of `memory`: `count` buffers of `buffer_bytes`, in one block of
    /// `buffers.group_bytes(count, buffer_bytes)` bytes aligned to `buffers.group_alignment`.
    pub fn provide_buffers(
        loop: *Loop,
        group_id: u16,
        memory: []align(buffers.group_alignment) u8,
        count: u16,
        buffer_bytes: u32,
    ) ProvideError!void {
        return backend.buffers.provide(&loop.inner, group_id, memory, count, buffer_bytes);
    }

    /// A buffer group for datagrams, with room in front of every buffer for what a datagram
    /// carries (decision 15). One loop serves one datagram shape.
    pub fn provide_datagram_buffers(
        loop: *Loop,
        group_id: u16,
        memory: []align(buffers.group_alignment) u8,
        count: u16,
        buffer_bytes: u32,
        group: core.datagram.GroupOptions,
    ) ProvideError!void {
        return loop.inner.provide_datagram_buffers(group_id, memory, count, buffer_bytes, group);
    }

    /// The datagram an event of group `group_id` names: the only reader of such a buffer.
    pub fn datagram(loop: *const Loop, group_id: u16, event: Event) core.Delivery {
        return loop.inner.datagram(group_id, event);
    }

    /// Returns a provided buffer to its group, after the caller has read it.
    pub fn give_back_buffer(loop: *Loop, group_id: u16, buffer_id: u16) void {
        backend.buffers.give_back(&loop.inner, group_id, buffer_id);
    }

    /// The bytes of the provided buffer a receive event named.
    pub fn provided_buffer(loop: *const Loop, group_id: u16, buffer_id: u16) []u8 {
        return loop.inner.provided_buffer(group_id, buffer_id);
    }
};

comptime {
    // The wrapped types carry the surface every backend must (decision 1). The backends check
    // this for themselves; checking it here as well is what makes this file's promise its own.
    core.surface.check(Loop);
    core.surface.check_remote(Remote);
}

const testing = std.testing;

/// The declarations of `Loop` beyond the surface: its error sets, and nothing else.
const loop_error_sets = [_][]const u8{
    "InitError", "TickError", "DrainError", "RegisterError", "ProvideError",
};
const remote_error_sets = [_][]const u8{ "InitError", "PostError" };
const registry_declarations = [_][]const u8{ "memory_bytes", "init", "loops" };

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

const test_operations = 4;
const test_options: Loop.Options = .{ .operations = test_operations };
const test_timer_ns = constants.ns_per_ms;
const test_wait_ms = 50;
const test_wait_ns = test_wait_ms * constants.ns_per_ms;

test "a loop built through the public module runs, cancels, drains and counts" {
    if (!supported) return error.SkipZigTest;
    var memory: [Loop.memory_bytes(test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, test_options);
    defer loop.deinit();
    var handles = [_]Handle{.none};
    var events: [4]Event = undefined;

    // A timer fires, with its user data, inside one waiting tick.
    try testing.expectEqual(1, loop.submit(&.{Operation.timer(7, test_timer_ns, 0)}, &handles));
    try testing.expect(handles[0] != Handle.none);
    try testing.expectEqual(1, loop.in_flight());
    try testing.expectEqual(1, try loop.tick(&events, test_wait_ns));
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
    try testing.expectEqual(3, registry.loops());
    var memory: [Loop.memory_bytes(test_options)]u8 align(memory_alignment) = undefined;
    var loop: Loop = undefined;
    var options = test_options;
    options.registry = &registry;
    try loop.init(&memory, options);
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
