//! File scenarios: what decision 2's file row promises, with O_DIRECT where the host has it.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const Operation = core.Operation;
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const sync = backend.sync;

/// The unit O_DIRECT transfers in: every buffer address, offset and length is a multiple of it.
const block_bytes = 4096;
const file_blocks = 4;

const path_format = "{s}/rotor_conformance_file_{d}";

/// The path of the scenario's file, with a file a killed run left there removed.
fn scratch(buffer: []u8) anyerror![:0]const u8 {
    const arguments = .{ backend.testing.directory, backend.testing.process_id() };
    return conformance.scratch_path(buffer, path_format, arguments);
}

test "a file a killed run left at the scenario's path does not stop the scenario" {
    if (conformance.unsupported()) return error.SkipZigTest;
    try conformance.expect_stale_file_removed(path_format, scratch);
}

test "a block written and synced reads back, and a read past the end returns 0" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init_blocking(0, null);
    defer harness.deinit();

    var path_buffer: [96]u8 = undefined;
    const path = try scratch(&path_buffer);
    const file = try sync.open_file(path, .{ .create = true, .direct = true });
    defer sync.close_now(file);
    defer backend.testing.remove_file(path);
    try sync.set_file_size(file, file_blocks * block_bytes);
    try testing.expectEqual(@as(u64, file_blocks * block_bytes), try sync.file_size(file));

    var out: [block_bytes]u8 align(block_bytes) = undefined;
    for (&out, 0..) |*byte, index| byte.* = @truncate(index * 7 + 3);
    var in: [block_bytes]u8 align(block_bytes) = @splat(0);
    var events: [1]Event = undefined;

    try harness.submit(&.{Operation.write(1, file, &out, 2 * block_bytes)}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, block_bytes), try events[0].outcome());

    try harness.submit(&.{Operation.fdatasync(2, file)}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 0), try events[0].outcome());

    try harness.submit(&.{Operation.fsync(5, file)}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u64, 5), events[0].user_data);
    try testing.expectEqual(@as(u32, 0), try events[0].outcome());

    try harness.submit(&.{Operation.read(3, file, &in, 2 * block_bytes)}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, block_bytes), try events[0].outcome());
    try testing.expectEqualSlices(u8, &out, &in);

    try harness.submit(&.{Operation.read(4, file, &in, file_blocks * block_bytes)}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 0), try events[0].outcome());
}
