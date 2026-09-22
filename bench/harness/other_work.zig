//! Other work on the machine while a series was measured: the CPU the machine spent busy in a
//! short pause before and after every run, while the harness ran nothing, carried on the row in
//! hundredths of one core.
//!
//! Four attempts on 2026-09-20 were spoiled by other work arriving part way through, and the
//! harness first answered with the one-minute load average, marking a row whose average moved by a
//! point. The comparison of 2026-09-22 showed that mark reading the harness itself: two busy
//! processes over a 75-second series raise a one-minute average by more than a point, and a
//! candidate that sleeps 4,096 threads raised it to 327 and left it decaying over the next runner's
//! rows on an idle machine. A load average lags, and it counts the harness's own threads.
//!
//! A second version read busy CPU time around the run and subtracted the harness's own `getrusage`.
//! It read 2.3 cores of other work during a one-second echo run on a desktop carrying about one:
//! loopback TCP runs in kernel threads that no process is charged for, so the harness's own traffic
//! counted as other work.
//!
//! So the reading is taken while the harness runs nothing. Before and after every run the runner
//! pauses for `gap_ns` and reads how much CPU the machine spent busy in that pause: with the
//! candidate's process exited and the runner asleep, every busy tick is someone else's. The row
//! carries the highest reading of the series and the mean, and a reading at or above
//! `other_work_hundredths_max` marks the row. A job that arrives during a run shows in the pause
//! after it. The jobs that spoiled the earlier attempts ran for minutes; a job that starts and ends
//! inside one run is what this cannot see.
//!
//! The busy time is `host_statistics` on macOS and /proc/stat on Linux. Hundredths, not a fraction:
//! `report.zig` prints every number as an integer.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const clock = @import("clock.zig");

/// The multiplier a reading is carried at: half a core is 50.
pub const scale: u32 = 100;

/// A reading at or above this, in hundredths of one core, marks the row. Half a core: an idle
/// desktop keeps under a tenth of a core, and a job arriving takes a core or more, which is what
/// spoiled the attempts of 2026-09-20. It is the harness's own threshold and not a measured
/// constant, like `series.spread_unreliable_percent`.
pub const other_work_hundredths_max: u32 = 50;

/// How long each pause is. A quarter of a second: the kernel counts in ticks of 10 ms, so a pause
/// this long resolves one core's work to 4 hundredths, and the two pauses add half a second to a
/// run, under a tenth of the shortest run the runners take.
pub const gap_ns: u64 = 250 * std.time.ns_per_ms;

/// Ticks per second of the kernel's CPU accounting: `USER_HZ` on Linux and `CLK_TCK` on macOS,
/// both 100.
const ticks_per_second: u64 = 100;
const ns_per_tick: u64 = std.time.ns_per_s / ticks_per_second;

/// The bytes /proc/stat is read into. Its first line is what is needed, and it is under 200 bytes.
const proc_bytes_max = 4096;
const proc_path: [*:0]const u8 = "/proc/stat";

/// Busy time over wall time, in hundredths of one core. 0 when no wall time passed.
pub fn other_hundredths(busy_delta_ns: u64, wall_delta_ns: u64) u32 {
    if (wall_delta_ns == 0) return 0;
    return @intCast(@min(busy_delta_ns * scale / wall_delta_ns, std.math.maxInt(u32)));
}

/// One pause: sleeps `gap_ns` and reads how busy the machine was meanwhile. Null on a host that
/// reports no busy time, or when the sleep was cut short.
pub fn read_gap(io: std.Io) ?u32 {
    const busy_before = busy_ns() orelse return null;
    const wall_before = clock.now_ns();
    io.sleep(.fromNanoseconds(gap_ns), .awake) catch return null;
    const busy_after = busy_ns() orelse return null;
    const wall_after = clock.now_ns();
    assert(wall_after >= wall_before);
    return other_hundredths(busy_after -| busy_before, wall_after - wall_before);
}

/// The other work read across one series of runs.
///
/// A runner begins and ends every run of a candidate on one of these, and `disturbed` is what the
/// row's verdict reads: a series with a pause that other work filled was not taken on a quiet
/// machine, whatever its spread says.
pub const Window = struct {
    /// The pause with the most other work, in hundredths of one core.
    peak: u32 = 0,
    /// The sum of every reading, for the mean.
    total: u64 = 0,
    /// Readings taken. 0 means the host reports nothing, and every question below answers false.
    readings: u32 = 0,

    pub const empty: Window = .{};

    /// The pause before a run. `io` is what the sleep needs.
    pub fn begin_run(window: *Window, io: std.Io) void {
        window.add(read_gap(io) orelse return);
    }

    /// The pause after a run. Call it once the candidate's process has been waited for, so the
    /// pause holds nothing of the harness's.
    pub fn end_run(window: *Window, io: std.Io) void {
        window.add(read_gap(io) orelse return);
    }

    /// Adds one reading, which a test passes in directly.
    pub fn add(window: *Window, reading: u32) void {
        window.peak = @max(window.peak, reading);
        window.total += reading;
        window.readings += 1;
        assert(window.total >= window.peak);
    }

    /// True when the window holds a reading, so its numbers mean something.
    pub fn known(window: Window) bool {
        return window.readings >= 1;
    }

    /// The mean over the readings, in hundredths of one core. 0 when nothing was read.
    pub fn mean(window: Window) u32 {
        if (!window.known()) return 0;
        return @intCast(window.total / window.readings);
    }

    /// True when some pause held `other_work_hundredths_max` or more of other work.
    pub fn disturbed(window: Window) bool {
        return window.known() and window.peak >= other_work_hundredths_max;
    }
};

/// CPU time every processor has spent busy since boot, summed, in ns. Null on a host that
/// reports none.
fn busy_ns() ?u64 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => darwin_busy_ns(),
        .linux => linux_busy_ns(),
        else => null,
    };
}

/// `host_statistics` with `HOST_CPU_LOAD_INFO` answers four tick counts summed over every
/// processor: user, system, idle and nice, in that order.
const HostCpuLoadInfo = extern struct {
    cpu_ticks: [cpu_states]u32,
};
const cpu_states = 4;
const cpu_state_idle = 2;
const host_cpu_load_info: c_int = 3;

extern "c" fn host_statistics(
    host: std.c.mach_port_t,
    flavor: c_int,
    info: *HostCpuLoadInfo,
    count: *u32,
) std.c.kern_return_t;

fn darwin_busy_ns() ?u64 {
    if (comptime !builtin.os.tag.isDarwin()) return null;
    var info: HostCpuLoadInfo = undefined;
    var count: u32 = @sizeOf(HostCpuLoadInfo) / @sizeOf(u32);
    if (host_statistics(std.c.mach_host_self(), host_cpu_load_info, &info, &count) != 0) return null;
    return busy_ticks_of(info) * ns_per_tick;
}

/// Every state's ticks but idle's. A function of its own so a test can reach it on any host.
fn busy_ticks_of(info: HostCpuLoadInfo) u64 {
    var busy: u64 = 0;
    for (info.cpu_ticks, 0..) |ticks, state| {
        if (state != cpu_state_idle) busy += ticks;
    }
    return busy;
}

fn linux_busy_ns() ?u64 {
    if (comptime builtin.os.tag != .linux) return null;
    var buffer: [proc_bytes_max]u8 = undefined;
    const contents = read_proc(proc_path, &buffer) orelse return null;
    const ticks = parse_busy_ticks(contents) orelse return null;
    return ticks * ns_per_tick;
}

/// The head of a `/proc` file, through the system calls directly: Zig 0.16's `std.fs` opens a file
/// through an `Io`, and this file is read from a place that has none. Null when it cannot be read,
/// so a host that answers nothing leaves the row without a reading rather than with a wrong one.
fn read_proc(path: [*:0]const u8, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) return null;
    const linux = std.os.linux;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const opened = linux.openat(linux.AT.FDCWD, path, flags, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const descriptor: i32 = @intCast(opened);
    defer _ = linux.close(descriptor);
    const count = linux.read(descriptor, buffer.ptr, buffer.len);
    if (linux.errno(count) != .SUCCESS) return null;
    return buffer[0..count];
}

/// The fields of the first line of /proc/stat after `cpu`, in USER_HZ ticks summed over every
/// processor. Idle and iowait are not busy. Guest and guest_nice are already inside user and nice,
/// so counting them would count that time twice.
const stat_idle = 3;
const stat_iowait = 4;
const stat_guest = 8;
const stat_guest_nice = 9;
/// Every kernel since 2.6 prints at least these: user, nice, system, idle, iowait, irq, softirq.
const stat_fields_min = 7;

/// Busy ticks from the first line of /proc/stat. Null when the text is not that line.
///
/// A function of its own so a test can reach it: the parse is the only part of the Linux read that
/// is not a system call, and it is the part that can be wrong.
pub fn parse_busy_ticks(contents: []const u8) ?u64 {
    const end = std.mem.indexOfScalar(u8, contents, '\n') orelse contents.len;
    var fields = std.mem.tokenizeScalar(u8, contents[0..end], ' ');
    const label = fields.next() orelse return null;
    if (!std.mem.eql(u8, label, "cpu")) return null;
    var busy: u64 = 0;
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        const value = std.fmt.parseInt(u64, field, 10) catch return null;
        if (is_busy_field(index)) busy = std.math.add(u64, busy, value) catch return null;
    }
    if (index < stat_fields_min) return null;
    return busy;
}

fn is_busy_field(index: usize) bool {
    return index != stat_idle and index != stat_iowait and index != stat_guest and
        index != stat_guest_nice;
}

const testing = std.testing;

test "busy ticks are every field of the cpu line but idle, iowait, guest and guest_nice" {
    // user 100, nice 2, system 30, idle 900, iowait 8, irq 4, softirq 6, steal 1, guest 10,
    // guest_nice 1: busy is 100 + 2 + 30 + 4 + 6 + 1.
    const line = "cpu  100 2 30 900 8 4 6 1 10 1\ncpu0 50 1 15 450 4 2 3 0 5 0\n";
    try testing.expectEqual(@as(?u64, 143), parse_busy_ticks(line));
    // The seven fields every kernel prints, and no more.
    try testing.expectEqual(@as(?u64, 142), parse_busy_ticks("cpu 100 2 30 900 8 4 6"));
    // The line may end the text.
    try testing.expectEqual(@as(?u64, 142), parse_busy_ticks("cpu 100 2 30 900 8 4 6\n"));
}

test "macOS busy ticks are user, system and nice, and not idle" {
    // user 100, system 30, idle 900, nice 2, in the order the kernel answers them.
    try testing.expectEqual(@as(u64, 132), busy_ticks_of(.{ .cpu_ticks = .{ 100, 30, 900, 2 } }));
}

test "text that is not the cpu line is refused, not guessed at" {
    try testing.expectEqual(@as(?u64, null), parse_busy_ticks(""));
    try testing.expectEqual(@as(?u64, null), parse_busy_ticks("cpu0 1 2 3 4 5 6 7"));
    try testing.expectEqual(@as(?u64, null), parse_busy_ticks("cpu 1 2 3"));
    try testing.expectEqual(@as(?u64, null), parse_busy_ticks("cpu 1 2 x 4 5 6 7"));
    try testing.expectEqual(@as(?u64, null), parse_busy_ticks("intr 1 2 3 4 5 6 7"));
}

test "a reading is busy time over wall time, in hundredths of one core" {
    const second = std.time.ns_per_s;
    // Two cores busy for a second.
    try testing.expectEqual(@as(u32, 200), other_hundredths(2 * second, second));
    // Half a core for a quarter of a second, which is what a pause reads.
    try testing.expectEqual(@as(u32, 50), other_hundredths(second / 8, second / 4));
    // No wall time passed: no reading, and no division by zero.
    try testing.expectEqual(@as(u32, 0), other_hundredths(second, 0));
}

test "a window keeps the peak and the mean, and says when a pause was filled" {
    var window: Window = .empty;
    // Nothing read: every question answers false, and no number is invented.
    try testing.expect(!window.known());
    try testing.expect(!window.disturbed());
    try testing.expectEqual(@as(u32, 0), window.mean());

    window.add(20);
    window.add(49);
    try testing.expect(window.known());
    try testing.expectEqual(@as(u32, 49), window.peak);
    try testing.expectEqual(@as(u32, 34), window.mean());
    // Just under half a core is not marked.
    try testing.expect(!window.disturbed());

    // Half a core in one pause marks the series, whatever the others read.
    window.add(other_work_hundredths_max);
    try testing.expect(window.disturbed());
    try testing.expectEqual(@as(u32, 50), window.peak);
    try testing.expectEqual(@as(u32, 39), window.mean());
    try testing.expectEqual(@as(u32, 3), window.readings);
}

test "a run's two pauses are read on this host, and each lasts the gap" {
    const start = clock.now_ns();
    const reading = read_gap(testing.io) orelse return error.SkipZigTest;
    try testing.expect(clock.now_ns() - start >= gap_ns);
    // Whatever the host read, one pause on one machine is under a thousand cores busy.
    try testing.expect(reading <= scale * 1000);
    var window: Window = .empty;
    window.begin_run(testing.io);
    window.end_run(testing.io);
    try testing.expectEqual(@as(u32, 2), window.readings);
    try testing.expect(clock.now_ns() - start >= 3 * gap_ns);
}
