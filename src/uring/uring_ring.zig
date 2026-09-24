//! `Ring`: one loop's io_uring instance: its setup, what it requires of the kernel, and the one
//! system call a tick makes. Everything in this file enters the kernel except the accessors over
//! the completion ring, so it is tested under Linux alone.
//!
//! Setup asks for `SINGLE_ISSUER` and `DEFER_TASKRUN`: the kernel then runs completion work only
//! when the loop's own thread enters the ring, never at an arbitrary return to user space, so a
//! tick's batch is reaped in one place (decision 2, Minimum kernel). A kernel that refuses those
//! flags is older than 6.1, and `init` answers `Unsupported`: it never falls back to a slower
//! path without saying so. `SUBMIT_ALL` keeps one malformed entry from holding back the rest of
//! its batch; the malformed entry fails with its own completion.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const assert_class_a = core.assertion_class.assert_class_a;
const linux = std.os.linux;
const IoUring = linux.IoUring;
const core = @import("core");
const constants = @import("constants.zig");

pub const InitError = error{ Unsupported, PermissionDenied, SystemResources, Unexpected };

/// `SystemResources`: the kernel refused transiently more than `enter_retries_max` times.
pub const EnterError = error{ SystemResources, Unexpected };

/// `TASKRUN_FLAG` makes the kernel raise `IORING_SQ_TASKRUN` in the ring's flags while deferred
/// completion work waits. Without it a loop that polls, with nothing to submit and no wait,
/// cannot tell that completions are waiting behind an enter, and would never make one.
/// Public so `tools/uring_probe.zig` checks exactly what `init` demands. The probe's job is to
/// name the first thing a kernel lacks, and it cannot do that from a copy of this list: a kernel
/// with two of these four passed the probe and then failed every `init` with an `Unsupported`
/// that named nothing.
pub const setup_flags: u32 = linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN |
    linux.IORING_SETUP_TASKRUN_FLAG | linux.IORING_SETUP_SUBMIT_ALL;

/// The ring flags that say an enter would produce completions: deferred completion work is
/// waiting, or completions overflowed the ring and wait in the kernel.
const flags_need_enter: u32 = linux.IORING_SQ_TASKRUN | linux.IORING_SQ_CQ_OVERFLOW;

/// `NODROP`: a full completion ring keeps completions and refuses submissions, and never drops
/// one. `EXT_ARG`: a wait takes its timeout as an argument, so no timeout entry stays armed
/// after the call (decision 6, kept from stompy).
pub const features_required: u32 = linux.IORING_FEAT_NODROP | linux.IORING_FEAT_EXT_ARG;

/// Every opcode version one submits. `init` probes each, and `set_opcode` refuses at compile time
/// an opcode that is not here.
pub const opcodes_required = [_]linux.IORING_OP{
    .ACCEPT,
    .CONNECT,
    .RECV,
    .SEND,
    .RECVMSG,
    .SENDMSG,
    .SHUTDOWN,
    .CLOSE,
    .READ,
    .WRITE,
    .READ_FIXED,
    .WRITE_FIXED,
    .FSYNC,
    .ASYNC_CANCEL,
    .MSG_RING,
    .NOP,
};

/// Sets the opcode of `sqe`. The backend sets every opcode it submits here, so an opcode that
/// `init` does not probe fails to compile. RECVMSG and SENDMSG were submitted without being probed
/// until 2026-09-23.
pub fn set_opcode(sqe: *linux.io_uring_sqe, comptime opcode: linux.IORING_OP) void {
    comptime assert(is_required(opcode));
    sqe.opcode = opcode;
}

fn is_required(comptime opcode: linux.IORING_OP) bool {
    for (opcodes_required) |required| {
        if (required == opcode) return true;
    }
    return false;
}

/// The two counts `IORING_REGISTER_IOWQ_MAX_WORKERS` takes: bounded and unbounded workers.
const worker_kinds = 2;

pub const Entered = enum {
    /// The kernel took every submission entry.
    submitted,
    /// The completion ring overflowed and the kernel took no entry. The entries stay in the
    /// submission ring; reaping makes room, and the next tick submits them.
    overcommitted,
};

pub const Ring = struct {
    io: IoUring,

    /// `entries` is a power of two in [1, constants.entries_max]. Must run on the thread that
    /// will own the loop: `SINGLE_ISSUER` binds the ring to the thread that creates it.
    pub fn init(entries: u16) InitError!Ring {
        assert(entries >= 1);
        assert(entries <= constants.entries_max);
        assert(std.math.isPowerOfTwo(entries));
        if (comptime builtin.os.tag != .linux) return error.Unsupported;
        var params = std.mem.zeroInit(linux.io_uring_params, .{ .flags = setup_flags });
        var io = IoUring.init_params(entries, &params) catch |err| return setup_error(err);
        errdefer io.deinit();
        if (io.features & features_required != features_required) return error.Unsupported;
        var ring: Ring = .{ .io = io };
        try ring.require_opcodes();
        try ring.cap_kernel_workers();
        assert(ring.io.fd >= 0);
        return ring;
    }

    pub fn deinit(ring: *Ring) void {
        assert(ring.io.fd >= 0);
        ring.io.deinit();
    }

    /// The descriptor another loop names to post into this one.
    pub fn descriptor(ring: *const Ring) core.Descriptor {
        assert(ring.io.fd >= 0);
        return ring.io.fd;
    }

    fn require_opcodes(ring: *Ring) InitError!void {
        const probe = ring.io.get_probe() catch return error.Unsupported;
        for (opcodes_required) |opcode| {
            if (!probe.is_supported(opcode)) return error.Unsupported;
        }
    }

    fn cap_kernel_workers(ring: *Ring) InitError!void {
        var counts: [worker_kinds]u32 = @splat(constants.kernel_workers_max);
        const rc = linux.io_uring_register(
            ring.io.fd,
            .REGISTER_IOWQ_MAX_WORKERS,
            &counts,
            worker_kinds,
        );
        if (linux.errno(rc) != .SUCCESS) return error.Unsupported;
    }

    /// A vacant submission entry, or null when the submission ring is full.
    pub fn get_sqe(ring: *Ring) ?*linux.io_uring_sqe {
        return ring.io.get_sqe() catch null;
    }

    /// Submission entries the ring can still hand out before the next `enter`.
    pub fn sqe_space(ring: *Ring) u32 {
        const capacity: u32 = @intCast(ring.io.sq.sqes.len);
        const used = ring.io.sq_ready();
        assert_class_a(used <= capacity);
        return capacity - used;
    }

    /// The tick's one system call: submits what `get_sqe` handed out and runs the kernel's
    /// deferred completion work. With `wait_ns`, blocks until one completion is ready or the
    /// wait passes. Makes no call at all when there is nothing to submit, nothing to wait for,
    /// and no completion work pending.
    pub fn enter(ring: *Ring, wait_ns: ?u64) EnterError!Entered {
        const to_submit = ring.io.flush_sq();
        if (to_submit == 0 and wait_ns == null and !ring.completions_wait_behind_an_enter()) {
            return .submitted;
        }
        var retry: u32 = 0;
        while (retry <= constants.enter_retries_max) : (retry += 1) {
            return ring.enter_once(to_submit, wait_ns) catch |err| switch (err) {
                error.Interrupted => continue,
                error.Unexpected => return error.Unexpected,
            };
        }
        return error.SystemResources;
    }

    /// `io_uring_enter(2)` with `GETEVENTS`, which `DEFER_TASKRUN` needs even when not waiting,
    /// and with the wait's timeout as an argument. ETIME is the timeout passing with nothing
    /// complete, which is a normal return. EINTR and EAGAIN are the caller's to retry.
    fn enter_once(
        ring: *Ring,
        to_submit: u32,
        wait_ns: ?u64,
    ) error{ Interrupted, Unexpected }!Entered {
        var timespec: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 };
        var argument: linux.io_uring_getevents_arg = .{
            .sigmask = 0,
            .sigmask_sz = 0,
            .pad = 0,
            .ts = @intFromPtr(&timespec),
        };
        var flags: u32 = linux.IORING_ENTER_GETEVENTS;
        var min_complete: u32 = 0;
        var argument_pointer: usize = 0;
        var argument_size: usize = 0;
        if (wait_ns) |nanoseconds| {
            assert(nanoseconds >= 1);
            assert(nanoseconds <= core.constants.wait_ns_max);
            timespec.sec = @intCast(nanoseconds / core.constants.ns_per_s);
            timespec.nsec = @intCast(nanoseconds % core.constants.ns_per_s);
            flags |= linux.IORING_ENTER_EXT_ARG;
            min_complete = 1;
            argument_pointer = @intFromPtr(&argument);
            argument_size = @sizeOf(linux.io_uring_getevents_arg);
        }
        const fd: usize = @bitCast(@as(isize, ring.io.fd));
        const rc = linux.syscall6(
            .io_uring_enter,
            fd,
            to_submit,
            min_complete,
            flags,
            argument_pointer,
            argument_size,
        );
        return switch (linux.errno(rc)) {
            .SUCCESS, .TIME => .submitted,
            .BUSY => .overcommitted,
            .INTR, .AGAIN => error.Interrupted,
            else => error.Unexpected,
        };
    }

    /// True when the kernel holds completions it will post only when the loop enters it.
    fn completions_wait_behind_an_enter(ring: *const Ring) bool {
        const flags = @atomicLoad(u32, ring.io.sq.flags, .unordered);
        return flags & flags_need_enter != 0;
    }

    /// Completion entries the kernel has posted and the loop has not consumed.
    pub fn cq_ready(ring: *Ring) u32 {
        return ring.io.cq_ready();
    }

    /// The completion entry `offset` places past the oldest unconsumed one.
    pub fn cqe_at(ring: *const Ring, offset: u32) *const linux.io_uring_cqe {
        const head = ring.io.cq.head.*;
        return &ring.io.cq.cqes[(head +% offset) & ring.io.cq.mask];
    }

    /// Hands the `count` oldest completion entries back to the kernel.
    pub fn cq_advance(ring: *Ring, count: u32) void {
        ring.io.cq_advance(count);
    }
};

fn setup_error(err: anyerror) InitError {
    return switch (err) {
        error.PermissionDenied => error.PermissionDenied,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => error.SystemResources,
        // ENOSYS: no io_uring. EINVAL: the kernel does not know a setup flag, so it is older
        // than the floor of decision 2.
        error.SystemOutdated, error.ArgumentsInvalid => error.Unsupported,
        else => error.Unexpected,
    };
}

const testing = std.testing;

test "the files that fill an entry set its opcode only through set_opcode" {
    // An opcode set any other way escapes the compile-time check, and `init` would not probe it.
    const sources = [_][]const u8{
        @embedFile("uring_submit.zig"),
        @embedFile("uring_datagram.zig"),
        @embedFile("uring_remote.zig"),
    };
    for (sources) |source| try testing.expect(std.mem.indexOf(u8, source, ".opcode = ") == null);
}

test "init refuses on a host without io_uring" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, Ring.init(8));
}

test "a ring sets up, reports its space, and enters with nothing to do" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ring = try Ring.init(8);
    defer ring.deinit();
    try testing.expectEqual(@as(u32, 8), ring.sqe_space());
    try testing.expectEqual(@as(u32, 0), ring.cq_ready());
    try testing.expectEqual(Entered.submitted, try ring.enter(null));
    try testing.expect(ring.descriptor() >= 0);
}

test "a wait with nothing in flight returns when its timeout passes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ring = try Ring.init(8);
    defer ring.deinit();
    try testing.expectEqual(Entered.submitted, try ring.enter(core.constants.ns_per_ms));
    try testing.expectEqual(@as(u32, 0), ring.cq_ready());
}

test "a no-op entry completes with the user data it carried" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ring = try Ring.init(8);
    defer ring.deinit();
    const sqe = ring.get_sqe().?;
    sqe.prep_nop();
    sqe.user_data = 0xABCD;
    try testing.expectEqual(@as(u32, 7), ring.sqe_space());
    try testing.expectEqual(Entered.submitted, try ring.enter(core.constants.ns_per_s));
    try testing.expectEqual(@as(u32, 1), ring.cq_ready());
    try testing.expectEqual(@as(u64, 0xABCD), ring.cqe_at(0).user_data);
    try testing.expectEqual(@as(i32, 0), ring.cqe_at(0).res);
    ring.cq_advance(1);
    try testing.expectEqual(@as(u32, 0), ring.cq_ready());
}
