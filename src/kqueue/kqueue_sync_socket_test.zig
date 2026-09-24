//! The tests of `kqueue_sync_socket.zig`, in a file of their own so that one stays at or under 500
//! lines (CLAUDE.md, Conventions). Every name below is that file's, aliased here so a test reads as
//! it did when it lived beside the code, and `kqueue.zig` names this file so they run.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const core = @import("core");
const posix = std.posix;
const c = std.c;
const socket_calls = @import("kqueue_sync_socket.zig");
const kqueue_address = @import("kqueue_address.zig");

const Address = core.Address;
const Descriptor = core.Descriptor;
const E = posix.E;
const SocketError = socket_calls.SocketError;
const ListenError = socket_calls.ListenError;
const open_socket = socket_calls.open_socket;
const prepare_accepted = socket_calls.prepare_accepted;
const ListenOptions = socket_calls.ListenOptions;
const listen = socket_calls.listen;
const local_address = socket_calls.local_address;
const set_no_delay = socket_calls.set_no_delay;
const close_now = socket_calls.close_now;
const set_flags = socket_calls.set_flags;
const socket_error = socket_calls.socket_error;
const listen_error = socket_calls.listen_error;
const socket_call_error = socket_calls.socket_call_error;
const open_datagram = socket_calls.open_datagram;
const set_buffer_bytes = socket_calls.set_buffer_bytes;
const socket_buffer_bytes_max = socket_calls.socket_buffer_bytes_max;

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
var sigpipes: std.atomic.Value(u32) align(@alignOf(std.atomic.Value(u32))) = .init(0);

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

test "a datagram socket closes on exec, does not block, and raises no SIGPIPE" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    // macOS has no SOCK_CLOEXEC and no SOCK_NONBLOCK, so a separate `fcntl(2)` sets both.
    const any_port = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const bound = try open_datagram(.ipv4, &any_port, .{});
    defer close_now(bound);
    try expect_settings(bound, true);
    const unbound = try open_datagram(.ipv4, null, .{});
    defer close_now(unbound);
    try expect_settings(unbound, true);
    try testing.expect((try local_address(bound)).port != 0);
    try testing.expectEqual(@as(u16, 0), (try local_address(unbound)).port);
}

test "a socket's buffer is set to what the kernel allows, and read back in the same call" {
    // Every number below is what this kernel answered, so the test names macOS and no other.
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const socket = try open_socket(.ipv4);
    defer close_now(socket);

    // **What the call answers is what the kernel has**, which a raw read finds. That is the whole
    // promise, and a call that handed the request back instead would pass here on this kernel and
    // fail on Linux, where 512 KiB becomes 1 MiB (`uring_sync_socket.zig` checks the same thing).
    const large = try set_buffer_bytes(socket, .receive, 512 << 10);
    try testing.expectEqual(large, try read_buffer_bytes(socket, .receive));

    // A larger request cannot answer smaller.
    const small = try set_buffer_bytes(socket, .receive, 32 << 10);
    try testing.expect(small <= large);
    _ = try set_buffer_bytes(socket, .receive, 512 << 10);

    // The receive and the send buffer are two settings, read without going through the call under
    // test: one that named a single option would show both the same.
    const sending = try set_buffer_bytes(socket, .send, 64 << 10);
    try testing.expectEqual(sending, try read_buffer_bytes(socket, .send));
    try testing.expectEqual(large, try read_buffer_bytes(socket, .receive));
    try testing.expect(large != sending);

    // This kernel grants what it is asked for, one byte included, where Linux floors it at 2,304
    // (2026-09-22).
    try testing.expectEqual(@as(u32, 1), try set_buffer_bytes(socket, .receive, 1));

    // Above its own limit it caps once and refuses after that, which the two calls below show:
    // the first brings the socket to the limit, and the second asks to go past it from there.
    // Measured on 2026-09-22, where the limit was 8 MiB. This is what `SizeRefused` is for, and a
    // caller that asks for more than a kernel will give must handle it.
    const capped = try set_buffer_bytes(socket, .receive, socket_buffer_bytes_max);
    try testing.expect(capped < socket_buffer_bytes_max);
    try testing.expectError(
        error.SizeRefused,
        set_buffer_bytes(socket, .receive, socket_buffer_bytes_max),
    );

    // A descriptor that is not open is refused. `probe_descriptor` closes what it opened, so the
    // kernel answers EBADF and not ENOTSOCK, which is `Unexpected`: a caller that reaches this has
    // a descriptor of its own it did not keep.
    const closed = try probe_descriptor();
    try testing.expectError(error.Unexpected, set_buffer_bytes(closed, .receive, 32 << 10));
}

/// Reads a socket buffer's size straight from the kernel, so a test can check what
/// `set_buffer_bytes` reports without calling it again.
fn read_buffer_bytes(descriptor: Descriptor, which: socket_calls.SocketBuffer) !u32 {
    const name: u32 = switch (which) {
        .receive => c.SO.RCVBUF,
        .send => c.SO.SNDBUF,
    };
    var value: c_int = -1;
    var len: c.socklen_t = @sizeOf(c_int);
    const rc = c.getsockopt(descriptor, c.SOL.SOCKET, name, &value, &len);
    try testing.expectEqual(E.SUCCESS, posix.errno(rc));
    try testing.expect(value >= 0);
    return @intCast(value);
}
