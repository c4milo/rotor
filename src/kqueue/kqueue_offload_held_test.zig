//! The file operations a kqueue loop holds for the offload's room (decision 18, amendment of
//! 2026-11-06), tested through this backend's own flush, cancel and close. The loop comes up
//! through `init_tables`, so it opens no kqueue, and no worker runs: the pool only keeps each work
//! it is handed. A test answers a work itself, with a push into the worker's ring.
//!
//! The conformance suite tests the same paths through `tick` with a real worker
//! (`conformance_offload_held.zig`). These tests catch a break in this backend's half alone.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const cancel_module = @import("kqueue_cancel.zig");
const offload_module = @import("kqueue_offload.zig");
const submit_module = @import("kqueue_submit.zig");
const kqueue = @import("kqueue.zig");
const kqueue_testing = @import("kqueue_testing.zig");

const Event = core.Event;
const Handle = core.Handle;
const Loop = kqueue.Loop;
const Operation = core.Operation;
const Work = core.offload.Work;

/// The operations each test holds at most, past those that fill the offload.
const held_max = 2;
/// Slots: one for each operation the offload lets out, and room for the held ones.
const operations = core.constants.offload_in_flight_max + held_max;
const entries = 16;
/// One worker, so one ring.
const workers: u16 = 1;
/// A descriptor no process has open. No work runs, so no call is made on it.
const closed_descriptor: core.Descriptor = 4096;
/// The deadline of the held read that times out.
const held_timeout_ns = core.constants.ns_per_ms;

const alignment = core.layout.memory_alignment;

/// The caller's offload, which keeps each work and runs none.
const Pool = struct {
    works: [operations]*Work,
    handed: u32,

    fn submit(context: ?*anyopaque, work: *Work) void {
        const pool: *Pool = @ptrCast(@alignCast(context.?));
        pool.works[pool.handed] = work;
        pool.handed += 1;
    }
};

const Fixture = struct {
    loop: Loop,
    pool: Pool,
    memory: [Loop.memory_bytes(options_for(null))]u8 align(alignment),
    rings: [offload_module.memory_bytes(workers)]u8 align(alignment),
    bytes: [8]u8,

    fn options_for(pool: ?*Pool) Loop.Options {
        return .{
            .operations = operations,
            .entries = entries,
            .file_policy = .offload,
            .offload = .{ .context = pool, .submit = Pool.submit, .workers = workers },
        };
    }

    /// Hands out one read for each operation the offload lets out, so the next file operation is
    /// held.
    fn fill(fixture: *Fixture) !void {
        fixture.pool.handed = 0;
        fixture.bytes = @splat(0);
        var options = options_for(&fixture.pool);
        options.offload_memory = &fixture.rings;
        fixture.loop.init_tables(&fixture.memory, options);
        var index: u32 = 0;
        while (index < core.constants.offload_in_flight_max) : (index += 1) {
            _ = try fixture.submit(Operation.read(index, closed_descriptor, &fixture.bytes, 0));
        }
        submit_module.flush(&fixture.loop);
        try testing.expectEqual(core.constants.offload_in_flight_max, fixture.pool.handed);
    }

    fn submit(fixture: *Fixture, operation: Operation) !Handle {
        var handles: [1]Handle = undefined;
        try testing.expectEqual(@as(u32, 1), fixture.loop.submit(&.{operation}, &handles));
        return handles[0];
    }

    /// Submits `operation` and flushes. The operation is held, so nothing is handed out.
    fn hold(fixture: *Fixture, operation: Operation) !Handle {
        const handle = try fixture.submit(operation);
        submit_module.flush(&fixture.loop);
        try testing.expectEqual(core.constants.offload_in_flight_max, fixture.pool.handed);
        try testing.expectEqual(@as(u32, 0), fixture.loop.tables.finished.count);
        return handle;
    }

    /// Answers the oldest work as a worker would, and lets the loop take the answer off the ring.
    fn answer_one(fixture: *Fixture) !void {
        const work = fixture.pool.works[0];
        const ring = &fixture.loop.inbox.completions[0];
        try testing.expect(ring.push(.{ .tag = core.offload.tag_of(0), .payload = work.index }));
        try testing.expectEqual(@as(u32, 1), offload_module.drain(&fixture.loop));
    }

    /// The events the loop finished, in order.
    fn finished(fixture: *Fixture, events: []Event) u32 {
        return fixture.loop.tables.drain_finished(events);
    }
};

var held_fixture: Fixture align(@alignOf(Fixture)) = undefined;

test "a held read goes out at the flush after a result comes back, and not before" {
    if (!kqueue.supported) return error.SkipZigTest;
    const fixture = &held_fixture;
    try fixture.fill();
    const held = try fixture.hold(Operation.read(operations, closed_descriptor, &fixture.bytes, 0));
    submit_module.flush(&fixture.loop);
    try testing.expectEqual(core.constants.offload_in_flight_max, fixture.pool.handed);

    try fixture.answer_one();
    submit_module.flush(&fixture.loop);
    try testing.expectEqual(core.constants.offload_in_flight_max + 1, fixture.pool.handed);
    try testing.expectEqual(held.index, fixture.pool.works[fixture.pool.handed - 1].index);
}

test "a close ends a held write on its descriptor with canceled, then closes, in that order" {
    if (!kqueue.supported) return error.SkipZigTest;
    const fixture = &held_fixture;
    try fixture.fill();
    const pair = try kqueue_testing.nonblocking_pair();
    defer _ = std.c.close(pair[1]);
    _ = try fixture.hold(Operation.write(operations, pair[0], &fixture.bytes, 0));

    _ = try fixture.submit(Operation.close(operations + 1, pair[0]));
    submit_module.flush(&fixture.loop);
    var events: [held_max + 1]Event = undefined;
    try testing.expectEqual(@as(u32, 2), fixture.finished(&events));
    try testing.expectEqual(@as(u64, operations), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u64, operations + 1), events[1].user_data);
    try testing.expectEqual(@as(u32, 0), try events[1].outcome());
    try testing.expectEqual(@as(u32, 0), fixture.loop.inbox.offload_in_flight.held.count);
}

test "a cancel ends a held read behind another held one at the next flush" {
    if (!kqueue.supported) return error.SkipZigTest;
    const fixture = &held_fixture;
    try fixture.fill();
    _ = try fixture.hold(Operation.read(operations, closed_descriptor, &fixture.bytes, 0));
    const second = Operation.read(operations + 1, closed_descriptor, &fixture.bytes, 0);
    const behind = try fixture.hold(second);

    fixture.loop.cancel(behind);
    submit_module.flush(&fixture.loop);
    var events: [held_max + 1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), fixture.finished(&events));
    try testing.expectEqual(@as(u64, operations + 1), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u32, 1), fixture.loop.inbox.offload_in_flight.held.count);
}

test "a held read's deadline ends it with timeout through this backend's cancel" {
    if (!kqueue.supported) return error.SkipZigTest;
    const fixture = &held_fixture;
    try fixture.fill();
    var timed = Operation.read(operations, closed_descriptor, &fixture.bytes, 0);
    timed.timeout_ns = held_timeout_ns;
    _ = try fixture.hold(timed);

    const tables = &fixture.loop.tables;
    tables.now_ns += held_timeout_ns;
    tables.expire(&fixture.loop, cancel_module.request);
    submit_module.flush(&fixture.loop);
    var events: [held_max + 1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), fixture.finished(&events));
    try testing.expectEqual(@as(u64, operations), events[0].user_data);
    try testing.expectError(error.Timeout, events[0].outcome());
    try testing.expectEqual(core.constants.offload_in_flight_max, fixture.pool.handed);
}
