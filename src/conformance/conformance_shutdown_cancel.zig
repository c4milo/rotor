//! Cancels on a shared loop on every backend (decisions 5, 26 and 27): `cancel_all` with records
//! in flight and tasks queued, a record that cancels operations from its own callback, and a
//! cancel whose final event comes in the same batch as a `more` event. The oracle is the one of
//! `conformance_shutdown.zig`: one final event for each record, and an empty loop at the end.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const shutdown = @import("conformance_shutdown.zig");
const tcp = @import("conformance_tcp.zig");
const timers = @import("conformance_timers.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Record = shutdown.Record;
const Counted = shutdown.Counted;
const sync = backend.sync;

const ms = core.constants.ns_per_ms;

/// The period of the repeating timers below. Long enough that a busy machine does not make one
/// tick see two fires, and short enough that a scenario ends in well under a second.
const period_ns = 20 * ms;

/// The user data of the operation without a record in the `cancel_all` scenario.
const plain_user_data = 9;

fn all_finished(records: *const [4]Record) bool {
    for (records) |*record| {
        if (!record.finished()) return false;
    }
    return true;
}

fn fired(record: *const Record) bool {
    return record.mores != 0;
}

test "cancel_all ends every record once, and the queued tasks still run once" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    // A long timer, a repeating timer that has fired, a receive the kernel holds and an accept,
    // each with a record, and one long timer without a record.
    var records: [4]Record = @splat(.{});
    var bytes: [8]u8 = undefined;
    try harness.submit(&.{
        Operation.timer(0, shutdown.never_ns, 0).completion(&records[0].completion),
        Operation.timer(0, ms, period_ns).completion(&records[1].completion),
        Operation.receive(0, pair[1], &bytes).completion(&records[2].completion),
        Operation.accept(0, listener.descriptor, true).completion(&records[3].completion),
        Operation.timer(plain_user_data, shutdown.never_ns, 0),
    }, &.{});
    try testing.expectEqual(@as(u32, 0), try shutdown.tick_until(&harness, &records[1], fired));
    var tasks: [2]Counted = @splat(.{});
    for (&tasks) |*counted| try harness.loop.schedule(&counted.task);

    harness.loop.cancel_all();
    try testing.expectEqual(@as(u32, 1), try shutdown.tick_until(&harness, &records, all_finished));
    try shutdown.expect_one_final(&records);
    for (&records) |*record| try testing.expectError(error.Canceled, record.final.?.outcome());
    for (&tasks) |*counted| try testing.expectEqual(@as(u32, 1), counted.runs);
    try shutdown.expect_empty(&harness);
}

/// A record whose first event cancels its own operation and the operation `other` names. It counts
/// its events in `record`.
const Canceller = struct {
    completion: core.Completion = .init(Canceller, "completion", called),
    record: Record = .{},
    loop: *conformance.Loop,
    own: Handle = undefined,
    other: Handle = undefined,

    fn called(canceller: *Canceller, event: Event) void {
        const first = canceller.record.mores + canceller.record.finals == 0;
        canceller.record.note(event);
        if (!first) return;
        canceller.loop.cancel(canceller.own);
        canceller.loop.cancel(canceller.other);
    }
};

fn both_finished(pair: struct { *const Canceller, *const Record }) bool {
    return pair[0].record.finished() and pair[1].finished();
}

test "a record that cancels its own operation and another record's operation ends each once" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    var canceller: Canceller = .{ .loop = &harness.loop };
    var other: Record = .{};
    var bytes: [8]u8 = undefined;
    var handles: [2]Handle = undefined;
    try harness.submit(&.{
        Operation.timer(0, ms, period_ns).completion(&canceller.completion),
        Operation.receive(0, pair[1], &bytes).completion(&other.completion),
    }, &handles);
    canceller.own = handles[0];
    canceller.other = handles[1];

    const both = .{ &canceller, &other };
    try testing.expectEqual(@as(u32, 0), try shutdown.tick_until(&harness, both, both_finished));
    // A loop held off past a period may hand over two fires before the cancel takes effect.
    try testing.expect(canceller.record.mores >= 1);
    try testing.expectEqual(@as(u32, 1), canceller.record.finals);
    try testing.expectEqual(@as(u32, 1), other.finals);
    try testing.expectError(error.Canceled, canceller.record.final.?.outcome());
    try testing.expectError(error.Canceled, other.final.?.outcome());
    try shutdown.expect_empty(&harness);
}

test "a cancel's final event and another record's more event in one batch each count right" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var repeating: Record = .{};
    var waiting: Record = .{};
    var handles: [2]Handle = undefined;
    try harness.submit(&.{
        Operation.timer(0, period_ns, period_ns).completion(&repeating.completion),
        Operation.timer(0, shutdown.never_ns, 0).completion(&waiting.completion),
    }, &handles);
    _ = try shutdown.tick_until(&harness, &repeating, fired);

    // Hold the loop off past the next fire, then cancel the long timer. The tables end a timer
    // at its cancel, so the next tick hands over its final event and the due fire together.
    timers.hold_off(period_ns + period_ns / 2);
    harness.loop.cancel(handles[1]);
    var events: [8]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, 0));
    // A busy machine can stretch the hold past a second period, and the tick then hands over two
    // fires. One is enough.
    try testing.expect(repeating.mores >= 2);
    try testing.expectEqual(@as(u32, 1), waiting.finals);
    // The more event kept its operation owed, and the final event ended the other one.
    try testing.expectEqual(@as(u32, 1), harness.loop.tables.dispatch.callbacks_outstanding);

    harness.loop.cancel(handles[0]);
    _ = try shutdown.tick_until(&harness, &repeating, Record.finished);
    try testing.expectEqual(@as(u32, 1), repeating.finals);
    try testing.expectError(error.Canceled, waiting.final.?.outcome());
    try shutdown.expect_empty(&harness);
}
