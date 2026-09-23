//! The synchronous socket calls of decision 2: a socket opened, a listener bound, a socket's own
//! address read, TCP_NODELAY set, a descriptor closed. They run at start-up and once per
//! connection, never per transfer, so they are plain: one raw syscall at a time, every return
//! value checked, every errno mapped to a named error, with `Unexpected` for the rest.
//!
//! Each map is a function of the errno alone, so a test on any host covers the refusals the kernel
//! will not produce on demand (decision 10, point 3). Every other test runs under Linux alone.
//!
//! Both Linux backends make these calls. The one difference is how a socket is opened: `uring`'s
//! sockets block, because the ring does the waiting, and `epoll`'s carry SOCK_NONBLOCK, because
//! the loop makes each transfer itself when the socket is ready (decision 20). So the calls that
//! open a socket take the type flags, and each backend passes its own.
//!
//! `close_now` and `descriptor_of` live here and `linux_shared_sync_file.zig` imports them, because
//! a file needs both and a socket needed them first.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const address_module = @import("linux_shared_address.zig");
const datagram = @import("linux_shared_datagram.zig");

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
pub const DatagramOptions = core.sync.DatagramOptions;

/// A TCP socket of `family`, opened with `flags`: SOCK_CLOEXEC, and SOCK_NONBLOCK for a backend
/// that makes each transfer itself.
pub fn open_socket(family: Address.Family, flags: u32) SocketError!Descriptor {
    assert(flags & linux.SOCK.CLOEXEC != 0);
    const domain: u32 = switch (family) {
        .ipv4 => linux.AF.INET,
        .ipv6 => linux.AF.INET6,
    };
    const rc = linux.socket(domain, linux.SOCK.STREAM | flags, linux.IPPROTO.TCP);
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) return socket_error(errno);
    return descriptor_of(rc);
}

/// socket, SO_REUSEADDR, SO_REUSEPORT when asked, bind, listen. SO_REUSEADDR lets a restarted
/// server bind its port while connections of the last run still sit in TIME_WAIT. Closes the
/// socket again on any failure after it was opened. An `address` with port 0 takes a port the
/// kernel chooses, which `local_address` reports. `flags` are `open_socket`'s.
pub fn listen(address: *const Address, options: ListenOptions, flags: u32) ListenError!Descriptor {
    assert(options.backlog >= 1);
    const socket = try open_socket(address.family, flags);
    errdefer close_now(socket);
    // A socket this function just opened has both options, so a refusal here has no name.
    set_option(socket, linux.SOL.SOCKET, linux.SO.REUSEADDR, true) catch return error.Unexpected;
    if (options.reuse_port) {
        set_option(socket, linux.SOL.SOCKET, linux.SO.REUSEPORT, true) catch
            return error.Unexpected;
    }
    var storage: address_module.Storage = undefined;
    const len = address_module.to_kernel(address, &storage);
    const bind_errno = linux.errno(linux.bind(socket, @ptrCast(&storage), len));
    if (bind_errno != .SUCCESS) return listen_error(bind_errno);
    // Two sockets that both set SO_REUSEADDR can bind one port while neither listens, so the
    // second of them meets EADDRINUSE here and not at bind.
    const listen_errno = linux.errno(linux.listen(socket, options.backlog));
    if (listen_errno != .SUCCESS) return listen_error(listen_errno);
    return socket;
}

/// getsockname: how a caller that bound port 0 learns the port the kernel chose.
pub fn local_address(descriptor: Descriptor) AddressError!Address {
    assert(descriptor >= 0);
    var storage = std.mem.zeroes(address_module.Storage);
    var len: linux.socklen_t = @sizeOf(address_module.Storage);
    const errno = linux.errno(linux.getsockname(descriptor, @ptrCast(&storage), &len));
    if (errno != .SUCCESS) return socket_call_error(errno);
    assert(len >= @sizeOf(linux.sa_family_t));
    return address_module.from_kernel(&storage, len) orelse error.AddressFamilyUnsupported;
}

/// TCP_NODELAY: when `enabled`, the kernel sends a small segment at once (Nagle's algorithm off).
pub fn set_no_delay(descriptor: Descriptor, enabled: bool) OptionError!void {
    return set_option(descriptor, linux.IPPROTO.TCP, linux.TCP.NODELAY, enabled);
}

/// close(2), for a descriptor with no operation in flight: start-up, shutdown and tests. A
/// descriptor with operations in flight is closed with the `close` operation (decision 5, rule 6).
/// Linux frees the descriptor whatever close(2) answers, EINTR and EIO included, so there is
/// nothing to retry and no error a caller could act on. EBADF is the exception: a double close,
/// which in a process with other threads closes a descriptor one of them just opened. It halts.
pub fn close_now(descriptor: Descriptor) void {
    assert(descriptor >= 0);
    const errno = linux.errno(linux.close(descriptor));
    assert(errno != .BADF);
}

/// The descriptor a successful `socket(2)` or `open(2)` returned.
pub fn descriptor_of(rc: usize) Descriptor {
    assert(linux.errno(rc) == .SUCCESS);
    assert(rc <= std.math.maxInt(Descriptor));
    return @intCast(rc);
}

pub fn set_option(descriptor: Descriptor, level: i32, name: u32, enabled: bool) OptionError!void {
    assert(descriptor >= 0);
    const value: c_int = @intFromBool(enabled);
    const rc = linux.setsockopt(descriptor, level, name, std.mem.asBytes(&value), @sizeOf(c_int));
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) return socket_call_error(errno);
}

fn socket_error(errno: linux.E) SocketError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .MFILE, .NFILE => error.DescriptorLimit,
        .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

/// The errno of a `bind(2)` or of a `listen(2)`.
fn listen_error(errno: linux.E) ListenError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// The errno of a call that takes a socket: `getsockname(2)` or `setsockopt(2)`.
fn socket_call_error(errno: linux.E) error{ NotSocket, Unexpected } {
    assert(errno != .SUCCESS);
    return if (errno == .NOTSOCK) error.NotSocket else error.Unexpected;
}

/// The errno of a buffer call. This kernel caps a large size rather than refusing it, so ENOBUFS
/// is not expected here; the arm exists because the surface is one on both backends.
fn buffer_error(errno: linux.E) BufferError {
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
        .receive => linux.SO.RCVBUF,
        .send => linux.SO.SNDBUF,
    };
    const wanted: c_int = @intCast(bytes);
    const set = linux.setsockopt(
        descriptor,
        linux.SOL.SOCKET,
        name,
        std.mem.asBytes(&wanted),
        @sizeOf(c_int),
    );
    if (linux.errno(set) != .SUCCESS) return buffer_error(linux.errno(set));
    var value: c_int = 0;
    var len: linux.socklen_t = @sizeOf(c_int);
    const read = linux.getsockopt(
        descriptor,
        linux.SOL.SOCKET,
        name,
        std.mem.asBytes(&value),
        &len,
    );
    if (linux.errno(read) != .SUCCESS) return buffer_error(linux.errno(read));
    assert(value >= 0);
    return @intCast(value);
}

/// A UDP socket of `family`, opened with `flags` as `open_socket` is, bound to `address` when one
/// is given. A port of 0 takes one the kernel chooses, which `local_address` reports. Closes the
/// socket again on any failure after it was opened.
pub fn open_datagram(
    family: Address.Family,
    bind_to: ?*const Address,
    options: DatagramOptions,
    flags: u32,
) ListenError!Descriptor {
    assert(flags & linux.SOCK.CLOEXEC != 0);
    const domain: u32 = switch (family) {
        .ipv4 => linux.AF.INET,
        .ipv6 => linux.AF.INET6,
    };
    const rc = linux.socket(domain, linux.SOCK.DGRAM | flags, linux.IPPROTO.UDP);
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) return socket_error(errno);
    const socket = descriptor_of(rc);
    errdefer close_now(socket);
    datagram.apply_options(socket, family, options);
    if (bind_to) |address| {
        assert(address.family == family);
        var storage: address_module.Storage = undefined;
        const len = address_module.to_kernel(address, &storage);
        const bind_errno = linux.errno(linux.bind(socket, @ptrCast(&storage), len));
        if (bind_errno != .SUCCESS) return listen_error(bind_errno);
    }
    return socket;
}

/// The options of a datagram socket. A kernel that refuses one is not a failure to open the
/// socket: the caller loses that answer and nothing else, and the conformance suite says which
/// ones a host actually honoured rather than assuming.
const testing = std.testing;

/// The type flags of each backend: `uring`'s sockets block and `epoll`'s do not.
const blocking: u32 = linux.SOCK.CLOEXEC;
const nonblocking: u32 = linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK;
const E = linux.E;

test "every socket errno maps to its named error, any other to Unexpected, on every host" {
    for ([_]struct { E, SocketError }{
        .{ .AFNOSUPPORT, error.AddressFamilyUnsupported }, .{ .MFILE, error.DescriptorLimit },
        .{ .NFILE, error.DescriptorLimit },                .{ .NOMEM, error.SystemResources },
        .{ .NOBUFS, error.SystemResources },               .{ .ACCES, error.Unexpected },
    }) |case| try testing.expectEqual(case[1], socket_error(case[0]));
    for ([_]struct { E, ListenError }{
        .{ .ADDRINUSE, error.AddressInUse }, .{ .ADDRNOTAVAIL, error.AddressNotAvailable },
        .{ .ACCES, error.AccessDenied },     .{ .BADF, error.Unexpected },
    }) |case| try testing.expectEqual(case[1], listen_error(case[0]));
    try testing.expectEqual(error.NotSocket, socket_call_error(.NOTSOCK));
    try testing.expectEqual(error.Unexpected, socket_call_error(.BADF));
}

fn expect_option(descriptor: Descriptor, level: i32, name: u32, expected: c_int) !void {
    var value: c_int = -1;
    var len: linux.socklen_t = @sizeOf(c_int);
    const rc = linux.getsockopt(descriptor, level, name, std.mem.asBytes(&value), &len);
    try testing.expectEqual(E.SUCCESS, linux.errno(rc));
    try testing.expectEqual(expected, value);
}

/// The descriptor's open flags, after checking that the descriptor closes on exec.
fn open_flags(descriptor: Descriptor) !linux.O {
    const descriptor_flags = linux.fcntl(descriptor, linux.F.GETFD, 0);
    try testing.expectEqual(E.SUCCESS, linux.errno(descriptor_flags));
    try testing.expect(descriptor_flags & linux.FD_CLOEXEC != 0);
    const rc = linux.fcntl(descriptor, linux.F.GETFL, 0);
    try testing.expectEqual(E.SUCCESS, linux.errno(rc));
    return @bitCast(@as(u32, @intCast(rc)));
}

/// The kernel hands out the lowest free descriptor, so two probes with no descriptor opened and
/// left open between them get one number.
fn probe_descriptor() !Descriptor {
    const probe = try open_socket(.ipv4, blocking);
    close_now(probe);
    return probe;
}

/// A connected client of the listener at `address`. The kernel completes the handshake from the
/// listener's backlog, so a blocking connect returns with no accept.
fn connect_to(address: *const Address) !Descriptor {
    const client = try open_socket(address.family, blocking);
    errdefer close_now(client);
    var storage: address_module.Storage = undefined;
    const len = address_module.to_kernel(address, &storage);
    try testing.expectEqual(E.SUCCESS, linux.errno(linux.connect(client, &storage, len)));
    return client;
}

/// A descriptor that is not a socket, which the refusals below need. procfs is always there under
/// Linux, so this file needs no path and no temporary file of its own.
fn not_a_socket() !Descriptor {
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const rc = linux.openat(linux.AT.FDCWD, "/proc/self/comm", flags, 0);
    try testing.expectEqual(E.SUCCESS, linux.errno(rc));
    return descriptor_of(rc);
}

const alone: ListenOptions = .{ .backlog = 1, .reuse_port = false };
const sharing: ListenOptions = .{ .backlog = 1, .reuse_port = true };

test "a listener on port 0 reports the port the kernel chose, and a client connects to it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var loopback6: [Address.ipv6_bytes]u8 = @splat(0);
    loopback6[Address.ipv6_bytes - 1] = 1;
    const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    for ([_]Address{ loopback, Address.ipv6(loopback6, 0, 0) }) |any_port| {
        const listener = listen(&any_port, alone, blocking) catch |err| {
            // A host with IPv6 switched off cannot run the second round.
            const no_stack = err == error.AddressFamilyUnsupported or
                err == error.AddressNotAvailable;
            return if (any_port.family == .ipv6 and no_stack) error.SkipZigTest else err;
        };
        defer close_now(listener);
        const bound = try local_address(listener);
        try testing.expectEqual(any_port.family, bound.family);
        try testing.expect(bound.port != 0);
        try testing.expectEqualSlices(u8, &any_port.bytes, &bound.bytes);
        try expect_option(listener, linux.SOL.SOCKET, linux.SO.ACCEPTCONN, 1);
        try expect_option(listener, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
        try expect_option(listener, linux.SOL.SOCKET, linux.SO.REUSEPORT, 0);
        const client = try connect_to(&bound);
        defer close_now(client);
        try testing.expect((try local_address(client)).port != bound.port);
    }
}

test "listeners share a port only when all ask, and a refused listen closes its socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const first = try listen(&loopback, sharing, blocking);
    defer close_now(first);
    const shared_address = try local_address(first);
    const second = try listen(&shared_address, sharing, blocking);
    defer close_now(second);
    try testing.expectEqual(shared_address.port, (try local_address(second)).port);
    const third = try listen(&loopback, alone, blocking);
    defer close_now(third);
    const third_address = try local_address(third);
    // A socket a refused listen left open would hold the number the first probe had.
    const probe_before = try probe_descriptor();
    try testing.expectError(error.AddressInUse, listen(&shared_address, alone, blocking));
    try testing.expectError(error.AddressInUse, listen(&third_address, alone, blocking));
    try testing.expectError(error.AddressInUse, listen(&third_address, sharing, blocking));
    // 192.0.2.1 is a documentation address (RFC 5737), which no interface carries.
    const nowhere = Address.ipv4(.{ 192, 0, 2, 1 }, 0);
    try testing.expectError(error.AddressNotAvailable, listen(&nowhere, alone, blocking));
    try testing.expectEqual(probe_before, try probe_descriptor());
}

test "a socket closes on exec, blocks unless asked, and takes TCP_NODELAY; others are refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // The one difference between the two Linux backends' sockets, and the one epoll depends on.
    const waiting = try open_socket(.ipv4, nonblocking);
    defer close_now(waiting);
    try testing.expect((try open_flags(waiting)).NONBLOCK);
    const socket = try open_socket(.ipv4, blocking);
    try testing.expect(!(try open_flags(socket)).NONBLOCK);
    try set_no_delay(socket, true);
    try expect_option(socket, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);
    try set_no_delay(socket, false);
    try expect_option(socket, linux.IPPROTO.TCP, linux.TCP.NODELAY, 0);
    close_now(socket);
    // The descriptor is free again: close_now closed it and did not only forget it.
    try testing.expectEqual(E.BADF, linux.errno(linux.fcntl(socket, linux.F.GETFD, 0)));
    const file = try not_a_socket();
    defer close_now(file);
    try testing.expectError(error.NotSocket, set_no_delay(file, true));
    try testing.expectError(error.NotSocket, local_address(file));
    const unix_socket = descriptor_of(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0));
    defer close_now(unix_socket);
    try testing.expectError(error.AddressFamilyUnsupported, local_address(unix_socket));
}

test "a datagram socket closes on exec and a bound one has taken a port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Linux takes SOCK_CLOEXEC in `socket(2)` itself, where macOS needs a separate `fcntl(2)`.
    // The two backends reach the same state by different calls, so both pin it.
    const any_port = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const bound = try open_datagram(.ipv4, &any_port, .{}, blocking);
    defer close_now(bound);
    _ = try open_flags(bound);
    try testing.expect((try local_address(bound)).port != 0);
    const unbound = try open_datagram(.ipv4, null, .{}, blocking);
    defer close_now(unbound);
    try testing.expect(!(try open_flags(unbound)).NONBLOCK);
    const waiting = try open_datagram(.ipv4, null, .{}, nonblocking);
    defer close_now(waiting);
    try testing.expect((try open_flags(waiting)).NONBLOCK);
    try testing.expectEqual(@as(u16, 0), (try local_address(unbound)).port);
}

test "a socket's buffer is set to what the kernel allows, and read back in the same call" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const socket = try open_socket(.ipv4, blocking);
    defer close_now(socket);

    // **What the call answers is what the kernel has**, which a raw read finds, and on this kernel
    // it is never the request: 512 KiB became 1 MiB on 2026-09-22, because Linux stores twice what
    // it is asked for. A call that handed the request back would fail here.
    const large = try set_buffer_bytes(socket, .receive, 512 << 10);
    try testing.expectEqual(large, try read_buffer_bytes(socket, .receive));
    try testing.expect(large > 512 << 10);

    // A larger request cannot answer smaller, and this kernel floors a small one: 1 byte became
    // 2,304 for a receive buffer and 4,608 for a send buffer that day.
    const small = try set_buffer_bytes(socket, .receive, 32 << 10);
    try testing.expect(small <= large);
    try testing.expect(try set_buffer_bytes(socket, .receive, 1) > 1);
    _ = try set_buffer_bytes(socket, .receive, 512 << 10);

    // The receive and the send buffer are two settings, read without going through the call under
    // test: one that named a single option would show both the same.
    const sending = try set_buffer_bytes(socket, .send, 64 << 10);
    try testing.expectEqual(sending, try read_buffer_bytes(socket, .send));
    try testing.expectEqual(large, try read_buffer_bytes(socket, .receive));
    try testing.expect(large != sending);

    // This kernel caps a size above its limit and does not refuse it, where macOS refuses.
    try testing.expect(try set_buffer_bytes(socket, .receive, socket_buffer_bytes_max) <
        socket_buffer_bytes_max);

    // A descriptor that is not open is refused. `probe_descriptor` closes what it opened, so the
    // kernel answers EBADF and not ENOTSOCK, which is `Unexpected`: a caller that reaches this has
    // a descriptor of its own it did not keep.
    const closed = try probe_descriptor();
    try testing.expectError(error.Unexpected, set_buffer_bytes(closed, .receive, 32 << 10));
}

/// Reads a socket buffer's size straight from the kernel, so a test can check what
/// `set_buffer_bytes` reports without calling it again.
fn read_buffer_bytes(descriptor: Descriptor, which: SocketBuffer) !u32 {
    const name: u32 = switch (which) {
        .receive => linux.SO.RCVBUF,
        .send => linux.SO.SNDBUF,
    };
    var value: c_int = -1;
    var len: linux.socklen_t = @sizeOf(c_int);
    const rc = linux.getsockopt(descriptor, linux.SOL.SOCKET, name, std.mem.asBytes(&value), &len);
    try testing.expectEqual(E.SUCCESS, linux.errno(rc));
    try testing.expect(value >= 0);
    return @intCast(value);
}
