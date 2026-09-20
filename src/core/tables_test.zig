//! `Tables` under test: the half of a loop that is the same on every kernel.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const event_module = @import("event.zig");
const tables_module = @import("tables.zig");

const CancelAction = tables_module.CancelAction;
const core = @import("core.zig");

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Slot = core.Slot;
const Tables = tables_module.Tables;
const TimerHeap = core.timer_heap.TimerHeap;

const capacity = 4;

const Fixture = struct {
    slots: [capacity]Slot,
    entries: [capacity]TimerHeap.Entry,
    tables: Tables,
    buffer: [8]u8,

    fn init(fixture: *Fixture) void {
        fixture.tables.init(&fixture.slots, &fixture.entries, 2);
        fixture.buffer = @splat(0);
    }

    fn timer(user_data: u64, after_ns: u64) Operation {
        return .{ .user_data = user_data, .kind = .{ .timer = .{ .after_ns = after_ns } } };
    }

    fn receive(fixture: *Fixture, user_data: u64, timeout_ns: u64) Operation {
        return .{ .user_data = user_data, .timeout_ns = timeout_ns, .kind = .{ .receive = .{
            .socket = 3,
            .target = .{ .buffer = .{ .bytes = &fixture.buffer } },
        } } };
    }

    /// What a backend's flush does to the oldest queued slot: hands it to the kernel.
    fn hand_to_kernel(fixture: *Fixture) u32 {
        const tables = &fixture.tables;
        const index = tables.pending.pop(tables.table.slots).?;
        const slot = tables.table.at(index);
        slot.state = .submitted;
        tables.arm(index, slot);
        return index;
    }
};

test "submit claims slots in order until the table is full, and counts what it took" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var batch: [capacity + 2]Operation = undefined;
    for (&batch, 0..) |*operation, index| operation.* = Fixture.timer(index, 1);
    var handles: [capacity + 2]Handle = undefined;
    try testing.expectEqual(@as(u32, capacity), tables.submit(&batch, &handles));
    try testing.expectEqual(@as(u32, capacity), tables.in_flight());
    try testing.expectEqual(@as(u32, capacity), tables.pending.count);
    try testing.expectEqual(@as(u64, capacity), tables.operation_sequence);
    try testing.expectEqual(@as(u32, 0), tables.submit(batch[capacity..], &.{}));
    for (handles[0..capacity], 0..) |handle, index| {
        try testing.expectEqual(@as(u64, index), tables.table.lookup(handle).?.user_data);
    }
    try testing.expectEqual(@as(?u32, 0), tables.pending.peek());
}

test "a result the loop produced waits for the drain, which hands it over and frees the slot" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    _ = tables.submit(&.{ Fixture.timer(10, 1), Fixture.timer(11, 1) }, &.{});
    const first = fixture.hand_to_kernel();
    const second = fixture.hand_to_kernel();
    tables.finish_local(second, 0);
    tables.finish_local(first, event_module.result_of(.canceled));
    try testing.expectEqual(@as(u32, 2), tables.in_flight());
    try testing.expectEqual(@as(u32, 0), tables.timers.count);

    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), tables.drain_finished(&events));
    try testing.expectEqual(@as(u64, 11), events[0].user_data);
    try testing.expectEqual(@as(u32, 1), tables.in_flight());
    try testing.expectEqual(@as(u32, 1), tables.drain_finished(&events));
    try testing.expectEqual(@as(u64, 10), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u32, 0), tables.drain_finished(&events));
    tables.assert_empty();
}

test "a cancel ends a timer, leaves a queued slot to the flush and an operation to the backend" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var handles: [3]Handle = undefined;
    _ = tables.submit(&.{
        Fixture.timer(1, 5), fixture.receive(2, 0), fixture.receive(3, 0),
    }, &handles);
    const timer_index = fixture.hand_to_kernel();
    const receive_index = fixture.hand_to_kernel();

    const timer_slot = tables.cancellable(handles[0]).?;
    try testing.expectEqual(CancelAction.none, tables.request_cancel(timer_index, timer_slot));
    try testing.expectEqual(Slot.State.finishing, timer_slot.state);
    try testing.expectEqual(event_module.result_of(.canceled), timer_slot.result);
    try testing.expectEqual(@as(u32, 0), tables.timers.count);
    try testing.expectEqual(@as(?*Slot, null), tables.cancellable(handles[0]));

    const receive_slot = tables.cancellable(handles[1]).?;
    const first_request = tables.request_cancel(receive_index, receive_slot);
    try testing.expectEqual(CancelAction.backend, first_request);
    const second_request = tables.request_cancel(receive_index, receive_slot);
    try testing.expectEqual(CancelAction.none, second_request);
    try testing.expectEqual(Slot.State.submitted, receive_slot.state);

    const queued_slot = tables.cancellable(handles[2]).?;
    const queued_request = tables.request_cancel(handles[2].index, queued_slot);
    try testing.expectEqual(CancelAction.none, queued_request);
    try testing.expectEqual(Slot.State.queued, queued_slot.state);
    try testing.expect(queued_slot.flags.cancel_requested);
}

test "due timers finish in deadline order, and an operation whose deadline passed is returned" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    _ = tables.submit(&.{
        Fixture.timer(30, 30),   Fixture.timer(10, 10),
        fixture.receive(20, 20), Fixture.timer(99, 99),
    }, &.{});
    for (0..4) |_| _ = fixture.hand_to_kernel();
    try testing.expectEqual(@as(u32, 4), tables.timers.count);

    tables.now_ns = 9;
    try testing.expectEqual(@as(?u32, null), tables.next_expired());
    tables.now_ns = 30;
    const expired = tables.next_expired().?;
    try testing.expectEqual(@as(u64, 20), tables.table.at(expired).user_data);
    try testing.expect(tables.table.at(expired).flags.timed_out);
    try testing.expectEqual(@as(?u32, null), tables.next_expired());
    try testing.expectEqual(@as(u32, 1), tables.timers.count);

    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 2), tables.drain_finished(&events));
    try testing.expectEqual(@as(u64, 10), events[0].user_data);
    try testing.expectEqual(@as(u64, 30), events[1].user_data);
    try testing.expectEqual(@as(u32, 0), try events[0].outcome());
}

test "arm uses a timer's delay and an operation's deadline, and leaves an armed slot alone" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    tables.now_ns = 100;
    const batch = [_]Operation{
        Fixture.timer(1, 7), fixture.receive(2, 50), fixture.receive(3, 0),
    };
    _ = tables.submit(&batch, &.{});
    const timer_index = fixture.hand_to_kernel();
    const timed_index = fixture.hand_to_kernel();
    _ = fixture.hand_to_kernel();
    try testing.expectEqual(@as(u32, 2), tables.timers.count);
    try testing.expectEqual(@as(?u64, 107), tables.timers.earliest_ns());
    tables.timers.disarm(timer_index);
    try testing.expectEqual(@as(?u64, 150), tables.timers.earliest_ns());
    // A slot resubmitted later keeps the deadline it was given first.
    tables.now_ns = 140;
    tables.arm(timed_index, tables.table.at(timed_index));
    try testing.expectEqual(@as(?u64, 150), tables.timers.earliest_ns());
}

test "a tick may wait only when nothing is queued, and never past the nearest deadline" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    const second = constants.ns_per_s;
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(0));
    try testing.expectEqual(@as(?u64, second), tables.wait_bound(second));
    _ = tables.submit(&.{Fixture.timer(1, 40)}, &.{});
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(second));
    const index = fixture.hand_to_kernel();
    try testing.expectEqual(@as(?u64, 40), tables.wait_bound(second));
    try testing.expectEqual(@as(?u64, 25), tables.wait_bound(25));
    tables.now_ns = 40;
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(second));
    tables.timers.disarm(index);
    tables.finish_local(index, 0);
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(second));
}

test "an operation may name a registered descriptor once the loop has noted how many it has" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    try testing.expectEqual(@as(u32, 0), tables.descriptors_registered);
    tables.note_descriptors(3);
    try testing.expectEqual(@as(u32, 3), tables.descriptors_registered);

    var operation = fixture.receive(7, 0);
    operation.descriptor_registered = true;
    operation.kind.receive.socket = 2;
    try testing.expectEqual(@as(u32, 1), tables.submit(&.{operation}, &.{}));
    const slot = tables.table.at(tables.pending.peek().?);
    try testing.expect(slot.flags.descriptor_registered);
    try testing.expectEqual(@as(i32, 2), slot.descriptor);
}

test "next_cancellable walks the slots a cancel can still reach, and skips the finishing" {
    var fixture: Fixture = undefined;
    fixture.init();
    const tables = &fixture.tables;
    try testing.expectEqual(@as(?u32, null), tables.next_cancellable(0));
    const batch = [_]Operation{ Fixture.timer(1, 5), Fixture.timer(2, 5), Fixture.timer(3, 5) };
    var handles: [batch.len]Handle = undefined;
    try testing.expectEqual(@as(u32, batch.len), tables.submit(&batch, &handles));
    // The first is handed to the kernel, the second finishes, the third stays queued.
    const submitted = fixture.hand_to_kernel();
    const finishing = tables.pending.pop(tables.table.slots).?;
    tables.finish_local(finishing, 0);
    const queued = tables.pending.peek().?;

    var reached: [capacity]u32 = undefined;
    var count: u32 = 0;
    var from: u32 = 0;
    while (tables.next_cancellable(from)) |index| : (from = index + 1) {
        reached[count] = index;
        count += 1;
    }
    try testing.expectEqual(@as(u32, 2), count);
    const low = @min(submitted, queued);
    const high = @max(submitted, queued);
    try testing.expectEqualSlices(u32, &.{ low, high }, reached[0..count]);
    try testing.expectEqual(@as(?u32, null), tables.next_cancellable(tables.table.capacity()));
}
