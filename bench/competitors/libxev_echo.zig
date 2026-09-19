//! libxev_echo: a TCP echo server on 127.0.0.1, the libxev side of rotor's echo comparison.
//!
//! Run:  libxev_echo PORT        Stop it with SIGTERM or SIGINT.
//!
//! It is written the way that is fastest for libxev, so that no result of the harness comes from
//! this file. A connection is one allocation, made at accept: its completion and its buffer.
//! Nothing is allocated per read or per write. A connection has one operation in flight at a
//! time: a read, then the write that echoes it, then the next read. So one completion serves all
//! three, which on io_uring is one submission entry per operation and nothing else.
//!
//! libxev gives a read its buffer when the read is submitted, so every connection owns a buffer
//! for as long as it is open. That is what rotor's source 2, provided buffers, removes
//! (docs/decisions/0003-speed-sources.md).
//!
//! Built by `zig build bench-competitors` against the libxev pinned in build.zig.zon.
const std = @import("std");
const xev = @import("xev");

/// The bytes one read may return: the same size bench/competitors/libuv_echo.c reads with.
const read_bytes_max = 64 * 1024;
/// The backlog passed to listen(2): the same as bench/competitors/libuv_echo.c.
const listen_backlog = 1024;
/// The submission queue entries libxev's io_uring backend is asked for; kqueue ignores it.
const loop_entries = 4096;

const Server = struct {
    gpa: std.mem.Allocator,
    socket: xev.TCP,
    accept_completion: xev.Completion = .{},
};

const Connection = struct {
    server: *Server,
    socket: xev.TCP,
    /// The one operation in flight: a read, the write that echoes it, or the close.
    completion: xev.Completion = .{},
    buffer: [read_bytes_max]u8 = undefined,
};

pub fn main(init: std.process.Init) !void {
    var arguments = init.minimal.args.iterate();
    _ = arguments.skip();
    const port = parse_port(arguments.next()) orelse {
        std.debug.print("usage: libxev_echo PORT\n", .{});
        std.process.exit(1);
    };

    var loop = try xev.Loop.init(.{ .entries = loop_entries });
    defer loop.deinit();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server: Server = .{ .gpa = init.gpa, .socket = try xev.TCP.init(address) };
    try server.socket.bind(address);
    try server.socket.listen(listen_backlog);
    server.socket.accept(&loop, &server.accept_completion, Server, &server, on_accept);

    // The harness waits for this line before it connects.
    var stdout_buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.print(
        "libxev_echo: libxev {s} listening on 127.0.0.1:{d}\n",
        .{ @tagName(xev.backend), port },
    );
    try stdout.interface.flush();

    try loop.run(.until_done);
}

/// The port named by `text`, or null when it is missing, not a number, or zero.
fn parse_port(text: ?[]const u8) ?u16 {
    const port = std.fmt.parseInt(u16, text orelse return null, 10) catch return null;
    return if (port == 0) null else port;
}

fn on_accept(
    server_pointer: ?*Server,
    loop: *xev.Loop,
    _: *xev.Completion,
    result: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const server = server_pointer.?;
    const socket = result catch |err| std.debug.panic("libxev_echo: accept: {t}", .{err});
    const connection = server.gpa.create(Connection) catch |err| {
        std.debug.panic("libxev_echo: allocate a connection: {t}", .{err});
    };
    connection.* = .{ .server = server, .socket = socket };
    // TCP_NODELAY, as every candidate of the comparison sets it: an echo must not wait for Nagle.
    const enabled: c_int = 1;
    std.posix.setsockopt(
        socket.fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&enabled),
    ) catch return close(connection, loop);
    read(connection, loop);
    return .rearm;
}

fn read(connection: *Connection, loop: *xev.Loop) void {
    const buffer: xev.ReadBuffer = .{ .slice = &connection.buffer };
    connection.socket.read(loop, &connection.completion, buffer, Connection, connection, on_read);
}

fn on_read(
    connection_pointer: ?*Connection,
    loop: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    buffer: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    const connection = connection_pointer.?;
    // error.EOF, or a failed read: either way the connection is over.
    const read_bytes = result catch return close_and_disarm(connection, loop);
    write(connection, loop, buffer.slice[0..read_bytes]);
    return .disarm;
}

fn write(connection: *Connection, loop: *xev.Loop, bytes: []const u8) void {
    const buffer: xev.WriteBuffer = .{ .slice = bytes };
    connection.socket.write(loop, &connection.completion, buffer, Connection, connection, on_write);
}

fn on_write(
    connection_pointer: ?*Connection,
    loop: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    buffer: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    const connection = connection_pointer.?;
    const written_bytes = result catch return close_and_disarm(connection, loop);
    const rest = buffer.slice[written_bytes..];
    // A short write leaves a rest to send before the next read may reuse the buffer.
    if (rest.len > 0) write(connection, loop, rest) else read(connection, loop);
    return .disarm;
}

/// Closes from `on_accept`, which rearms its own completion whatever happens to the connection.
fn close(connection: *Connection, loop: *xev.Loop) xev.CallbackAction {
    connection.socket.close(loop, &connection.completion, Connection, connection, on_close);
    return .rearm;
}

/// Closes from a callback of the connection's own completion, which the close now reuses.
fn close_and_disarm(connection: *Connection, loop: *xev.Loop) xev.CallbackAction {
    connection.socket.close(loop, &connection.completion, Connection, connection, on_close);
    return .disarm;
}

fn on_close(
    connection_pointer: ?*Connection,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.CloseError!void,
) xev.CallbackAction {
    const connection = connection_pointer.?;
    connection.server.gpa.destroy(connection);
    return .disarm;
}
