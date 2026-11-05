//! The network calls (decision 22, "Which calls run on rotor"): each blocking call submits one
//! operation of the loop and blocks the calling context until its final event.
//!
//! `netRead` receives into the first buffer that has room, and `netWrite` sends the first bytes it
//! has: the header, then each buffer, then the repeated last buffer once. Each may so return fewer
//! bytes than it was given, which `std.Io.Reader` and `std.Io.Writer` allow. rotor has no vectored
//! receive or send, and decision 22's open question 4 waits for the harness before it adds one.
//!
//! Listening and binding open their sockets with `sync`, as a caller of the loop does. An accepted
//! socket's peer address costs one `getpeername` call, because the loop's accept reports the new
//! descriptor alone.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = std.Io.net;
const rotor = @import("../rotor.zig");
const adapter_module = @import("adapter.zig");
const scheduler = @import("adapter_scheduler.zig");
const tasks = @import("adapter_tasks.zig");
const wait = @import("adapter_wait.zig");
const errors = @import("adapter_net_errors.zig");
const datagram = @import("adapter_datagram.zig");
const Adapter = adapter_module.Adapter;

const perform = scheduler.perform;

pub fn to_rotor(address: *const net.IpAddress) rotor.Address {
    return switch (address.*) {
        .ip4 => |ip4| rotor.Address.ipv4(ip4.bytes, ip4.port),
        .ip6 => |ip6| rotor.Address.ipv6(ip6.bytes, ip6.port, ip6.interface.index),
    };
}

pub fn from_rotor(address: rotor.Address) net.IpAddress {
    return switch (address.family) {
        .ipv4 => .{ .ip4 = .{
            .bytes = address.bytes[0..rotor.Address.ipv4_bytes].*,
            .port = address.port,
        } },
        .ipv6 => .{ .ip6 = .{
            .bytes = address.bytes,
            .port = address.port,
            .interface = .{ .index = address.scope_id },
        } },
    };
}

/// The socket `sync` opened, with the address the kernel bound it to.
fn bound_socket(handle: rotor.Descriptor) error{Unexpected}!net.Socket {
    const local = rotor.sync.local_address(handle) catch {
        rotor.sync.close_now(handle);
        return error.Unexpected;
    };
    return .{ .handle = handle, .address = from_rotor(local) };
}

pub fn net_listen_ip(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ListenOptions,
) net.IpAddress.ListenError!net.Socket {
    _ = adapter_module.from(userdata);
    if (options.mode != .stream) return error.SocketModeUnsupported;
    if (options.protocol != .tcp) return error.ProtocolUnsupportedByAddressFamily;
    const local = to_rotor(address);
    const handle = rotor.sync.listen(&local, .{
        .backlog = @max(options.kernel_backlog, 1),
        .reuse_port = options.reuse_address,
    }) catch |failure| return errors.listen(failure);
    return bound_socket(handle);
}

pub fn net_bind_ip(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.BindOptions,
) net.IpAddress.BindError!net.Socket {
    _ = adapter_module.from(userdata);
    if (options.mode != .dgram) return error.SocketModeUnsupported;
    if (options.protocol != null and options.protocol != .udp) return error.ProtocolUnsupportedByAddressFamily;
    if (options.ip6_only or options.allow_broadcast) return error.OptionUnsupported;
    const local = to_rotor(address);
    const handle = rotor.sync.open_datagram(local.family, &local, .{}) catch |failure|
        return errors.bind(failure);
    return bound_socket(handle);
}

pub fn net_connect_ip(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ConnectOptions,
) net.IpAddress.ConnectError!net.Socket {
    const adapter = adapter_module.from(userdata);
    if (options.mode != .stream) return error.SocketModeUnsupported;
    if (options.protocol != null and options.protocol != .tcp) return error.ProtocolUnsupportedByAddressFamily;
    try tasks.cancel_point(scheduler.current(adapter));
    const remote = to_rotor(address);
    const deadline_ns = @min(wait.timeout_ns(adapter, options.timeout) orelse 0, rotor.constants.timeout_ns_max);
    if (options.timeout != .none and deadline_ns == 0) return error.Timeout;
    const handle = rotor.sync.open_socket(remote.family) catch |failure| return errors.socket(failure);
    errdefer rotor.sync.close_now(handle);
    const result = try perform(adapter, .{ .connect = .{ .socket = handle, .address = &remote } }, deadline_ns);
    if (result < 0) return errors.connect(code_of(result));
    return .{ .handle = handle, .address = address.* };
}

pub fn net_accept(
    userdata: ?*anyopaque,
    server: net.Socket.Handle,
    options: net.Server.AcceptOptions,
) net.Server.AcceptError!net.Socket {
    const adapter = adapter_module.from(userdata);
    _ = options;
    const result = try perform(adapter, .{ .accept = .{ .listener = server } }, 0);
    if (result < 0) return errors.accept(code_of(result));
    const handle: rotor.Descriptor = result;
    var storage: Io.Threaded.PosixAddress = undefined;
    var len: std.posix.socklen_t = @sizeOf(Io.Threaded.PosixAddress);
    std.posix.getpeername(handle, &storage.any, &len) catch {
        // The peer left between the accept and this call.
        rotor.sync.close_now(handle);
        return error.ConnectionAborted;
    };
    return .{ .handle = handle, .address = Io.Threaded.addressFromPosix(&storage) };
}

pub fn net_read(userdata: ?*anyopaque, source: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    const adapter = adapter_module.from(userdata);
    const buffer = for (data) |buffer| {
        if (buffer.len != 0) break buffer;
    } else return 0;
    const result = try perform(adapter, .{ .receive = .{
        .socket = source,
        .target = .{ .buffer = .{ .bytes = buffer } },
    } }, 0);
    if (result < 0) return errors.read(code_of(result));
    return @intCast(result);
}

/// The first bytes `netWrite` has to send: the header, each buffer but the last, then the last
/// once when `splat` repeats it at least once.
pub fn first_bytes(header: []const u8, data: []const []const u8, splat: usize) []const u8 {
    if (header.len != 0) return header;
    assert(data.len >= 1);
    for (data[0 .. data.len - 1]) |buffer| {
        if (buffer.len != 0) return buffer;
    }
    return if (splat == 0) &.{} else data[data.len - 1];
}

pub fn net_write(
    userdata: ?*anyopaque,
    destination: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    const adapter = adapter_module.from(userdata);
    const bytes = first_bytes(header, data, splat);
    if (bytes.len == 0) return 0;
    const result = try perform(adapter, .{ .send = .{
        .socket = destination,
        .buffer = .{ .bytes = bytes },
    } }, 0);
    if (result < 0) return errors.write(code_of(result));
    return @intCast(result);
}

/// One datagram per message. Returns the error that stopped it, if one did, and how many messages
/// were sent.
pub fn net_send(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    messages: []net.OutgoingMessage,
    flags: net.SendFlags,
) struct { ?net.Socket.SendError, usize } {
    const adapter = adapter_module.from(userdata);
    _ = flags;
    for (messages, 0..) |*message, sent| {
        const outbound: rotor.datagram.Outbound = .{
            .peer = to_rotor(message.address),
            .local = std.mem.zeroes(rotor.Address),
            .segment_bytes = 0,
            .ecn = .not_ect,
            .flags = .{ .peer = true },
        };
        const result = perform(adapter, .{ .send_to = .{
            .socket = handle,
            .buffer = .{ .bytes = message.data_ptr[0..message.data_len] },
            .to = &outbound,
        } }, 0) catch |failure| return .{ failure, sent };
        if (result < 0) return .{ errors.send(code_of(result)), sent };
        message.data_len = @intCast(result);
    }
    return .{ null, messages.len };
}

/// Closes each socket on the loop. A close is no cancel point: its error set has no `Canceled`.
/// A socket's standing datagram receive ends first, and its entry is freed after the close.
pub fn net_close(userdata: ?*anyopaque, handles: []const net.Socket.Handle) void {
    const adapter = adapter_module.from(userdata);
    for (handles) |handle| {
        datagram.stop(adapter, handle);
        scheduler.submit(adapter, .{ .close = .{ .descriptor = handle } });
        scheduler.block(adapter, .operation, false);
        datagram.release(adapter, handle);
    }
}

pub fn net_shutdown(userdata: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    const adapter = adapter_module.from(userdata);
    const result = try perform(adapter, .{ .shutdown = .{
        .socket = handle,
        .how = switch (how) {
            .recv => .receive,
            .send => .send,
            .both => .both,
        },
    } }, 0);
    if (result < 0) return errors.shutdown(code_of(result));
}

fn code_of(result: i32) rotor.Code {
    assert(result < 0);
    return @enumFromInt(@as(u8, @intCast(-result)));
}
