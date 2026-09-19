//! The socket calls the probes share, spelled once for both targets. On macOS they are libSystem's
//! stubs, the only supported way into the kernel. On Linux the probes link no libc, so the same
//! names are the raw system calls of std.os.linux, and `send` and `recv` are `sendto` and
//! `recvfrom` with no address, which is what a libc makes of them.
//!
//! The Linux branches compile and have never run: docs/costs.md has no Linux machine yet.
//!
//! A failed call returns `error.SystemCallFailed`. No call here retries on EINTR, because the
//! probes install no signal handler.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const system = posix.system;
const Error = @import("measure.zig").Error;

pub const fd_t = posix.fd_t;

/// 127.0.0.1, in host byte order.
const loopback_address = 0x7f00_0001;

/// The listen backlog of the socket a pair connects through: one connection ever arrives.
const listen_backlog = 1;

/// The value that switches a boolean socket option on.
const option_enabled: c_int = 1;

fn check(rc: anytype) Error!void {
    if (posix.errno(rc) != .SUCCESS) return error.SystemCallFailed;
}

fn descriptor(rc: anytype) Error!fd_t {
    try check(rc);
    return @intCast(rc);
}

fn count(rc: anytype) Error!usize {
    try check(rc);
    return @intCast(rc);
}

pub fn close(fd: fd_t) void {
    const rc = system.close(fd);
    assert(posix.errno(rc) == .SUCCESS);
}

/// Two connected TCP sockets on the loopback interface, TCP_NODELAY set on both.
pub const Pair = struct {
    near: fd_t,
    far: fd_t,

    pub fn deinit(pair: Pair) void {
        close(pair.near);
        close(pair.far);
    }
};

/// Connects a pair through a listener on an ephemeral port, and closes the listener.
pub fn tcp_pair() Error!Pair {
    const listener = try tcp_socket();
    defer close(listener);
    var address: posix.sockaddr.in = .{
        .port = 0,
        .addr = std.mem.nativeToBig(u32, loopback_address),
    };
    var address_bytes: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try check(system.bind(listener, @ptrCast(&address), address_bytes));
    try check(system.listen(listener, listen_backlog));
    try check(system.getsockname(listener, @ptrCast(&address), &address_bytes));
    assert(address.port != 0);

    const near = try tcp_socket();
    errdefer close(near);
    try check(system.connect(near, @ptrCast(&address), address_bytes));
    const far = try descriptor(system.accept(listener, null, null));
    errdefer close(far);
    try set_no_delay(near);
    try set_no_delay(far);
    return .{ .near = near, .far = far };
}

fn tcp_socket() Error!fd_t {
    return descriptor(system.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP));
}

/// Without TCP_NODELAY a 1-byte send can wait for the peer's delayed acknowledgement, and the
/// round trip would measure that timer.
fn set_no_delay(fd: fd_t) Error!void {
    const option = std.mem.asBytes(&option_enabled);
    posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, option) catch
        return error.SystemCallFailed;
}

/// One `send` with no flags. Returns the bytes the kernel took.
pub fn send(fd: fd_t, bytes: []const u8) Error!usize {
    const rc = switch (builtin.os.tag) {
        .linux => std.os.linux.sendto(fd, bytes.ptr, bytes.len, 0, null, 0),
        else => std.c.send(fd, bytes.ptr, bytes.len, 0),
    };
    return count(rc);
}

/// One `recv`. `flags` is a set of posix.MSG values. Returns the bytes received.
pub fn recv(fd: fd_t, buffer: []u8, flags: u32) Error!usize {
    const rc = switch (builtin.os.tag) {
        .linux => std.os.linux.recvfrom(fd, buffer.ptr, buffer.len, flags, null, null),
        else => std.c.recv(fd, buffer.ptr, buffer.len, @intCast(flags)),
    };
    return count(rc);
}

/// Wakes a thread blocked in `recv` on the other end with an end of stream: a helper thread that
/// fails calls this so the measuring thread fails too, where it would otherwise block for good.
pub fn shutdown(fd: fd_t) void {
    _ = system.shutdown(fd, posix.SHUT.RDWR);
}
