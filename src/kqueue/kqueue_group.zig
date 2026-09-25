//! The wakes of a group on kqueue: a registry whose loops may run in several processes (decision 21,
//! point 3).
//!
//! A loop's own wake is an `EVFILT_USER` trigger on its kqueue, and no other process can use it:
//! kqueue(2) says a queue is not inherited by a child created with fork(2), and the trigger is sent
//! through the queue. So the process that creates the group makes one pipe per loop before any
//! other process of the group starts, and every process inherits both ends at the same numbers.
//! A loop watches the read end with `EVFILT_READ`, and a sender writes one byte to the write end.
//! In a group every wake takes this path, from the loop's own process too, so a sender never needs
//! to know where a loop runs.
//!
//! The loop keeps its `EVFILT_USER` event for what only its own process sends: the trigger a
//! polling tick carries (decision 12, point 6) and the wake of its offload's workers (decision 18).
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("constants.zig");
const queue_module = @import("kqueue_queue.zig");

const Descriptor = core.Descriptor;
const Wake = core.mailbox.Wake;
const Kevent = queue_module.Kevent;

/// Why `make` made no wakes.
pub const MakeError = error{
    /// The process or the system has no descriptor left for another pipe.
    SystemResources,
    Unexpected,
};

/// Makes one pipe per entry of `wakes`, for the process that creates a group, before it starts any
/// other process of the group. Both ends are non-blocking, and neither closes on exec, since the
/// other processes are meant to inherit them (decision 21, open question 2). The write end raises
/// no `SIGPIPE`. On failure it closes every pipe it made and writes nothing more.
pub fn make(wakes: []Wake) MakeError!void {
    assert(wakes.len >= 1);
    assert(wakes.len <= core.constants.loops_max);
    for (wakes, 0..) |*wake, made| {
        wake.* = make_one() catch |err| {
            close(wakes[0..made]);
            return err;
        };
    }
}

/// A pipe has a read end and a write end.
const pipe_ends = 2;

fn make_one() MakeError!Wake {
    var ends: [pipe_ends]std.c.fd_t = undefined;
    const rc = std.c.pipe(&ends);
    if (rc != 0) {
        return switch (std.posix.errno(rc)) {
            .MFILE, .NFILE => error.SystemResources,
            else => error.Unexpected,
        };
    }
    const wake: Wake = .{ .send = ends[1], .watch = ends[0] };
    errdefer close(&.{wake});
    try set_nonblocking(wake.watch);
    try set_nonblocking(wake.send);
    if (std.c.fcntl(wake.send, std.c.F.SETNOSIGPIPE, @as(c_int, 1)) != 0) return error.Unexpected;
    assert(wake.send >= 0 and wake.watch >= 0);
    return wake;
}

fn set_nonblocking(descriptor: Descriptor) MakeError!void {
    const flags = std.c.fcntl(descriptor, std.c.F.GETFL);
    if (flags < 0) return error.Unexpected;
    if (std.c.fcntl(descriptor, std.c.F.SETFL, flags | nonblocking_flag) != 0) return error.Unexpected;
}

const nonblocking_flag: c_int = @bitCast(std.c.O{ .NONBLOCK = true });

/// Closes this process's copies of `wakes`. Every process of a group holds its own copies, and each
/// closes them when it is done with the group; the other processes keep theirs.
pub fn close(wakes: []const Wake) void {
    for (wakes) |wake| {
        assert(wake.send >= 0 and wake.watch >= 0);
        _ = std.c.close(wake.send);
        _ = std.c.close(wake.watch);
    }
}

/// The change that makes a loop's kqueue report its wake pipe. It is kept and level-triggered: the
/// pipe stays ready until the loop reads what was written.
pub fn watch_event(watch: Descriptor) Kevent {
    assert(watch >= 0);
    return queue_module.descriptor_event(watch, std.c.EVFILT.READ, std.c.EV.ADD);
}

/// A sender wakes the loop whose pipe's write end is `send`. A full pipe already holds a wake the
/// loop has not read, and a write it refuses is dropped, as `Queue.wake` drops a refused trigger:
/// the message is in the ring, and the loop reads it at its next tick.
pub fn send(descriptor: Descriptor) void {
    assert(descriptor >= 0);
    const byte = [1]u8{1};
    _ = std.c.write(descriptor, &byte, byte.len);
}

/// The loop reads what senders wrote to its pipe, up to `group_wake_drain_bytes`. What is left keeps
/// the read end ready, and the next tick reads more; each wake writes one byte, and a sender writes
/// only to a loop that said it sleeps, so little is ever left.
pub fn drain(watch: Descriptor) void {
    assert(watch >= 0);
    var bytes: [constants.group_wake_drain_bytes]u8 = undefined;
    _ = std.c.read(watch, &bytes, bytes.len);
}

const testing = std.testing;

test "a group's pipes do not block, raise no signal, and stay open across exec" {
    if (!@import("builtin").os.tag.isDarwin()) return error.SkipZigTest;
    var wakes: [3]Wake = undefined;
    try make(&wakes);
    defer close(&wakes);
    for (wakes) |wake| {
        for ([_]Descriptor{ wake.send, wake.watch }) |descriptor| {
            try testing.expect(std.c.fcntl(descriptor, std.c.F.GETFL) & nonblocking_flag != 0);
            try testing.expectEqual(@as(c_int, 0), std.c.fcntl(descriptor, std.c.F.GETFD) & std.c.FD_CLOEXEC);
        }
        try testing.expectEqual(@as(c_int, 1), std.c.fcntl(wake.send, std.c.F.GETNOSIGPIPE));
    }
}

test "a wake written to a pipe is read back, and a full pipe refuses without blocking" {
    if (!@import("builtin").os.tag.isDarwin()) return error.SkipZigTest;
    var wakes: [1]Wake = undefined;
    try make(&wakes);
    defer close(&wakes);
    const wake = wakes[0];
    var byte: [1]u8 = undefined;
    try testing.expect(std.c.read(wake.watch, &byte, 1) < 0);
    send(wake.send);
    drain(wake.watch);
    try testing.expect(std.c.read(wake.watch, &byte, 1) < 0);

    // Fill the pipe. A blocking write end would stop this test here.
    const chunk: [4096]u8 = @splat(1);
    var full = false;
    for (0..256) |_| {
        if (std.c.write(wake.send, &chunk, chunk.len) < 0) {
            full = true;
            break;
        }
    }
    try testing.expect(full);
    send(wake.send);
    drain(wake.watch);
    try testing.expect(std.c.read(wake.watch, &byte, 1) == 1);
}
