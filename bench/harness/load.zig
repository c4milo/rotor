//! The machine's load average, and the window of it a series of runs was taken inside.
//!
//! Four measurement attempts on 2026-09-20 were spoiled by other work arriving on the machine, and
//! only their spread said so. The last one ran the full macOS echo matrix while the load average
//! climbed from 4.40 to 10.27; 13 of 16 rows came back marked, and reading the marks was the only
//! way to learn the machine had not been quiet. A run cannot certify a machine in advance, because
//! the job that spoils it arrives part way through. So the harness samples the load around every
//! run and marks the row when it moved.
//!
//! **Hundredths, not a fraction.** `report.zig` prints every number as an integer and lets no
//! floating point take part. The load average is a fraction, so this file carries it multiplied by
//! 100: a load of 8.10 is 810. Neither platform's read needs a float to produce that.
//!
//! macOS answers `sysctl vm.loadavg`, whose `struct loadavg` holds the three averages as fixed
//! point integers with their own scale, so the conversion is one multiply and one divide. Linux has
//! no such sysctl and answers in the text of /proc/loadavg, which this file parses the way
//! `machine_proc.zig` parses the other /proc files.
//!
//! A host that answers neither gives null, and a row taken on it carries no load. The record never
//! guesses, which is the rule `machine.zig` states for its own fields.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The multiplier a load average is carried at: 8.10 becomes 810.
pub const scale: u32 = 100;

/// The bytes /proc/loadavg is read into. The whole file is under 64 bytes; this is room to spare.
const proc_bytes_max = 128;

const proc_path = "/proc/loadavg";

/// How far the load may move across a series before the row is marked, in hundredths. One whole
/// point of load average: on the 2026-09-20 attempt it moved by almost six, and a run that moves by
/// one has had something arrive or leave while it was measuring.
///
/// It is the harness's own threshold and not a measured constant, like
/// `series.spread_unreliable_percent`.
pub const moved_hundredths: u32 = 100;

/// The one-minute load average in hundredths, or null when the host does not report it.
pub fn hundredths() ?u32 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => darwin_hundredths(),
        .linux => linux_hundredths(),
        else => null,
    };
}

/// `vm.loadavg` holds `struct loadavg`: three fixed point averages and the scale they are in.
fn darwin_hundredths() ?u32 {
    if (builtin.os.tag != .macos) return null;
    const LoadAverage = extern struct {
        ldavg: [3]u32,
        fscale: c_long,
    };
    var value: LoadAverage = undefined;
    var len: usize = @sizeOf(LoadAverage);
    if (std.c.sysctlbyname("vm.loadavg", &value, &len, null, 0) != 0) return null;
    if (len != @sizeOf(LoadAverage)) return null;
    if (value.fscale <= 0) return null;
    const fscale: u64 = @intCast(value.fscale);
    return @intCast(@as(u64, value.ldavg[0]) * scale / fscale);
}

/// /proc/loadavg begins with the one-minute average, as `0.42`, then two more and a task count.
fn linux_hundredths() ?u32 {
    if (builtin.os.tag != .linux) return null;
    var buffer: [proc_bytes_max]u8 = undefined;
    const file = std.fs.openFileAbsolute(proc_path, .{}) catch return null;
    defer file.close();
    const read = file.read(&buffer) catch return null;
    return parse_first(buffer[0..read]);
}

/// The first field of /proc/loadavg, in hundredths. Null when the text is not a load average.
///
/// A function of its own so a test can reach it: the parse is the only part of the Linux read that
/// is not a system call, and it is the part that can be wrong.
pub fn parse_first(contents: []const u8) ?u32 {
    const end = std.mem.indexOfAny(u8, contents, " \n") orelse contents.len;
    const field = contents[0..end];
    const dot = std.mem.indexOfScalar(u8, field, '.') orelse {
        // A whole number with no fraction is still a load average.
        const whole = std.fmt.parseInt(u32, field, 10) catch return null;
        return std.math.mul(u32, whole, scale) catch null;
    };
    const whole = std.fmt.parseInt(u32, field[0..dot], 10) catch return null;
    const fraction_text = field[dot + 1 ..];
    if (fraction_text.len == 0) return null;
    // Two digits, because the value is carried in hundredths. Linux prints two; a kernel that
    // printed more would have the rest dropped, and one that printed one digit is read as tens.
    const digits = @min(fraction_text.len, 2);
    var fraction = std.fmt.parseInt(u32, fraction_text[0..digits], 10) catch return null;
    if (digits == 1) fraction *= 10;
    const scaled = std.math.mul(u32, whole, scale) catch return null;
    return std.math.add(u32, scaled, fraction) catch null;
}

/// The lowest and highest load seen across one series of runs.
///
/// A caller samples around every run and keeps one of these per series. `moved` is what a row's
/// verdict reads: a series whose window is wide was not taken on one machine, whatever its spread
/// happens to say.
pub const Window = struct {
    lowest: u32 = std.math.maxInt(u32),
    highest: u32 = 0,
    /// Samples taken. 0 means the host reports no load, and every question below answers false.
    samples: u32 = 0,

    pub const empty: Window = .{};

    /// Takes one sample now. A host that reports nothing leaves the window untouched.
    pub fn sample(window: *Window) void {
        window.add(hundredths() orelse return);
    }

    /// Adds a reading, which a test passes in directly.
    pub fn add(window: *Window, reading: u32) void {
        window.lowest = @min(window.lowest, reading);
        window.highest = @max(window.highest, reading);
        window.samples += 1;
        assert(window.lowest <= window.highest);
    }

    /// True when the window holds a reading, so its numbers mean something.
    pub fn known(window: Window) bool {
        return window.samples >= 1;
    }

    /// How far the load moved across the series, in hundredths. 0 when nothing was sampled.
    pub fn span(window: Window) u32 {
        if (!window.known()) return 0;
        return window.highest - window.lowest;
    }

    /// True when the load moved more than `moved_hundredths` while the series was measured. A row
    /// this describes was not taken on one machine.
    pub fn moved(window: Window) bool {
        return window.known() and window.span() >= moved_hundredths;
    }
};

const testing = std.testing;

test "a load average is read in hundredths, with or without a fraction" {
    try testing.expectEqual(@as(?u32, 42), parse_first("0.42 0.38 0.35 1/234 5678"));
    try testing.expectEqual(@as(?u32, 810), parse_first("8.10 8.00 7.24 2/1000 1"));
    try testing.expectEqual(@as(?u32, 1027), parse_first("10.27 9.00 8.00 1/1 1"));
    try testing.expectEqual(@as(?u32, 0), parse_first("0.00 0.00 0.00 1/1 1"));

    // One digit of fraction is tens, not hundredths, or every such reading would read as 100 times
    // too small.
    try testing.expectEqual(@as(?u32, 450), parse_first("4.5 1.0 1.0 1/1 1"));
    // More than two digits: the rest is dropped rather than changing the scale.
    try testing.expectEqual(@as(?u32, 456), parse_first("4.5678 1.0 1.0 1/1 1"));
    // A whole number with no dot at all.
    try testing.expectEqual(@as(?u32, 700), parse_first("7 1.0 1.0 1/1 1"));
    // The field may end the text, with no space after it.
    try testing.expectEqual(@as(?u32, 125), parse_first("1.25"));
    try testing.expectEqual(@as(?u32, 125), parse_first("1.25\n"));
}

test "text that is not a load average is refused, not guessed at" {
    try testing.expectEqual(@as(?u32, null), parse_first(""));
    try testing.expectEqual(@as(?u32, null), parse_first("\n"));
    try testing.expectEqual(@as(?u32, null), parse_first("x.yz 1.0"));
    try testing.expectEqual(@as(?u32, null), parse_first("1. 1.0"));
    try testing.expectEqual(@as(?u32, null), parse_first("-1.00 1.0"));
    try testing.expectEqual(@as(?u32, null), parse_first(".5 1.0"));
}

test "a window holds the lowest and highest, and says when the load moved" {
    var window: Window = .empty;
    // Nothing sampled: every question answers false, and no number is invented.
    try testing.expect(!window.known());
    try testing.expect(!window.moved());
    try testing.expectEqual(@as(u32, 0), window.span());

    window.add(440);
    try testing.expect(window.known());
    try testing.expectEqual(@as(u32, 0), window.span());
    try testing.expect(!window.moved());

    // Half a point of movement is under the threshold.
    window.add(490);
    try testing.expectEqual(@as(u32, 50), window.span());
    try testing.expect(!window.moved());

    // The 2026-09-20 attempt: 4.40 to 10.27, which is what this exists to catch.
    window.add(1027);
    try testing.expectEqual(@as(u32, 587), window.span());
    try testing.expect(window.moved());
    try testing.expectEqual(@as(u32, 440), window.lowest);
    try testing.expectEqual(@as(u32, 1027), window.highest);
    try testing.expectEqual(@as(u32, 3), window.samples);
}

test "the threshold is one whole point of load average" {
    var window: Window = .empty;
    window.add(100);
    window.add(100 + moved_hundredths - 1);
    try testing.expect(!window.moved());
    window.add(100 + moved_hundredths);
    try testing.expect(window.moved());
}

test "this host reports a load average, or says it does not" {
    // Both platforms the harness runs on report one. The assertion is on the shape and not on the
    // value: a machine's load is whatever it is.
    const reading = hundredths();
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        try testing.expect(reading != null);
        // A load average above 10,000 would be 100 runnable threads per core on any machine the
        // harness runs on, which means the read found something other than a load average.
        try testing.expect(reading.? < 1_000_000);
    }
}
