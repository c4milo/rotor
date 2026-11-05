//! A TCP echo server written against `std.Io` alone, run on rotor's adapter (decision 22): a task
//! per connection, each reading and writing as if the calls blocked.
//!
//! Run:  zig build examples && ./zig-out/bin/std_io_echo [PORT]
//! Then: nc 127.0.0.1 9000
//!
//! Only `main` names rotor: it starts a loop and the adapter, and hands `serve` the adapter's
//! `std.Io`. `serve` and `echo` would run on `std.Io.Threaded` unchanged. `zig build test` runs
//! `tools/echo_check.zig` against this program, and the Linux gate does so on io_uring and on
//! epoll.
const std = @import("std");
const rotor = @import("rotor");
const Io = std.Io;
const net = std.Io.net;

/// The port it listens on when the command line names none.
const port_default = 9000;

/// Connections served at once: one fiber each. A connection that finds every fiber busy is closed.
const fibers = 64;

/// What each connection reads and writes through.
const buffer_bytes = 4096;

const loop_options: rotor.Loop.Options = .{ .operations = fibers + 1 };
var loop_memory: [rotor.Loop.memory_bytes(loop_options)]u8 align(rotor.memory_alignment) = undefined;

const adapter_sizing: rotor.adapter.Options = .{
    .fibers = fibers,
    .stack_bytes = rotor.adapter.adapter_constants.stack_bytes_min,
    .rest = undefined,
};
var adapter_memory: [rotor.adapter.memory_bytes(adapter_sizing)]u8 align(rotor.adapter.memory_alignment) = undefined;

pub fn main(init: std.process.Init) !void {
    const port = try port_of(init);
    var loop: rotor.Loop = undefined;
    try loop.init(&loop_memory, loop_options);
    var adapter: rotor.adapter.Adapter = undefined;
    // The calls the adapter does not run on the loop go to the process's own `std.Io`.
    var options = adapter_sizing;
    options.rest = init.io;
    adapter.init(&loop, &adapter_memory, options);
    std.debug.print("std_io_echo on 127.0.0.1:{d}, {t} backend\n", .{ port, rotor.backend() });
    // The server runs until it is stopped, so it never ends the adapter or the loop.
    try serve(adapter.io(), port);
}

/// Accepts connections for ever, and echoes each in a task of its own.
fn serve(io: Io, port: u16) !void {
    const address: net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = server.accept(io) catch |failure| switch (failure) {
            error.ConnectionAborted => continue,
            else => return failure,
        };
        // `concurrent` and not `async`: `async` may run the task here, and then this loop would
        // accept nothing until that connection ends.
        group.concurrent(io, echo, .{ io, stream }) catch stream.close(io);
    }
}

/// One connection, until the peer stops sending.
fn echo(io: Io, stream: net.Stream) void {
    defer stream.close(io);
    var read_buffer: [buffer_bytes]u8 = undefined;
    var write_buffer: [buffer_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    while (true) {
        const bytes = reader.interface.peekGreedy(1) catch return;
        writer.interface.writeAll(bytes) catch return;
        writer.interface.flush() catch return;
        reader.interface.toss(bytes.len);
    }
}

fn port_of(init: std.process.Init) !u16 {
    var arguments = init.minimal.args.iterate();
    _ = arguments.next();
    const text = arguments.next() orelse return port_default;
    return std.fmt.parseInt(u16, text, 10);
}
