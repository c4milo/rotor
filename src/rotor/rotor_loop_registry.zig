//! The public `Registry`, split from `rotor_loop.zig` for the 500-line limit. It wraps the host's
//! backend as `Loop` and `Remote` do, and follows the same choice of backend.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const loop_module = @import("rotor_loop.zig");

const Tag = loop_module.Tag;
const chosen = loop_module.chosen;
const module = loop_module.module;
const linux = @import("builtin").os.tag == .linux;
const uring = @import("uring");
const epoll = @import("epoll");
const kqueue = @import("kqueue");

/// The registry a group of loops shares, for `post` between them (decision 4). The application
/// owns its memory and hands it to every loop and remote of the group. It keeps the descriptor that
/// wakes each loop for its whole life, so the application calls `close_wakes` once every loop and
/// remote of it ended (decision 4, amendment of 2026-11-06).
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

    /// A registry for loops of one process. It makes no descriptor: the first loop of each id
    /// makes the one that wakes it, and the registry keeps it until `close_wakes`.
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

    /// Why `init_group` made no group: the process or the system had no descriptor left for a
    /// loop's wake.
    pub const GroupError = error{ SystemResources, Unexpected };
    pub const AttachError = core.mailbox.AttachError;

    /// A registry whose loops may run in several processes (decision 21). `memory` is a mapping
    /// every process of the group maps with `MAP_SHARED`, aligned to 128 as a mapping is. It makes
    /// one wake per loop, a pipe on macOS and an eventfd on Linux, which every process the caller
    /// then forks, or spawns with them kept open at the same numbers, inherits. A loop of the group
    /// is woken through its wake, so no descriptor moves between processes after they start.
    pub fn init_group(
        registry: *Registry,
        memory: []align(core.layout.memory_alignment) u8,
        loop_count: u16,
    ) GroupError!void {
        assert(loop_count <= core.constants.loops_max);
        var wakes: [core.constants.loops_max]core.mailbox.Wake = undefined;
        switch (chosen()) {
            inline else => |tag| {
                try module(tag).group_module.make(wakes[0..loop_count]);
                registry.inner = @unionInit(Inner, @tagName(tag), undefined);
                @field(registry.inner, @tagName(tag)).init_group(memory, loop_count, wakes[0..loop_count]);
            },
        }
    }

    /// This process's value over a group's registry another process made with `init_group`. Its
    /// loops may then claim their ids, and its `Remote`s post, as in the process that made it.
    pub fn attach(registry: *Registry, memory: []align(core.layout.memory_alignment) u8) AttachError!void {
        switch (chosen()) {
            inline else => |tag| {
                registry.inner = @unionInit(Inner, @tagName(tag), undefined);
                try @field(registry.inner, @tagName(tag)).attach(memory);
            },
        }
    }

    /// Withdraws loop `id` of a group on behalf of the process that ran it and died (decision 21,
    /// point 5). Posts to it are then refused as `loop_not_found`, until a loop of a new process
    /// claims the id and takes its rings over. Only for a process known to be dead.
    pub fn release(registry: *Registry, id: core.LoopId) void {
        switch (registry.inner) {
            inline else => |*inner| inner.release(id),
        }
    }

    /// Closes the descriptors that wake the registry's loops, once every loop and remote of it
    /// ended and every thread that posts to them stopped. In one process, a loop or a remote that
    /// still holds an id halts it, and the call closes the descriptor each id's first loop made
    /// (decision 4, amendment of 2026-11-06). In a group it closes this process's copies of the
    /// wakes, and every process closes its own.
    pub fn close_wakes(registry: *Registry) void {
        switch (registry.inner) {
            inline else => |*inner, tag| {
                if (inner.group) {
                    module(tag).group_module.close(inner.wakes);
                } else {
                    module(tag).wake_module.close_kept(inner);
                }
            },
        }
    }
};

const testing = std.testing;

test "a group's registry is attached by a second value over its memory, and releases a loop's id" {
    const loop_count = 2;
    var memory: [Registry.memory_bytes(loop_count)]u8 align(128) = undefined;
    var registry: Registry = undefined;
    try registry.init_group(&memory, loop_count);
    defer registry.close_wakes();
    var member: Registry = undefined;
    try member.attach(&memory);
    try testing.expectEqual(@as(u16, loop_count), member.loops());

    // A remote of a process that died holds id 1. Once another process releases it, a new remote
    // claims it; a claim of an id still held would halt.
    var dead: loop_module.Remote = undefined;
    try dead.init(&registry, 1);
    member.release(1);
    var heir: loop_module.Remote = undefined;
    try heir.init(&member, 1);
    heir.deinit();
}

test "attach refuses memory that holds a registry of one process" {
    const loop_count = 2;
    var memory: [Registry.memory_bytes(loop_count)]u8 align(128) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, loop_count);
    registry.close_wakes();
    var member: Registry = undefined;
    try testing.expectError(error.NotAGroup, member.attach(&memory));
}

/// A pipe has a read end and a write end.
const pipe_ends = 2;

/// A pipe for a test: its read end is a descriptor that no backend's wake reaches.
fn test_pipe() ![pipe_ends]core.Descriptor {
    var ends: [pipe_ends]i32 = undefined;
    if (linux) {
        const rc = std.os.linux.pipe2(&ends, .{ .CLOEXEC = true });
        if (std.os.linux.errno(rc) != .SUCCESS) return error.Unexpected;
    } else if (std.c.pipe(&ends) != 0) return error.Unexpected;
    return ends;
}

test "a remote counts the wakes the kernel refused, and its deinit keeps the count" {
    if (!(if (linux) uring.supported or epoll.supported else kqueue.supported)) {
        return error.SkipZigTest;
    }
    const loop_count = 2;
    var memory: [Registry.memory_bytes(loop_count)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: Registry = undefined;
    registry.init(&memory, loop_count);
    const ends = try test_pipe();
    defer for (ends) |end| {
        _ = if (linux) std.os.linux.close(end) else std.c.close(end);
    };
    // Loop 0 publishes the read end of a pipe, and it sleeps: each post asks for a wake.
    switch (registry.inner) {
        inline else => |*inner| {
            inner.set(0, ends[0]);
            inner.begin_sleep(0);
        },
    }
    var remote: loop_module.Remote = undefined;
    try remote.init(&registry, 1);
    try testing.expectEqual(0, remote.dropped_wakes());
    try remote.post(0, .{ .payload = 1, .tag = 0 });
    // io_uring reads the kernel's answer in `deinit`, kqueue and epoll in `post`.
    remote.deinit();
    try testing.expectEqual(1, remote.dropped_wakes());
    switch (registry.inner) {
        inline else => |*inner| {
            inner.end_sleep(0);
            inner.clear(0);
        },
    }
}

test "a loop counts the wakes the kernel refused, and its deinit keeps the count" {
    if (!(if (linux) uring.supported or epoll.supported else kqueue.supported)) {
        return error.SkipZigTest;
    }
    const loop_count = 2;
    var memory: [Registry.memory_bytes(loop_count)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: Registry = undefined;
    registry.init(&memory, loop_count);
    defer registry.close_wakes();
    const ends = try test_pipe();
    defer for (ends) |end| {
        _ = if (linux) std.os.linux.close(end) else std.c.close(end);
    };
    // Loop 0 publishes the read end of a pipe, and it sleeps: each post asks for a wake.
    switch (registry.inner) {
        inline else => |*inner| {
            inner.set(0, ends[0]);
            inner.begin_sleep(0);
        },
    }
    const sizing: loop_module.Loop.Options = .{ .operations = 1 };
    var loop_memory: [loop_module.Loop.memory_bytes(sizing)]u8 align(core.layout.memory_alignment) =
        undefined;
    var loop: loop_module.Loop = undefined;
    try loop.init(&loop_memory, .{ .operations = 1, .id = 1, .registry = &registry });
    try testing.expectEqual(0, loop.dropped_wakes());
    try loop.post(0, .{ .payload = 1, .tag = 0 });
    // io_uring sends the wake and reads the kernel's answer in `deinit`, kqueue and epoll in
    // `post` (decision 4, fourth amendment of 2026-11-06).
    loop.deinit();
    try testing.expectEqual(1, loop.dropped_wakes());
    switch (registry.inner) {
        inline else => |*inner| {
            inner.end_sleep(0);
            inner.clear(0);
        },
    }
}

/// True when `descriptor` is open in this process.
fn is_open(descriptor: core.Descriptor) bool {
    if (linux) {
        const rc = std.os.linux.fcntl(descriptor, std.os.linux.F.GETFD, 0);
        return std.os.linux.errno(rc) == .SUCCESS;
    }
    return std.c.fcntl(descriptor, std.c.F.GETFD) >= 0;
}

test "a registry of one process keeps the descriptor that wakes a loop until close_wakes" {
    if (!(if (linux) uring.supported or epoll.supported else kqueue.supported)) {
        return error.SkipZigTest;
    }
    const loop_count = 2;
    var memory: [Registry.memory_bytes(loop_count)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: Registry = undefined;
    registry.init(&memory, loop_count);
    const sizing: loop_module.Loop.Options = .{ .operations = 1 };
    var loop_memory: [loop_module.Loop.memory_bytes(sizing)]u8 align(core.layout.memory_alignment) =
        undefined;
    var loop: loop_module.Loop = undefined;
    try loop.init(&loop_memory, .{ .operations = 1, .registry = &registry });
    const number = switch (registry.inner) {
        inline else => |*inner| inner.get(0),
    };
    try testing.expect(number >= 0);
    // A sender may still hold the number after the loop ended, so the loop leaves it open.
    loop.deinit();
    try testing.expect(is_open(number));
    registry.close_wakes();
    try testing.expect(!is_open(number));
}
