//! The map from a Linux errno to a `core.Code`. When an operation fails, io_uring's completion
//! entry holds `-errno` in its result. The reap takes one branch for every negative result and
//! calls into this file, so nothing here runs for an operation that succeeded.
//!
//! The file is pure. It names `std.os.linux.E` values and enters no kernel, so it compiles and
//! its tests run on every host (decision 10). An errno's number differs between architectures,
//! so the map names each errno and writes no number.
//!
//! The comment on each arm names the kernel situation that produces the errno. A comment that
//! cites a kernel source file states what was read there, in Linux 6.1, the floor of decision 2,
//! unless it names another version. A comment that cites a manual page states what is recalled
//! of that page. "Recalled" alone marks a situation that was read nowhere for this file.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("constants.zig");
const linux = std.os.linux;

const Code = core.Code;
const E = linux.E;

/// The largest errno Linux returns, so a completion's result in [-errno_max, -1] is an errno
/// (recalled: `MAX_ERRNO` in the kernel's include/linux/err.h).
const errno_max = constants.errno_max;

/// The integer an `E` holds.
const Errno = @typeInfo(E).@"enum".tag_type;

/// What the failed operation was, as far as the errno's meaning depends on it.
pub const Context = struct {
    /// The operation receives into a provided-buffer group, where ENOBUFS means the group is
    /// empty and not that the kernel is out of memory.
    from_group: bool = false,
    /// The operation is a `post`, where the errno describes the target ring.
    is_post: bool = false,
};

/// The code a failed operation's errno carries.
///
/// ECANCELED always maps to `canceled`. When the loop's own deadline caused the cancel, the
/// final event says `timeout` (decision 5, rule 4). The reap makes that change itself, because
/// the slot records whose cancel it was and the errno does not. This map never returns `timeout`.
pub fn code_of(errno: E, context: Context) Code {
    assert_errno(errno);
    // A post receives nothing, so no operation is both.
    assert(!(context.from_group and context.is_post));
    const code: Code = switch (errno) {
        // `IORING_OP_ASYNC_CANCEL` found the operation before it finished, or the operation's
        // linked timeout expired first and the kernel cancelled the operation
        // (io_uring_enter(2)).
        .CANCELED => .canceled,
        // EAGAIN: the operation could not go on without waiting, and io_uring did not try it
        // again. It reissues a file's read or write only when `io_rw_should_reissue` allows
        // (io_uring/rw.c). Recalled: a direct write fails with EAGAIN when the block layer has
        // no free request.
        // EINTR: a signal interrupted the operation, and the kernel asked for the call to be
        // restarted. io_uring cannot restart it, so it fails the operation with EINTR
        // (`io_rw_done` in io_uring/rw.c; the send, receive and connect paths of
        // io_uring/net.c).
        // The reap resubmits both (`is_retryable`), so the caller sees `would_block` only when
        // the retries ran out.
        .AGAIN, .INTR => .would_block,
        // The kernel had no memory for the operation: for the state io_uring keeps of a connect
        // it tries again (`io_connect` in io_uring/net.c), or for the request that carries a
        // post to its target ring (`io_msg_data_remote` in io_uring/msg_ring.c, Linux 6.12).
        .NOMEM => .system_resources,
        // An empty buffer group, or a network stack out of buffer space: the helper says which.
        .NOBUFS => code_of_no_buffers(context),
        // An accept found no free descriptor: the process is at its limit of open descriptors
        // (EMFILE), or the system is at its limit of open files (ENFILE). accept(2).
        .MFILE, .NFILE => .descriptor_limit,
        // The peer reset the connection, and a send or a receive found the reset (send(2)).
        .CONNRESET => .connection_reset,
        // A connect found nothing listening on the peer's address (connect(2)).
        .CONNREFUSED => .connection_refused,
        // An accept took a connection that the peer had already aborted (accept(2)).
        .CONNABORTED => .connection_aborted,
        // TCP stopped waiting for the peer: a connect whose attempt went unanswered (connect(2)),
        // or a connection whose retransmitted data went unacknowledged (tcp(7)).
        .TIMEDOUT => .connection_timed_out,
        // A send on a connected socket whose sending side is shut down (send(2)). Recalled: a
        // send also fails with it after the peer closed and an earlier send reported the reset.
        .PIPE => .broken_pipe,
        // A send, a receive or a shutdown on a socket that is not connected (send(2), recv(2),
        // shutdown(2)).
        .NOTCONN => .not_connected,
        // A connect found no route to the peer's network (ENETUNREACH, connect(2)) or to the
        // peer (EHOSTUNREACH, ip(7)). An accept can fail with each of the four, because Linux
        // hands it the pending network error of the new socket (accept(2)). Recalled: a local
        // interface that is down sets ENETDOWN, and an ICMP message that says the host is
        // unknown sets EHOSTDOWN.
        .NETUNREACH, .HOSTUNREACH, .NETDOWN, .HOSTDOWN => .network_unreachable,
        // The device failed a read, a write or an fdatasync (read(2), write(2), fsync(2)).
        .IO => .input_output,
        // A write or an fdatasync found no room: the device is full (ENOSPC), or the user's
        // quota of blocks on it is used up (EDQUOT). write(2), fsync(2).
        .NOSPC, .DQUOT => .no_space_left,
        // What the errno of a post says about its target ring: the helper names each situation.
        // For every other operation these five are `unexpected`.
        .OVERFLOW => code_of_post(context, .mailbox_full),
        .BADFD, .NXIO, .BADF, .OWNERDEAD => code_of_post(context, .loop_not_found),
        else => .unexpected,
    };
    assert(code != .timeout);
    return code;
}

/// ENOBUFS. For a receive from a provided-buffer group, `io_buffer_select` found the group empty
/// and the receive ended, a multishot receive included (`io_recv` in io_uring/net.c). For every
/// other operation the network stack had no buffer space: a socket at its buffer limit, or an
/// interface whose output queue is full (accept(2), send(2)).
fn code_of_no_buffers(context: Context) Code {
    return if (context.from_group) .buffers_exhausted else .system_resources;
}

/// The code of an errno that describes the target ring of a `post`. For every other operation
/// rotor has no code for the errno, so it is `unexpected`.
///
/// - EOVERFLOW, `mailbox_full`: `io_msg_ring_data` could not put the message's completion entry
///   in the target ring (io_uring/msg_ring.c, Linux 6.1 and 6.12). Recalled: a full completion
///   ring sends the entry to the ring's overflow list, so the failure is the kernel finding no
///   memory for that list. In Linux 6.12 a target ring set up with `IORING_SETUP_DEFER_TASKRUN`
///   takes `io_msg_data_remote` instead, which returns ENOMEM or EOWNERDEAD and never EOVERFLOW.
/// - EBADFD, `loop_not_found`: the descriptor the post names is open and is not an io_uring
///   (`io_msg_ring` in io_uring/msg_ring.c), or the target ring is not enabled yet
///   (`IORING_SETUP_R_DISABLED`, Linux 6.12).
/// - EBADF, `loop_not_found`: the descriptor the post names is not open, because the target
///   loop closed its ring (`io_issue_sqe` in io_uring/io_uring.c).
/// - EOWNERDEAD, `loop_not_found`: the thread that owned the target ring has exited
///   (`io_msg_data_remote` in io_uring/msg_ring.c, Linux 6.12).
/// - ENXIO, `loop_not_found`: recalled. `io_uring_enter` answers ENXIO for a ring that is being
///   torn down. No path of io_uring/msg_ring.c returns it in Linux 6.1 or 6.12.
fn code_of_post(context: Context, code: Code) Code {
    assert(code == .mailbox_full or code == .loop_not_found);
    return if (context.is_post) code else .unexpected;
}

/// True when the kernel transferred nothing and asked to be tried again: EAGAIN and EINTR. The
/// reap resubmits such an operation up to `core.constants.transfer_retries_max` times before the
/// caller hears of it.
pub fn is_retryable(errno: E) bool {
    assert_errno(errno);
    return switch (errno) {
        .AGAIN, .INTR => true,
        else => false,
    };
}

/// The errno in a completion's negative result.
pub fn errno_of(result: i32) E {
    assert(result < 0);
    assert(result >= -errno_max);
    const errno: E = @enumFromInt(@as(Errno, @intCast(-result)));
    assert_errno(errno);
    return errno;
}

/// Halts on a value no failed operation's result holds: 0 is success, and the kernel returns no
/// errno above `errno_max`.
fn assert_errno(errno: E) void {
    assert(errno != .SUCCESS);
    assert(@intFromEnum(errno) <= errno_max);
}

comptime {
    // `errno_of` names errnos that std has no name for, so `E` must hold every integer in
    // [1, errno_max] and must not be exhaustive.
    assert(errno_max >= 1);
    assert(errno_max <= std.math.maxInt(Errno));
    assert(!@typeInfo(E).@"enum".is_exhaustive);
    // A message's result is its tag with the top bit set (`core.constants.message_tag_max`), so
    // the largest one is below every errno's result, and `errno_of` is never handed a message.
    const message_result_max = std.math.minInt(i32) + @as(i64, core.constants.message_tag_max);
    assert(message_result_max < -errno_max);
}

const testing = std.testing;

/// One row of the map: an errno, what failed, and the code the caller must see.
const Row = struct { errno: E, context: Context = .{}, code: Code };

const group: Context = .{ .from_group = true };
const post: Context = .{ .is_post = true };

/// Every arm of the map by name, and every arm that reads the context under each context.
const rows = [_]Row{
    .{ .errno = .CANCELED, .code = .canceled },
    .{ .errno = .AGAIN, .code = .would_block },
    .{ .errno = .INTR, .code = .would_block },
    .{ .errno = .NOMEM, .code = .system_resources },
    .{ .errno = .NOMEM, .context = group, .code = .system_resources },
    .{ .errno = .NOBUFS, .code = .system_resources },
    .{ .errno = .NOBUFS, .context = group, .code = .buffers_exhausted },
    .{ .errno = .NOBUFS, .context = post, .code = .system_resources },
    .{ .errno = .MFILE, .code = .descriptor_limit },
    .{ .errno = .NFILE, .code = .descriptor_limit },
    .{ .errno = .CONNRESET, .code = .connection_reset },
    .{ .errno = .CONNREFUSED, .code = .connection_refused },
    .{ .errno = .CONNABORTED, .code = .connection_aborted },
    .{ .errno = .TIMEDOUT, .code = .connection_timed_out },
    .{ .errno = .PIPE, .code = .broken_pipe },
    .{ .errno = .NOTCONN, .code = .not_connected },
    .{ .errno = .NETUNREACH, .code = .network_unreachable },
    .{ .errno = .HOSTUNREACH, .code = .network_unreachable },
    .{ .errno = .NETDOWN, .code = .network_unreachable },
    .{ .errno = .HOSTDOWN, .code = .network_unreachable },
    .{ .errno = .IO, .code = .input_output },
    .{ .errno = .NOSPC, .code = .no_space_left },
    .{ .errno = .DQUOT, .code = .no_space_left },
    .{ .errno = .OVERFLOW, .context = post, .code = .mailbox_full },
    .{ .errno = .OVERFLOW, .code = .unexpected },
    .{ .errno = .OVERFLOW, .context = group, .code = .unexpected },
    .{ .errno = .BADFD, .context = post, .code = .loop_not_found },
    .{ .errno = .BADFD, .code = .unexpected },
    .{ .errno = .NXIO, .context = post, .code = .loop_not_found },
    .{ .errno = .NXIO, .code = .unexpected },
    .{ .errno = .BADF, .context = post, .code = .loop_not_found },
    .{ .errno = .BADF, .code = .unexpected },
    // Errnos the map does not name: a caller's mistake, an operation the kernel lacks, the
    // linked timeout's own result, and what Linux 6.12 answers a post whose target ring's
    // thread has exited (`io_msg_remote_post` in io_uring/msg_ring.c).
    .{ .errno = .INVAL, .code = .unexpected },
    .{ .errno = .INVAL, .context = post, .code = .unexpected },
    .{ .errno = .FAULT, .code = .unexpected },
    .{ .errno = .OPNOTSUPP, .code = .unexpected },
    .{ .errno = .TIME, .code = .unexpected },
    .{ .errno = .OWNERDEAD, .context = post, .code = .loop_not_found },
    .{ .errno = .OWNERDEAD, .code = .unexpected },
};

test "every arm of the map yields its code, and an arm that reads the context obeys it" {
    for (rows) |row| {
        errdefer std.debug.print("errno {s}, {any}\n", .{ @tagName(row.errno), row.context });
        try testing.expectEqual(row.code, code_of(row.errno, row.context));
    }
}

test "the map names 20 errnos for every operation and 4 more for a post, and no other" {
    const contexts = [_]Context{ .{}, group, post };
    const named = [_]u32{ 20, 20, 25 };
    for (contexts, named) |context, expected| {
        var count: u32 = 0;
        for (1..4096) |number| {
            const errno = errno_of(-@as(i32, @intCast(number)));
            if (code_of(errno, context) != .unexpected) count += 1;
        }
        try testing.expectEqual(expected, count);
    }
}

test "EAGAIN and EINTR are retryable, and no other errno is" {
    try testing.expect(is_retryable(.AGAIN));
    try testing.expect(is_retryable(.INTR));
    const final = [_]E{
        .CANCELED, .NOMEM, .NOBUFS,     .TIMEDOUT, .CONNRESET,
        .BUSY,     .NXIO,  .INPROGRESS, .ALREADY,  .TIME,
    };
    for (final) |errno| try testing.expect(!is_retryable(errno));
    var retryable: u32 = 0;
    for (1..4096) |number| {
        const errno = errno_of(-@as(i32, @intCast(number)));
        // The reap retries exactly the errnos the caller would see as `would_block`.
        try testing.expectEqual(code_of(errno, .{}) == .would_block, is_retryable(errno));
        if (is_retryable(errno)) retryable += 1;
    }
    try testing.expectEqual(2, retryable);
}

test "errno_of reads the errno out of a completion's negative result" {
    for (rows) |row| {
        const result = -@as(i32, @intFromEnum(row.errno));
        try testing.expectEqual(row.errno, errno_of(result));
    }
    // Both ends of the range. std has no name for 4095, and the map has none either.
    try testing.expectEqual(E.PERM, errno_of(-1));
    try testing.expectEqual(4095, @intFromEnum(errno_of(-4095)));
    try testing.expectEqual(Code.unexpected, code_of(errno_of(-4095), .{}));
}

test "a fabricated completion's result becomes the error the caller sees" {
    // What the reap does with a negative result it does not retry (decision 10, point 3).
    const result = -@as(i32, @intFromEnum(E.CONNRESET));
    try testing.expect(!is_retryable(errno_of(result)));
    const event = core.Event.failure(7, code_of(errno_of(result), .{}));
    try testing.expectEqual(core.event.result_of(.connection_reset), event.result);
    try testing.expectError(error.ConnectionReset, event.outcome());
}
