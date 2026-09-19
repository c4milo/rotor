//! File scenarios: what decision 2's file row promises, with O_DIRECT where the host has it.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

/// The unit O_DIRECT transfers in: every buffer address, offset and length is a multiple of it.
const block_bytes = 4096;
const file_blocks = 4;

test "a block written and synced reads back, and a read past the end returns 0" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();

    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/rotor_conformance_file_{d}", .{
        backend.testing.directory, backend.testing.process_id(),
    });
    const file = try sync.open_file(path, .{ .create = true, .direct = true });
    defer sync.close_now(file);
    defer backend.testing.remove_file(path);
    try sync.set_file_size(file, file_blocks * block_bytes);
    try testing.expectEqual(@as(u64, file_blocks * block_bytes), try sync.file_size(file));

    var out: [block_bytes]u8 align(block_bytes) = undefined;
    for (&out, 0..) |*byte, index| byte.* = @truncate(index * 7 + 3);
    var in: [block_bytes]u8 align(block_bytes) = @splat(0);
    var events: [1]Event = undefined;

    try harness.submit(&.{.{ .user_data = 1, .kind = .{ .write = .{
        .file = file,
        .buffer = .{ .bytes = &out },
        .offset = 2 * block_bytes,
    } } }}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, block_bytes), try events[0].outcome());

    try harness.submit(&.{.{ .user_data = 2, .kind = .{ .fdatasync = .{ .file = file } } }}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 0), try events[0].outcome());

    try harness.submit(&.{.{ .user_data = 3, .kind = .{ .read = .{
        .file = file,
        .buffer = .{ .bytes = &in },
        .offset = 2 * block_bytes,
    } } }}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, block_bytes), try events[0].outcome());
    try testing.expectEqualSlices(u8, &out, &in);

    try harness.submit(&.{.{ .user_data = 4, .kind = .{ .read = .{
        .file = file,
        .buffer = .{ .bytes = &in },
        .offset = file_blocks * block_bytes,
    } } }}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 0), try events[0].outcome());
}
