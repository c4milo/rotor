//! echo_check: starts an echo server and checks that it echoes, the way a person would who
//! followed the README. `zig build test` runs it against `examples/echo.zig` on the host, and the
//! Linux gate runs it on io_uring and on epoll.
//!
//! Run:  echo_check SERVER
//!
//! It starts SERVER with a free port as its one argument, then checks, in order:
//!
//!   1. one line comes back as it was sent, as `nc` would send it;
//!   2. 32 clients at once, 64 KiB each, each get their own bytes back;
//!   3. 4 clients at once, 4 MiB each: far past the server's 4 KiB buffer and the sockets' own
//!      buffers;
//!   4. the same with clients that start reading late, so the socket buffers fill, the server's
//!      sends come up short, and it must send the rest before it reads again;
//!   5. 20 clients that send 8 KiB and hang up without reading do not stop the server;
//!   6. a client that shuts down its sending side gets its bytes back and then the end of the
//!      stream, so the server closes a connection whose peer is done;
//!   7. a new client is still served after all of that.
//!
//! Last, it stops the server with SIGTERM and requires that SIGTERM is what ended it: a server
//! that crashed during the checks ends some other way.
//!
//! It is written on `std.Io` and not on rotor, so a fault in rotor cannot hide in the checker. A
//! watchdog thread ends the check, and the server, when the checks outlast `checks_timeout_seconds`,
//! so a server that stops answering fails the check instead of hanging it. A socket timeout cannot
//! do this: `std.Io` waits again when a timed-out read returns `EAGAIN`.
const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const posix = std.posix;

/// Clients that echo at once. A late client reads nothing for `late_read_ms`, so the socket buffers
/// fill and the server's sends to it come up short. It does not also shrink its receive buffer: on
/// Linux a 4 KiB window paced 4 MiB so slowly that a plain blocking echo server on `std.Io`, with no
/// rotor in it, outlasted the watchdog too (2026-09-26).
const Check = struct { clients: u32, payload_bytes: usize, late: bool = false, name: []const u8 };

const checks = [_]Check{
    .{ .clients = 32, .payload_bytes = 64 * 1024, .name = "32 clients x 64 KiB" },
    .{ .clients = 4, .payload_bytes = 4 * 1024 * 1024, .name = "4 clients x 4 MiB" },
    .{
        .clients = 4,
        .payload_bytes = 4 * 1024 * 1024,
        .late = true,
        .name = "4 clients x 4 MiB reading late",
    },
};

const late_read_ms = 200;

/// The clients of the largest check.
const clients_max = 32;
/// Clients that send and hang up without reading.
const hang_ups = 20;
const hang_up_bytes = 8 * 1024;
/// How long all the checks may take together. They take about a second on a Mac.
const checks_timeout_seconds = 60;
/// How long the check waits for the server to listen, in tries of `connect_retry_ms`.
const connect_tries = 250;
const connect_retry_ms = 20;
/// The bytes one write or read hands the kernel at most.
const chunk_bytes = 64 * 1024;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) return error.Usage;
    const io = init.io;
    const port = try free_port(io);
    var port_text: [8]u8 = undefined;
    const argv = [_][]const u8{ arguments[1], try std.fmt.bufPrint(&port_text, "{d}", .{port}) };
    var child = try std.process.spawn(io, .{ .argv = &argv, .stdout = .ignore });
    var reaped = false;
    defer if (!reaped) child.kill(io);
    const watchdog = try std.Thread.spawn(.{}, stop_after_timeout, .{ io, child.id.? });
    watchdog.detach();

    try run_checks(io, init.arena.allocator(), port);

    if (child.id) |id| posix.kill(id, posix.SIG.TERM) catch {};
    const term = try child.wait(io);
    reaped = true;
    switch (term) {
        .signal => |signal| if (signal != posix.SIG.TERM) return error.ServerCrashed,
        else => return error.ServerExited,
    }
    std.debug.print(
        "echo_check: {s} passed: a line, {s}, {s}, {s}, {d} hang-ups, a half close, a new client\n",
        .{ arguments[1], checks[0].name, checks[1].name, checks[2].name, hang_ups },
    );
}

/// Ends the server and this process when the checks outlast their time.
fn stop_after_timeout(io: Io, server: std.process.Child.Id) void {
    io.sleep(.fromSeconds(checks_timeout_seconds), .awake) catch {};
    const running = step_names[current_step.load(.acquire)];
    std.debug.print("echo_check: the checks took over {d} s; the server stopped answering in: {s}\n", .{
        checks_timeout_seconds, running,
    });
    posix.kill(server, posix.SIG.KILL) catch {};
    std.process.exit(1);
}

/// The steps in the order `run_checks` takes them, so a failure names the one that was running.
const step_names = [_][]const u8{
    "a line",
    checks[0].name,
    checks[1].name,
    checks[2].name,
    "hang-ups",
    "a half close",
    "a new client",
};

/// The step running now: an index into `step_names`, which the watchdog reads.
var current_step: std.atomic.Value(u8) align(@alignOf(std.atomic.Value(u8))) = .init(0);

fn run_checks(io: Io, allocator: std.mem.Allocator, port: u16) !void {
    current_step.store(0, .release);
    try echo_line(io, port, "hello rotor\n");
    for (checks, 1..) |check, step| {
        current_step.store(@intCast(step), .release);
        try echo_at_once(io, allocator, port, check);
    }
    current_step.store(checks.len + 1, .release);
    for (0..hang_ups) |_| try hang_up(io, port);
    current_step.store(checks.len + 2, .release);
    try half_close(io, port);
    current_step.store(checks.len + 3, .release);
    try echo_line(io, port, "still serving\n");
}

/// A port nothing listens on now: the kernel picks one for a listener, which then closes.
fn free_port(io: Io) !u16 {
    const any = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try any.listen(io, .{});
    defer server.deinit(io);
    return server.socket.address.getPort();
}

fn echo_line(io: Io, port: u16, line: []const u8) !void {
    var back: [64]u8 = undefined;
    try echo(io, port, line, back[0..line.len], false);
    if (!std.mem.eql(u8, line, back[0..line.len])) return error.WrongBytes;
}

/// Runs `check.clients` clients at once, each on a thread of its own.
fn echo_at_once(io: Io, allocator: std.mem.Allocator, port: u16, check: Check) !void {
    std.debug.assert(check.clients <= clients_max);
    var threads: [clients_max]std.Thread = undefined;
    var results: [clients_max]anyerror!void = undefined;
    for (0..check.clients) |index| {
        const payload = try allocator.alloc(u8, check.payload_bytes);
        const back = try allocator.alloc(u8, check.payload_bytes);
        fill(payload, @intCast(index + 1));
        const arguments = .{ io, port, payload, back, check.late, &results[index] };
        threads[index] = try std.Thread.spawn(.{}, echo_client, arguments);
    }
    for (threads[0..check.clients]) |thread| thread.join();
    for (results[0..check.clients]) |result| try result;
}

fn echo_client(
    io: Io,
    port: u16,
    payload: []const u8,
    back: []u8,
    late: bool,
    result: *anyerror!void,
) void {
    result.* = echo(io, port, payload, back, late);
    if (result.*) |_| {
        if (!std.mem.eql(u8, payload, back)) result.* = error.WrongBytes;
    } else |_| {}
}

/// Sends `payload` and reads as many bytes back into `back`, the reading on a second thread, so
/// that a payload larger than both sockets' buffers cannot stop both ends at once.
fn echo(io: Io, port: u16, payload: []const u8, back: []u8, late: bool) !void {
    std.debug.assert(payload.len == back.len);
    const stream = try connect(io, port);
    defer stream.close(io);
    var read_result: anyerror!void = {};
    const reader = try std.Thread.spawn(.{}, read_all, .{ io, stream, back, late, &read_result });
    const written = write_all(io, stream, payload);
    reader.join();
    try written;
    try read_result;
}

/// Sends bytes and closes without reading any back.
fn hang_up(io: Io, port: u16) !void {
    var payload: [hang_up_bytes]u8 = undefined;
    fill(&payload, hang_up_bytes);
    const stream = try connect(io, port);
    defer stream.close(io);
    try write_all(io, stream, &payload);
}

/// Sends a line, shuts down the sending side, and requires the line back and then the end of the
/// stream: an echo server closes a connection whose peer has finished.
fn half_close(io: Io, port: u16) !void {
    const line = "goodbye\n";
    const stream = try connect(io, port);
    defer stream.close(io);
    try write_all(io, stream, line);
    try stream.shutdown(io, .send);
    var buffer: [chunk_bytes]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    var back: [line.len]u8 = undefined;
    try reader.interface.readSliceAll(&back);
    if (!std.mem.eql(u8, line, &back)) return error.WrongBytes;
    const more = reader.interface.takeByte();
    if (more != error.EndOfStream) return error.ServerKeptTheConnection;
}

fn connect(io: Io, port: u16) !net.Stream {
    const address = try net.IpAddress.parseIp4("127.0.0.1", port);
    for (0..connect_tries) |_| {
        const stream = address.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
            error.ConnectionRefused => {
                try io.sleep(.fromMilliseconds(connect_retry_ms), .awake);
                continue;
            },
            else => return err,
        };
        return stream;
    }
    return error.ServerNeverListened;
}

fn write_all(io: Io, stream: net.Stream, bytes: []const u8) !void {
    var buffer: [chunk_bytes]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn read_all(io: Io, stream: net.Stream, into: []u8, late: bool, result: *anyerror!void) void {
    if (late) io.sleep(.fromMilliseconds(late_read_ms), .awake) catch {};
    var buffer: [chunk_bytes]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    reader.interface.readSliceAll(into) catch |err| {
        result.* = err;
        return;
    };
    result.* = {};
}

/// Bytes that differ from client to client and from position to position, so a server that sends
/// one client's bytes to another, or repeats a buffer, fails the compare.
fn fill(bytes: []u8, seed: u64) void {
    var state: u64 = seed *% 0x9e37_79b9_7f4a_7c15 | 1;
    for (bytes) |*byte| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        byte.* = @truncate(state);
    }
}
