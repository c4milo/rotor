//! The descriptor that wakes a kqueue loop in a registry of one process (decision 4, amendment of
//! 2026-11-06).
//!
//! A sender wakes a loop that sleeps with a `kevent` call that triggers the loop's `EVFILT_USER`
//! event, on a descriptor it read from the registry. Until 2026-11-06 that was the loop's own
//! kqueue, which the loop closed at `deinit`. A loop that ended between a sender's read and its
//! call freed the number, and the next open could get it. A trigger to a descriptor that is no
//! kqueue is refused with EBADF, so no byte reaches a file or a socket. But when the open was the
//! kqueue of some other library, and that kqueue held a user event of the same `ident`, the
//! trigger fired that event, which nobody had sent.
//!
//! Now the registry keeps one descriptor per id for its whole life, as on io_uring
//! (`uring_wake.zig`):
//!
//! - The first loop of an id copies its kqueue to a new descriptor with `dup`, and the registry
//!   keeps the copy.
//! - A later loop of the id points that number at its own kqueue with `dup2`.
//! - At `deinit` the loop points the number at its stand-in, a kqueue that holds no event, which
//!   it made at `init`, and closes its own descriptor of the stand-in. The kernel refuses a
//!   trigger to it with ENOENT.
//!
//! `dup2` replaces the file behind a number in one step, so the number is never free while the
//! registry lives. Neither number closes on exec: a kqueue is not inherited by a child created with
//! fork(2), as `kqueue_group.zig` says. In a group the loop is woken through its pipe, and nothing
//! here applies.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("constants.zig");

const Descriptor = core.Descriptor;
const Registry = core.mailbox.Registry;
const Kevent = std.c.Kevent;

pub const ClaimError = error{ SystemResources, Unexpected };

/// What `claim` hands the loop: the descriptor senders wake it through, and its stand-in.
pub const Claimed = struct {
    send: Descriptor,
    stand_in: Descriptor,
};

/// Points the registry's descriptor for `id` at `queue`, and makes the stand-in `release` points it
/// back at. The first loop of `id` makes the descriptor, and the registry keeps it. Call it before
/// `set`, with the descriptor it returns.
pub fn claim(registry: *Registry, id: core.LoopId, queue: Descriptor) ClaimError!Claimed {
    assert(!registry.group);
    const stand_in = std.c.kqueue();
    if (stand_in < 0) return error.SystemResources;
    errdefer close_descriptor(stand_in);
    if (registry.wake(id)) |kept| {
        try point(kept.send, queue);
        return .{ .send = kept.send, .stand_in = stand_in };
    }
    const send = std.c.dup(queue);
    if (send < 0) return error.SystemResources;
    registry.keep_wake(id, .{ .send = send, .watch = send });
    return .{ .send = send, .stand_in = stand_in };
}

/// Points the registry's descriptor for `id` at `stand_in`, and closes the loop's own descriptor
/// of it. Call it before `clear`: a later loop of `id` may claim it once `clear` returns.
pub fn release(registry: *Registry, id: core.LoopId, stand_in: Descriptor) void {
    assert(!registry.group);
    const send = registry.get(id);
    // An id this loop does not hold, or a stand-in that is not open, is a programmer error, and
    // `dup2` refuses either. With both open, only a kernel that refuses `dup2`
    // `interrupt_retries_max` times in a row reaches the halt.
    const pointed = if (point(send, stand_in)) |_| true else |_| false;
    assert(pointed);
    close_descriptor(stand_in);
}

/// Closes every descriptor a registry of one process keeps, once every loop and remote of it
/// ended.
pub fn close_kept(registry: *Registry) void {
    registry.close_kept_wakes(close_descriptor);
}

/// Makes `number` refer to what `source` refers to, in one step. It tries again when a signal
/// interrupted the call, at most `interrupt_retries_max` times.
fn point(number: Descriptor, source: Descriptor) ClaimError!void {
    var retry: u32 = 0;
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        const rc = std.c.dup2(source, number);
        if (rc >= 0) return;
        switch (std.posix.errno(rc)) {
            .INTR => continue,
            .MFILE => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
    return error.SystemResources;
}

fn close_descriptor(descriptor: Descriptor) void {
    _ = std.c.close(descriptor);
}

/// Kqueues a `Trap` opens. A kqueue loop frees two numbers at `deinit`, its kqueue and its own
/// descriptor of the stand-in, and three if it closed the registry's copy.
const trap_queues = 4;

/// For tests: kqueues opened right after a loop's `deinit`, which take the lowest numbers free,
/// the ones that loop freed among them. Each holds the user event a wake triggers, so a wake that
/// reached a reused number would fire it.
pub const Trap = struct {
    queues: [trap_queues]Descriptor,

    pub fn open(trap: *Trap) !void {
        for (&trap.queues, 0..) |*queue, opened| {
            queue.* = open_one() catch |err| {
                for (trap.queues[0..opened]) |made| close_descriptor(made);
                return err;
            };
        }
    }

    fn open_one() !Descriptor {
        const queue = std.c.kqueue();
        if (queue < 0) return error.SystemResources;
        errdefer close_descriptor(queue);
        const added = [1]Kevent{user_event(std.c.EV.ADD | std.c.EV.CLEAR)};
        if (std.c.kevent(queue, &added, added.len, &.{}, 0, null) < 0) return error.Unexpected;
        return queue;
    }

    /// True when a wake fired the user event of any of the kqueues.
    pub fn received(trap: *const Trap) bool {
        const none: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        for (trap.queues) |queue| {
            var ready: [1]Kevent = undefined;
            if (std.c.kevent(queue, &.{}, 0, &ready, ready.len, &none) > 0) return true;
        }
        return false;
    }

    /// True when `number` is one of the kqueues: the trap took it, so it was free.
    pub fn holds(trap: *const Trap, number: Descriptor) bool {
        for (trap.queues) |queue| {
            if (queue == number) return true;
        }
        return false;
    }

    pub fn close(trap: *Trap) void {
        for (trap.queues) |queue| close_descriptor(queue);
    }
};

/// The user event a loop's wake triggers, as `kqueue_queue.zig` registers it.
fn user_event(flags: u16) Kevent {
    return .{
        .ident = constants.wake_identifier,
        .filter = std.c.EVFILT.USER,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
}

const testing = std.testing;
const kqueue = @import("kqueue.zig");

/// A loop of a registry, over static memory.
const Held = struct {
    const sizing: kqueue.Loop.Options = .{ .operations = 1 };
    memory: [kqueue.Loop.memory_bytes(sizing)]u8 align(core.layout.memory_alignment),
    loop: kqueue.Loop,

    fn init(held: *Held, registry: *Registry, id: core.LoopId) !void {
        try held.loop.init(&held.memory, .{ .operations = 1, .id = id, .registry = registry });
    }
};

const held_loops = 2;

test "a wake through a number read before the loop ended reaches no kqueue opened after it" {
    if (!kqueue.supported) return error.SkipZigTest;
    var registry_memory: [Registry.memory_bytes(held_loops)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: Registry = undefined;
    registry.init(&registry_memory, held_loops);
    var held_loop: Held = undefined;
    try held_loop.init(&registry, 0);
    // A sender read this and has not triggered yet.
    const number = registry.get(0);
    try testing.expect(number >= 0);
    try testing.expect(number != held_loop.loop.queue.descriptor);
    held_loop.loop.deinit();

    var trap: Trap = undefined;
    try trap.open();
    defer trap.close();
    // The number now refers to the loop's stand-in, which holds no event, so the kernel refuses
    // the trigger and no kqueue opened after the loop ended sees it.
    try testing.expect(!kqueue.queue_module.Queue.wake_sent(number));
    try testing.expect(!trap.received());

    // The next loop of the id is woken through the same number.
    try held_loop.init(&registry, 0);
    try testing.expectEqual(number, registry.get(0));
    try testing.expect(kqueue.queue_module.Queue.wake_sent(number));
    var events: [1]core.Event = undefined;
    const before = kqueue.testing.monotonic_ns();
    try testing.expectEqual(@as(u32, 0), try held_loop.loop.tick(&events, core.constants.ns_per_s));
    try testing.expect(kqueue.testing.monotonic_ns() - before < core.constants.ns_per_s / 2);
    held_loop.loop.deinit();
    try testing.expect(!trap.received());

    close_kept(&registry);
    try testing.expectEqual(@as(?core.mailbox.Wake, null), registry.wake(0));
    try testing.expect(std.c.fcntl(number, std.c.F.GETFD) < 0);
}
