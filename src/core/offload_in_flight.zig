//! How many operations a loop has out on its offload's workers, and the file operations that wait
//! for room (decision 18, amendment of 2026-11-06). Each loop holds one in its `Inbox`, and only the
//! loop thread reads or writes it. kqueue and epoll use it. io_uring has no offload.
//!
//! A worker pushes each result to its own ring of `constants.mailbox_messages`, and `Work.run`
//! asserts the push. Before 2026-11-06 a loop handed out every file operation at once. A loop with
//! more than a ring's worth on one worker, busy while they finished, filled the ring and halted.
//! Load and timing reached that halt, and no mistake of the caller's was needed.
//!
//! So a loop hands out at most `constants.offload_in_flight_max` operations, and keeps each further
//! file operation queued until a result comes back. It does not refuse it. Every result in a ring
//! belongs to an operation that is out, so a ring never holds more results than it has room for.
//!
//! A worker also has to see each ring's `head` no older than it was when the loop handed out the
//! work. The caller's `submit` makes the `Work` fields visible to the worker, so it orders every
//! store the loop made before the hand-out before the worker's loads. The pops of `head` are such
//! stores. A worker that sees a later `head` sees more room, never less.
//!
//! A held operation is the loop's alone, so the loop ends it, as it ends a queued one (Camilo's
//! rulings of 2026-11-06): its deadline runs while it waits, a cancel ends it wherever it sits in
//! the list, and a `close` of its descriptor ends it before the descriptor closes.
//!
//! An operation out is the worker's until its result comes back. So a `close` of its descriptor
//! waits for that result, and closes after it (ruling (d) of 2026-11-06). The loop keeps the slot
//! and the descriptor of each operation out, so a close can learn whether it must wait.
//! `offload_in_flight_close.zig` holds the closes that wait.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const operation_module = @import("operation.zig");
const slot_module = @import("slot.zig");
const slot_list = @import("slot_list.zig");
const tables_module = @import("tables.zig");
const close_module = @import("offload_in_flight_close.zig");

const Descriptor = operation_module.Descriptor;
const Slot = slot_module.Slot;
const SlotList = slot_list.SlotList;
const Tables = tables_module.Tables;

/// One operation out on a worker: its slot, and the descriptor its system call names. 8 bytes,
/// aligned to 4, so the out array of a loop is 2 KiB.
pub const Out = struct {
    index: u32,
    descriptor: Descriptor,
};

/// The out array of a loop with an offload: one entry for each operation the limit lets out.
pub const OutArray = [constants.offload_in_flight_max]Out;

/// 40 bytes, aligned to 8: the out array's address, the count, the two lists' three words each,
/// and the flag. Each loop's `Inbox` holds one, and a tick reads it, so the size is held here.
pub const InFlight = struct {
    /// The operations out, in no order: the first `count` entries are in use. A close reads it to
    /// learn whether a worker still has an operation on its descriptor. It is the loop's memory,
    /// carved at init, and null for a loop with no offload, which hands nothing out.
    out: ?*OutArray,
    /// Operations handed out whose result the loop has not taken off a ring. At most
    /// `constants.offload_in_flight_max`.
    count: u32,
    /// File operations that wait for room, oldest first. Each is `queued` and on no other list, and
    /// the next flush with room hands it out.
    held: SlotList,
    /// Closes that wait for a worker's result on their descriptor, oldest first. Each is `queued`
    /// and on no other list (`offload_in_flight_close.zig`).
    closing: SlotList,
    /// A cancel reached a queued operation while some were held, so the next flush looks through
    /// the held list for the operations to end. A flush with no such cancel does not walk the list.
    canceled: bool,

    pub const empty: InFlight = .{
        .out = null,
        .count = 0,
        .held = SlotList.empty,
        .closing = SlotList.empty,
        .canceled = false,
    };

    /// An empty count over the out array `out`, or over none for a loop with no offload.
    pub fn init(out: ?*OutArray) InFlight {
        var in_flight = empty;
        in_flight.out = out;
        return in_flight;
    }

    /// True when the loop may hand out one more operation.
    pub fn has_room(in_flight: *const InFlight) bool {
        return in_flight.count < constants.offload_in_flight_max;
    }

    /// Records one operation handed out: the slot in `index`, whose call names `descriptor`. A
    /// backend asks `has_room` first, so a hand-out with no room is rotor's own mistake, and a ring
    /// could then overflow. The bounds check of the out array halts it. An `assert` of the room
    /// here cannot be proved by a halt scenario, because that check halts too.
    pub fn note_handed_out(in_flight: *InFlight, index: u32, descriptor: Descriptor) void {
        // Only a loop with an offload hands out, and only such a loop has an out array.
        const out = in_flight.out.?;
        out[in_flight.count] = .{ .index = index, .descriptor = descriptor };
        in_flight.count += 1;
    }

    /// Records that the loop took the result of the operation in slot `index` off a ring, and moves
    /// the last entry of the out array into its place. It visits at most `count` entries.
    pub fn note_back(in_flight: *InFlight, index: u32) void {
        const out = in_flight.out.?;
        var position: u32 = 0;
        while (position < in_flight.count and out[position].index != index) : (position += 1) {}
        // Each result belongs to an operation the loop handed out, and a hand-out records it here.
        assert(position < in_flight.count);
        in_flight.count -= 1;
        out[position] = out[in_flight.count];
    }

    /// Puts the queued file operation in `index` at the back of the held list, and arms its
    /// deadline. The deadline starts at this flush, the first that tried the operation, as it does
    /// for every operation. So the wait for room counts against `timeout_ns` (ruling (b) of
    /// 2026-11-06), and the later hand-out keeps the deadline that is armed.
    pub fn hold(in_flight: *InFlight, tables: *Tables, index: u32) void {
        // A backend holds an operation only at the limit, which `may_sleep` depends on.
        assert(!in_flight.has_room());
        in_flight.held.push(tables.table.slots, index);
        tables.arm(index, tables.table.at(index));
    }

    /// Records a cancel that `Tables.request_cancel` marked and left to the backend's flush. A
    /// queued operation may be on the held list, and the next flush ends it there (ruling (c) of
    /// 2026-11-06). A cancel of a queued operation on the pending list costs that flush one walk
    /// of the held list, which finds nothing to end. A close is never held: a cancel of a close
    /// that waits ends it now, and the descriptor stays open (ruling (d) of 2026-11-06).
    pub fn note_cancel(in_flight: *InFlight, tables: *Tables, index: u32, slot: *const Slot) void {
        assert(slot.flags.cancel_requested);
        if (slot.state != .queued) return;
        if (slot.code == .close) return in_flight.end_canceled_close(tables, index);
        if (in_flight.held.count != 0) in_flight.canceled = true;
    }

    /// True when the loop may sleep with what it holds. Nothing is held, or a worker owes the loop
    /// a result, and the worker's push wakes it. A held operation with nothing out would wait with
    /// nothing to end the wait. A kept close always has an operation out on its descriptor, which
    /// `core.offload.drain` checks, so this check reads only the held list.
    pub fn may_sleep(in_flight: *const InFlight) bool {
        return in_flight.held.count == 0 or in_flight.count != 0;
    }

    /// True when a worker has an operation on `descriptor`: `offload_in_flight_close.zig`.
    pub const out_on = close_module.out_on;
    /// Keeps a close while a worker has an operation on its descriptor:
    /// `offload_in_flight_close.zig`.
    pub const keep_close = close_module.keep;
    /// Hands each kept close to the backend's close again: `offload_in_flight_close.zig`.
    pub const settle_closes = close_module.settle;
    /// Ends a kept close whose cancel came: `offload_in_flight_close.zig`.
    pub const end_canceled_close = close_module.end_canceled;

    /// Ends with its cancel's code each held operation whose cancel came, and then hands out the
    /// held operations, oldest first, while there is room. A backend's flush calls it before it
    /// visits its pending list, so a file operation queued later never passes a held one.
    /// `hand_out` is the backend's own, with its loop as `backend`.
    pub fn flush(
        in_flight: *InFlight,
        tables: *Tables,
        backend: anytype,
        comptime hand_out: fn (@TypeOf(backend), u32, *Slot) void,
    ) void {
        if (in_flight.canceled) in_flight.end_held(tables, null);
        const held = in_flight.held.count;
        var visited: u32 = 0;
        while (visited < held and in_flight.has_room()) : (visited += 1) {
            const index = in_flight.held.pop(tables.table.slots).?;
            const slot = tables.table.at(index);
            // `note_cancel` saw every cancel of a held operation, so `end_held` ended it above.
            assert(!slot.flags.cancel_requested);
            hand_out(backend, index, slot);
        }
    }

    /// Ends with `canceled` every held operation on `descriptor`, oldest first: what a backend's
    /// `close` does before it closes the descriptor (decision 5, rule 6, and ruling (a) of
    /// 2026-11-06). The finished list keeps their order, so the caller sees each of them before
    /// the close.
    pub fn end_descriptor(in_flight: *InFlight, tables: *Tables, descriptor: Descriptor) void {
        assert(descriptor >= 0);
        if (in_flight.held.count != 0) in_flight.end_held(tables, descriptor);
    }

    /// Visits each held operation once, oldest first. It ends each one whose cancel came, and each
    /// one on `closing`, with its cancel's code, and puts the others back in their order. So every
    /// cancel `note_cancel` recorded is settled.
    fn end_held(in_flight: *InFlight, tables: *Tables, closing: ?Descriptor) void {
        const held = in_flight.held.count;
        var visited: u32 = 0;
        while (visited < held) : (visited += 1) {
            const index = in_flight.held.pop(tables.table.slots).?;
            const slot = tables.table.at(index);
            assert(slot.state == .queued);
            if (closing) |descriptor| {
                if (slot.descriptor == descriptor) slot.flags.cancel_requested = true;
            }
            if (slot.flags.cancel_requested) {
                tables.finish_canceled(index);
            } else {
                in_flight.held.push(tables.table.slots, index);
            }
        }
        in_flight.canceled = false;
    }
};

comptime {
    assert(@sizeOf(InFlight) == 40);
    assert(@alignOf(InFlight) == 8);
    assert(@sizeOf(Out) == 8);
}

const testing = std.testing;
const event_module = @import("event.zig");
const TimerHeap = @import("timer_heap.zig").TimerHeap;
const Heartbeat = @import("stall.zig").Heartbeat;

const Event = event_module.Event;
const Handle = @import("handle.zig").Handle;
const Operation = operation_module.Operation;

/// Operations of the tests below that wait for room after the first flush.
const test_held = 2;
/// Slots of the tests below: more than the limit, so `test_held` operations wait for room.
const test_slots = constants.offload_in_flight_max + test_held + 1;
/// The bytes each test operation names. No transfer is performed.
const test_bytes = 8;
/// The file each test operation names. No transfer is performed, so no file is open.
const test_descriptor = 3;
/// A second file, which only the test of a close names.
const test_other_descriptor = 4;
/// The deadline of the test read that times out while it is held.
const test_timeout_ns = 5;

/// A loop with an offload and no kernel: the tables, the count, and the order of its hand-outs.
const Fixture = struct {
    slots: [test_slots]Slot,
    entries: [test_slots]TimerHeap.Entry,
    starts: [test_slots]u64,
    heartbeat: Heartbeat,
    tables: Tables,
    in_flight: InFlight,
    out: OutArray,
    handed: [test_slots]u32,
    handed_len: u32,
    /// The hand-outs whose result came back, oldest first.
    taken_len: u32,
    bytes: [test_bytes]u8,

    fn init(fixture: *Fixture) void {
        fixture.tables.init(&fixture.slots, &fixture.entries, &fixture.starts, &fixture.heartbeat, .{});
        fixture.in_flight = .init(&fixture.out);
        fixture.handed_len = 0;
        fixture.taken_len = 0;
        fixture.bytes = @splat(0);
    }

    /// What `core.offload.drain` does with the count when the results of the `taken` oldest
    /// hand-outs come back.
    fn take_back(fixture: *Fixture, taken: u32) void {
        var index: u32 = 0;
        while (index < taken) : (index += 1) {
            fixture.in_flight.note_back(fixture.handed[fixture.taken_len]);
            fixture.taken_len += 1;
        }
    }

    /// What a backend's `hand_out` does with the count: holds the operation at the limit, and
    /// otherwise marks it `submitted`, counts it and records its order.
    fn hand_out(fixture: *Fixture, index: u32, slot: *Slot) void {
        if (!fixture.in_flight.has_room()) return fixture.in_flight.hold(&fixture.tables, index);
        fixture.tables.hand_over(index, slot);
        fixture.in_flight.note_handed_out(index, slot.descriptor);
        fixture.handed[fixture.handed_len] = index;
        fixture.handed_len += 1;
    }

    /// What a backend's `cancel` does with a queued operation: the tables mark it, and the count
    /// notes it. The loop calls it for a deadline that passed too.
    fn request(fixture: *Fixture, index: u32, slot: *Slot) void {
        const action = fixture.tables.request_cancel(index, slot);
        assert(action == .none);
        fixture.in_flight.note_cancel(&fixture.tables, index, slot);
    }

    /// Submits `count` reads of `test_descriptor` and flushes them as a backend does.
    fn submit_and_flush(fixture: *Fixture, count: u32) !void {
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            const read = Operation.read(index, test_descriptor, &fixture.bytes, 0);
            try testing.expectEqual(@as(u32, 1), fixture.tables.submit(&.{read}, &.{}));
        }
        fixture.flush();
    }

    /// Submits `operation`, writes its handle, and flushes.
    fn submit_one(fixture: *Fixture, operation: Operation, handle: *Handle) !void {
        var handles: [1]Handle = undefined;
        try testing.expectEqual(@as(u32, 1), fixture.tables.submit(&.{operation}, &handles));
        handle.* = handles[0];
        fixture.flush();
    }

    /// A backend's flush: the held operations first, then the pending list.
    fn flush(fixture: *Fixture) void {
        const tables = &fixture.tables;
        fixture.in_flight.flush(tables, fixture, Fixture.hand_out);
        while (tables.next_pending()) |index| {
            tables.take_pending(index);
            fixture.hand_out(index, tables.table.at(index));
        }
    }

    /// The one event the loop finished, which must be that of `user_data`.
    fn only_event(fixture: *Fixture, user_data: u64) !Event {
        var events: [test_held + 1]Event = undefined;
        try testing.expectEqual(@as(u32, 1), fixture.tables.drain_finished(&events));
        try testing.expectEqual(user_data, events[0].user_data);
        return events[0];
    }
};

test "a loop hands out up to the limit, holds the rest, and hands them out as results come back" {
    var fixture_value: Fixture = undefined;
    const fixture = &fixture_value;
    fixture.init();
    const submitted = constants.offload_in_flight_max + test_held;
    try fixture.submit_and_flush(submitted);
    try testing.expectEqual(constants.offload_in_flight_max, fixture.in_flight.count);
    try testing.expectEqual(@as(u32, test_held), fixture.in_flight.held.count);
    try testing.expectEqual(constants.offload_in_flight_max, fixture.handed_len);
    // Held, so not handed to the kernel, and still the loop's: decision 5 owes each one an event.
    try testing.expectEqual(@as(u32, submitted), fixture.tables.in_flight());
    try testing.expect(fixture.in_flight.may_sleep());

    // No result came back, so the next flush hands out nothing.
    fixture.flush();
    try testing.expectEqual(constants.offload_in_flight_max, fixture.handed_len);

    // One result back, room for one: the oldest held operation goes, and the other still waits.
    fixture.take_back(1);
    fixture.flush();
    try testing.expectEqual(constants.offload_in_flight_max, fixture.in_flight.count);
    try testing.expectEqual(@as(u32, 1), fixture.in_flight.held.count);
    fixture.take_back(1);
    fixture.flush();
    try testing.expectEqual(@as(u32, 0), fixture.in_flight.held.count);

    // Every operation went out once, in the order it was submitted.
    try testing.expectEqual(@as(u32, submitted), fixture.handed_len);
    for (fixture.handed[0..fixture.handed_len], 0..) |index, position| {
        try testing.expectEqual(@as(u64, position), fixture.tables.table.at(index).user_data);
    }
}

test "a file operation queued after a held one waits behind it, even when room came back" {
    var fixture_value: Fixture = undefined;
    const fixture = &fixture_value;
    fixture.init();
    try fixture.submit_and_flush(constants.offload_in_flight_max + 1);
    try testing.expectEqual(@as(u32, 1), fixture.in_flight.held.count);
    // Room for one, and a new read queued: the held read is older, so it goes first.
    fixture.take_back(1);
    const late = Operation.read(test_slots, test_descriptor, &fixture.bytes, 0);
    try testing.expectEqual(@as(u32, 1), fixture.tables.submit(&.{late}, &.{}));
    fixture.flush();
    const last_handed = fixture.handed[fixture.handed_len - 1];
    try testing.expectEqual(
        @as(u64, constants.offload_in_flight_max),
        fixture.tables.table.at(last_handed).user_data,
    );
    try testing.expectEqual(@as(u32, 1), fixture.in_flight.held.count);
}

test "a cancel ends a held operation behind another held one at the next flush, with no room" {
    var fixture_value: Fixture = undefined;
    const fixture = &fixture_value;
    fixture.init();
    try fixture.submit_and_flush(constants.offload_in_flight_max);
    var handles: [test_held]Handle = undefined;
    for (&handles, 0..) |*handle, position| {
        const user_data = constants.offload_in_flight_max + position;
        const held = Operation.read(user_data, test_descriptor, &fixture.bytes, 0);
        try fixture.submit_one(held, handle);
    }
    try testing.expectEqual(@as(u32, test_held), fixture.in_flight.held.count);

    // The second held read is cancelled. The first still waits for room, and stays held.
    const behind = handles[test_held - 1];
    fixture.request(behind.index, fixture.tables.cancellable(behind).?);
    try testing.expect(fixture.in_flight.canceled);
    fixture.flush();
    try testing.expect(!fixture.in_flight.canceled);
    try testing.expectEqual(@as(u32, test_held - 1), fixture.in_flight.held.count);
    try testing.expectEqual(constants.offload_in_flight_max, fixture.in_flight.count);
    const event = try fixture.only_event(constants.offload_in_flight_max + test_held - 1);
    try testing.expectError(error.Canceled, event.outcome());

    // Room for one: the first held read goes out, and nothing else ends.
    fixture.take_back(1);
    fixture.flush();
    try testing.expectEqual(@as(u32, 0), fixture.in_flight.held.count);
    try testing.expectEqual(handles[0].index, fixture.handed[fixture.handed_len - 1]);
}

test "a held operation's deadline runs while it waits for room, and ends it with timeout" {
    var fixture_value: Fixture = undefined;
    const fixture = &fixture_value;
    fixture.init();
    try fixture.submit_and_flush(constants.offload_in_flight_max);
    var timed = Operation.read(test_slots, test_descriptor, &fixture.bytes, 0);
    timed.timeout_ns = test_timeout_ns;
    var handle: Handle = undefined;
    try fixture.submit_one(timed, &handle);
    // Held, and its deadline is armed from the flush that held it.
    try testing.expectEqual(@as(u32, 1), fixture.in_flight.held.count);
    try testing.expect(fixture.tables.timers.is_armed(handle.index));

    fixture.tables.now_ns = test_timeout_ns;
    fixture.tables.expire(fixture, Fixture.request);
    fixture.flush();
    try testing.expectEqual(@as(u32, 0), fixture.in_flight.held.count);
    const event = try fixture.only_event(test_slots);
    try testing.expectError(error.Timeout, event.outcome());
    try testing.expectEqual(constants.offload_in_flight_max, fixture.handed_len);
}

test "a close ends the held operations on its descriptor, and keeps the others in order" {
    var fixture_value: Fixture = undefined;
    const fixture = &fixture_value;
    fixture.init();
    try fixture.submit_and_flush(constants.offload_in_flight_max);
    var handles: [test_held + 1]Handle = undefined;
    const descriptors = [_]Descriptor{ test_descriptor, test_other_descriptor, test_descriptor };
    for (&handles, descriptors, 0..) |*handle, descriptor, position| {
        const user_data = constants.offload_in_flight_max + position;
        const write = Operation.write(user_data, descriptor, &fixture.bytes, 0);
        try fixture.submit_one(write, handle);
    }

    fixture.in_flight.end_descriptor(&fixture.tables, test_other_descriptor);
    try testing.expectEqual(@as(u32, test_held), fixture.in_flight.held.count);
    const event = try fixture.only_event(constants.offload_in_flight_max + 1);
    try testing.expectError(error.Canceled, event.outcome());

    // The two left go out in the order they came.
    fixture.take_back(test_held);
    fixture.flush();
    try testing.expectEqual(handles[0].index, fixture.handed[fixture.handed_len - 2]);
    try testing.expectEqual(handles[2].index, fixture.handed[fixture.handed_len - 1]);
}

test "a loop may sleep with operations held only while a worker owes it a result" {
    var in_flight: InFlight = .empty;
    try testing.expect(in_flight.may_sleep());
    in_flight.held.count = 1;
    try testing.expect(!in_flight.may_sleep());
    in_flight.count = 1;
    try testing.expect(in_flight.may_sleep());
}
