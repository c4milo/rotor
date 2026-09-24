//! The one clock every benchmark reads. A span is only comparable when both ends of it, and both
//! candidates measured against each other, read the same clock the same way.
//!
//! It is the monotonic clock, which is the one the backends' ticks read: a wall clock can step
//! backwards when the host adjusts it, and a span measured across such a step is not a span.
//!
//! This is the helper `bench/echo/client.zig` and `bench/timers/rotor_timers.zig` each carried a
//! copy of, lifted here when the cross-core workload would have made a third. Nothing in `src/`
//! may read a clock at all (CLAUDE.md, non-negotiable 2); a benchmark is what does the reading,
//! and it lives outside the module graph.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The timespec the host's monotonic clock fills, which the two platforms spell apart.
const Timespec = if (builtin.os.tag == .linux) std.os.linux.timespec else std.c.timespec;

/// The monotonic clock in nanoseconds. A round trip is thousands of these, so the read's own cost
/// (C20, about 20 ns by a recalled prior) is not what a caller is measuring.
pub fn now_ns() u64 {
    var value: Timespec = undefined;
    if (builtin.os.tag == .linux) {
        assert(std.os.linux.clock_gettime(.MONOTONIC, &value) == 0);
    } else {
        assert(std.c.clock_gettime(.MONOTONIC, &value) == 0);
    }
    return nanoseconds_of(value);
}

/// The CPU time the calling thread has used, user and system time together, in nanoseconds. It
/// rises only while the thread runs, so a thread that sleeps or blocks in the kernel adds nothing
/// to it. Decision 13's idle case reads it to price what a loop spends while it waits for work.
pub fn thread_cpu_ns() u64 {
    var value: Timespec = undefined;
    if (builtin.os.tag == .linux) {
        assert(std.os.linux.clock_gettime(.THREAD_CPUTIME_ID, &value) == 0);
    } else {
        assert(std.c.clock_gettime(.THREAD_CPUTIME_ID, &value) == 0);
    }
    return nanoseconds_of(value);
}

fn nanoseconds_of(value: Timespec) u64 {
    assert(value.sec >= 0);
    assert(value.nsec >= 0);
    const seconds: u64 = @intCast(value.sec);
    return seconds * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}

const testing = std.testing;

test "the clock moves forward and never backward" {
    const first = now_ns();
    const second = now_ns();
    try testing.expect(second >= first);

    var previous = second;
    for (0..64) |_| {
        const reading = now_ns();
        try testing.expect(reading >= previous);
        previous = reading;
    }
}

test "the clock counts nanoseconds and not whole seconds" {
    // A reading that dropped the nanosecond field would still rise and would still be far below
    // the epoch, so both other tests would pass while every span rounded to a second. One
    // reading with a non-zero remainder is enough to show the field is there.
    var fine = false;
    for (0..64) |_| {
        if (now_ns() % std.time.ns_per_s != 0) {
            fine = true;
            break;
        }
    }
    try testing.expect(fine);
}

test "the clock is not the epoch, so it is not the wall clock" {
    // A monotonic clock counts from an arbitrary point, usually the host's boot. A wall clock
    // would read about 1.7e18 ns since 1970, which is far above anything an uptime reaches.
    const wall_clock_floor_ns: u64 = 1_000_000_000 * 1_000_000_000;
    try testing.expect(now_ns() < wall_clock_floor_ns);
}

test "a thread's CPU clock stands still while the thread sleeps, and rises while it runs" {
    const sleep_ns = 20 * std.time.ns_per_ms;
    const before_sleep = thread_cpu_ns();
    try testing.io.sleep(.fromNanoseconds(sleep_ns), .awake);
    // The monotonic clock read in its place would count the whole sleep.
    try testing.expect(thread_cpu_ns() - before_sleep < sleep_ns / 2);

    const spin_ns = 2 * std.time.ns_per_ms;
    const before_spin = thread_cpu_ns();
    const spin_until_ns = now_ns() + spin_ns;
    while (now_ns() < spin_until_ns) {}
    try testing.expect(thread_cpu_ns() > before_spin);
}
