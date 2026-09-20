//! std_io_echo: a TCP echo server on 127.0.0.1 written against `std.Io`, the standard library's
//! own I/O interface, which is the third and fourth candidate of the comparison.
//!
//! Run:  std_io_echo PORT [--backend uring|threaded]
//!
//! One program serves both, because `std.Io` is an interface and the two are implementations of
//! it: every line below is the same for either, and `--backend` picks which `Io` the program
//! runs on. That is the point of the interface, and writing two programs would hide it.
//!
//!   - `uring`: `std.Io.Uring`, fibers over io_uring. Linux only.
//!   - `threaded`: `std.Io.Threaded`, a thread pool with a blocking call per operation.
//!
//! It is written the way `std.Io` is meant to be written, so that no result of the harness comes
//! from this file: a task per connection, reading and writing as if the calls blocked, with the
//! implementation deciding what actually happens. That shape is the whole argument for the
//! interface, and a candidate that avoided it would not be `std.Io`.
//!
//! The connection tasks are started with `Group.concurrent` and not `Group.async`, because
//! `async` may run a task on the calling thread and a server that accepts one connection at a
//! time is not a server. See the comment at the call.
//!
//! What it costs, which decision 3's table records: a task per connection means a fiber stack
//! under `uring` and a thread under `threaded`, against one slot of 64 bytes in rotor. The
//! buffer is per connection too, as libuv's and libxev's are.
const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Stream = std.Io.net.Stream;

/// The read buffer of one connection, which is what a completion-based read without provided
/// buffers costs, the same figure libxev_echo holds.
const connection_buffer_bytes = 64 * 1024;

const listen_backlog = 1024;

/// Connections served at once. A task is spawned per connection and awaited at the end.
const connections_max = 512;

const Backend = enum { uring, threaded };

/// Memory `std.Io.Uring` and `std.Io.Threaded` take for their fiber stacks and their pool.
const backing_bytes = 64 * 1024 * 1024;

var backing: [backing_bytes]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    var arena = std.heap.FixedBufferAllocator.init(&backing);
    const gpa = arena.allocator();

    switch (options.backend) {
        .threaded => {
            var threaded: std.Io.Threaded = .init(gpa, .{});
            defer threaded.deinit();
            try serve(init, threaded.io(), options);
        },
        .uring => {
            if (builtin.os.tag != .linux) return error.UringNeedsLinux;
            var evented: std.Io.Uring = undefined;
            try evented.init(gpa, .{});
            defer evented.deinit();
            try serve(init, evented.io(), options);
        },
    }
}

fn serve(init: std.process.Init, io: Io, options: Options) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", options.port);
    var server = try std.Io.net.IpAddress.listen(&address, io, .{
        .kernel_backlog = listen_backlog,
        .reuse_address = true,
    });
    defer server.deinit(io);

    // The harness waits for this line before it connects.
    var out_buffer: [128]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    try out.interface.print("std_io_echo: std.Io.{t} listening on 127.0.0.1:{d}\n", .{
        options.backend,
        options.port,
    });
    try out.interface.flush();

    var group: Io.Group = .init;
    defer group.cancel(io);
    var served: u32 = 0;
    while (served < connections_max) : (served += 1) {
        const stream = server.accept(io) catch |failure| switch (failure) {
            error.ConnectionAborted, error.WouldBlock => continue,
            else => return failure,
        };
        // `concurrent` and not `async`: `async` is allowed to run the task on the calling
        // thread, and an implementation that does leaves this loop serving connection one for
        // ever and never accepting connection two. `concurrent` is the call that promises the
        // task runs beside this loop, which is what a server needs. The first version of this
        // file used `async` and the harness reported it stalled, which is what that looks like.
        group.concurrent(io, echo, .{ io, stream }) catch |failure| {
            stream.close(io);
            return failure;
        };
    }
    group.await(io) catch {};
}

/// One connection, until the peer stops. Written as if the calls blocked, which is what the
/// interface promises and what an implementation is free to make true in its own way.
fn echo(io: Io, stream: Stream) void {
    var read_buffer: [connection_buffer_bytes]u8 = undefined;
    var write_buffer: [connection_buffer_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    defer stream.close(io);

    while (true) {
        const bytes = reader.interface.peekGreedy(1) catch return;
        writer.interface.writeAll(bytes) catch return;
        writer.interface.flush() catch return;
        reader.interface.toss(bytes.len);
    }
}

const Options = struct {
    port: u16,
    backend: Backend = if (builtin.os.tag == .linux) .uring else .threaded,
};

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingPort;
    var options: Options = .{ .port = try std.fmt.parseInt(u16, arguments[1], 10) };
    var index: usize = 2;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        if (!std.mem.eql(u8, arguments[index], "--backend")) return error.UnknownArgument;
        const value = arguments[index + 1];
        if (std.mem.eql(u8, value, "uring")) {
            options.backend = .uring;
        } else if (std.mem.eql(u8, value, "threaded")) {
            options.backend = .threaded;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}
