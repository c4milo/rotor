//! `Queue`: one loop's epoll instance: its setup, the registrations a tick makes, and the one
//! `epoll_pwait2` call that waits. Everything here enters the kernel, so it is tested under Linux
//! alone.
//!
//! Two things differ from `kqueue_queue.zig`, which this file otherwise mirrors (decision 20).
//!
//! **A registration is its own system call.** kqueue carries up to 256 changes in the call that
//! waits; `epoll_ctl` takes one descriptor at a time and there is no batched form. libuv batches
//! them through an io_uring ring, which is closed to this backend by definition. So `control` is
//! called once per change and a tick that registers N descriptors makes N+1 calls. Registrations
//! are left in place rather than re-armed, which is what keeps that N small: see `arm` below.
//!
//! **The wake is an eventfd.** kqueue triggers an `EVFILT_USER` it registered at init; epoll has no
//! user event, so the loop owns an eventfd registered for read readiness, and another thread wakes
//! it with one 8-byte write. The counter is drained when the wake is reaped, so a loop that was
//! woken many times waits again rather than spinning.
//!
//! `epoll_pwait2` and not `epoll_wait`: the latter takes a timeout in milliseconds, coarser than
//! every deadline rotor accepts. It arrived in Linux 5.11, below decision 2's floor of 6.1, and
//! `init` answers `Unsupported` on a kernel that refuses it, as `uring_ring.zig` refuses a kernel
//! missing a flag it needs. `std.os.linux` has no wrapper for it, so this file makes the call.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");

/// One readiness the kernel reports. `epoll_event` is packed on x86-64, so it is the kernel's own
/// type and never rotor's.
pub const Event = linux.epoll_event;

pub const InitError = error{ Unsupported, PermissionDenied, SystemResources, Unexpected };

/// `SystemResources`: a signal interrupted the call more than `interrupt_retries_max` times.
pub const WaitError = error{ SystemResources, Unexpected };

/// `Unexpected` covers every refusal of `epoll_ctl` a correct caller cannot reach: a descriptor it
/// does not own is a programmer error and asserts instead.
pub const ControlError = error{ SystemResources, Unexpected };

const supported = builtin.os.tag == .linux;

/// What a descriptor is registered for. `read` and `write` are the two a socket operation waits on;
/// `both` is a descriptor with an operation of each kind in flight.
pub const Interest = enum {
    read,
    write,
    both,

    /// The epoll event mask. `ERR` and `HUP` arrive whether or not they are asked for, so naming
    /// them costs nothing and says which readiness the reap must handle.
    pub fn mask(interest: Interest) u32 {
        const common: u32 = linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP;
        const wanted: u32 = switch (interest) {
            .read => linux.EPOLL.IN,
            .write => linux.EPOLL.OUT,
            .both => linux.EPOLL.IN | linux.EPOLL.OUT,
        };
        return common | wanted;
    }
};

pub const Queue = struct {
    descriptor: core.Descriptor,
    /// The eventfd another thread writes to wake this loop. Registered for read readiness at init
    /// and never removed, so a wake is one write and needs no registration of its own.
    wake_descriptor: core.Descriptor,

    /// Opens the epoll instance and the eventfd that wakes it.
    pub fn init() InitError!Queue {
        if (comptime !supported) return error.Unsupported;
        const opened = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        const descriptor = try descriptor_of(opened);
        var queue: Queue = .{ .descriptor = descriptor, .wake_descriptor = -1 };
        errdefer queue.deinit();

        const flags = linux.EFD.CLOEXEC | linux.EFD.NONBLOCK;
        queue.wake_descriptor = try descriptor_of(linux.eventfd(0, flags));
        queue.arm(queue.wake_descriptor, .read, constants.wake_user_data) catch
            return error.Unexpected;

        // A kernel without `epoll_pwait2` refuses it with ENOSYS, and this backend has no second
        // path: a millisecond timeout cannot hold a deadline rotor accepts.
        var readiness: [1]Event = undefined;
        _ = queue.wait(&readiness, 0) catch return error.Unsupported;
        assert(queue.descriptor >= 0 and queue.wake_descriptor >= 0);
        return queue;
    }

    pub fn deinit(queue: *Queue) void {
        if (queue.wake_descriptor >= 0) {
            _ = linux.close(queue.wake_descriptor);
            queue.wake_descriptor = -1;
        }
        if (queue.descriptor >= 0) {
            _ = linux.close(queue.descriptor);
            queue.descriptor = -1;
        }
    }

    /// Registers `descriptor` for `interest`, or changes what an already registered one waits for.
    /// `user_data` is what the readiness carries back, which is the slot the reap looks up.
    ///
    /// One `epoll_ctl` per call, and `CTL_ADD` or `CTL_MOD` decided by the kernel's answer rather
    /// than by bookkeeping here: EEXIST means it was already registered, so the same call becomes a
    /// modify. That keeps this file from holding a second copy of what the waiters table knows.
    pub fn arm(
        queue: *const Queue,
        descriptor: core.Descriptor,
        interest: Interest,
        user_data: u64,
    ) ControlError!void {
        assert(queue.descriptor >= 0);
        assert(descriptor >= 0);
        var event: Event = .{ .events = interest.mask(), .data = .{ .u64 = user_data } };
        const added = linux.epoll_ctl(queue.descriptor, linux.EPOLL.CTL_ADD, descriptor, &event);
        switch (linux.errno(added)) {
            .SUCCESS => return,
            .EXIST => {},
            .NOMEM, .NOSPC, .PERM => return error.SystemResources,
            else => return error.Unexpected,
        }
        const changed = linux.epoll_ctl(queue.descriptor, linux.EPOLL.CTL_MOD, descriptor, &event);
        return switch (linux.errno(changed)) {
            .SUCCESS => {},
            .NOMEM, .NOSPC => error.SystemResources,
            else => error.Unexpected,
        };
    }

    /// Removes `descriptor` from the epoll instance. A descriptor the kernel already forgot, which
    /// is what a closed one is, answers ENOENT or EBADF and is not an error: closing a descriptor
    /// removes it, so the loop's own disarm races that and loses harmlessly.
    pub fn disarm(queue: *const Queue, descriptor: core.Descriptor) void {
        assert(queue.descriptor >= 0);
        assert(descriptor >= 0);
        var event: Event = .{ .events = 0, .data = .{ .u64 = 0 } };
        _ = linux.epoll_ctl(queue.descriptor, linux.EPOLL.CTL_DEL, descriptor, &event);
    }

    /// Fills `readiness` and returns how many. With `wait_ns` above 0, blocks until a descriptor is
    /// ready, the loop is woken, or the wait passes; with 0, returns at once.
    pub fn wait(queue: *const Queue, readiness: []Event, wait_ns: u64) WaitError!u32 {
        assert(queue.descriptor >= 0);
        assert(readiness.len >= 1);
        assert(readiness.len <= constants.readiness_max);
        assert(wait_ns <= core.constants.wait_ns_max);
        const timeout: linux.timespec = .{
            .sec = @intCast(wait_ns / core.constants.ns_per_s),
            .nsec = @intCast(wait_ns % core.constants.ns_per_s),
        };
        var retry: u32 = 0;
        while (retry <= constants.interrupt_retries_max) : (retry += 1) {
            const rc = linux.syscall6(
                .epoll_pwait2,
                @bitCast(@as(isize, queue.descriptor)),
                @intFromPtr(readiness.ptr),
                readiness.len,
                @intFromPtr(&timeout),
                0,
                @sizeOf(linux.sigset_t),
            );
            const errno = linux.errno(rc);
            if (errno == .SUCCESS) return @intCast(rc);
            if (errno != .INTR) return error.Unexpected;
        }
        return error.SystemResources;
    }

    /// Wakes the loop whose eventfd is `target` out of its wait. Any thread may call it: it is one
    /// write to a descriptor, and it touches no memory of the target loop.
    pub fn wake(target: core.Descriptor) void {
        assert(target >= 0);
        const one: u64 = 1;
        _ = linux.write(target, std.mem.asBytes(&one), @sizeOf(u64));
    }

    /// Empties the wake counter, which the reap calls when it sees the wake readiness. Without this
    /// a level-triggered eventfd stays ready and every wait returns at once.
    pub fn drain_wake(queue: *const Queue) void {
        assert(queue.wake_descriptor >= 0);
        var counter: u64 = 0;
        _ = linux.read(queue.wake_descriptor, std.mem.asBytes(&counter), @sizeOf(u64));
    }
};

fn descriptor_of(rc: usize) InitError!core.Descriptor {
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE, .NFILE, .NOMEM => error.SystemResources,
        .PERM, .ACCES => error.PermissionDenied,
        else => error.Unexpected,
    };
}

const testing = std.testing;

test "init refuses on a host without epoll" {
    if (supported) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, Queue.init());
}

test "a poll of an idle epoll returns nothing, and a wake ends a wait long before it is over" {
    if (!supported) return error.SkipZigTest;
    var queue = try Queue.init();
    defer queue.deinit();
    var readiness: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try queue.wait(&readiness, 0));

    Queue.wake(queue.wake_descriptor);
    try testing.expectEqual(@as(u32, 1), try queue.wait(&readiness, core.constants.wait_ns_max));
    try testing.expectEqual(constants.wake_user_data, readiness[0].data.u64);

    // Level triggered, so the eventfd stays ready until its counter is read.
    try testing.expectEqual(@as(u32, 1), try queue.wait(&readiness, 0));
    queue.drain_wake();
    try testing.expectEqual(@as(u32, 0), try queue.wait(&readiness, 0));
}

test "arming a descriptor twice modifies it rather than failing" {
    if (!supported) return error.SkipZigTest;
    var queue = try Queue.init();
    defer queue.deinit();
    const pair = try pipe_pair();
    defer for (pair) |end| {
        _ = linux.close(end);
    };

    const user_data = 0x5ec0_0001;
    try queue.arm(pair[0], .read, user_data);
    // The same descriptor again: the add answers EEXIST and the modify carries the new interest.
    try queue.arm(pair[0], .both, user_data);

    var readiness: [4]Event = undefined;
    // Nothing written yet, so the read end is not ready; the write end was never armed.
    try testing.expectEqual(@as(u32, 0), try queue.wait(&readiness, 0));
    const byte: [1]u8 = .{0xa5};
    try testing.expectEqual(@as(usize, 1), linux.write(pair[1], &byte, 1));
    try testing.expectEqual(@as(u32, 1), try queue.wait(&readiness, 0));
    try testing.expectEqual(@as(u64, user_data), readiness[0].data.u64);
    try testing.expect(readiness[0].events & linux.EPOLL.IN != 0);

    queue.disarm(pair[0]);
    try testing.expectEqual(@as(u32, 0), try queue.wait(&readiness, 0));
    // A descriptor the queue never held: removing it is not an error.
    queue.disarm(pair[1]);
}

/// Ends of a pipe: the read end and the write end.
const pipe_ends = 2;

/// A pipe, read end first. A pipe and not a socket, so this test needs nothing of `epoll_sync`.
fn pipe_pair() ![pipe_ends]core.Descriptor {
    var ends: [pipe_ends]i32 = undefined;
    const rc = linux.pipe2(&ends, .{ .CLOEXEC = true });
    if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
    return .{ ends[0], ends[1] };
}
