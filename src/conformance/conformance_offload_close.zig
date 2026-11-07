//! A close waits for the operations out on its descriptor (decision 5, rule 6, and decision 18,
//! ruling (d) of 2026-11-06). A worker owns an operation out until its result comes back, so the
//! loop keeps the close and closes the descriptor after that result.
//!
//! Each scenario hands one read or write of a second descriptor of the fixture's file to a worker
//! that holds, and then submits a close of that descriptor. The close must wait: no event comes,
//! and the descriptor stays open. The scenario then opens an empty file. A close that did not wait
//! gave its number to that file, so the worker's call would read or write the wrong file. Last,
//! the worker answers: its event comes first, with its whole transfer, and the close's event
//! follows.
//!
//! It runs where a file operation blocks the loop: on kqueue and epoll. On io_uring the scenarios
//! skip, as `conformance_offload_limit.zig` does.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const limit = @import("conformance_offload_limit.zig");

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Fixture = limit.Fixture;
const sync = backend.sync;

/// The user data of the file operation out on the worker.
const transfer_user_data = 0;
/// The user data of the close behind it.
const close_user_data = 1;
/// The events a scenario expects after the worker answers: the transfer's and the close's.
const events_expected = 2;
/// The wait of each tick while a scenario waits for the worker.
const tick_wait_ns = 10 * core.constants.ns_per_ms;

// Restates its type's alignment, as every static of the suite does: Zig 0.16's own x86-64 backend
// places a static without it unless the static declares it.
var close_fixture: Fixture align(@alignOf(Fixture)) = undefined;

const path_format = "{s}/rotor_offload_close_{d}";

/// The path of the decoy's file, with a file a killed run left there removed.
fn scratch(buffer: []u8) anyerror![:0]const u8 {
    const arguments = .{ backend.testing.directory, backend.testing.process_id() };
    return conformance.scratch_path(buffer, path_format, arguments);
}

test "a file a killed run left at the decoy's path does not stop the decoy" {
    if (conformance.unsupported()) return error.SkipZigTest;
    try conformance.expect_stale_file_removed(path_format, scratch);
}

/// An empty file, opened while the close waits. A read of it answers 0 bytes, and a write to it
/// makes it longer, so a worker's call that reached it shows in its event or in the file's size.
const Decoy = struct {
    path_buffer: [96]u8,
    path: [:0]const u8,
    descriptor: core.Descriptor,

    fn open(decoy: *Decoy) !void {
        decoy.path = try scratch(&decoy.path_buffer);
        decoy.descriptor = try sync.open_file(decoy.path, .{ .create = true, .direct = false });
    }

    fn close(decoy: *Decoy) void {
        sync.close_now(decoy.descriptor);
        backend.testing.remove_file(decoy.path);
    }
};

/// Starts the fixture, and opens a second descriptor of its file, which the scenario closes.
fn start(fixture: *Fixture) !core.Descriptor {
    try fixture.init();
    errdefer fixture.deinit();
    return sync.open_file(fixture.path, .{ .create = false, .direct = false });
}

/// Hands `transfer` to the worker, which holds it, and then submits a close of `closing`. The close
/// waits: two ticks hand over no event, and both operations are still in flight. Returns the
/// close's handle.
fn close_behind(fixture: *Fixture, transfer: Operation, closing: core.Descriptor) !Handle {
    var events: [limit.events_per_tick]Event = undefined;
    try testing.expectEqual(@as(u32, 1), fixture.loop.submit(&.{transfer}, &.{}));
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 1), fixture.pool.submitted());

    var handles: [1]Handle = undefined;
    const close = Operation.close(close_user_data, closing);
    try testing.expectEqual(@as(u32, 1), fixture.loop.submit(&.{close}, &handles));
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 2), fixture.loop.in_flight());
    return handles[0];
}

/// Lets the worker answer, and collects every event that follows into `collected`. Returns how
/// many came. A scenario that expects fewer than `events_expected` stops at what it expects.
fn answer(fixture: *Fixture, collected: []Event) !u32 {
    fixture.pool.holding.store(false, .release);
    try fixture.pool.wait_for_served(1);
    var events: [limit.events_per_tick]Event = undefined;
    var count: u32 = 0;
    var round: u32 = 0;
    while (count < collected.len and round < conformance.collect_rounds_max) : (round += 1) {
        const produced = try fixture.loop.tick(&events, tick_wait_ns);
        try testing.expect(count + produced <= collected.len);
        @memcpy(collected[count..][0..produced], events[0..produced]);
        count += produced;
    }
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
    // Nothing more comes: each operation had one final event and no second one.
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    return count;
}

/// Lets the worker answer, and requires its event, with `transfer_bytes`, and then the close's.
fn answer_then_close(fixture: *Fixture, transfer_bytes: u32) !void {
    var collected: [events_expected]Event = undefined;
    try testing.expectEqual(@as(u32, events_expected), try answer(fixture, &collected));
    // The worker's call ran on the file the transfer named, which was still open.
    try testing.expectEqual(@as(u64, transfer_user_data), collected[0].user_data);
    try testing.expectEqual(transfer_bytes, try collected[0].outcome());
    try testing.expectEqual(@as(u64, close_user_data), collected[1].user_data);
    try testing.expectEqual(@as(u32, 0), try collected[1].outcome());
}

test "a close behind a worker's read waits for it, and the read finds its own file open" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    const fixture = &close_fixture;
    const closing = try start(fixture);
    defer fixture.deinit();
    const read = Operation.read(transfer_user_data, closing, &fixture.buffers[0], 0);
    _ = try close_behind(fixture, read, closing);

    var decoy: Decoy = undefined;
    try decoy.open();
    defer decoy.close();
    // The close waits, so `closing` is still open, and the new file takes another number.
    try testing.expect(decoy.descriptor != closing);
    try answer_then_close(fixture, limit.read_bytes);
}

test "a close behind a worker's write waits for it, and no other file takes the bytes" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    const fixture = &close_fixture;
    const closing = try start(fixture);
    defer fixture.deinit();
    const bytes: [limit.read_bytes]u8 = @splat('w');
    const write = Operation.write(transfer_user_data, closing, &bytes, 0);
    _ = try close_behind(fixture, write, closing);

    var decoy: Decoy = undefined;
    try decoy.open();
    defer decoy.close();
    try testing.expect(decoy.descriptor != closing);
    try answer_then_close(fixture, limit.read_bytes);
    // The write went to the fixture's file, and the empty file is still empty.
    try testing.expectEqual(@as(u64, 0), try sync.file_size(decoy.descriptor));
}

test "a cancel ends a close that waits with canceled, and the descriptor stays open" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    const fixture = &close_fixture;
    const closing = try start(fixture);
    defer fixture.deinit();
    const read = Operation.read(transfer_user_data, closing, &fixture.buffers[0], 0);
    const close = try close_behind(fixture, read, closing);

    // The cancel ends the close at the next tick, while the worker still holds the read.
    fixture.loop.cancel(close);
    var events: [limit.events_per_tick]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try fixture.loop.tick(&events, 0));
    try testing.expectEqual(@as(u64, close_user_data), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());

    var collected: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try answer(fixture, &collected));
    try testing.expectEqual(@as(u64, transfer_user_data), collected[0].user_data);
    try testing.expectEqual(@as(u32, limit.read_bytes), try collected[0].outcome());
    // The close did not happen, so the descriptor is the caller's to close. A close of a closed
    // descriptor halts.
    sync.close_now(closing);
}
