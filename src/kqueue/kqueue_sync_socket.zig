//! The socket half of `kqueue_sync.zig`: a socket or a listener made ready for the loop, an
//! accepted socket given the same settings, a socket's address and TCP_NODELAY, and `close_now`.
//!
//! This backend makes each transfer itself when kqueue reports readiness (decision 12, point 1),
//! so a socket that blocks would block the loop. macOS has no SOCK_NONBLOCK, no SOCK_CLOEXEC and
//! no MSG_NOSIGNAL, so every socket takes three settings after it is opened or accepted:
//! O_NONBLOCK, FD_CLOEXEC and SO_NOSIGPIPE (decision 12, point 8).
//!
//! Each errno map is a function of the errno alone, so its test runs on every host. Every other
//! test enters the kernel and runs under macOS alone.
const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const core = @import("core");
const kqueue_address = @import("kqueue_address.zig");

const Address = core.Address;
const Descriptor = core.Descriptor;

// The types are `core/sync.zig`'s, which every backend's calls take and return.
pub const SocketError = core.sync.SocketError;
pub const ListenError = core.sync.ListenError;
pub const AddressError = core.sync.AddressError;
pub const OptionError = core.sync.OptionError;
pub const ListenOptions = core.sync.ListenOptions;
pub const SocketBuffer = core.sync.SocketBuffer;
pub const socket_buffer_bytes_max = core.sync.socket_buffer_bytes_max;
pub const BufferError = core.sync.BufferError;
// macOS carries every `DatagramOptions` option a QUIC stack needs. The IPv6 names sit behind
// `__APPLE_USE_RFC_3542` in the SDK, which gates the header and not the kernel, so
// `kqueue_datagram.zig` names them by their numbers. A refusal costs the caller that answer.
pub const DatagramOptions = core.sync.DatagramOptions;

const E = posix.E;

/// A TCP socket of `family` with the three settings of `prepare_accepted`: it does not block,
/// it closes on exec, and a send to a closed peer answers EPIPE and raises no SIGPIPE.
pub fn open_socket(family: Address.Family) SocketError!Descriptor {
    const domain: c_uint = switch (family) {
        .ipv4 => c.AF.INET,
        .ipv6 => c.AF.INET6,
    };
    const rc = c.socket(domain, c.SOCK.STREAM, c.IPPROTO.TCP);
    const errno = posix.errno(rc);
    if (errno != .SUCCESS) return socket_error(errno);
    assert(rc >= 0);
    errdefer close_now(rc);
    // A TCP socket this function just opened takes all three settings, so a refusal has no name.
    prepare_accepted(rc) catch return error.Unexpected;
    return rc;
}

/// The three settings a socket needs before the loop may use it, for a socket `accept(2)`
/// returned: macOS has no `accept4`, so the loop's accept path calls this (decision 12, point 8).
/// SO_NOSIGPIPE goes first, so a descriptor that is no socket is refused before its flags change.
/// F_SETFL replaces the status flags, which drops an O_ASYNC inherited from the listener, and
/// F_SETFD replaces the descriptor flags, which a descriptor just accepted has none of.
pub fn prepare_accepted(descriptor: Descriptor) OptionError!void {
    assert(descriptor >= 0);
    try set_option(descriptor, c.SOL.SOCKET, c.SO.NOSIGPIPE, true);
    const nonblocking: c.O = .{ .NONBLOCK = true };
    try set_flags(descriptor, c.F.SETFL, @bitCast(nonblocking));
    try set_flags(descriptor, c.F.SETFD, c.FD_CLOEXEC);
}

/// socket with its three settings, SO_REUSEADDR, SO_REUSEPORT when asked, bind, listen.
/// SO_REUSEADDR lets a restarted server bind its port while connections of the last run still
/// sit in TIME_WAIT. Closes the socket again on any failure after it was opened. An `address`
/// with port 0 takes a port the kernel chooses, which `local_address` reports.
pub fn listen(address: *const Address, options: ListenOptions) ListenError!Descriptor {
    assert(options.backlog >= 1);
    const socket = try open_socket(address.family);
    errdefer close_now(socket);
    // A socket this function just opened has both options, so a refusal here has no name.
    set_option(socket, c.SOL.SOCKET, c.SO.REUSEADDR, true) catch return error.Unexpected;
    if (options.reuse_port) {
        set_option(socket, c.SOL.SOCKET, c.SO.REUSEPORT, true) catch return error.Unexpected;
    }
    var storage: kqueue_address.Storage = undefined;
    const len = kqueue_address.to_kernel(address, &storage);
    const bind_errno = posix.errno(c.bind(socket, @ptrCast(&storage), len));
    if (bind_errno != .SUCCESS) return listen_error(bind_errno);
    const listen_errno = posix.errno(c.listen(socket, options.backlog));
    if (listen_errno != .SUCCESS) return listen_error(listen_errno);
    return socket;
}

/// getsockname: how a caller that bound port 0 learns the port the kernel chose.
pub fn local_address(descriptor: Descriptor) AddressError!Address {
    assert(descriptor >= 0);
    var storage = std.mem.zeroes(kqueue_address.Storage);
    var len: c.socklen_t = @sizeOf(kqueue_address.Storage);
    const errno = posix.errno(c.getsockname(descriptor, @ptrCast(&storage), &len));
    if (errno != .SUCCESS) return socket_call_error(errno);
    // The kernel reports the untruncated length, which the path of a Unix socket makes longer
    // than `storage` (measured on Darwin 25.6). `from_kernel` reads the family and refuses it.
    const address = kqueue_address.from_kernel(&storage, len) orelse
        return error.AddressFamilyUnsupported;
    assert(len >= @sizeOf(posix.sockaddr.in));
    return address;
}

/// TCP_NODELAY: when `enabled`, the kernel sends a small segment at once (Nagle's algorithm off).
pub fn set_no_delay(descriptor: Descriptor, enabled: bool) OptionError!void {
    return set_option(descriptor, c.IPPROTO.TCP, c.TCP.NODELAY, enabled);
}

/// close(2), for a descriptor with no operation in flight: start-up, shutdown and tests. A
/// descriptor with operations in flight is closed with the `close` operation (decision 5, rule 6).
/// `std.c.close` is `close$NOCANCEL` here, which is no cancellation point: it frees the
/// descriptor whatever it answers, EINTR and EIO included, so there is nothing to retry and no
/// error a caller could act on. EBADF is the exception: a double close, which in a process with
/// other threads closes a descriptor one of them just opened. It halts.
pub fn close_now(descriptor: Descriptor) void {
    assert(descriptor >= 0);
    const errno = posix.errno(c.close(descriptor));
    assert(errno != .BADF);
}

pub fn set_option(descriptor: Descriptor, level: i32, name: u32, enabled: bool) OptionError!void {
    assert(descriptor >= 0);
    const value: c_int = @intFromBool(enabled);
    const rc = c.setsockopt(descriptor, level, name, &value, @sizeOf(c_int));
    const errno = posix.errno(rc);
    if (errno != .SUCCESS) return socket_call_error(errno);
}

/// fcntl(F_SETFL) with the status flags, or fcntl(F_SETFD) with the descriptor flags. It sets
/// `flags` whole and reads nothing first, which keeps a setting at one system call.
/// `pub` for `kqueue_sync_socket_test.zig`, which checks what it answers.
/// `kqueue_sync.zig` names what this backend exports, so this reaches no consumer.
pub fn set_flags(descriptor: Descriptor, command: c_int, flags: c_int) OptionError!void {
    assert(descriptor >= 0);
    assert(command == c.F.SETFL or command == c.F.SETFD);
    const rc = c.fcntl(descriptor, command, flags);
    if (posix.errno(rc) != .SUCCESS) return error.Unexpected;
}

/// `pub` for `kqueue_sync_socket_test.zig`, which checks what it answers.
/// `kqueue_sync.zig` names what this backend exports, so this reaches no consumer.
pub fn socket_error(errno: E) SocketError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .MFILE, .NFILE => error.DescriptorLimit,
        .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

/// The errno of a `bind(2)` or of a `listen(2)`.
/// `pub` for `kqueue_sync_socket_test.zig`, which checks what it answers.
/// `kqueue_sync.zig` names what this backend exports, so this reaches no consumer.
pub fn listen_error(errno: E) ListenError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// The errno of a call that takes a socket: `getsockname(2)` or `setsockopt(2)`.
/// `pub` for `kqueue_sync_socket_test.zig`, which checks what it answers.
/// `kqueue_sync.zig` names what this backend exports, so this reaches no consumer.
pub fn socket_call_error(errno: E) error{ NotSocket, Unexpected } {
    assert(errno != .SUCCESS);
    return if (errno == .NOTSOCK) error.NotSocket else error.Unexpected;
}

/// The errno of a buffer call. ENOBUFS is this kernel refusing the size, which is the one answer a
/// caller can act on: ask for less.
fn buffer_error(errno: E) BufferError {
    assert(errno != .SUCCESS);
    if (errno == .NOBUFS) return error.SizeRefused;
    return socket_call_error(errno);
}

/// Asks the kernel for `bytes` of buffer on this socket, and answers the size it set.
///
/// **The answer is not the request, and the two kernels differ in how.** Measured on 2026-09-22:
///
/// - Linux doubles what it is asked for, to cover its own bookkeeping, floors it at 2,304 bytes
///   for a receive buffer and 4,608 for a send buffer, and caps it at `net.core.rmem_max` or
///   `wmem_max` for a caller without `CAP_NET_ADMIN`. It never refuses: 1 byte becomes 2,304 and
///   2 GiB became 15,000,000 on the kernel of that day.
/// - macOS grants exactly what it is asked for, 1 byte included, up to its own limit, which was
///   8 MiB on the machine measured. Above that it does one of two things, and which one depends on
///   the size the socket already has: from a small buffer it capped a 2 GiB request to 8 MiB, and
///   from 8 MiB it refused the same request with ENOBUFS. That refusal is `SizeRefused`, and it is
///   why this call has an error of its own.
///
/// So a caller reads the answer, as it reads back the port `local_address` reports for port 0.
///
/// A datagram receiver under load is what this is for: a socket whose receive buffer is too small
/// drops what arrives while the loop is elsewhere, and no operation reports that.
pub fn set_buffer_bytes(
    descriptor: Descriptor,
    which: SocketBuffer,
    bytes: u32,
) BufferError!u32 {
    assert(descriptor >= 0);
    assert(bytes >= 1);
    assert(bytes <= socket_buffer_bytes_max);
    const name: u32 = switch (which) {
        .receive => c.SO.RCVBUF,
        .send => c.SO.SNDBUF,
    };
    const wanted: c_int = @intCast(bytes);
    const set = c.setsockopt(descriptor, c.SOL.SOCKET, name, &wanted, @sizeOf(c_int));
    if (posix.errno(set) != .SUCCESS) return buffer_error(posix.errno(set));
    var value: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    const read = c.getsockopt(descriptor, c.SOL.SOCKET, name, &value, &len);
    if (posix.errno(read) != .SUCCESS) return buffer_error(posix.errno(read));
    assert(value >= 0);
    return @intCast(value);
}

/// A UDP socket of `family`, closed on exec, bound to `address` when one is given.
pub fn open_datagram(
    family: Address.Family,
    bind_to: ?*const Address,
    options: DatagramOptions,
) ListenError!Descriptor {
    const domain: c_uint = switch (family) {
        .ipv4 => c.AF.INET,
        .ipv6 => c.AF.INET6,
    };
    // No SOCK_CLOEXEC and no SOCK_NONBLOCK: macOS has neither, so `prepare_accepted` sets both
    // afterwards, exactly as `open_socket` does for a stream socket (decision 12, point 8).
    const rc = c.socket(domain, c.SOCK.DGRAM, c.IPPROTO.UDP);
    const errno = posix.errno(rc);
    if (errno != .SUCCESS) return socket_error(errno);
    assert(rc >= 0);
    errdefer close_now(rc);
    // The loop waits on readiness here, so a blocking socket would stall every other connection
    // inside one `recvmsg`.
    prepare_accepted(rc) catch return error.Unexpected;
    @import("kqueue_datagram.zig").apply_options(rc, family, options);
    if (bind_to) |address| {
        assert(address.family == family);
        var storage: kqueue_address.Storage = undefined;
        const len = kqueue_address.to_kernel(address, &storage);
        const bound = c.bind(rc, @ptrCast(@alignCast(&storage)), len);
        const bind_errno = posix.errno(bound);
        if (bind_errno != .SUCCESS) return listen_error(bind_errno);
    }
    return rc;
}
