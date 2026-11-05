//! The adapter's file calls (decision 22, step 3): on the loop when its policy lets it, and through
//! `rest` when the loop refuses.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const rotor = @import("../rotor.zig");
const adapter_module = @import("adapter.zig");
const fixtures = @import("adapter_test.zig");
const Fixture = fixtures.Fixture;

/// The calls that reached `rest`, counted by a table that wraps the fixture's own.
var rest_calls: u32 = 0;
var wrapped: *const Io.VTable = undefined;

fn counting_read(userdata: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
    rest_calls += 1;
    return wrapped.fileReadPositional(userdata, file, data, offset);
}

fn counting_write(
    userdata: ?*anyopaque,
    file: Io.File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) Io.File.WritePositionalError!usize {
    rest_calls += 1;
    return wrapped.fileWritePositional(userdata, file, header, data, splat, offset);
}

fn counting_sync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    rest_calls += 1;
    return wrapped.fileSync(userdata, file);
}

/// Writes, syncs and reads back one file through the adapter, and returns how many of those three
/// calls reached `rest`.
fn round_trip(setup: fixtures.Setup) !u32 {
    var fixture: Fixture = undefined;
    try fixture.init_with(setup);
    defer fixture.deinit();
    wrapped = fixture.threaded.io().vtable;
    var table = wrapped.*;
    table.fileReadPositional = counting_read;
    table.fileWritePositional = counting_write;
    table.fileSync = counting_sync;
    fixture.adapter.rest = .{ .userdata = &fixture.threaded, .vtable = &table };
    rest_calls = 0;
    const io = fixture.io();

    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    const file = try directory.dir.createFile(testing.io, "adapter", .{ .read = true });
    try testing.expectEqual(4, try io.vtable.fileWritePositional(io.userdata, file, "", &.{"tail"}, 1, 4));
    try testing.expectEqual(4, try io.vtable.fileWritePositional(io.userdata, file, "head", &.{""}, 0, 0));
    try io.vtable.fileSync(io.userdata, file);
    var bytes: [8]u8 = undefined;
    var empty: [0]u8 = .{};
    var data = [_][]u8{ &empty, &bytes };
    try testing.expectEqual(8, try io.vtable.fileReadPositional(io.userdata, file, &data, 0));
    try testing.expectEqualStrings("headtail", &bytes);
    io.vtable.fileClose(io.userdata, &.{file});
    try testing.expectEqual(0, fixture.loop.in_flight());
    return rest_calls;
}

test "a loop that refuses files hands the calls to rest, except on io_uring" {
    if (!adapter_module.supported) return error.SkipZigTest;
    const calls = try round_trip(.{ .file_policy = .refuse });
    // Two writes, a sync and a read. io_uring runs files whatever the policy says.
    try testing.expectEqual(@as(u32, if (rotor.backend() == .uring) 0 else 4), calls);
}

test "a loop that runs files inline runs every call itself" {
    if (!adapter_module.supported) return error.SkipZigTest;
    try testing.expectEqual(0, try round_trip(.{ .file_policy = .blocking }));
}
