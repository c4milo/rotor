//! What the conformance suite needs from a Linux backend beside its surface: a directory to make
//! files in, a number that tells this process's files from another's, and a way to remove a
//! file. Test support only: no path of the loop calls into this file.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

/// Where the suite makes its files. tools/linux_test.sh runs the suite where this directory
/// takes O_DIRECT.
pub const directory = "/tmp";

pub fn process_id() u32 {
    const id = linux.getpid();
    assert(id >= 1);
    return @intCast(id);
}

/// Removes the file at `path`. A file that is already gone is not an error: this runs from a
/// test's `defer`.
pub fn remove_file(path: [*:0]const u8) void {
    assert(path[0] != 0);
    _ = linux.unlink(path);
}

/// The clock the tick reads, for a scenario that measures how long a tick waited.
pub const monotonic_ns = @import("linux_shared_clock.zig").clock_ns;

/// The CPU time the calling thread has used, in nanoseconds, for a scenario that tells a tick that
/// polled from one that slept (decision 13): polling spends the thread's CPU, and sleeping does
/// not.
pub fn thread_cpu_ns() u64 {
    var now: linux.timespec = undefined;
    assert(linux.clock_gettime(.THREAD_CPUTIME_ID, &now) == 0);
    assert(now.sec >= 0 and now.nsec >= 0);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// True when `descriptor` closes on exec: what the suite checks of an accepted socket.
pub fn closes_on_exec(descriptor: i32) bool {
    const flags = linux.fcntl(descriptor, linux.F.GETFD, 0);
    assert(linux.errno(flags) == .SUCCESS);
    return flags & linux.FD_CLOEXEC != 0;
}
