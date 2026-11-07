//! Operations that name a record and that the loop ends itself (decision 26). The `refuse` policy
//! ends a file read at the flush, and the caller's offload runs one on its own thread (decision 18).
//! A write names a registered descriptor and a registered buffer. On kqueue and epoll each final
//! event comes from the loop's own list of finished operations, and not from the kernel's answer.
//! Each scenario requires the event to reach its record, and the tick to hand its caller nothing.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const offload = @import("conformance_offload.zig");

const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

const block_bytes = offload.block_bytes;
const wait_ns = 10 * core.constants.ns_per_ms;

const path_format = "{s}/rotor_conformance_dispatch_{d}";

/// The path of the write scenario's file, with a file a killed run left there removed.
fn scratch(buffer: []u8) anyerror![:0]const u8 {
    const arguments = .{ backend.testing.directory, backend.testing.process_id() };
    return conformance.scratch_path(buffer, path_format, arguments);
}

test "a file a killed run left at the write scenario's path does not stop the scenario" {
    if (conformance.unsupported()) return error.SkipZigTest;
    try conformance.expect_stale_file_removed(path_format, scratch);
}

/// One library's record: the last event it received, and how many of them were final.
const Library = struct {
    completion: core.Completion = .init(Library, "completion", called),
    last: ?Event = null,
    finals: u32 = 0,

    fn called(library: *Library, event: Event) void {
        std.debug.assert(event.flags.dispatched);
        library.last = event;
        if (!event.flags.more) library.finals += 1;
    }
};

/// Submits `operation` with `library`'s record, ticks until the record has the final event, and
/// returns that event. Fails when a tick hands its caller an event, which carried no record.
fn reach_record(loop: *backend.Loop, operation: Operation, library: *Library) !Event {
    const named = operation.completion(&library.completion);
    if (loop.submit(&.{named}, &.{}) != 1) return error.TableFull;
    var events: [1]Event = undefined;
    var round: u32 = 0;
    while (library.finals == 0 and round < conformance.collect_rounds_max) : (round += 1) {
        try testing.expectEqual(@as(u32, 0), try loop.tick(&events, wait_ns));
    }
    try testing.expectEqual(@as(u32, 1), library.finals);
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
    return library.last.?;
}

// Each static restates its type's alignment, as `conformance_offload.zig` says why.
var loop_fixture: offload.Fixture align(@alignOf(offload.Fixture)) = undefined;
var worker_pool: offload.Pool align(@alignOf(offload.Pool)) = undefined;

test "a file read that the refuse policy ends at the flush reaches its record" {
    if (conformance.unsupported()) return error.SkipZigTest;
    try loop_fixture.init(.refuse, null);
    defer loop_fixture.deinit();
    var into: [block_bytes]u8 align(block_bytes) = @splat(0);
    var library: Library = .{};
    const read = Operation.read(0, loop_fixture.file, &into, 0);
    const event = try reach_record(&loop_fixture.loop, read, &library);
    if (backend.files_block) {
        try testing.expectError(error.Unsupported, event.outcome());
    } else {
        // io_uring takes the policy and ignores it: the kernel reads the block.
        try testing.expectEqual(@as(u32, block_bytes), try event.outcome());
    }
}

test "a file read that the caller's offload runs reaches its record" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    try worker_pool.start();
    try loop_fixture.init(.offload, &worker_pool);
    defer {
        // The pool stops first, because a worker reads the loop after it hands back the result.
        worker_pool.stop();
        loop_fixture.deinit();
    }
    var into: [block_bytes]u8 align(block_bytes) = @splat(0xaa);
    var library: Library = .{};
    const read = Operation.read(0, loop_fixture.file, &into, 0);
    const event = try reach_record(&loop_fixture.loop, read, &library);
    try testing.expectEqual(@as(u32, block_bytes), try event.outcome());
    worker_pool.stop();
    try testing.expectEqual(@as(u32, 1), worker_pool.served.load(.monotonic));
}

test "a write on a registered descriptor from a registered buffer reaches its record" {
    // Known at compile time, so a host that cannot run the backend does not compile the rest:
    // io_uring's buffer registration does not compile for macOS.
    if (comptime conformance.unsupported()) return error.SkipZigTest;
    var harness: conformance.Harness = undefined;
    try harness.init_blocking(0, null);
    defer harness.deinit();
    var path_buffer: [96]u8 = undefined;
    const path = try scratch(&path_buffer);
    const file = try sync.open_file(path, .{ .create = true, .direct = true });
    defer sync.close_now(file);
    defer backend.testing.remove_file(path);
    try sync.set_file_size(file, block_bytes);
    var out: [block_bytes]u8 align(block_bytes) = @splat(5);
    try harness.loop.register_descriptors(&.{file});
    try harness.loop.register_buffers(&.{&out});

    const write: Operation = .{ .user_data = 0, .descriptor_registered = true, .kind = .{ .write = .{
        .file = 0,
        .buffer = .{ .bytes = &out, .registered = 0 },
        .offset = 0,
    } } };
    var library: Library = .{};
    const event = try reach_record(&harness.loop, write, &library);
    try testing.expectEqual(@as(u32, block_bytes), try event.outcome());
}
