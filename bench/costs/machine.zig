//! The machine a run was made on, printed above the table: a number in docs/costs.md belongs to
//! the machine its column names (rule 1), so every run says where it ran.
//!
//! On macOS the facts come from `sysctl`. The cache sizes are printed per core kind, because
//! `hw.l1dcachesize` and `hw.l2cachesize` answer for the efficiency cores and the probes run on
//! the performance cores. On any other OS this file prints what `uname` knows and says what it
//! did not read.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const Writer = std.Io.Writer;

/// The longest sysctl string this file reads: the CPU brand, an OS version.
const text_bytes_max = 128;

/// Byte units, largest first, for printing a size in the largest unit that divides it.
const units = [_]struct { bytes: u64, name: []const u8 }{
    .{ .bytes = 1 << 30, .name = "GiB" },
    .{ .bytes = 1 << 20, .name = "MiB" },
    .{ .bytes = 1 << 10, .name = "KiB" },
    .{ .bytes = 1, .name = "bytes" },
};

comptime {
    // `sysctl_integer` reads a 4-byte answer into the low half of a u64.
    assert(builtin.cpu.arch.endian() == .little);
}

pub fn print(writer: *Writer) Writer.Error!void {
    switch (builtin.os.tag) {
        .macos => try print_macos(writer),
        else => try print_uname(writer),
    }
    try writer.print("zig: {s}, {s}\n", .{ builtin.zig_version_string, @tagName(builtin.mode) });
    try print_date(writer);
}

fn print_macos(writer: *Writer) Writer.Error!void {
    var brand: [text_bytes_max]u8 = undefined;
    try writer.print("machine: {s}, ", .{sysctl_text("machdep.cpu.brand_string", &brand)});
    try print_count(writer, sysctl_integer("hw.perflevel0.physicalcpu"));
    try writer.writeAll(" performance and ");
    try print_count(writer, sysctl_integer("hw.perflevel1.physicalcpu"));
    try writer.writeAll(" efficiency cores, ");
    try print_size(writer, sysctl_integer("hw.memsize"));
    try writer.writeAll(" memory\ncaches: performance core L1d ");
    try print_size(writer, sysctl_integer("hw.perflevel0.l1dcachesize"));
    try writer.writeAll(" and L2 ");
    try print_size(writer, sysctl_integer("hw.perflevel0.l2cachesize"));
    try writer.writeAll(", efficiency core L1d ");
    try print_size(writer, sysctl_integer("hw.perflevel1.l1dcachesize"));
    try writer.writeAll(" and L2 ");
    try print_size(writer, sysctl_integer("hw.perflevel1.l2cachesize"));
    try writer.writeAll(", line ");
    try print_size(writer, sysctl_integer("hw.cachelinesize"));
    try writer.writeAll(", page ");
    try print_size(writer, sysctl_integer("hw.pagesize"));

    var product: [text_bytes_max]u8 = undefined;
    var release: [text_bytes_max]u8 = undefined;
    try writer.print("\nos: macOS {s}, Darwin {s}\n", .{
        sysctl_text("kern.osproductversion", &product),
        sysctl_text("kern.osrelease", &release),
    });
}

fn print_uname(writer: *Writer) Writer.Error!void {
    const uts = posix.uname();
    try writer.print("machine: {s}; the CPU model, the core count and the memory are not" ++
        " read on this OS, record them by hand\n", .{std.mem.sliceTo(&uts.machine, 0)});
    try writer.print("os: {s} {s}\n", .{
        std.mem.sliceTo(&uts.sysname, 0),
        std.mem.sliceTo(&uts.release, 0),
    });
}

/// The date of the run, from the wall clock, in UTC.
fn print_date(writer: *Writer) Writer.Error!void {
    var time: posix.timespec = undefined;
    const rc = posix.system.clock_gettime(.REALTIME, &time);
    assert(posix.errno(rc) == .SUCCESS);
    assert(time.sec >= 0);
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(time.sec) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    try writer.print("date: {d}-{d:0>2}-{d:0>2} (UTC)\n", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
    });
}

fn print_count(writer: *Writer, value: ?u64) Writer.Error!void {
    const count = value orelse return writer.writeAll("an unknown number of");
    try writer.print("{d}", .{count});
}

fn print_size(writer: *Writer, value: ?u64) Writer.Error!void {
    const bytes = value orelse return writer.writeAll("unknown");
    for (units) |unit| {
        if (bytes % unit.bytes != 0) continue;
        return writer.print("{d} {s}", .{ bytes / unit.bytes, unit.name });
    }
    unreachable; // The last unit is 1 byte, which divides every size.
}

fn sysctl_integer(name: [*:0]const u8) ?u64 {
    var value: u64 = 0;
    var value_bytes: usize = @sizeOf(u64);
    if (std.c.sysctlbyname(name, &value, &value_bytes, null, 0) != 0) return null;
    assert(value_bytes == @sizeOf(u32) or value_bytes == @sizeOf(u64));
    return value;
}

fn sysctl_text(name: [*:0]const u8, buffer: *[text_bytes_max]u8) []const u8 {
    var text_bytes: usize = buffer.len;
    if (std.c.sysctlbyname(name, buffer, &text_bytes, null, 0) != 0) return "unknown";
    assert(text_bytes <= buffer.len);
    // The kernel counts the terminating zero in the length.
    return std.mem.sliceTo(buffer[0..text_bytes], 0);
}
