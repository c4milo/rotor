//! The closes a loop keeps while a worker has an operation on their descriptor (decision 5, rule 6,
//! and decision 18, ruling (d) of 2026-11-06). Split from `offload_in_flight.zig` for the 500-line
//! limit. `InFlight` declares the public functions, so a backend calls `in_flight.keep_close`.
//!
//! A worker owns an operation out until its result comes back, and a `pread` or a `pwrite` that
//! runs cannot be stopped. A close that closed the descriptor at once let that call run on a closed
//! descriptor, or on a file that took its number, and let its event come after the close's event.
//! So a backend's close keeps the close on `InFlight.closing` while the out array names its
//! descriptor. Each drain that takes a result hands every kept close to the backend's close again,
//! which closes the descriptor when nothing is out on it any more. The close's event then comes
//! after the event of every operation that was out on its descriptor.
//!
//! A kept close is `queued`, as a held operation is, and the loop ends it as it ends a queued one.
//! Its deadline runs from the flush that keeps it, and a cancel or the deadline ends it with
//! `canceled` or `timeout`. The descriptor then stays open, because the close did not happen.
const std = @import("std");
const assert = std.debug.assert;
const operation_module = @import("operation.zig");
const slot_module = @import("slot.zig");
const tables_module = @import("tables/tables.zig");
const in_flight_module = @import("offload_in_flight.zig");

const Descriptor = operation_module.Descriptor;
const InFlight = in_flight_module.InFlight;
const Slot = slot_module.Slot;
const Tables = tables_module.Tables;

/// True when a worker has an operation on `descriptor`. It reads at most `count` entries of the
/// out array, 2 KiB at the limit, and none on a loop with nothing out.
pub fn out_on(in_flight: *const InFlight, descriptor: Descriptor) bool {
    if (in_flight.count == 0) return false;
    const out = in_flight.out.?;
    for (out[0..in_flight.count]) |entry| {
        if (entry.descriptor == descriptor) return true;
    }
    return false;
}

/// Keeps the close in `index` on the closing list when a worker has an operation on its
/// descriptor, arms its deadline, and returns true. Returns false when the backend may close the
/// descriptor now. A backend calls it after it ended the waiters and the held operations of the
/// descriptor. A loop with no offload has nothing out, and pays one compare.
pub fn keep(in_flight: *InFlight, tables: *Tables, index: u32) bool {
    const slot = tables.table.at(index);
    // Only a close is kept, and only one the loop has not ended: a slot on no list.
    assert(slot.tag == .close and slot.state == .queued);
    if (!in_flight.out_on(slot.descriptor)) return false;
    in_flight.closing.push(tables.table.slots, index);
    // The deadline starts at the flush that keeps the close, as a held operation's does. A close
    // kept again keeps the deadline that is armed.
    tables.arm(index, slot);
    return true;
}

/// Hands each kept close, oldest first, to `close`, the backend's own, with its loop as `backend`.
/// `close` ends what was submitted on the descriptor since, and then closes it or keeps the close
/// again at the back of the list. So kept closes stay in their order. A backend calls it after
/// `core.offload.drain` took a result, which is the only thing that can end a close's wait.
pub fn settle(
    in_flight: *InFlight,
    tables: *Tables,
    backend: anytype,
    comptime close: fn (@TypeOf(backend), u32, *Slot) void,
) void {
    defer {
        // A close stays kept only while an operation is out on its descriptor, so a worker owes
        // the loop a result, and its push wakes a loop that sleeps. Here and not in
        // `InFlight.may_sleep`, so a loop with no offload does not pay for it on each tick.
        assert(in_flight.closing.count == 0 or in_flight.count != 0);
    }
    const kept = in_flight.closing.count;
    var visited: u32 = 0;
    while (visited < kept) : (visited += 1) {
        const index = in_flight.closing.pop(tables.table.slots).?;
        const slot = tables.table.at(index);
        // `InFlight.note_cancel` ends a kept close at its cancel, so none on the list is marked.
        assert(!slot.flags.cancel_requested);
        close(backend, index, slot);
    }
}

/// Ends with its cancel's code the close in `index` when it is kept, and leaves the other kept
/// closes in their order. A close on the pending list is not kept, and the flush ends it there.
/// The descriptor stays open: the close did not happen, as for any queued operation a cancel
/// reaches (decision 5, rule 2).
pub fn end_canceled(in_flight: *InFlight, tables: *Tables, index: u32) void {
    const kept = in_flight.closing.count;
    var visited: u32 = 0;
    while (visited < kept) : (visited += 1) {
        const popped = in_flight.closing.pop(tables.table.slots).?;
        if (popped == index) {
            tables.finish_canceled(index);
        } else {
            in_flight.closing.push(tables.table.slots, popped);
        }
    }
}

const testing = std.testing;
const event_module = @import("event.zig");
const layout = @import("layout.zig");
const mailbox_module = @import("mailbox.zig");
const offload = @import("offload.zig");
const Heartbeat = @import("stall.zig").Heartbeat;
const TimerHeap = @import("timer_heap.zig").TimerHeap;

const Event = event_module.Event;
const Handle = @import("handle.zig").Handle;
const Mailbox = mailbox_module.Mailbox;
const Operation = operation_module.Operation;

/// Slots of the tests below: a few file operations and two closes.
const test_slots = 8;
/// The bytes each test read names. No transfer is performed.
const test_bytes = 8;
/// The file the closes close. No file is open: the test's close only records the descriptor.
const test_descriptor = 3;
/// A second file, with an operation out that no close waits for.
const test_other_descriptor = 4;
/// The deadline of the test close that times out.
const test_timeout_ns = 5;
/// The bytes each answered read reports.
const test_result = 8;

/// A loop with an offload of one worker and no kernel: the tables, the count, one ring, and the
/// descriptors its close closed, in order.
const Fixture = struct {
    slots: [test_slots]Slot,
    entries: [test_slots]TimerHeap.Entry,
    starts: [test_slots]u64,
    heartbeat: Heartbeat,
    groups: @import("scheduling/scheduling.zig").Groups,
    tables: Tables,
    in_flight: InFlight,
    out: in_flight_module.OutArray,
    ring_memory: [offload.Offload.memory_bytes(1)]u8 align(layout.memory_alignment),
    rings: []Mailbox,
    closed: [test_slots]Descriptor,
    closed_len: u32,
    bytes: [test_bytes]u8,

    fn init(fixture: *Fixture) void {
        const tables = &fixture.tables;
        tables.init(&fixture.slots, &fixture.entries, &fixture.starts, &fixture.heartbeat, &fixture.groups, .{});
        fixture.in_flight = .init(&fixture.out);
        fixture.rings = offload.init_rings(&fixture.ring_memory, 1);
        fixture.closed_len = 0;
        fixture.bytes = @splat(0);
    }

    /// Submits `operation` and takes it off the pending list, as a backend's flush does.
    fn submit(fixture: *Fixture, operation: Operation) !Handle {
        var handles: [1]Handle = undefined;
        try testing.expectEqual(@as(u32, 1), fixture.tables.submit(&.{operation}, &handles));
        const index = fixture.tables.next_pending().?;
        fixture.tables.take_pending(index);
        try testing.expectEqual(handles[0].index, index);
        return handles[0];
    }

    /// Hands a read of `descriptor` out, as a backend's `hand_out` does. Returns its slot index.
    fn read_out(fixture: *Fixture, user_data: u64, descriptor: Descriptor) !u32 {
        const read = Operation.read(user_data, descriptor, &fixture.bytes, 0);
        const index = (try fixture.submit(read)).index;
        fixture.tables.hand_over(index, fixture.tables.table.at(index));
        fixture.in_flight.note_handed_out(index, descriptor);
        return index;
    }

    /// What a backend's close does, with a record of the descriptor in place of the system call.
    fn close(fixture: *Fixture, index: u32, slot: *Slot) void {
        fixture.in_flight.end_descriptor(&fixture.tables, slot.descriptor);
        if (fixture.in_flight.keep_close(&fixture.tables, index)) return;
        fixture.closed[fixture.closed_len] = slot.descriptor;
        fixture.closed_len += 1;
        fixture.tables.finish_local(index, 0);
    }

    /// Submits a close of `descriptor`, and runs the close as the flush does.
    fn submit_close(fixture: *Fixture, operation: Operation) !Handle {
        const handle = try fixture.submit(operation);
        fixture.close(handle.index, fixture.tables.table.at(handle.index));
        return handle;
    }

    /// The worker answers the read in `index`, and the loop drains the ring.
    fn answer(fixture: *Fixture, index: u32) !void {
        const message: operation_module.Message = .{
            .tag = offload.tag_of(test_result),
            .payload = index,
        };
        try testing.expect(fixture.rings[0].push(message));
        const in_flight = &fixture.in_flight;
        const tables = &fixture.tables;
        try testing.expectEqual(@as(u32, 1), offload.drain(fixture.rings, in_flight, tables, test_slots));
        // What a backend's drain does next.
        if (in_flight.closing.count != 0) in_flight.settle_closes(tables, fixture, close);
    }

    /// What a backend's cancel does with a queued operation, and with one whose deadline passed.
    fn request(fixture: *Fixture, index: u32, slot: *Slot) void {
        const action = fixture.tables.request_cancel(index, slot);
        assert(action == .none);
        fixture.in_flight.note_cancel(&fixture.tables, index, slot);
    }

    /// The events the loop finished, in order. Returns how many.
    fn finished(fixture: *Fixture, events: []Event) u32 {
        return fixture.tables.drain_finished(events);
    }
};

test "a close with nothing out on its descriptor closes at once, whatever else is out" {
    var fixture_value: Fixture = undefined;
    const fixture = &fixture_value;
    fixture.init();
    _ = try fixture.read_out(0, test_other_descriptor);
    _ = try fixture.submit_close(Operation.close(1, test_descriptor));
    try testing.expectEqual(@as(u32, 0), fixture.in_flight.closing.count);
    try testing.expectEqual(@as(u32, 1), fixture.closed_len);
    try testing.expectEqual(@as(Descriptor, test_descriptor), fixture.closed[0]);
    var events: [test_slots]Event = undefined;
    try testing.expectEqual(@as(u32, 1), fixture.finished(&events));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
}

test "a close waits for each operation out on its descriptor, and its event comes after theirs" {
    var fixture_value: Fixture = undefined;
    const fixture = &fixture_value;
    fixture.init();
    const first = try fixture.read_out(0, test_descriptor);
    const other = try fixture.read_out(1, test_other_descriptor);
    const second = try fixture.read_out(2, test_descriptor);
    _ = try fixture.submit_close(Operation.close(3, test_descriptor));
    try testing.expectEqual(@as(u32, 1), fixture.in_flight.closing.count);
    try testing.expectEqual(@as(u32, 0), fixture.closed_len);

    // A result on the descriptor, and one on another: a read on the descriptor is still out.
    try fixture.answer(first);
    try fixture.answer(other);
    try testing.expectEqual(@as(u32, 0), fixture.closed_len);
    try testing.expectEqual(@as(u32, 1), fixture.in_flight.closing.count);

    // The last result on the descriptor: the same drain closes it, after that result.
    try fixture.answer(second);
    try testing.expectEqual(@as(u32, 1), fixture.closed_len);
    try testing.expectEqual(@as(u32, 0), fixture.in_flight.closing.count);
    var events: [test_slots]Event = undefined;
    try testing.expectEqual(@as(u32, 4), fixture.finished(&events));
    const order = [_]u64{ 0, 1, 2, 3 };
    for (events[0..order.len], order) |event, user_data| {
        try testing.expectEqual(user_data, event.user_data);
    }
    try testing.expectEqual(@as(u32, 0), try events[3].outcome());
}

test "a cancel ends a kept close with canceled, and the descriptor stays open" {
    var fixture_value: Fixture = undefined;
    const fixture = &fixture_value;
    fixture.init();
    const read = try fixture.read_out(0, test_descriptor);
    const close = try fixture.submit_close(Operation.close(1, test_descriptor));
    fixture.request(close.index, fixture.tables.cancellable(close).?);
    try testing.expectEqual(@as(u32, 0), fixture.in_flight.closing.count);
    var events: [test_slots]Event = undefined;
    try testing.expectEqual(@as(u32, 1), fixture.finished(&events));
    try testing.expectError(error.Canceled, events[0].outcome());

    // The read's result comes back, and nothing is closed.
    try fixture.answer(read);
    try testing.expectEqual(@as(u32, 0), fixture.closed_len);
}

test "a kept close's deadline ends it with timeout while the read is out" {
    var fixture_value: Fixture = undefined;
    const fixture = &fixture_value;
    fixture.init();
    _ = try fixture.read_out(0, test_descriptor);
    var timed = Operation.close(1, test_descriptor);
    timed.timeout_ns = test_timeout_ns;
    const close = try fixture.submit_close(timed);
    try testing.expect(fixture.tables.timers.is_armed(close.index));

    fixture.tables.now_ns = test_timeout_ns;
    fixture.tables.expire(fixture, Fixture.request);
    try testing.expectEqual(@as(u32, 0), fixture.in_flight.closing.count);
    var events: [test_slots]Event = undefined;
    try testing.expectEqual(@as(u32, 1), fixture.finished(&events));
    try testing.expectError(error.Timeout, events[0].outcome());
    try testing.expectEqual(@as(u32, 0), fixture.closed_len);
}

test "two closes of one descriptor wait, and run in the order they came" {
    var fixture_value: Fixture = undefined;
    const fixture = &fixture_value;
    fixture.init();
    const read = try fixture.read_out(0, test_descriptor);
    _ = try fixture.submit_close(Operation.close(1, test_descriptor));
    _ = try fixture.submit_close(Operation.close(2, test_descriptor));
    try testing.expectEqual(@as(u32, 2), fixture.in_flight.closing.count);

    try fixture.answer(read);
    try testing.expectEqual(@as(u32, 2), fixture.closed_len);
    var events: [test_slots]Event = undefined;
    try testing.expectEqual(@as(u32, 3), fixture.finished(&events));
    try testing.expectEqual(@as(u64, 1), events[1].user_data);
    try testing.expectEqual(@as(u64, 2), events[2].user_data);
}
