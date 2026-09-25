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
};

/// The code a failed operation's errno carries.
///
/// ECANCELED always maps to `canceled`. When the loop's own deadline caused the cancel, the
/// final event says `timeout` (decision 5, rule 4). The reap makes that change itself, because
/// the slot records whose cancel it was and the errno does not. This map never returns `timeout`.
pub fn code_of(errno: E, context: Context) Code {
    assert_errno(errno);
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
        // An empty buffer group, or a network stack out of buffer space: the helper says which.
        .NOBUFS => code_of_no_buffers(context),
        // Until 2026-09-25 these five described the target ring of a post, which went through
        // `IORING_OP_MSG_RING`. A post goes through the mailbox rings now (decision 4), so no
        // operation rotor submits gives them a meaning of its own.
        .OVERFLOW, .BADFD, .NXIO, .BADF, .OWNERDEAD => .unexpected,
        // io_uring's connect waits for the handshake itself, so no completion carries EINPROGRESS
        // (recalled). `core.errno` keeps it for a readiness backend and asserts it never arrives.
        .INPROGRESS => .unexpected,
        // Every other errno means on io_uring what it means for a backend that makes the call
        // itself, so `core.errno` maps it. ENOMEM there covers the state io_uring keeps of a
        // connect it tries again (`io_connect` in io_uring/net.c).
        else => core.errno.datagram_code_of(errno),
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

/// Every arm of the map by name, and every arm that reads the context under each context.
const rows = [_]Row{
    .{ .errno = .CANCELED, .code = .canceled },
    .{ .errno = .AGAIN, .code = .would_block },
    .{ .errno = .INTR, .code = .would_block },
    .{ .errno = .NOMEM, .code = .system_resources },
    .{ .errno = .NOMEM, .context = group, .code = .system_resources },
    .{ .errno = .NOBUFS, .code = .system_resources },
    .{ .errno = .NOBUFS, .context = group, .code = .buffers_exhausted },
    .{ .errno = .MFILE, .code = .descriptor_limit },
    .{ .errno = .NFILE, .code = .descriptor_limit },
    .{ .errno = .CONNRESET, .code = .connection_reset },
    .{ .errno = .CONNREFUSED, .code = .connection_refused },
    .{ .errno = .CONNABORTED, .code = .connection_aborted },
    .{ .errno = .TIMEDOUT, .code = .connection_timed_out },
    .{ .errno = .PIPE, .code = .broken_pipe },
    .{ .errno = .NOTCONN, .code = .not_connected },
    .{ .errno = .DESTADDRREQ, .code = .not_connected },
    .{ .errno = .MSGSIZE, .code = .message_too_long },
    .{ .errno = .NETUNREACH, .code = .network_unreachable },
    .{ .errno = .HOSTUNREACH, .code = .network_unreachable },
    .{ .errno = .NETDOWN, .code = .network_unreachable },
    .{ .errno = .HOSTDOWN, .code = .network_unreachable },
    .{ .errno = .IO, .code = .input_output },
    .{ .errno = .NOSPC, .code = .no_space_left },
    .{ .errno = .DQUOT, .code = .no_space_left },
    .{ .errno = .OVERFLOW, .code = .unexpected },
    .{ .errno = .OVERFLOW, .context = group, .code = .unexpected },
    .{ .errno = .BADFD, .code = .unexpected },
    .{ .errno = .NXIO, .code = .unexpected },
    .{ .errno = .BADF, .code = .unexpected },
    // Errnos the map does not name: a caller's mistake, an operation the kernel lacks, and the
    // linked timeout's own result.
    .{ .errno = .INVAL, .code = .unexpected },
    .{ .errno = .FAULT, .code = .unexpected },
    .{ .errno = .OPNOTSUPP, .code = .unexpected },
    .{ .errno = .TIME, .code = .unexpected },
    .{ .errno = .OWNERDEAD, .code = .unexpected },
};

test "every arm of the map yields its code, and an arm that reads the context obeys it" {
    for (rows) |row| {
        errdefer std.debug.print("errno {s}, {any}\n", .{ @tagName(row.errno), row.context });
        try testing.expectEqual(row.code, code_of(row.errno, row.context));
    }
}

test "the map names 22 errnos for every operation, and no other" {
    const contexts = [_]Context{ .{}, group };
    const named = [_]u32{ 22, 22 };
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
