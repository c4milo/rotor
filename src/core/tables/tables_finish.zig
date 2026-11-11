//! How the tables hand over the events the loop produced itself: a slot that the loop ends waits on
//! `finished`, a due timer waits on `fired`, and the next drain hands its event over and releases
//! the slot (decision 5, rules 1 and 2). Both lists are first in, first out. When both hold more
//! than a drain has places for, each takes about half of them (W3, ruled 2026-11-07). Split from
//! `tables.zig` for the 500-line limit. `Tables` declares the public ones, so a caller writes
//! `tables.finish_local(...)`.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("../assertion_class.zig").assert_class_a;
const event_module = @import("../event.zig");
const slot_module = @import("../slot.zig");
const slot_list_module = @import("../slot_list.zig");
const deadline = @import("tables_deadline.zig");
const tables_module = @import("tables.zig");

const Event = event_module.Event;
const Slot = slot_module.Slot;
const SlotList = slot_list_module.SlotList;
const Tables = tables_module.Tables;

/// The lists a drain shares its places between: `fired` and `finished`.
const lists_count = 2;

/// The loop produced the operation's final result itself. The slot waits on `finished`, and
/// the next `drain_finished` hands its event over and releases it: never the call that
/// produced the result (decision 5, rule 2).
pub fn finish_local(tables: *Tables, index: u32, result: i32) void {
    // A receive from a group that succeeded took a buffer, which `finish_local_buffer` records.
    assert_class_a(result < 0 or !names_buffer(tables.table.at(index)));
    finish_now(tables, index, result);
}

/// `finish_local` for a single-shot receive from a group that the flush completed: its event
/// names the buffer the call took. The slot holds the id in `len` until the event is handed
/// over, because a receive from a group names no buffer of its own and leaves `len` unused.
pub fn finish_local_buffer(tables: *Tables, index: u32, result: i32, buffer_id: u16) void {
    const slot = tables.table.at(index);
    assert(names_buffer(slot));
    assert(result >= 0);
    slot.len = buffer_id;
    finish_now(tables, index, result);
}

fn finish_now(tables: *Tables, index: u32, result: i32) void {
    finish_onto(tables, &tables.finished, index, result);
}

/// A due timer's fire: the slot waits on `fired`, in the order the timers came due, and the next
/// drain hands its event over (W3, ruled 2026-11-07). A timer that a cancel ends goes to `finished`
/// through `finish_canceled`.
pub fn fire(tables: *Tables, index: u32) void {
    assert(tables.table.at(index).tag == .timer);
    finish_onto(tables, &tables.fired, index, 0);
}

/// Ends the slot in `index` with `result` and puts it at the back of `list`.
fn finish_onto(tables: *Tables, list: *SlotList, index: u32, result: i32) void {
    const slot = tables.table.at(index);
    assert_class_a(slot.state == .queued or slot.state == .submitted);
    if (slot.heap_position != slot_module.heap_position_none) tables.timers.disarm(index);
    slot.state = .finishing;
    slot.result = result;
    list.push(tables.table.slots, index);
}

/// Hands the caller the events the loop produced itself, into at most `lists_max` places of
/// `events`, and releases their slots: the moment decision 5, rule 1 names. Of `F = lists_max`
/// places, `fired` takes up to `F - min(finished.count, F / 2)`, and `finished` takes what is left.
/// So when both lists hold `F` or more, each takes about half, and no place stays empty while
/// either list holds an entry (W3, ruled 2026-11-07). Each pop writes one place and slices
/// nothing, so a share past the events halts only where a pop writes.
pub fn drain_lists(tables: *Tables, events: []Event, lists_max: u32) u32 {
    assert(lists_max <= events.len);
    const fired_max = lists_max - @min(tables.finished.count, lists_max / lists_count);
    // One loop pops both lists, so `hand_over` has one call, which the compiler inlines. With a
    // loop for each list it did not, and a drain of one timer cost 29 instructions more
    // (cachegrind, arm64 Linux, 2026-11-07).
    var produced: u32 = 0;
    while (produced < lists_max) : (produced += 1) {
        const fired = if (produced < fired_max) tables.fired.pop(tables.table.slots) else null;
        const index = fired orelse tables.finished.pop(tables.table.slots) orelse break;
        hand_over(tables, index, &events[produced]);
    }
    assert(produced <= lists_max);
    return produced;
}

/// `drain_lists` into every place of `events`: for the callers that drain everything, and for a
/// tick whose lists cannot reach the reserves (`core.tick_share.drain_first`).
pub fn drain_finished(tables: *Tables, events: []Event) u32 {
    return drain_lists(tables, events, @intCast(events.len));
}

/// Writes the event of the slot in `index`, which a drain took off its list, to `event`. Then it
/// releases the slot, or arms a repeating timer's next fire.
fn hand_over(tables: *Tables, index: u32, event: *Event) void {
    const slot = tables.table.at(index);
    assert_class_a(slot.state == .finishing);
    // A repeating timer that was not cancelled has more to come: its event says so and its slot
    // stays the loop's (decision 14, rule 2).
    const again = repeats(slot);
    if (slot.flags.sampled and !again) tables.statistics.finished(index, slot, tables.now_ns);
    // The flags are built in a register and stored with the event. A packed literal with two
    // runtime fields compiled to a read of the old event and a second write (decision 26).
    var flags: Event.Flags = .{};
    flags.more = again;
    flags.dispatched = slot.flags.dispatched;
    event.* = .{ .user_data = slot.user_data, .result = slot.result, .flags = flags };
    if (names_buffer(slot) and slot.result >= 0) {
        event.flags.buffer = true;
        event.flags.buffer_id = @intCast(slot.len);
    }
    if (again) deadline.rearm(tables, index, slot) else tables.table.release(index);
}

/// True for a single-shot receive from a group: an event of it that succeeded names the buffer
/// its bytes are in. A multishot one never finishes locally with a success.
fn names_buffer(slot: *const Slot) bool {
    return slot.flags.buffer_group and !slot.flags.multishot;
}

/// True when this slot is a repeating timer whose caller has not cancelled it, so the event
/// being handed over is one of many and not the last (decision 14, rule 2).
pub fn repeats(slot: *const Slot) bool {
    if (slot.tag != .timer or !slot.flags.multishot) return false;
    return !slot.flags.cancel_requested;
}

const testing = std.testing;
const Heartbeat = @import("../stall.zig").Heartbeat;
const Operation = @import("../operation.zig").Operation;
const TimerHeap = @import("../timer_heap.zig").TimerHeap;

/// Slots of the tests below: room for the two full lists of the first one.
const test_slots = 96;

/// The buffer of the receives the tests finish, and the socket they name. No kernel sees either.
const test_bytes = 8;
const test_socket = 3;

/// The test of both expiries: two due timers and three finished receives.
const expiry_timers = 2;
const expiry_finished = 3;

/// The user data of the first timer a test submits. A finished receive's user data starts at 0.
const timer_user_data_first = 1000;

/// Tables over memory the test owns, as a backend's loop holds them.
const TestTables = struct {
    slots: [test_slots]Slot,
    entries: [test_slots]TimerHeap.Entry,
    starts: [test_slots]u64,
    heartbeat: Heartbeat,
    tables: Tables,
    bytes: [test_bytes]u8,

    fn init(fixture: *TestTables) void {
        const tables = &fixture.tables;
        tables.init(&fixture.slots, &fixture.entries, &fixture.starts, &fixture.heartbeat, .{});
        fixture.bytes = @splat(0);
    }

    /// Submits `count` receives, hands each to the kernel, and ends each as the loop ends one it
    /// performed itself: onto `finished`, in order.
    fn finish(fixture: *TestTables, count: u32) !void {
        const tables = &fixture.tables;
        for (0..count) |user_data| {
            const receive = Operation.receive(user_data, test_socket, &fixture.bytes);
            try testing.expectEqual(@as(u32, 1), tables.submit(&.{receive}, &.{}));
            const index = tables.next_pending().?;
            tables.take_pending(index);
            tables.hand_over(index, tables.table.at(index));
            tables.finish_local(index, 0);
        }
    }

    /// Submits `count` timers, the first due after `count` ns and each later one 1 ns sooner, and
    /// arms them. So the timers come due in the reverse of the order they were submitted.
    fn arm_timers(fixture: *TestTables, count: u32, repeat_ns: u64) !void {
        const tables = &fixture.tables;
        for (0..count) |offset| {
            const timer = Operation.timer(timer_user_data_first + offset, count - offset, repeat_ns);
            try testing.expectEqual(@as(u32, 1), tables.submit(&.{timer}, &.{}));
        }
        try testing.expectEqual(@as(?u32, null), tables.next_pending());
    }
};

/// The two kinds of event a drain hands over in these tests.
const Kinds = struct {
    timers: u32 = 0,
    finished: u32 = 0,
};

/// Counts the timer events and the other events among `events`.
fn kinds(events: []const Event) Kinds {
    var counted: Kinds = .{};
    for (events) |event| {
        if (event.user_data >= timer_user_data_first) counted.timers += 1 else counted.finished += 1;
    }
    return counted;
}

test "when both lists are full, each takes half of the places, in its own order" {
    var fixture: TestTables = undefined;
    fixture.init();
    const tables = &fixture.tables;
    const count = 40;
    try fixture.finish(count);
    try fixture.arm_timers(count, 0);
    tables.now_ns = count;
    tables.finish_due_timers();
    try testing.expectEqual(@as(u32, count), tables.fired.count);
    var events: [10]Event = undefined;
    for (0..count / 5) |drain| {
        try testing.expectEqual(@as(u32, 10), tables.drain_lists(&events, 10));
        const counted = kinds(&events);
        try testing.expectEqual(@as(u32, 5), counted.timers);
        try testing.expectEqual(@as(u32, 5), counted.finished);
        // The fired list comes first. The last timer submitted came due first.
        for (events[0..5], 0..) |event, offset| {
            const due = drain * 5 + offset;
            try testing.expectEqual(timer_user_data_first + count - 1 - due, event.user_data);
        }
        for (events[5..10], 0..) |event, offset| {
            try testing.expectEqual(drain * 5 + offset, event.user_data);
        }
    }
    try testing.expectEqual(@as(u32, 0), tables.in_flight());
}

test "a timer that repeats every nanosecond does not hold the finished list off" {
    var fixture: TestTables = undefined;
    fixture.init();
    const tables = &fixture.tables;
    const count = 20;
    try fixture.finish(count);
    try fixture.arm_timers(1, 1);
    var events: [4]Event = undefined;
    var next_finished: u64 = 0;
    for (1..11) |now_ns| {
        tables.now_ns = now_ns;
        tables.finish_due_timers();
        const produced = tables.drain_lists(&events, events.len);
        // The timer fires once in each tick, flagged `more`, and comes first.
        try testing.expectEqual(timer_user_data_first, events[0].user_data);
        try testing.expect(events[0].flags.more);
        for (events[1..produced]) |event| {
            try testing.expectEqual(next_finished, event.user_data);
            next_finished += 1;
        }
    }
    try testing.expectEqual(@as(u64, count), next_finished);
}

test "a list that is short leaves its places to the other" {
    var fixture: TestTables = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var events: [10]Event = undefined;
    try fixture.finish(40);
    try fixture.arm_timers(2, 0);
    tables.now_ns = 2;
    tables.finish_due_timers();
    try testing.expectEqual(@as(u32, 10), tables.drain_lists(&events, 10));
    try testing.expectEqual(Kinds{ .timers = 2, .finished = 8 }, kinds(&events));

    fixture.init();
    try fixture.finish(2);
    try fixture.arm_timers(40, 0);
    tables.now_ns = 40;
    tables.finish_due_timers();
    try testing.expectEqual(@as(u32, 10), tables.drain_lists(&events, 10));
    try testing.expectEqual(Kinds{ .timers = 8, .finished = 2 }, kinds(&events));
}

/// A cancel that the expiry should never ask for: every armed slot of these tests is a timer.
fn no_cancel(tables: *Tables, index: u32, slot: *Slot) void {
    _ = tables;
    _ = index;
    _ = slot;
    unreachable;
}

/// Checks that the two due timers of `fixture` wait on `fired` in deadline order, and the three
/// finished receives wait on `finished` behind them.
fn expect_fired_in_order(fixture: *TestTables) !void {
    const tables = &fixture.tables;
    try testing.expectEqual(@as(u32, expiry_timers), tables.fired.count);
    try testing.expectEqual(@as(u32, expiry_finished), tables.finished.count);
    var events: [expiry_timers + expiry_finished]Event = undefined;
    try testing.expectEqual(@as(u32, events.len), tables.drain_lists(&events, events.len));
    // The last timer submitted came due first, and the receives keep their order behind them.
    for (events[0..expiry_timers], 0..) |event, offset| {
        try testing.expectEqual(timer_user_data_first + expiry_timers - 1 - offset, event.user_data);
    }
    for (events[expiry_timers..], 0..) |event, offset| {
        try testing.expectEqual(@as(u64, offset), event.user_data);
    }
}

test "both expiries put due timers on the fired list, and a cancelled timer on the finished list" {
    var fixture: TestTables = undefined;
    const tables = &fixture.tables;
    // The first expiry of a tick.
    fixture.init();
    try fixture.finish(3);
    try fixture.arm_timers(2, 0);
    tables.now_ns = 2;
    tables.finish_due_timers();
    try expect_fired_in_order(&fixture);
    // The expiry after the reap.
    fixture.init();
    try fixture.finish(3);
    try fixture.arm_timers(2, 0);
    tables.now_ns = 2;
    tables.expire(tables, no_cancel);
    try expect_fired_in_order(&fixture);
    // A cancel ends a timer on `finished`.
    fixture.init();
    var handles: [1]@import("../handle.zig").Handle = undefined;
    _ = tables.submit(&.{Operation.timer(timer_user_data_first, 5, 0)}, &handles);
    try testing.expectEqual(@as(?u32, null), tables.next_pending());
    _ = tables.request_cancel(handles[0].index, tables.cancellable(handles[0]).?);
    try testing.expectEqual(@as(u32, 0), tables.fired.count);
    try testing.expectEqual(@as(u32, 1), tables.finished.count);
}

test "a tick does not block while a fired timer waits to be handed over" {
    var fixture: TestTables = undefined;
    fixture.init();
    const tables = &fixture.tables;
    const wait_ns = 1000;
    try fixture.arm_timers(1, 0);
    tables.now_ns = 1;
    tables.finish_due_timers();
    try testing.expectEqual(@as(u32, 1), tables.fired.count);
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(wait_ns));
    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), tables.drain_finished(&events));
    try testing.expectEqual(@as(?u64, wait_ns), tables.wait_bound(wait_ns));
}
