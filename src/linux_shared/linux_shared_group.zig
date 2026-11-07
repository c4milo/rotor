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

/// An eventfd of this process alone: non-blocking, and closed on exec. A registry of one process
/// keeps one as the wake of each epoll loop, and an io_uring loop holds one as the stand-in of its
/// wake (decision 4, amendment of 2026-11-06).
pub fn make_private() MakeError!Descriptor {
    const rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .MFILE, .NFILE, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
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
    _ = wake_sent(descriptor);
}

/// `send`, and true when the loop has the wake. The write added one to the count, or it failed with
/// EAGAIN: the count is at its most, so the eventfd is readable already. A `Remote` counts each
/// false (decision 4, third amendment of 2026-11-06).
pub fn wake_sent(descriptor: Descriptor) bool {
    assert(descriptor >= 0);
    const rc = linux.write(descriptor, std.mem.asBytes(&one), @sizeOf(u64));
    return switch (linux.errno(rc)) {
        .SUCCESS, .AGAIN => true,
        else => false,
    };
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

test "a wake to an eventfd whose count is at its most is held, and one to a pipe's read end is not" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var wakes: [1]Wake = undefined;
    try make(&wakes);
    defer close(&wakes);
    // The count can reach one short of 2^64. A write past it fails with EAGAIN, and the eventfd
    // is readable already.
    const most: u64 = std.math.maxInt(u64) - 1;
    try testing.expectEqual(@as(usize, 8), linux.write(wakes[0].send, std.mem.asBytes(&most), 8));
    try testing.expect(wake_sent(wakes[0].send));
    drain(wakes[0].watch);

    var ends: [2]i32 = undefined;
    try testing.expectEqual(@as(usize, 0), linux.pipe2(&ends, .{ .CLOEXEC = true }));
    defer for (ends) |end| {
        _ = linux.close(end);
    };
    try testing.expect(!wake_sent(ends[0]));
}

test "a private eventfd does not block, closes on exec, and counts a wake" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const descriptor = try make_private();
    defer _ = linux.close(descriptor);
    const flags = linux.fcntl(descriptor, linux.F.GETFD, 0);
    try testing.expect(flags & linux.FD_CLOEXEC != 0);
    var counter: u64 = 0;
    try testing.expectEqual(linux.E.AGAIN, linux.errno(linux.read(descriptor, std.mem.asBytes(&counter), 8)));
    try testing.expect(wake_sent(descriptor));
    try testing.expectEqual(@as(usize, 8), linux.read(descriptor, std.mem.asBytes(&counter), 8));
    try testing.expectEqual(@as(u64, 1), counter);
}
