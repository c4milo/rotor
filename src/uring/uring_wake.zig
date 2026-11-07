//! The descriptor that wakes an io_uring loop in a registry of one process (decision 4, amendment
//! of 2026-11-06).
//!
//! A sender wakes a loop that sleeps with an `IORING_OP_MSG_RING` to a descriptor it read from the
//! registry. Until 2026-11-06 that was the loop's own ring, which the loop closed at `deinit`. A
//! loop that ended between a sender's read and its send freed the number, and the next open could
//! get it. When that open was a ring of some other library, the kernel posted a completion with
//! rotor's `user_data` into it, which that library never submitted.
//!
//! Now the registry keeps one descriptor per id for its whole life, as a group does:
//!
//! - The first loop of an id copies its ring to a new descriptor with `F_DUPFD_CLOEXEC`, and the
//!   registry keeps the copy.
//! - A later loop of the id points that number at its own ring with `dup3`.
//! - At `deinit` the loop points the number at its stand-in, an eventfd it made at `init`, and
//!   closes its own descriptor of the stand-in. The kernel refuses a wake to it with EBADFD.
//!
//! `dup3` replaces the file behind a number in one step, so the number is never free while the
//! registry lives. The ring is freed when the loop closes its own descriptor, because the number no
//! longer refers to it. In a group the loop is woken through its eventfd (`uring_group.zig`), and
//! nothing here applies.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const group = @import("linux_shared").group;

const Descriptor = core.Descriptor;
const Registry = core.mailbox.Registry;

pub const ClaimError = error{ SystemResources, Unexpected };

/// What `claim` hands the loop: the descriptor senders wake it through, and its stand-in.
pub const Claimed = struct {
    send: Descriptor,
    stand_in: Descriptor,
};

/// Points the registry's descriptor for `id` at `ring`, and makes the stand-in `release` points it
/// back at. The first loop of `id` makes the descriptor, and the registry keeps it. Call it before
/// `set`, with the descriptor it returns.
pub fn claim(registry: *Registry, id: core.LoopId, ring: Descriptor) ClaimError!Claimed {
    assert(!registry.group);
    const stand_in = try group.make_private();
    errdefer close_descriptor(stand_in);
    if (registry.wake(id)) |kept| {
        try point(kept.send, ring);
        return .{ .send = kept.send, .stand_in = stand_in };
    }
    const send = try copy(ring);
    registry.keep_wake(id, .{ .send = send, .watch = send });
    return .{ .send = send, .stand_in = stand_in };
}

/// Points the registry's descriptor for `id` at `stand_in`, and closes the loop's own descriptor
/// of it. Call it before `clear`: a later loop of `id` may claim it once `clear` returns.
pub fn release(registry: *Registry, id: core.LoopId, stand_in: Descriptor) void {
    assert(!registry.group);
    const send = registry.get(id);
    // An id this loop does not hold, or a stand-in that is not open, is a programmer error, and
    // `dup3` refuses either. With both open, only a kernel that refuses `dup3`
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

/// A new descriptor for what `source` refers to, closed on exec.
fn copy(source: Descriptor) ClaimError!Descriptor {
    const rc = linux.fcntl(source, linux.F.DUPFD_CLOEXEC, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE, .NFILE, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

const close_on_exec: u32 = @bitCast(linux.O{ .CLOEXEC = true });

/// Makes `number` refer to what `source` refers to, in one step. It tries again when a signal
/// interrupted the call, or when the kernel answered EBUSY, at most `interrupt_retries_max` times.
fn point(number: Descriptor, source: Descriptor) ClaimError!void {
    var retry: u32 = 0;
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        switch (linux.errno(linux.dup3(source, number, close_on_exec))) {
            .SUCCESS => return,
            .INTR, .BUSY => continue,
            .MFILE, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
    return error.SystemResources;
}

fn close_descriptor(descriptor: Descriptor) void {
    _ = linux.close(descriptor);
}

/// Rings a `Trap` opens. An io_uring loop frees two numbers at `deinit`, its ring and its own
/// descriptor of the stand-in, and three if it closed the registry's copy.
const trap_rings = 4;
/// The submission entries of a trap's ring. A trap submits nothing.
const trap_entries = 1;

/// For tests: rings opened right after a loop's `deinit`, which take the lowest numbers free, the
/// ones that loop freed among them. A wake that reached a reused number would post a completion
/// into one of them. They are plain rings and not rotor's, so the kernel posts such a completion
/// at once, and no enter of the trap's thread is needed to see it.
pub const Trap = struct {
    rings: [trap_rings]linux.IoUring,

    pub fn open(trap: *Trap) !void {
        if (comptime builtin.os.tag != .linux) return error.Unsupported;
        for (&trap.rings, 0..) |*ring, opened| {
            ring.* = linux.IoUring.init(trap_entries, 0) catch |err| {
                for (trap.rings[0..opened]) |*made| made.deinit();
                return err;
            };
        }
    }

    /// True when a completion reached any of the rings.
    pub fn received(trap: *Trap) bool {
        for (&trap.rings) |*ring| {
            if (ring.cq_ready() > 0) return true;
        }
        return false;
    }

    /// True when `number` is one of the rings: the trap took it, so it was free.
    pub fn holds(trap: *const Trap, number: Descriptor) bool {
        for (&trap.rings) |*ring| {
            if (ring.fd == number) return true;
        }
        return false;
    }

    pub fn close(trap: *Trap) void {
        for (&trap.rings) |*ring| ring.deinit();
    }
};

const testing = std.testing;
const uring = @import("uring.zig");

/// A loop of a registry, over static memory.
const Held = struct {
    const sizing: uring.Loop.Options = .{ .operations = 1 };
    memory: [uring.Loop.memory_bytes(sizing)]u8 align(core.layout.memory_alignment),
    loop: uring.Loop,

    fn init(held: *Held, registry: *Registry, id: core.LoopId) !void {
        try held.loop.init(&held.memory, .{ .operations = 1, .id = id, .registry = registry });
    }
};

const held_loops = 2;

/// The submission entries of the ring a test sends its wakes on.
const sender_entries = 2;

/// Sends one wake to `target` from `sender`, as a loop's flush or a `Remote` does, and returns the
/// kernel's answer to it.
fn send_wake(sender: *linux.IoUring, target: Descriptor) !i32 {
    const sqe = try sender.get_sqe();
    uring.submit_module.prepare_wake(sqe, target);
    _ = try sender.submit_and_wait(1);
    const answer = try sender.copy_cqe();
    return answer.res;
}

test "a wake through a number read before the loop ended reaches no ring opened after it" {
    if (!uring.supported) return error.SkipZigTest;
    var registry_memory: [Registry.memory_bytes(held_loops)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: Registry = undefined;
    registry.init(&registry_memory, held_loops);
    var held_loop: Held = undefined;
    try held_loop.init(&registry, 0);
    // A sender read this and has not sent yet.
    const number = registry.get(0);
    try testing.expect(number >= 0);
    held_loop.loop.deinit();

    var trap: Trap = undefined;
    try trap.open();
    defer trap.close();
    var sender = try linux.IoUring.init(sender_entries, 0);
    defer sender.deinit();
    // The number now refers to the loop's stand-in, an eventfd, which is no ring.
    const refused = -@as(i32, @intFromEnum(linux.E.BADFD));
    try testing.expectEqual(refused, try send_wake(&sender, number));
    try testing.expect(!trap.received());

    // The next loop of the id is woken through the same number.
    try held_loop.init(&registry, 0);
    try testing.expectEqual(number, registry.get(0));
    try testing.expectEqual(@as(i32, 0), try send_wake(&sender, number));
    var events: [1]core.Event = undefined;
    const before = uring.testing.monotonic_ns();
    try testing.expectEqual(@as(u32, 0), try held_loop.loop.tick(&events, core.constants.ns_per_s));
    try testing.expect(uring.testing.monotonic_ns() - before < core.constants.ns_per_s / 2);
    held_loop.loop.deinit();
    try testing.expect(!trap.received());

    close_kept(&registry);
    try testing.expectEqual(@as(?core.mailbox.Wake, null), registry.wake(0));
    try testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(number, linux.F.GETFD, 0)));
}
