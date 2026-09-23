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
//! The backend is this host's. On Darwin it is `kqueue`. On Linux it is `uring` where the kernel
//! gives the process a ring and `epoll` where the kernel refuses one, chosen once per process and
//! reported by `backend()` (decision 20, open question 5; `rotor_loop.zig` says how). Every backend
//! carries the surface (decision 1), so what a consumer writes is the same whichever runs. A
//! consumer that needs a backend of its own, such as a deterministic twin for replay (decision 10),
//! writes a module carrying this surface and imports it instead of this one.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
const uring = @import("uring");
const epoll = @import("epoll");
const kqueue = @import("kqueue");
const loop_module = @import("rotor_loop.zig");

const linux = builtin.os.tag == .linux;

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

/// Opening, closing and naming a socket or a file: the calls a caller makes before it has a loop,
/// and the ones a loop does not make for it. The same twenty-four names on every backend.
pub const sync = if (linux) linux_sync else kqueue.sync;

/// `sync` on Linux. Every call is the uring backend's, which are the same Linux calls the epoll
/// backend makes, except the three that open a socket: those open it the way the process's backend
/// needs, blocking for uring, whose ring does the waiting, and not blocking for epoll, whose loop
/// makes each call itself.
const linux_sync = struct {
    const from = uring.sync;

    pub const SocketError = from.SocketError;
    pub const ListenError = from.ListenError;
    pub const AddressError = from.AddressError;
    pub const OptionError = from.OptionError;
    pub const ListenOptions = from.ListenOptions;
    pub const local_address = from.local_address;
    pub const set_no_delay = from.set_no_delay;
    pub const close_now = from.close_now;
    pub const SocketBuffer = from.SocketBuffer;
    pub const BufferError = from.BufferError;
    pub const socket_buffer_bytes_max = from.socket_buffer_bytes_max;
    pub const set_buffer_bytes = from.set_buffer_bytes;
    pub const DatagramOptions = from.DatagramOptions;
    pub const OpenError = from.OpenError;
    pub const FileSizeError = from.FileSizeError;
    pub const SyncDirectoryError = from.SyncDirectoryError;
    pub const OpenOptions = from.OpenOptions;
    pub const open_file = from.open_file;
    pub const file_size = from.file_size;
    pub const set_file_size = from.set_file_size;
    pub const sync_directory = from.sync_directory;

    /// A TCP socket of `family`, closed on exec, for the backend this process runs.
    pub fn open_socket(family: Address.Family) SocketError!Descriptor {
        return switch (loop_module.chosen()) {
            .uring => uring.sync.open_socket(family),
            .epoll => epoll.sync.open_socket(family),
        };
    }

    /// socket, SO_REUSEADDR, SO_REUSEPORT when asked, bind, listen, for the backend this process
    /// runs.
    pub fn listen(address: *const Address, options: ListenOptions) ListenError!Descriptor {
        return switch (loop_module.chosen()) {
            .uring => uring.sync.listen(address, options),
            .epoll => epoll.sync.listen(address, .{
                .backlog = options.backlog,
                .reuse_port = options.reuse_port,
            }),
        };
    }

    /// A UDP socket of `family`, closed on exec, bound to `bind_to` when one is given, for the
    /// backend this process runs.
    pub fn open_datagram(
        family: Address.Family,
        bind_to: ?*const Address,
        options: DatagramOptions,
    ) ListenError!Descriptor {
        return switch (loop_module.chosen()) {
            .uring => uring.sync.open_datagram(family, bind_to, options),
            .epoll => epoll.sync.open_datagram(family, bind_to, .{
                .control = options.control,
                .dont_fragment = options.dont_fragment,
            }),
        };
    }
};

/// Sizing the memory of a provided-buffer group. Every backend lays a group out the same way, which
/// `rotor_loop.zig` holds with a comptime assert.
pub const buffers = struct {
    pub const group_alignment = loop_module.group_alignment;
    pub const group_bytes = if (linux) uring.buffers.group_bytes else kqueue.buffers.group_bytes;
};

/// Whether a loop's file operations may block the loop thread, which is what decides whether
/// `Loop.Options.file_policy` and an offload mean anything (decision 18). On Linux it is true: a
/// process that runs epoll makes those calls itself, and io_uring checks the policy and ignores it,
/// so a caller that sets one is right on both. `backend()` says which one runs.
pub const files_block = if (linux) uring.files_block or epoll.files_block else kqueue.files_block;

/// Whether a `post` may be refused for lack of room at the target, from a loop or from a `Remote`:
/// what a caller may assume of `mailbox_full` and `MailboxFull` (decision 4). On Linux it is true,
/// because epoll's rings are bounded where io_uring's are not; a caller that handles the refusal is
/// right on both.
pub const post_bounded = if (linux)
    uring.post_bounded or epoll.post_bounded
else
    kqueue.post_bounded;

/// True when a kernel this module can run on is the one running. False in a cross build.
pub const supported = if (linux) uring.supported or epoll.supported else kqueue.supported;

/// The bytes of memory `Loop.Options.offload_memory` needs for an offload of `workers` threads
/// (decision 18): the rings the workers answer through. On Linux it is what epoll needs, and what
/// io_uring checks for although it uses none of it; a caller sizes it before the choice is made.
pub fn offload_memory_bytes(workers: u16) usize {
    if (linux) return epoll.offload_module.memory_bytes(workers);
    return kqueue.offload_module.memory_bytes(workers);
}

/// The registry a group of loops shares, for `post` between them (decision 4).
pub const Registry = loop_module.Registry;

/// What a thread that owns no loop holds to post with (decision 4).
pub const Remote = loop_module.Remote;

/// The loop. One belongs to one thread, holds no lock and starts no thread (decision 4).
pub const Loop = loop_module.Loop;

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

test "every public function compiles for this host, not only the ones something calls" {
    // Zig analyses a function only when something names it. `register_descriptors` and
    // `register_buffers` did not compile for Linux until 2026-09-22, and no gate said so, because
    // nothing on Linux called them. Naming every function of every public type here closes that.
    inline for (.{ Loop, Registry, Remote, sync }) |T| {
        inline for (@typeInfo(T).@"struct".decls) |declaration| {
            const value = @field(T, declaration.name);
            if (@typeInfo(@TypeOf(value)) == .@"fn") _ = &value;
        }
    }
    _ = &backend;
    _ = &offload_memory_bytes;
}

test "the public sync carries the backend's twenty-four names, and nothing else" {
    const Host = if (linux) uring.sync else kqueue.sync;
    const own = @typeInfo(sync).@"struct".decls;
    // Its own private helper aside, the public sync names what the backend's names.
    var public: usize = 0;
    inline for (own) |declaration| {
        try testing.expect(@hasDecl(Host, declaration.name));
        public += 1;
    }
    try testing.expectEqual(@typeInfo(Host).@"struct".decls.len, public);
}

test "the process runs io_uring where the kernel takes a ring, and epoll where it refuses one" {
    if (!linux) {
        try testing.expectEqual(Backend.kqueue, backend());
        return;
    }
    // Asked here directly, with one raw `io_uring_setup`, rather than through the backend's own
    // probe: a probe that always answered one way would pass a test that asked it.
    const os = std.os.linux;
    var params = std.mem.zeroes(os.io_uring_params);
    const rc = os.io_uring_setup(1, &params);
    const refused = switch (os.errno(rc)) {
        .SUCCESS => blk: {
            _ = os.close(@intCast(rc));
            break :blk false;
        },
        .PERM, .NOSYS => true,
        else => return error.SkipZigTest,
    };
    try testing.expectEqual(if (refused) Backend.epoll else Backend.uring, backend());
    // The choice holds: a second ask is answered the same, from what the first kept.
    try testing.expectEqual(backend(), backend());
}

test "a socket from sync suits the backend: it does not block exactly when epoll runs" {
    if (!supported or !linux) return error.SkipZigTest;
    const os = std.os.linux;
    const socket = try sync.open_socket(.ipv4);
    defer sync.close_now(socket);
    const listener = try sync.listen(&Address.ipv4(.{ 127, 0, 0, 1 }, 0), .{
        .backlog = 1,
        .reuse_port = false,
    });
    defer sync.close_now(listener);
    const datagram_socket = try sync.open_datagram(.ipv4, null, .{});
    defer sync.close_now(datagram_socket);
    for ([_]Descriptor{ socket, listener, datagram_socket }) |descriptor| {
        const flags = os.fcntl(descriptor, os.F.GETFL, 0);
        try testing.expectEqual(os.E.SUCCESS, os.errno(flags));
        const status: os.O = @bitCast(@as(u32, @intCast(flags)));
        try testing.expectEqual(backend() == .epoll, status.NONBLOCK);
    }
}

test {
    _ = loop_module;
}
