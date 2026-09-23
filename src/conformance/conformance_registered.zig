//! Registered descriptors (decision 2's registration row): an operation that names a descriptor
//! by its index in the list the loop registered does what the same operation does by descriptor.
//! Every scenario registers the descriptor under test at an index other than 0, behind another
//! open descriptor, so a backend that ignores the flag, or that resolves every index to the
//! first entry, reaches the wrong file and fails.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const tcp = @import("conformance_tcp.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const sync = backend.sync;

const block_bytes = 4096;

/// `operation`, naming index `index` of the registered descriptors where it named a descriptor.
fn registered(operation: Operation, index: core.Descriptor) Operation {
    var named = operation;
    named.descriptor_registered = true;
    switch (named.kind) {
        .accept => |*kind| kind.listener = index,
        .receive => |*kind| kind.socket = index,
        .send => |*kind| kind.socket = index,
        .shutdown => |*kind| kind.socket = index,
        .read => |*kind| kind.file = index,
        .write => |*kind| kind.file = index,
        .fdatasync => |*kind| kind.file = index,
        else => unreachable,
    }
    return named;
}

/// A receive into `buffer` with a deadline, on descriptor 0 until `registered` names its index.
fn receive(user_data: u64, buffer: []u8, timeout_ns: u64) Operation {
    var operation = Operation.receive(user_data, 0, buffer);
    operation.timeout_ns = timeout_ns;
    return operation;
}

test "a file named by its registered index is written, synced and read as by its descriptor" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init_blocking(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);

    var path_buffer: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/rotor_conformance_registered_{d}", .{
        backend.testing.directory, backend.testing.process_id(),
    });
    const file = try sync.open_file(path, .{ .create = true, .direct = true });
    defer sync.close_now(file);
    defer backend.testing.remove_file(path);
    try sync.set_file_size(file, 2 * block_bytes);
    try harness.loop.register_descriptors(&.{ listener.descriptor, file });

    var out: [block_bytes]u8 align(block_bytes) = undefined;
    for (&out, 0..) |*byte, index| byte.* = @truncate(index * 5 + 1);
    var events: [1]Event = undefined;
    try harness.submit(&.{registered(Operation.write(1, 0, &out, block_bytes), 1)}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, block_bytes), try events[0].outcome());

    const fdatasync: Operation = Operation.fdatasync(2, 0);
    try harness.submit(&.{registered(fdatasync, 1)}, &.{});
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 0), try events[0].outcome());

    // Read once by descriptor, which shows where the write landed, and once by index.
    const read: Operation = .{ .user_data = 3, .kind = .{ .read = .{
        .file = file,
        .buffer = undefined,
        .offset = block_bytes,
    } } };
    for ([_]bool{ false, true }) |by_index| {
        var in: [block_bytes]u8 align(block_bytes) = @splat(0);
        var operation = read;
        operation.kind.read.buffer = .{ .bytes = &in };
        try harness.submit(&.{if (by_index) registered(operation, 1) else operation}, &.{});
        try harness.collect(&events);
        try testing.expectEqual(@as(u32, block_bytes), try events[0].outcome());
        try testing.expectEqualSlices(u8, &out, &in);
    }
}

const deadline_ns = 20 * core.constants.ns_per_ms;

test "sockets named by registered index carry bytes, time out, shut down, and accept" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init_blocking(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);
    try harness.loop.register_descriptors(&.{ pair[0], pair[1], listener.descriptor });

    // Bytes from index 0 to index 1, and a receive on index 0 that nothing answers.
    var in: [8]u8 = @splat(0);
    var idle: [8]u8 = undefined;
    try harness.submit(&.{
        registered(Operation.send(1, 0, "by index"), 0),
        registered(receive(2, &in, 0), 1),
        registered(receive(3, &idle, deadline_ns), 0),
    }, &.{});
    var events: [3]Event = undefined;
    try harness.collect(&events);
    try testing.expectEqual(@as(u32, 8), try (try Harness.find(&events, 1)).outcome());
    try testing.expectEqual(@as(u32, 8), try (try Harness.find(&events, 2)).outcome());
    try testing.expectEqualStrings("by index", &in);
    try testing.expectError(error.Timeout, (try Harness.find(&events, 3)).outcome());

    // Index 0 shuts its sending side, and index 1 reads the end of the stream.
    const shutdown: Operation = Operation.shutdown(4, 0, .send);
    try harness.submit(&.{ registered(shutdown, 0), registered(receive(5, &in, 0), 1) }, &.{});
    try harness.collect(events[0..2]);
    try testing.expectEqual(@as(u32, 0), try (try Harness.find(events[0..2], 4)).outcome());
    try testing.expectEqual(@as(u32, 0), try (try Harness.find(events[0..2], 5)).outcome());

    try accept_by_index(&harness, &listener);
}

/// A multishot accept on the registered listener takes a connection, and a cancel ends it.
fn accept_by_index(harness: *Harness, listener: *const tcp.Listener) !void {
    var handles: [1]Handle = undefined;
    try harness.submit(&.{registered(Operation.accept(6, 0, true), 2)}, &handles);
    const client = try sync.open_socket(.ipv4);
    defer sync.close_now(client);
    try harness.submit(&.{Operation.connect(7, client, &listener.address)}, &.{});
    var events: [2]Event = undefined;
    try harness.collect(&events);
    const accepted = try Harness.find(&events, 6);
    try testing.expect(accepted.flags.more);
    sync.close_now(@intCast(try accepted.outcome()));
    try testing.expectEqual(@as(u32, 0), try (try Harness.find(&events, 7)).outcome());

    harness.loop.cancel(handles[0]);
    try harness.collect(events[0..1]);
    try testing.expectEqual(@as(u64, 6), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expect(!events[0].flags.more);
}

test "register_descriptors refuses a descriptor that is not open, and the loop may register after" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init_blocking(0, null);
    defer harness.deinit();
    const open = try sync.open_socket(.ipv4);
    defer sync.close_now(open);
    const closed = try sync.open_socket(.ipv4);
    sync.close_now(closed);

    const refused = harness.loop.register_descriptors(&.{ open, closed });
    try testing.expectError(error.DescriptorInvalid, refused);
    try harness.loop.register_descriptors(&.{open});
}
