//! The monotonic clock both Linux backends' ticks read.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");

/// The monotonic clock, in nanoseconds. A tick reads it once, and once more after a wait that
/// produced nothing (decision 9, rule 4). The tests read it too, so a test measures with the clock
/// the tick reads.
pub fn clock_ns() u64 {
    var now: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &now);
    assert(linux.errno(rc) == .SUCCESS);
    assert(now.sec >= 0);
    const seconds: u64 = @intCast(now.sec);
    const nanoseconds: u64 = @intCast(now.nsec);
    return seconds * core.constants.ns_per_s + nanoseconds;
}
