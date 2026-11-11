//! The `connection` workload of `work.zig`: one TCP connection's life on loopback, served by one
//! plain loop with no registry, as a server's loop is. One iteration is:
//!
//! 1. The loop takes an accept, and one tick finds no connection, so the accept waits for the
//!    listener's readiness.
//! 2. The client connects and writes the request.
//! 3. One tick hands over the accept.
//! 4. A receive, a send and a close follow, one tick each. The request is there before the
//!    receive, and the socket has room for the response, so neither waits.
//!
//! The client makes plain blocking system calls, the same calls at every commit of rotor. It reads
//! the response before the close, and closes last with a reset (`SO_LINGER` of 0), so no port of
//! either side waits in TIME_WAIT and an iteration can run as often as the gate needs.
//!
//! macOS can complete a transfer on loopback in a kernel thread after the call that started it
//! returns. So before steps 3 and 4 the program waits with `poll` until the listener, and then the
//! accepted socket, is readable. Without the waits, a tick could find nothing on one run and the
//! connection on the next, and the count would change from run to run.
//!
//! On Linux, cachegrind counts the instructions of both sides in user space, so a change of the
//! count between two commits is rotor's. The gate does not run this workload on macOS, where
//! `/usr/bin/time -l` also counts the kernel's work for the connection (`work.zig`,
//! `counts_connection`).
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const backend = @import("backend");

const Loop = backend.Loop;
const Event = core.Event;
const Operation = core.Operation;

pub const request = "GET / HTTP/1.1\r\nHost: work\r\nConnection: close\r\n\r\n";
pub const response = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n";

/// Connections the kernel may queue for the listener. One iteration queues one.
const backlog = 16;

/// The longest wait for a socket to become readable. On `mac` at a load average of 40, a whole
/// iteration took about 2 ms, so only a fault reaches this wait, and the iteration then fails.
const readable_wait_ms = 1000;

/// The user data of each operation of one iteration.
const accept_user_data = 1;
const receive_user_data = 2;
const send_user_data = 3;
const close_user_data = 4;

/// The listener of every iteration, and its address in the kernel's form for the client.
pub const Listener = struct {
    descriptor: core.Descriptor,
    storage: backend.address.Storage,
    storage_len: u32,

    /// Listens on a port of 127.0.0.1 that the kernel picks.
    pub fn open(listener: *Listener) !void {
        const loopback = core.Address.ipv4(.{ 127, 0, 0, 1 }, 0);
        listener.descriptor = try backend.sync.listen(&loopback, .{ .backlog = backlog, .reuse_port = false });
        errdefer backend.sync.close_now(listener.descriptor);
        const bound = try backend.sync.local_address(listener.descriptor);
        listener.storage_len = backend.address.to_kernel(&bound, &listener.storage);
    }

    pub fn close(listener: *const Listener) void {
        backend.sync.close_now(listener.descriptor);
    }
};

/// One connection's life, served by `loop`, which hands its events over in `events`. The receive
/// reads into `received`.
pub fn serve_one(loop: *Loop, events: []Event, listener: *const Listener, received: []u8) !void {
    try submit(loop, Operation.accept(accept_user_data, listener.descriptor));
    try expect(loop, events, 0);
    const client = try Client.connect(listener);
    defer client.close();
    try Client.wait_readable(listener.descriptor);
    try expect_one(loop, events, accept_user_data, null);
    const accepted: core.Descriptor = @intCast(try events[0].outcome());
    try Client.wait_readable(accepted);
    try submit(loop, Operation.receive(receive_user_data, accepted, received));
    try expect_one(loop, events, receive_user_data, request.len);
    try submit(loop, Operation.send(send_user_data, accepted, response));
    try expect_one(loop, events, send_user_data, response.len);
    try client.read_response();
    try submit(loop, Operation.close(close_user_data, accepted));
    try expect_one(loop, events, close_user_data, 0);
}

fn submit(loop: *Loop, operation: Operation) !void {
    if (loop.submit(&.{operation}, &.{}) != 1) return error.TableFull;
}

/// Ticks once, with no wait, and fails unless that tick handed over exactly `count` events.
fn expect(loop: *Loop, events: []Event, count: u32) !void {
    if (try loop.tick(events, 0) != count) return error.EventsMissing;
}

/// Ticks once, with no wait, and fails unless that tick handed over one event, of `user_data`, with
/// the result `result` when it is not null.
fn expect_one(loop: *Loop, events: []Event, user_data: u64, result: ?u32) !void {
    try expect(loop, events, 1);
    if (events[0].user_data != user_data) return error.UnexpectedEvent;
    const outcome = try events[0].outcome();
    if (result) |wanted| {
        if (outcome != wanted) return error.UnexpectedResult;
    }
}

/// The client's side, and the program's waits: blocking system calls, Linux's own on Linux and
/// libc's on macOS.
const Client = struct {
    descriptor: i32,

    const on_linux = builtin.os.tag == .linux;
    const system = if (on_linux) std.os.linux else std.c;

    /// `struct linger`, the same on Linux and on macOS.
    const Linger = extern struct { on: c_int, seconds: c_int };

    /// Opens a blocking socket that closes with a reset, connects it to `listener`, and writes the
    /// request.
    fn connect(listener: *const Listener) !Client {
        const descriptor: i32 = @intCast(try checked(system.socket(system.AF.INET, system.SOCK.STREAM, 0)));
        errdefer _ = system.close(descriptor);
        const reset: Linger = .{ .on = 1, .seconds = 0 };
        _ = try checked(system.setsockopt(
            descriptor,
            system.SOL.SOCKET,
            system.SO.LINGER,
            @ptrCast(&reset),
            @sizeOf(Linger),
        ));
        _ = try checked(system.connect(descriptor, @ptrCast(&listener.storage), listener.storage_len));
        const written = try checked(system.write(descriptor, request, request.len));
        if (written != request.len) return error.ShortWrite;
        return .{ .descriptor = descriptor };
    }

    /// Reads the whole response, which the server sent before this call.
    fn read_response(client: Client) !void {
        var buffer: [response.len]u8 = undefined;
        const read = try checked(system.read(client.descriptor, &buffer, buffer.len));
        if (read != response.len) return error.ShortRead;
    }

    fn close(client: Client) void {
        _ = system.close(client.descriptor);
    }

    /// Waits until `descriptor` is readable, at most `readable_wait_ms`.
    fn wait_readable(descriptor: i32) !void {
        var polled = [1]system.pollfd{.{ .fd = descriptor, .events = system.POLL.IN, .revents = 0 }};
        const ready = try checked(system.poll(&polled, polled.len, readable_wait_ms));
        if (ready != polled.len) return error.NotReadable;
    }

    /// The count a system call returned, or an error when it failed.
    fn checked(returned: anytype) error{ClientCallFailed}!usize {
        if (comptime on_linux) {
            if (std.os.linux.errno(returned) != .SUCCESS) return error.ClientCallFailed;
            return returned;
        }
        if (returned < 0) return error.ClientCallFailed;
        return @intCast(returned);
    }
};
