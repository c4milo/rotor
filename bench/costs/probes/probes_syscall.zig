//! Rows C6 and C20: the smallest system call, and one read of the monotonic clock.
//!
//! C6 calls `getppid`, which does nothing in the kernel but read one field. A process can get a
//! new parent at any time, so no libc may answer it from a cache, and every call enters the
//! kernel. `std.posix.getppid` is the raw `syscall` instruction on Linux, where the probes link
//! no libc. On macOS it is libSystem's stub, a few instructions around `svc #0x80`, because Apple
//! supports no other way into the kernel. A raw `svc` was tried in development and measured
//! within 3 percent of the stub.
//!
//! C20 reads `measure.clock_id`, the clock the probes are timed with and the one std.Io reads.
//! On macOS that call is `mach_absolute_time` plus a conversion to a timespec, so the note also
//! gives `mach_absolute_time` alone, which is what a loop that keeps ticks would pay.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const measure = @import("../measure.zig");
const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;

pub const probes = [_]measure.Probe{
    .{ .row = 6, .operation = "smallest syscall round trip, getppid", .run = run_getppid },
    .{ .row = 20, .operation = "monotonic clock read", .run = run_clock_read },
};

const getppid_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 128 };
const clock_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 1024 };

/// What the note says when this target has no second clock to compare.
const no_tick_clock_text = "the same call times every probe";

const Parent = struct {
    expected: posix.pid_t,

    pub fn run_batch(parent: *Parent, calls: u32) Error!void {
        var mismatches: u32 = 0;
        var remaining = calls;
        while (remaining != 0) : (remaining -= 1) {
            mismatches +%= @intFromBool(posix.getppid() != parent.expected);
        }
        if (mismatches != 0) return error.UnexpectedResult;
    }
};

fn run_getppid(environment: *Environment) Error!Result {
    // The parent may be 0: the first process of a Linux container has no parent it can see.
    var parent: Parent = .{ .expected = posix.getppid() };
    const summary = try measure.sample(Parent, &parent, getppid_plan, environment.values[0]);
    const path = switch (builtin.os.tag) {
        .macos => "libSystem's getppid stub around svc #0x80, the only supported path on macOS",
        .linux => "the raw syscall instruction, no libc",
        else => "std.posix.getppid",
    };
    const note = environment.note("{s}; every call's answer is checked", .{path});
    return .{ .summary = summary, .plan = getppid_plan, .unit = "calls", .note = note };
}

const ClockReads = struct {
    last_ns: u64 = 0,

    pub fn run_batch(reads: *ClockReads, count: u32) Error!void {
        var last_ns = reads.last_ns;
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            const now_ns = measure.now_ns();
            if (now_ns < last_ns) return error.UnexpectedResult;
            last_ns = now_ns;
        }
        reads.last_ns = last_ns;
    }
};

/// macOS only: the tick counter `clock_gettime` is built on, with no conversion to nanoseconds.
const TickReads = struct {
    last_ticks: u64 = 0,

    pub fn run_batch(reads: *TickReads, count: u32) Error!void {
        var last_ticks = reads.last_ticks;
        var remaining = count;
        while (remaining != 0) : (remaining -= 1) {
            const ticks = std.c.mach_absolute_time();
            if (ticks < last_ticks) return error.UnexpectedResult;
            last_ticks = ticks;
        }
        reads.last_ticks = last_ticks;
    }
};

fn run_clock_read(environment: *Environment) Error!Result {
    var reads: ClockReads = .{};
    const summary = try measure.sample(ClockReads, &reads, clock_plan, environment.values[0]);
    const note = if (builtin.os.tag == .macos) macos_note: {
        var ticks: TickReads = .{};
        const raw = try measure.sample(TickReads, &ticks, clock_plan, environment.values[1]);
        break :macos_note environment.note(
            "{s}, the clock that times every probe; mach_absolute_time alone, in ticks and" ++
                " not nanoseconds, took {d:.2} ns ({d:.2})",
            .{ measure.clock_name, raw.median_ns, raw.p99_ns },
        );
    } else environment.note("{s}; {s}", .{ measure.clock_name, no_tick_clock_text });
    return .{ .summary = summary, .plan = clock_plan, .unit = "reads", .note = note };
}
