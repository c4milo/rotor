//! What `Machine` records about a block device: whether it holds writes in a volatile cache.
//!
//! **A durable write row cannot be read without this.** `fdatasync` on a drive that reports
//! `write back` issues a FLUSH the drive must honour, which costs; on one that reports
//! `write through`, usually an enterprise NVMe with power-loss protection, there is nothing volatile
//! to flush and the call is nearly free. So one durable row means opposite things on the two, and a
//! number without its machine is not evidence (docs/costs.md).
//!
//! macOS has no equivalent. There is no sysctl for a drive's write cache, so the field stays empty
//! there and the record says `unknown` rather than implying the drive is one thing or the other.
const std = @import("std");
const text = @import("text.zig");

const Text = text.Text;

/// Where Linux reports whether a block device holds writes in a volatile cache: `write back` when it
/// does and `write through` when it does not.
///
/// A durable write row cannot be read without it. `fdatasync` on a drive that reports `write back`
/// issues a FLUSH the drive must honour, which costs; on one that reports `write through`, usually
/// an enterprise NVMe with power-loss protection, there is nothing volatile to flush and the call is
/// nearly free. So the same durable row means opposite things on the two, and a number without its
/// machine is not evidence (docs/costs.md).
const block_directory = "/sys/block";
const write_cache_leaf = "/queue/write_cache";

/// Block devices whose write cache the record reads. NVMe is the destination rotor is measured for,
/// and a machine with more than this many is not one these rows describe.
const block_devices_max = 8;

/// Fills `into` with each NVMe device's write-cache setting. A host with none leaves it empty, and
/// the record then says `unknown` rather than implying the drive is one thing or the other.
fn read_write_caches(io: std.Io, into: *Text) void {
    var listing = std.Io.Dir.cwd().openDir(io, block_directory, .{ .iterate = true }) catch return;
    defer listing.close(io);

    var line: [text.text_bytes_max]u8 = undefined;
    var used: usize = 0;
    var found: u32 = 0;
    var entries = listing.iterate();
    while (found < block_devices_max) {
        const entry = (entries.next(io) catch return) orelse break;
        if (!std.mem.startsWith(u8, entry.name, "nvme")) continue;
        found += 1;
        const setting = read_setting(io, entry.name) orelse continue;
        used += append(line[used..], used == 0, entry.name, setting) orelse break;
    }
    if (used != 0) into.set(line[0..used]);
}

/// One device's `write_cache` file, trimmed, or null when the host does not answer.
fn read_setting(io: std.Io, device: []const u8) ?[]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}{s}", .{
        block_directory, device, write_cache_leaf,
    }) catch return null;
    // The value is copied into `setting_buffer`, which outlives the call: a caller only reads it
    // before the next call, and there is one caller.
    const value = std.Io.Dir.cwd().readFile(io, path, &setting_buffer) catch return null;
    const setting = std.mem.trim(u8, value, " \n\r\t");
    return if (setting.len == 0) null else setting;
}

var setting_buffer: [text.text_bytes_max]u8 = undefined;

/// Writes `device setting` into `into`, with `; ` in front when it is not the first. Null when it
/// does not fit, which stops the scan rather than cutting a name in half.
fn append(into: []u8, first: bool, device: []const u8, setting: []const u8) ?usize {
    const written = std.fmt.bufPrint(into, "{s}{s} {s}", .{
        if (first) "" else "; ", device, setting,
    }) catch return null;
    return written.len;
}

const testing = std.testing;
const builtin = @import("builtin");

test "a host with no NVMe report leaves the write cache empty, and claims nothing" {
    // macOS has no sysctl for a drive's write cache, and a Linux host without NVMe has no file. The
    // field must stay empty in both: a durable write row on an unknown drive is uninterpretable, and
    // saying so is the only honest answer (docs/costs.md, and `unknown` everywhere else here).
    var into: Text = .{};
    read_write_caches(testing.io, &into);
    if (builtin.os.tag != .linux) {
        try testing.expectEqualStrings("", into.slice());
    }
}

test "the write cache is read for NVMe alone, and bounded" {
    // The destination rotor is measured for. A machine with more devices than this is not one these
    // rows describe, and the scan stops rather than overrunning the record's fixed text.
    try testing.expect(block_devices_max >= 1);
    try testing.expectEqualStrings("/sys/block", block_directory);
    try testing.expectEqualStrings("/queue/write_cache", write_cache_leaf);
}
