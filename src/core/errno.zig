//! The map from an errno to a `Code`: the branch an operation that succeeded never takes. A
//! readiness backend makes each system call itself, so the errno is the call's own. `kqueue` and
//! `epoll` share this file; `uring` has its own, because io_uring returns `-errno` in a completion
//! and its map documents each kernel situation that produces one.
//!
//! Two errnos never reach this map. EAGAIN means the descriptor is not ready: the operation waits
//! for readiness and is tried again (decision 12, point 1). EINTR means a signal interrupted the
//! call before it transferred anything: the backend makes the call again.
//!
//! The map matches by name, not by number, so it compiles and its tests run on every host. It takes
//! the errno as `anytype` for one reason: `epoll` reads `std.os.linux.E`, which is a different
//! type from `std.posix.E` on a macOS build, and every arm here names a tag both have. `E` below
//! is the host's, for a caller that wants to name the type.
const std = @import("std");
const assert = std.debug.assert;
const event_module = @import("event.zig");

pub const E = std.posix.E;

/// True when the call transferred nothing and the backend handles the errno itself.
pub fn is_handled_by_the_backend(errno: anytype) bool {
    return errno == .AGAIN or errno == .INTR or errno == .INPROGRESS;
}

/// The code a failed call's errno carries.
pub fn code_of(errno: anytype) event_module.Code {
    assert(errno != .SUCCESS);
    assert(!is_handled_by_the_backend(errno));
    return switch (errno) {
        // The kernel had no memory, or no socket buffer space, for the call.
        .NOMEM, .NOBUFS => .system_resources,
        // accept(2): the process, or the system, has no free descriptor.
        .MFILE, .NFILE => .descriptor_limit,
        .CONNRESET => .connection_reset,
        .CONNREFUSED => .connection_refused,
        // accept(2): the peer gave up before the accept.
        .CONNABORTED => .connection_aborted,
        // The peer stopped answering: TCP's own timeout.
        .TIMEDOUT => .connection_timed_out,
        .PIPE => .broken_pipe,
        .NOTCONN => .not_connected,
        .NETUNREACH, .HOSTUNREACH, .NETDOWN, .HOSTDOWN => .network_unreachable,
        .IO => .input_output,
        .NOSPC, .DQUOT => .no_space_left,
        else => .unexpected,
    };
}

/// The code a failed `recvmsg` or `sendmsg` on a datagram socket carries. Two errnos have a
/// datagram meaning of their own: EMSGSIZE has its own code, because a QUIC stack answers it by
/// lowering its packet size, and EDESTADDRREQ is a send with no peer on a socket that has none.
/// Every other errno means what it means for any call, so `code_of` answers it.
pub fn datagram_code_of(errno: anytype) event_module.Code {
    return switch (errno) {
        .MSGSIZE => .message_too_long,
        .DESTADDRREQ => .not_connected,
        else => code_of(errno),
    };
}

const testing = std.testing;

const Row = struct { errno: E, code: event_module.Code };

const rows = [_]Row{
    .{ .errno = .NOMEM, .code = .system_resources },
    .{ .errno = .NOBUFS, .code = .system_resources },
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
    .{ .errno = .BADF, .code = .unexpected },
    .{ .errno = .INVAL, .code = .unexpected },
};

test "every errno the map names carries its code, and one it does not name is unexpected" {
    for (rows) |row| try testing.expectEqual(row.code, code_of(row.errno));
}

test "the backend keeps would-block, interrupted and in-progress to itself" {
    try testing.expect(is_handled_by_the_backend(.AGAIN));
    try testing.expect(is_handled_by_the_backend(.INTR));
    try testing.expect(is_handled_by_the_backend(.INPROGRESS));
    for (rows) |row| try testing.expect(!is_handled_by_the_backend(row.errno));
}

test "no errno maps to a code that only the loop itself produces" {
    for (rows) |row| {
        const code = code_of(row.errno);
        try testing.expect(code != .canceled and code != .timeout);
        try testing.expect(code != .mailbox_full and code != .loop_not_found);
        try testing.expect(code != .buffers_exhausted and code != .would_block);
    }
}

test "the map reads a Linux errno on a macOS build, which is what the epoll backend hands it" {
    // `std.os.linux.E` is a different type from `std.posix.E` unless the target is Linux, and the
    // epoll backend names the first. Every arm of the map names a tag both types have, so the same
    // rows answer the same codes; this test proves that on whatever host runs it.
    const LinuxE = std.os.linux.E;
    try testing.expectEqual(event_module.Code.system_resources, code_of(LinuxE.NOMEM));
    try testing.expectEqual(event_module.Code.connection_reset, code_of(LinuxE.CONNRESET));
    try testing.expectEqual(event_module.Code.no_space_left, code_of(LinuxE.DQUOT));
    try testing.expectEqual(event_module.Code.unexpected, code_of(LinuxE.BADF));
    try testing.expect(is_handled_by_the_backend(LinuxE.AGAIN));
    try testing.expect(!is_handled_by_the_backend(LinuxE.NOMEM));
}

/// The errnos a datagram call may meet. The first two are the datagram's own; the rest are the
/// ones the kqueue backend's first map, written apart from `code_of`, answered `unexpected`.
const datagram_rows = [_]Row{
    .{ .errno = .MSGSIZE, .code = .message_too_long },
    .{ .errno = .DESTADDRREQ, .code = .not_connected },
    .{ .errno = .CONNRESET, .code = .connection_reset },
    .{ .errno = .PIPE, .code = .broken_pipe },
    .{ .errno = .TIMEDOUT, .code = .connection_timed_out },
    .{ .errno = .NETDOWN, .code = .network_unreachable },
    .{ .errno = .HOSTDOWN, .code = .network_unreachable },
};

test "a datagram call's errno carries its datagram code, or the code any call's would" {
    for (datagram_rows) |row| try testing.expectEqual(row.code, datagram_code_of(row.errno));
    for (rows) |row| try testing.expectEqual(row.code, datagram_code_of(row.errno));
}

test "the datagram map reads a Linux errno on a macOS build, as the epoll backend hands it" {
    const LinuxE = std.os.linux.E;
    try testing.expectEqual(event_module.Code.message_too_long, datagram_code_of(LinuxE.MSGSIZE));
    try testing.expectEqual(event_module.Code.not_connected, datagram_code_of(LinuxE.DESTADDRREQ));
    try testing.expectEqual(event_module.Code.broken_pipe, datagram_code_of(LinuxE.PIPE));
}
