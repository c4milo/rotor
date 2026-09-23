//! `Queue`: one loop's epoll instance: its setup, the registrations a tick makes, and the one
//! `epoll_pwait2` call that waits. Everything here enters the kernel, so it is tested under Linux
//! alone.
//!
//! Two things differ from `kqueue_queue.zig`, which this file otherwise mirrors (decision 20).
//!
//! **A registration is its own system call.** kqueue carries up to 256 changes in the call that
//! waits; `epoll_ctl` takes one descriptor at a time and there is no batched form. libuv batches
//! them through an io_uring ring, which is closed to this backend by definition. So a tick that
//! registers N descriptors makes N+1 calls.
//!
//! **Registrations are left in place, and the kernel says what is there.** The loop keeps no record
//! of what it registered: a descriptor the caller closed with `sync.close_now` leaves the epoll
//! instance with it, and its number can come back as another socket, so a record in user space
//! would be wrong exactly when it matters. `arm` therefore asks the kernel each time, modifying
//! first and adding when the kernel answers that it holds nothing. A descriptor that stays in use,
//! which is a connection between two of its operations, costs one `epoll_ctl` per operation that
//! waits. `epoll_reap.zig` takes a direction out only when the kernel reports it ready and nobody
//! waits on it, which is what keeps a level-triggered registration from reporting for ever.
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

/// `SystemResources`: the kernel had no memory for the registration, or the user's
/// `max_user_watches` is used up. `Unexpected` covers every refusal a correct caller cannot reach:
/// EBADF for a descriptor that is not open, and EPERM for one epoll cannot watch, which is a
/// regular file or a directory. Only socket operations wait, so neither reaches here from a correct
/// caller.
pub const ControlError = error{ SystemResources, Unexpected };

const supported = builtin.os.tag == .linux;

/// What a descriptor is registered for. `read` and `write` are the two a socket operation waits on;
/// `both` is a descriptor with an operation of each kind in flight.
pub const Interest = enum {
    read,
    write,
    both,

    /// The interest for the directions that have an operation waiting, or null for none.
    pub fn of(read: bool, write: bool) ?Interest {
        if (read and write) return .both;
        if (read) return .read;
        if (write) return .write;
        return null;
    }

    /// The epoll event mask. `ERR` and `HUP` arrive whether or not they are asked for, so they are
    /// not named. `RDHUP`, the peer's half close, is asked for with the read direction alone: it is
    /// level triggered like the rest, so asking for it with only the write direction would report a
    /// half-closed socket on every wait with nobody to serve it.
    pub fn mask(interest: Interest) u32 {
        const read_bits: u32 = linux.EPOLL.IN | linux.EPOLL.RDHUP;
        return switch (interest) {
            .read => read_bits,
            .write => linux.EPOLL.OUT,
            .both => read_bits | linux.EPOLL.OUT,
        };
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
        var wake_event: Event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = constants.wake_user_data },
        };
        const added = linux.epoll_ctl(
            queue.descriptor,
            linux.EPOLL.CTL_ADD,
            queue.wake_descriptor,
            &wake_event,
        );
        if (linux.errno(added) != .SUCCESS) return error.SystemResources;

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

    /// Makes the kernel report `descriptor` for `interest` and nothing else. The readiness carries
    /// the descriptor back, which is what the reap looks its waiters up by.
    ///
    /// `CTL_MOD` first, and `CTL_ADD` only when the kernel answers ENOENT, because a descriptor in
    /// use is one the kernel already holds: see the file's comment. So one call in the common case,
    /// and two for the first operation that waits on a descriptor.
    pub fn arm(
        queue: *const Queue,
        descriptor: core.Descriptor,
        interest: Interest,
    ) ControlError!void {
        assert(queue.descriptor >= 0);
        assert(descriptor >= 0);
        const user_data: u64 = @intCast(descriptor);
        var event: Event = .{ .events = interest.mask(), .data = .{ .u64 = user_data } };
        const changed = linux.epoll_ctl(queue.descriptor, linux.EPOLL.CTL_MOD, descriptor, &event);
        switch (linux.errno(changed)) {
            .SUCCESS => return,
            .NOENT => {},
            else => |errno| return control_error(errno),
        }
        const added = linux.epoll_ctl(queue.descriptor, linux.EPOLL.CTL_ADD, descriptor, &event);
        switch (linux.errno(added)) {
            .SUCCESS => return,
            else => |errno| return control_error(errno),
        }
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
        while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
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

fn control_error(errno: linux.E) ControlError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .NOMEM, .NOSPC => error.SystemResources,
        else => error.Unexpected,
    };
}

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

test "arming adds a descriptor the kernel does not hold, and modifies one it does" {
    if (!supported) return error.SkipZigTest;
    var queue = try Queue.init();
    defer queue.deinit();
    const pair = try pipe_pair();
    defer for (pair) |end| {
        _ = linux.close(end);
    };

    // Not held yet: the modify answers ENOENT and the add registers it.
    try queue.arm(pair[0], .read);
    // Held: the modify alone changes the interest.
    try queue.arm(pair[0], .both);

    var readiness: [4]Event = undefined;
    // Nothing written yet, so the read end is not ready. A pipe's read end is never writable, so
    // asking for both reports nothing either.
    try testing.expectEqual(@as(u32, 0), try queue.wait(&readiness, 0));
    const byte: [1]u8 = .{0xa5};
    try testing.expectEqual(@as(usize, 1), linux.write(pair[1], &byte, 1));
    try testing.expectEqual(@as(u32, 1), try queue.wait(&readiness, 0));
    // The readiness names the descriptor, which is how the reap finds its waiters.
    try testing.expectEqual(@as(u64, @intCast(pair[0])), readiness[0].data.u64);
    try testing.expect(readiness[0].events & linux.EPOLL.IN != 0);

    // Level triggered: still ready, still reported, until it is read or disarmed.
    try testing.expectEqual(@as(u32, 1), try queue.wait(&readiness, 0));
    queue.disarm(pair[0]);
    try testing.expectEqual(@as(u32, 0), try queue.wait(&readiness, 0));
    // A descriptor the queue never held: removing it is not an error.
    queue.disarm(pair[1]);
}

test "a descriptor closed while registered leaves the instance, and its number arms again" {
    if (!supported) return error.SkipZigTest;
    var queue = try Queue.init();
    defer queue.deinit();
    const first = try pipe_pair();
    try queue.arm(first[0], .read);
    // Closed the way `sync.close_now` closes it, with no disarm: the kernel drops the registration.
    _ = linux.close(first[0]);
    _ = linux.close(first[1]);
    // The kernel hands out the lowest free number, so the new pipe's read end is the old number.
    const second = try pipe_pair();
    defer for (second) |end| {
        _ = linux.close(end);
    };
    try testing.expectEqual(first[0], second[0]);
    // A record in user space would say it is armed and skip the call; the kernel says ENOENT, and
    // the add makes the new descriptor report.
    try queue.arm(second[0], .read);
    const byte: [1]u8 = .{0x5a};
    try testing.expectEqual(@as(usize, 1), linux.write(second[1], &byte, 1));
    var readiness: [2]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try queue.wait(&readiness, 0));
}

test "an interest names the directions that have a waiter, and half close rides with reading" {
    try testing.expectEqual(@as(?Interest, null), Interest.of(false, false));
    try testing.expectEqual(@as(?Interest, .read), Interest.of(true, false));
    try testing.expectEqual(@as(?Interest, .write), Interest.of(false, true));
    try testing.expectEqual(@as(?Interest, .both), Interest.of(true, true));
    try testing.expect(Interest.read.mask() & linux.EPOLL.RDHUP != 0);
    try testing.expect(Interest.write.mask() & linux.EPOLL.RDHUP == 0);
    try testing.expect(Interest.write.mask() & linux.EPOLL.IN == 0);
    try testing.expect(Interest.read.mask() & linux.EPOLL.OUT == 0);
    try testing.expectEqual(Interest.read.mask() | Interest.write.mask(), Interest.both.mask());
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
