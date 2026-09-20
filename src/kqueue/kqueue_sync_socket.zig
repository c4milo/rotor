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
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const core = @import("core");
const kqueue_address = @import("kqueue_address.zig");

const Address = core.Address;
const Descriptor = core.Descriptor;
const E = posix.E;

/// `socket(2)` refused. `AddressFamilyUnsupported`: the host carries no stack for the family.
/// `DescriptorLimit` is EMFILE or ENFILE, and `SystemResources` is ENOMEM or ENOBUFS, as in
/// `core.Code`.
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

/// `setsockopt(2)` refused, or `fcntl(2)` did, which is `Unexpected`.
pub const OptionError = error{ NotSocket, Unexpected };

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

pub const ListenOptions = struct {
    /// Connections the kernel queues for `accept`, at least 1, capped at `kern.ipc.somaxconn`.
    backlog: u31,
    /// SO_REUSEPORT: several listeners bind one address (decision 4, `listener_per_core`).
    /// Decision 4 recalls that macOS does not spread connections across them.
    reuse_port: bool,
};

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
fn set_flags(descriptor: Descriptor, command: c_int, flags: c_int) OptionError!void {
    assert(descriptor >= 0);
    assert(command == c.F.SETFL or command == c.F.SETFD);
    const rc = c.fcntl(descriptor, command, flags);
    if (posix.errno(rc) != .SUCCESS) return error.Unexpected;
}

fn socket_error(errno: E) SocketError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .MFILE, .NFILE => error.DescriptorLimit,
        .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

/// The errno of a `bind(2)` or of a `listen(2)`.
fn listen_error(errno: E) ListenError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// The errno of a call that takes a socket: `getsockname(2)` or `setsockopt(2)`.
fn socket_call_error(errno: E) error{ NotSocket, Unexpected } {
    assert(errno != .SUCCESS);
    return if (errno == .NOTSOCK) error.NotSocket else error.Unexpected;
}

/// Options a datagram socket is opened with (decision 15). The same shape `uring_sync_socket`
/// offers, because the conformance suite calls `backend.sync` on whichever backend it was given.
pub const DatagramOptions = struct {
    control: bool = true,
    dont_fragment: bool = true,
};

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

/// The options of a datagram socket. macOS carries every one a QUIC stack needs; the IPv6 names
/// sit behind `__APPLE_USE_RFC_3542` in the SDK, which gates the header and not the kernel, so
/// they are named by their numbers in `kqueue_datagram.zig`. A refusal costs the caller that
/// answer and nothing else.
const testing = std.testing;

test "every errno of a socket call maps to its named error, any other to Unexpected" {
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

/// The longest a test waits for a socket to become ready, in milliseconds.
const wait_ms_max = 2000;

/// Sends `send_until_refused` makes before it gives up, and the wait between two of them, in
/// milliseconds: the peer's reset arrives some time after the send that provoked it returned.
const send_tries_max = 200;
const send_retry_ms = 1;

/// SIGPIPE signals this process took while `count_sigpipes` was installed.
var sigpipes = std.atomic.Value(u32).init(0);

fn count_sigpipe(_: c.SIG) callconv(.c) void {
    _ = sigpipes.fetchAdd(1, .monotonic);
}

/// Installs `count_sigpipe` and returns what it replaced, which the caller installs again.
fn count_sigpipes() !c.Sigaction {
    sigpipes.store(0, .monotonic);
    const counting: c.Sigaction = .{
        .handler = .{ .handler = count_sigpipe },
        .mask = std.mem.zeroes(c.sigset_t),
        .flags = 0,
    };
    var replaced: c.Sigaction = undefined;
    try testing.expectEqual(E.SUCCESS, posix.errno(c.sigaction(.PIPE, &counting, &replaced)));
    return replaced;
}

fn restore_sigpipe(replaced: *const c.Sigaction) void {
    assert(posix.errno(c.sigaction(.PIPE, replaced, null)) == .SUCCESS);
}

/// macOS answers a set boolean option with the option's own bit, not with 1.
fn expect_option(descriptor: Descriptor, level: i32, name: u32, enabled: bool) !void {
    var value: c_int = -1;
    var len: c.socklen_t = @sizeOf(c_int);
    const rc = c.getsockopt(descriptor, level, name, &value, &len);
    try testing.expectEqual(E.SUCCESS, posix.errno(rc));
    try testing.expectEqual(enabled, value != 0);
}

/// O_NONBLOCK, FD_CLOEXEC and SO_NOSIGPIPE: all three set, or none of them.
fn expect_settings(socket: Descriptor, set: bool) !void {
    const status_flags = c.fcntl(socket, c.F.GETFL, @as(c_int, 0));
    try testing.expectEqual(E.SUCCESS, posix.errno(status_flags));
    try testing.expectEqual(set, @as(c.O, @bitCast(status_flags)).NONBLOCK);
    const descriptor_flags = c.fcntl(socket, c.F.GETFD, @as(c_int, 0));
    try testing.expectEqual(E.SUCCESS, posix.errno(descriptor_flags));
    try testing.expectEqual(set, descriptor_flags & c.FD_CLOEXEC != 0);
    try expect_option(socket, c.SOL.SOCKET, c.SO.NOSIGPIPE, set);
}

/// The kernel hands out the lowest free descriptor, so two probes with no descriptor opened and
/// left open between them get one number.
fn probe_descriptor() !Descriptor {
    const probe = try open_socket(.ipv4);
    close_now(probe);
    return probe;
}

fn wait_until_ready(descriptor: Descriptor, events: i16) !void {
    var polled = [_]c.pollfd{.{ .fd = descriptor, .events = events, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 1), c.poll(&polled, polled.len, wait_ms_max));
}

/// A connected client of the listener at `address`. The client does not block, so connect(2)
/// answers EINPROGRESS and the socket turns writable when the handshake ends. A port nobody
/// listens on ends it with ECONNREFUSED in SO_ERROR, so this also shows that `listen` listens.
fn connect_to(address: *const Address) !Descriptor {
    const client = try open_socket(address.family);
    errdefer close_now(client);
    var storage: kqueue_address.Storage = undefined;
    const len = kqueue_address.to_kernel(address, &storage);
    const errno = posix.errno(c.connect(client, @ptrCast(&storage), len));
    try testing.expect(errno == .SUCCESS or errno == .INPROGRESS);
    try wait_until_ready(client, c.POLL.OUT);
    try expect_option(client, c.SOL.SOCKET, c.SO.ERROR, false);
    return client;
}

/// The server end of the one connection `listener` holds or is about to hold.
fn accept_from(listener: Descriptor) !Descriptor {
    try wait_until_ready(listener, c.POLL.IN);
    const accepted = c.accept(listener, null, null);
    try testing.expectEqual(E.SUCCESS, posix.errno(accepted));
    return accepted;
}

/// An IPv4 listener made with none of this file's calls: it blocks and has no SO_NOSIGPIPE. A
/// socket accepted from a listener inherits both, so one accepted from this listener starts
/// with none of the three settings.
fn plain_listener(address: *const Address) !Descriptor {
    assert(address.family == .ipv4);
    const listener = c.socket(c.AF.INET, c.SOCK.STREAM, c.IPPROTO.TCP);
    try testing.expectEqual(E.SUCCESS, posix.errno(listener));
    errdefer close_now(listener);
    var storage: kqueue_address.Storage = undefined;
    const len = kqueue_address.to_kernel(address, &storage);
    try testing.expectEqual(E.SUCCESS, posix.errno(c.bind(listener, @ptrCast(&storage), len)));
    try testing.expectEqual(E.SUCCESS, posix.errno(c.listen(listener, 1)));
    return listener;
}

/// A socket accepted from `listener` whose client connected and closed again.
fn accept_orphan(listener: Descriptor) !Descriptor {
    const client = try connect_to(&try local_address(listener));
    defer close_now(client);
    return accept_from(listener);
}

/// Sends one byte at a time until the kernel refuses one, and returns that errno. The peer is
/// closed: it answers the first byte with a reset, and every send after the reset is refused.
fn send_until_refused(socket: Descriptor) !E {
    var nothing: [1]c.pollfd = undefined;
    for (0..send_tries_max) |_| {
        const rc = c.send(socket, "x", 1, 0);
        if (rc == -1) return posix.errno(rc);
        try testing.expectEqual(@as(c_int, 0), c.poll(&nothing, 0, send_retry_ms));
    }
    return error.SendNeverRefused;
}

const alone: ListenOptions = .{ .backlog = 1, .reuse_port = false };
const sharing: ListenOptions = .{ .backlog = 1, .reuse_port = true };

test "a listener on port 0 reports the port the kernel chose, and a client connects to it" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
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
        // The loop accepts from the listener itself, so an accept with no connection must not
        // block: it answers EAGAIN.
        try expect_settings(listener, true);
        try testing.expectEqual(E.AGAIN, posix.errno(c.accept(listener, null, null)));
        try expect_option(listener, c.SOL.SOCKET, c.SO.REUSEADDR, true);
        try expect_option(listener, c.SOL.SOCKET, c.SO.REUSEPORT, false);
        const client = try connect_to(&bound);
        defer close_now(client);
        try testing.expect((try local_address(client)).port != bound.port);
    }
}

test "listeners share a port only when all ask, and a refused listen closes its socket" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const first = try listen(&loopback, sharing);
    defer close_now(first);
    try expect_option(first, c.SOL.SOCKET, c.SO.REUSEPORT, true);
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

test "a socket has its three settings and takes TCP_NODELAY; a file and a unix socket are refused" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const socket = try open_socket(.ipv4);
    try expect_settings(socket, true);
    try set_no_delay(socket, true);
    try expect_option(socket, c.IPPROTO.TCP, c.TCP.NODELAY, true);
    try set_no_delay(socket, false);
    try expect_option(socket, c.IPPROTO.TCP, c.TCP.NODELAY, false);
    close_now(socket);
    // The descriptor is free again: close_now closed it and did not only forget it.
    try testing.expectEqual(E.BADF, posix.errno(c.fcntl(socket, c.F.GETFD, @as(c_int, 0))));
    // fcntl refuses a closed descriptor, and `set_flags` reads the refusal.
    try testing.expectError(error.Unexpected, set_flags(socket, c.F.SETFD, c.FD_CLOEXEC));
    const file = c.open("/dev/null", .{ .ACCMODE = .RDWR });
    try testing.expectEqual(E.SUCCESS, posix.errno(file));
    defer close_now(file);
    try testing.expectError(error.NotSocket, set_no_delay(file, true));
    try testing.expectError(error.NotSocket, local_address(file));
    const unix_socket = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    try testing.expectEqual(E.SUCCESS, posix.errno(unix_socket));
    defer close_now(unix_socket);
    try testing.expectError(error.AddressFamilyUnsupported, local_address(unix_socket));
}

test "prepare_accepted gives an accepted socket its three settings, and leaves a file as it was" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const listener = try plain_listener(&Address.ipv4(.{ 127, 0, 0, 1 }, 0));
    defer close_now(listener);
    const client = try connect_to(&try local_address(listener));
    defer close_now(client);
    const accepted = try accept_from(listener);
    defer close_now(accepted);
    try expect_settings(accepted, false);
    try prepare_accepted(accepted);
    try expect_settings(accepted, true);
    // The refusal comes before any flag changes: the file still blocks.
    const file = c.open("/dev/null", .{ .ACCMODE = .RDWR });
    try testing.expectEqual(E.SUCCESS, posix.errno(file));
    defer close_now(file);
    try testing.expectError(error.NotSocket, prepare_accepted(file));
    const status_flags = c.fcntl(file, c.F.GETFL, @as(c_int, 0));
    try testing.expect(!@as(c.O, @bitCast(status_flags)).NONBLOCK);
}

test "a send to a closed peer answers EPIPE and raises no SIGPIPE, from either end" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    // Without SO_NOSIGPIPE the kernel raises SIGPIPE beside the EPIPE, which kills a process
    // that does not handle it. The handler counts, so a lost setting fails an expectation here
    // and does not kill the test runner.
    const replaced = try count_sigpipes();
    defer restore_sigpipe(&replaced);
    const listener = try plain_listener(&Address.ipv4(.{ 127, 0, 0, 1 }, 0));
    defer close_now(listener);
    // The end `open_socket` made sends to an accepted socket that is closed.
    const client = try connect_to(&try local_address(listener));
    defer close_now(client);
    close_now(try accept_from(listener));
    try testing.expectEqual(E.PIPE, try send_until_refused(client));
    // The end `prepare_accepted` prepared sends to a client that is closed.
    const accepted = try accept_orphan(listener);
    defer close_now(accepted);
    try prepare_accepted(accepted);
    try testing.expectEqual(E.PIPE, try send_until_refused(accepted));
    try testing.expectEqual(@as(u32, 0), sigpipes.load(.monotonic));
}
