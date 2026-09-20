//! The synchronous socket calls of decision 2: a socket opened, a listener bound, a socket's own
//! address read, TCP_NODELAY set, a descriptor closed. They run at start-up and once per
//! connection, never per transfer, so they are plain: one raw syscall at a time, every return
//! value checked, every errno mapped to a named error, with `Unexpected` for the rest.
//!
//! Each map is a function of the errno alone, so a test on any host covers the refusals the kernel
//! will not produce on demand (decision 10, point 3). Every other test runs under Linux alone.
//!
//! `close_now` and `descriptor_of` live here and `uring_sync_file.zig` imports them, because a
//! file needs both and a socket needed them first, as `kqueue_sync_file.zig` takes `close_now`
//! from its own socket file.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const uring_address = @import("uring_address.zig");

const Address = core.Address;
const Descriptor = core.Descriptor;

/// `socket(2)` refused. `AddressFamilyUnsupported`: the host carries no stack for the family, as
/// with IPv6 switched off. `DescriptorLimit` is EMFILE or ENFILE, and `SystemResources` is ENOMEM
/// or ENOBUFS, as in `core.Code`.
pub const SocketError = error{
    AddressFamilyUnsupported,
    DescriptorLimit,
    SystemResources,
    Unexpected,
};

/// `bind(2)` or `listen(2)` refused. `AddressInUse`: another socket listens on the address, and
/// one of the two did not ask for `reuse_port`. `AddressNotAvailable`: no interface of this host
/// has the address. `AccessDenied`: only a privileged process may bind the port.
pub const ListenError = SocketError || error{ AddressInUse, AddressNotAvailable, AccessDenied };

/// `getsockname(2)` refused, or the socket's family is one rotor does not carry.
pub const AddressError = error{ NotSocket, AddressFamilyUnsupported, Unexpected };

/// `setsockopt(2)` refused.
pub const OptionError = error{ NotSocket, Unexpected };

/// A TCP socket of `family`, closed on exec. It blocks: the ring does the waiting, so the socket
/// needs no SOCK_NONBLOCK.
pub fn open_socket(family: Address.Family) SocketError!Descriptor {
    const domain: u32 = switch (family) {
        .ipv4 => linux.AF.INET,
        .ipv6 => linux.AF.INET6,
    };
    const rc = linux.socket(domain, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) return socket_error(errno);
    return descriptor_of(rc);
}

pub const ListenOptions = struct {
    /// Connections the kernel queues for `accept`, at least 1, capped at `net.core.somaxconn`.
    backlog: u31,
    /// SO_REUSEPORT: several listeners bind one address, and the kernel picks one for each
    /// connection by a hash of the connection's addresses (decision 4, `listener_per_core`).
    reuse_port: bool,
};

/// socket, SO_REUSEADDR, SO_REUSEPORT when asked, bind, listen. SO_REUSEADDR lets a restarted
/// server bind its port while connections of the last run still sit in TIME_WAIT. Closes the
/// socket again on any failure after it was opened. An `address` with port 0 takes a port the
/// kernel chooses, which `local_address` reports.
pub fn listen(address: *const Address, options: ListenOptions) ListenError!Descriptor {
    assert(options.backlog >= 1);
    const socket = try open_socket(address.family);
    errdefer close_now(socket);
    // A socket this function just opened has both options, so a refusal here has no name.
    set_option(socket, linux.SOL.SOCKET, linux.SO.REUSEADDR, true) catch return error.Unexpected;
    if (options.reuse_port) {
        set_option(socket, linux.SOL.SOCKET, linux.SO.REUSEPORT, true) catch
            return error.Unexpected;
    }
    var storage: uring_address.Storage = undefined;
    const len = uring_address.to_kernel(address, &storage);
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
    var storage = std.mem.zeroes(uring_address.Storage);
    var len: linux.socklen_t = @sizeOf(uring_address.Storage);
    const errno = linux.errno(linux.getsockname(descriptor, @ptrCast(&storage), &len));
    if (errno != .SUCCESS) return socket_call_error(errno);
    assert(len >= @sizeOf(linux.sa_family_t));
    return uring_address.from_kernel(&storage, len) orelse error.AddressFamilyUnsupported;
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

fn set_option(descriptor: Descriptor, level: i32, name: u32, enabled: bool) OptionError!void {
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

const testing = std.testing;
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
    const probe = try open_socket(.ipv4);
    close_now(probe);
    return probe;
}

/// A connected client of the listener at `address`. The kernel completes the handshake from the
/// listener's backlog, so a blocking connect returns with no accept.
fn connect_to(address: *const Address) !Descriptor {
    const client = try open_socket(address.family);
    errdefer close_now(client);
    var storage: uring_address.Storage = undefined;
    const len = uring_address.to_kernel(address, &storage);
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
        const listener = listen(&any_port, alone) catch |err| {
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
    const first = try listen(&loopback, sharing);
    defer close_now(first);
    const shared_address = try local_address(first);
    const second = try listen(&shared_address, sharing);
    defer close_now(second);
    try testing.expectEqual(shared_address.port, (try local_address(second)).port);
    const third = try listen(&loopback, alone);
    defer close_now(third);
    const third_address = try local_address(third);
    // A socket a refused listen left open would hold the number the first probe had.
    const probe_before = try probe_descriptor();
    try testing.expectError(error.AddressInUse, listen(&shared_address, alone));
    try testing.expectError(error.AddressInUse, listen(&third_address, alone));
    try testing.expectError(error.AddressInUse, listen(&third_address, sharing));
    // 192.0.2.1 is a documentation address (RFC 5737), which no interface carries.
    const nowhere = Address.ipv4(.{ 192, 0, 2, 1 }, 0);
    try testing.expectError(error.AddressNotAvailable, listen(&nowhere, alone));
    try testing.expectEqual(probe_before, try probe_descriptor());
}

test "a socket closes on exec and takes TCP_NODELAY; a file and a unix socket are refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const socket = try open_socket(.ipv4);
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
