//! The wake of an epoll loop that has a registry (decision 4, amendment of 2026-11-06).
//!
//! A sender reads the eventfd of a loop from the registry, pushes its message, and then writes 8
//! bytes to that eventfd. Until 2026-11-06 each loop made its own eventfd and closed it at `deinit`.
//! A loop that ended between a sender's read and its write freed the number, and the next open on
//! any thread could get it. The write then put 8 bytes into an unrelated file or socket, and it
//! succeeded, so nothing counted it.
//!
//! Now the registry keeps the eventfd of each id for its whole life, as a group already did
//! (decision 21, point 3). The first loop of an id makes it and hands it over. Every loop of the id
//! waits on it and never closes it. The application closes it after every loop and remote of the
//! registry ended, with `close_kept`. A write that reaches the eventfd of a loop that ended adds
//! to its count. The next loop of the id reads that count once, as a wake with no message.
const std = @import("std");
const linux = std.os.linux;
const core = @import("core");
const group = @import("linux_shared").group;

const Descriptor = core.Descriptor;
const Registry = core.mailbox.Registry;
const Wake = core.mailbox.Wake;

pub const ClaimError = group.MakeError;

/// The wake loop `id` waits on: the one the registry keeps for `id`. The first loop of `id` in a
/// registry of one process makes it, and the registry keeps it from then on. Call it before `set`.
pub fn claim(registry: *Registry, id: core.LoopId) ClaimError!Wake {
    if (registry.wake(id)) |kept| return kept;
    const made = try group.make_private();
    const kept: Wake = .{ .send = made, .watch = made };
    registry.keep_wake(id, kept);
    return kept;
}

/// Closes every wake a registry of one process keeps, once every loop and remote of it ended.
pub fn close_kept(registry: *Registry) void {
    registry.close_kept_wakes(close_descriptor);
}

fn close_descriptor(descriptor: Descriptor) void {
    _ = linux.close(descriptor);
}

/// Pipes a `Trap` opens: two numbers each. An epoll loop frees two numbers at `deinit`, and three
/// if it closed the eventfd it borrowed.
const trap_pipes = 4;
/// A pipe has a read end and a write end.
const pipe_ends = 2;

/// For tests: pipes opened right after a loop's `deinit`, which take the lowest numbers free, the
/// ones that loop freed among them. A wake that reached a reused number would write 8 bytes into a
/// pipe's write end, and its read end would hold them. A write to a read end is refused.
pub const Trap = struct {
    pipes: [trap_pipes][pipe_ends]Descriptor,

    pub fn open(trap: *Trap) !void {
        for (&trap.pipes, 0..) |*ends, opened| {
            const rc = linux.pipe2(ends, .{ .CLOEXEC = true, .NONBLOCK = true });
            if (linux.errno(rc) != .SUCCESS) {
                close_pipes(trap.pipes[0..opened]);
                return error.Unexpected;
            }
        }
    }

    /// True when a byte reached any of the pipes.
    pub fn received(trap: *const Trap) bool {
        for (trap.pipes) |ends| {
            var byte: [1]u8 = undefined;
            const rc = linux.read(ends[0], &byte, byte.len);
            if (linux.errno(rc) == .SUCCESS and rc > 0) return true;
        }
        return false;
    }

    /// True when `number` is one of the pipes' ends: the trap took it, so it was free.
    pub fn holds(trap: *const Trap, number: Descriptor) bool {
        for (trap.pipes) |ends| {
            for (ends) |end| {
                if (end == number) return true;
            }
        }
        return false;
    }

    pub fn close(trap: *Trap) void {
        close_pipes(&trap.pipes);
    }

    fn close_pipes(pipes: []const [pipe_ends]Descriptor) void {
        for (pipes) |ends| {
            for (ends) |end| close_descriptor(end);
        }
    }
};

const testing = std.testing;
const epoll = @import("epoll.zig");

/// A loop of a registry, over static memory.
const Held = struct {
    const sizing: epoll.Loop.Options = .{ .operations = 1 };
    memory: [epoll.Loop.memory_bytes(sizing)]u8 align(core.layout.memory_alignment),
    loop: epoll.Loop,

    fn init(held: *Held, registry: *Registry, id: core.LoopId) !void {
        try held.loop.init(&held.memory, .{ .operations = 1, .id = id, .registry = registry });
    }
};

const held_loops = 2;

test "a wake through a number read before the loop ended reaches no descriptor opened after it" {
    if (!epoll.supported) return error.SkipZigTest;
    var registry_memory: [Registry.memory_bytes(held_loops)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: Registry = undefined;
    registry.init(&registry_memory, held_loops);
    var held_loop: Held = undefined;
    try held_loop.init(&registry, 0);
    // A sender read this and has not written yet.
    const number = registry.get(0);
    try testing.expect(number >= 0);
    held_loop.loop.deinit();

    var trap: Trap = undefined;
    try trap.open();
    defer trap.close();
    // The registry keeps the eventfd, so the write lands there and in no pipe.
    try testing.expect(epoll.queue_module.Queue.wake_sent(number));
    try testing.expect(!trap.received());

    // The next loop of the id waits on the same eventfd, so the same number wakes it.
    try held_loop.init(&registry, 0);
    try testing.expectEqual(number, registry.get(0));
    var events: [1]core.Event = undefined;
    const before = epoll.testing.monotonic_ns();
    try testing.expectEqual(@as(u32, 0), try held_loop.loop.tick(&events, core.constants.ns_per_s));
    try testing.expect(epoll.testing.monotonic_ns() - before < core.constants.ns_per_s / 2);
    held_loop.loop.deinit();
    close_kept(&registry);
    try testing.expectEqual(@as(?Wake, null), registry.wake(0));
    try testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(number, linux.F.GETFD, 0)));
}
