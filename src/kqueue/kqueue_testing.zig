//! What the conformance suite needs from a backend beside its surface: a directory to make
//! files in, a number that tells this process's files from another's, and a way to remove a
//! file. Test support only: no path of the loop calls into this file.
const std = @import("std");
const assert = std.debug.assert;

/// Where the suite makes its files.
pub const directory = "/tmp";

pub fn process_id() u32 {
    const id = std.c.getpid();
    assert(id >= 1);
    return @intCast(id);
}

/// Removes the file at `path`. A file that is already gone is not an error: this runs from a
/// test's `defer`.
pub fn remove_file(path: [*:0]const u8) void {
    assert(path[0] != 0);
    _ = std.c.unlink(path);
}

/// The clock the tick reads, for a scenario that measures how long a tick waited.
pub const monotonic_ns = @import("kqueue_tick.zig").clock_ns;

/// The CPU time the calling thread has used, in nanoseconds, for a scenario that tells a tick that
/// polled from one that slept (decision 13): polling spends the thread's CPU, and sleeping does
/// not.
pub fn thread_cpu_ns() u64 {
    var now: std.c.timespec = undefined;
    assert(std.c.clock_gettime(.THREAD_CPUTIME_ID, &now) == 0);
    assert(now.sec >= 0 and now.nsec >= 0);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// True when `descriptor` closes on exec: what the suite checks of an accepted socket.
pub fn closes_on_exec(descriptor: i32) bool {
    const flags = std.c.fcntl(descriptor, std.c.F.GETFD, @as(c_int, 0));
    assert(flags >= 0);
    return flags & std.c.FD_CLOEXEC != 0;
}

/// The ends of a socket pair.
pub const pair_ends = 2;

/// Two connected Unix stream sockets that do not block, for a test of this backend alone.
pub fn nonblocking_pair() ![pair_ends]i32 {
    var descriptors: [pair_ends]c_int = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &descriptors) != 0) {
        return error.SocketPairFailed;
    }
    for (descriptors) |descriptor| {
        const flags = std.c.fcntl(descriptor, std.c.F.GETFL, @as(c_int, 0));
        const nonblocking: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        if (std.c.fcntl(descriptor, std.c.F.SETFL, flags | nonblocking) != 0) {
            return error.NonBlockingFailed;
        }
    }
    return descriptors;
}
