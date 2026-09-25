//! The wakes of a group on Linux: a registry whose loops may run in several processes (decision 21,
//! point 3). The process that creates the group makes one eventfd per loop before any other process
//! of the group starts, and every process inherits it at the same number. A sender adds one to the
//! count with `write(2)`; the loop waits for the eventfd to be readable, with epoll or with a poll
//! in its io_uring ring, and reads the count back to zero. In a group every wake takes this path,
//! from the loop's own process too, so a sender never needs to know where a loop runs.
//!
//! An eventfd has one descriptor, so a wake's `send` and `watch` are the same number. It does not
//! block: a read that finds no count returns at once, and a write fails only when the count is one
//! short of 2^64, which counting one per wake never reaches.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");

const Descriptor = core.Descriptor;
const Wake = core.mailbox.Wake;

/// Why `make` made no wakes.
pub const MakeError = error{
    /// The process or the system has no descriptor left for another eventfd.
    SystemResources,
    Unexpected,
};

/// What one wake adds to the counter.
const one: u64 = 1;

/// Makes one eventfd per entry of `wakes`, for the process that creates a group, before it starts
/// any other process of the group. None closes on exec, since the other processes are meant to
/// inherit them (decision 21, open question 2). On failure it closes every one it made.
pub fn make(wakes: []Wake) MakeError!void {
    assert(wakes.len >= 1);
    assert(wakes.len <= core.constants.loops_max);
    for (wakes, 0..) |*wake, made| {
        const rc = linux.eventfd(0, linux.EFD.NONBLOCK);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .MFILE, .NFILE, .NOMEM => {
                close(wakes[0..made]);
                return error.SystemResources;
            },
            else => {
                close(wakes[0..made]);
                return error.Unexpected;
            },
        }
        const descriptor: Descriptor = @intCast(rc);
        wake.* = .{ .send = descriptor, .watch = descriptor };
    }
}

/// Closes this process's copies of `wakes`. Every process of a group holds its own copies, and each
/// closes them when it is done with the group; the other processes keep theirs.
pub fn close(wakes: []const Wake) void {
    for (wakes) |wake| {
        assert(wake.send >= 0 and wake.send == wake.watch);
        _ = linux.close(wake.send);
    }
}

/// A sender wakes the loop whose eventfd is `descriptor`. A write the kernel refuses is dropped,
/// as every backend drops a refused wake: the message is in the ring, and the loop reads it at its
/// next tick.
pub fn send(descriptor: Descriptor) void {
    assert(descriptor >= 0);
    _ = linux.write(descriptor, std.mem.asBytes(&one), @sizeOf(u64));
}

/// The loop empties the count of its eventfd, once it saw it readable. A read that finds no count
/// returns at once.
pub fn drain(descriptor: Descriptor) void {
    assert(descriptor >= 0);
    var counter: u64 = 0;
    _ = linux.read(descriptor, std.mem.asBytes(&counter), @sizeOf(u64));
}

const testing = std.testing;

test "a group's eventfds count the wakes, and the loop's read empties them" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var wakes: [2]Wake = undefined;
    try make(&wakes);
    defer close(&wakes);
    for (wakes) |wake| {
        try testing.expectEqual(wake.send, wake.watch);
        const flags = linux.fcntl(wake.send, linux.F.GETFD, 0);
        try testing.expectEqual(@as(usize, 0), flags & linux.FD_CLOEXEC);
    }
    send(wakes[0].send);
    send(wakes[0].send);
    var counter: u64 = 0;
    try testing.expectEqual(@as(usize, 8), linux.read(wakes[0].watch, std.mem.asBytes(&counter), 8));
    try testing.expectEqual(@as(u64, 2), counter);
    // Empty, a read returns at once: the loop's drain never blocks it.
    drain(wakes[0].watch);
    try testing.expectEqual(linux.E.AGAIN, linux.errno(linux.read(wakes[0].watch, std.mem.asBytes(&counter), 8)));
}
