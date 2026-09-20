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

/// The monotonic clock, for a scenario that measures how long a tick waited.
pub fn monotonic_ns() u64 {
    var now: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.MONOTONIC, &now);
    assert(rc == 0);
    return @as(u64, @intCast(now.sec)) * ns_per_s + @as(u64, @intCast(now.nsec));
}

const ns_per_s: u64 = 1_000_000_000;

/// True when `descriptor` closes on exec: what the suite checks of an accepted socket.
pub fn closes_on_exec(descriptor: i32) bool {
    const flags = std.c.fcntl(descriptor, std.c.F.GETFD, @as(c_int, 0));
    assert(flags >= 0);
    return flags & std.c.FD_CLOEXEC != 0;
}
