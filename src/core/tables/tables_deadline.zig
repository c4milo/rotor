//! When the tables' deadlines run: how the loop arms an operation's deadline or a timer's delay,
//! where each starts, how long a tick may block before the nearest one, where in a tick each kind
//! of deadline expires, how the loop finds an operation whose deadline passed, and when a repeating
//! timer fires next. Split from `tables.zig` for the 500-line limit. `Tables` declares the public
//! ones, so a caller writes `tables.arm(...)`.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("../assertion_class.zig").assert_class_a;
const constants = @import("../constants.zig");
const event_module = @import("../event.zig");
const slot_module = @import("../slot.zig");
const tables_module = @import("tables.zig");

const Event = event_module.Event;
const Slot = slot_module.Slot;
const Tables = tables_module.Tables;
const WaitLimit = @import("../dispatch/dispatch.zig").WaitLimit;

/// Arms the deadline of a slot the backend has just handed to the kernel, or the delay of a timer.
/// A slot being resubmitted keeps the deadline it has.
pub fn arm(tables: *Tables, index: u32, slot: *Slot) void {
    const after_ns = if (slot.tag == .timer) slot.offset else slot.timeout_ns;
    assert_class_a(after_ns <= constants.timeout_ns_max);
    if (slot.tag != .timer and after_ns == 0) return;
    if (tables.timers.is_armed(index)) return;
    const due_ns = start_ns(tables, slot) + after_ns;
    // A repeating timer measures every later period from this deadline (decision 14, rule 3).
    if (slot.tag == .timer) slot.buffer = due_ns;
    tables.timers.arm(index, due_ns);
}

/// When a delay or a deadline starts running. A timer's starts at the reading the caller saw when
/// it submitted the timer, which `submit` kept in `Slot.buffer`, as libuv's and libxev's timers
/// start at the loop's cached time: a timer re-armed while the caller works through a batch does
/// not also wait out the rest of the batch (decision 14, rule 6). A timer submitted before any
/// tick read the clock, and an operation's deadline, start at this tick's reading.
fn start_ns(tables: *const Tables, slot: *const Slot) u64 {
    if (slot.tag != .timer or slot.buffer == 0) return tables.now_ns;
    // The clock only moves forward, so the reading at submit is at or before this one.
    assert(slot.buffer <= tables.now_ns);
    return slot.buffer;
}

/// How long a tick may block: not at all while queued work waits for the next flush, and never
/// past the nearest deadline, a timer's or a poller's limit (decision 29). Null means do not
/// block. A limit at or before this tick's stamp gives no wait, so the next `begin` calls the
/// poller again, and the poller sees its deadline due.
pub fn wait_bound(tables: *const Tables, wait_ns: u64) ?u64 {
    assert(wait_ns <= constants.wait_ns_max);
    if (wait_ns == 0) return null;
    const lists = tables.finished.count + tables.fired.count;
    if (tables.pending.count != 0 or lists != 0) return null;
    const earliest = earliest_limit(tables);
    if (earliest == @intFromEnum(WaitLimit.none)) return wait_ns;
    if (earliest <= tables.now_ns) return null;
    return @min(wait_ns, earliest - tables.now_ns);
}

/// The least of the nearest timer and the pollers' limit, on the loop's clock, or null when neither
/// exists. A deadline inside a spin's window ends the spin before it starts, so the tick sleeps
/// until the deadline and does not poll for it (decision 13, point 2; decision 29).
pub fn earliest_deadline_ns(tables: *const Tables) ?u64 {
    const earliest = earliest_limit(tables);
    if (earliest == @intFromEnum(WaitLimit.none)) return null;
    return earliest;
}

/// The least of the nearest timer and the pollers' limit, on the loop's clock: `maxInt(u64)`, the
/// value of `.none`, when neither exists.
fn earliest_limit(tables: *const Tables) u64 {
    const timer = tables.timers.earliest_ns() orelse @intFromEnum(WaitLimit.none);
    return @min(timer, @intFromEnum(tables.dispatch.until_ns));
}

/// Core's part of `Loop.wait_limit`, a host's last call before it sleeps (decision 29). `.now`
/// while a task is queued, operations wait to be submitted, results wait to be handed over, or
/// the least of the nearest timer and the pollers' limit is at or before `now_ns`. Otherwise `.at`
/// of that least value, or `.none` when neither exists. It reads no clock and changes nothing.
/// Halts inside a tick. The backend adds its mailboxes.
pub fn wait_limit(tables: *const Tables) WaitLimit {
    if (tables.dispatch.limit_between_ticks() == .now) return .now;
    const lists = tables.finished.count + tables.fired.count;
    if (tables.pending.count != 0 or lists != 0) return .now;
    const earliest = earliest_limit(tables);
    if (earliest <= tables.now_ns) return .now;
    return .at(earliest);
}

/// A tick's first expiry, before it asks the kernel anything: moves the due timers at the head
/// of the heap onto `fired`, in deadline order, and stops at the first operation's deadline. An
/// operation's result can be on its way from the kernel, so its deadline waits for
/// `expire_after_reap` (issue 10). A timer's cannot, so a tick whose only work is a due timer
/// hands it over at once.
pub fn finish_due_timers(tables: *Tables) void {
    const armed = tables.timers.count;
    var finished: u32 = 0;
    while (finished < armed) : (finished += 1) {
        const earliest_ns = tables.timers.earliest_ns() orelse return;
        if (earliest_ns > tables.now_ns) return;
        const head = tables.timers.entries[0].slot;
        if (tables.table.at(head).tag != .timer) return;
        const index = tables.timers.pop_due(tables.now_ns).?;
        assert(index == head);
        tables.fire(index);
    }
    assert(tables.timers.count <= armed);
}

/// Moves every timer that is due onto `fired`, and returns the next operation whose deadline
/// passed, marked `timed_out`, for the backend to cancel (decision 5, rule 4). Null when nothing
/// more is due. At most the heap's entries can be due, which bounds the loop.
///
/// An expired slot may be `queued` and not only `submitted`. A backend that resubmits an
/// operation the kernel refused transiently puts it back on the pending list and leaves its
/// deadline armed, because the deadline belongs to the operation and not to one attempt of
/// it (`uring_reap.zig`, `should_retry`). Its deadline can pass before the flush that would
/// resubmit it, and a tick reaches exactly that: it reaps, the retry produces no event, and
/// it expires again against a clock it has just read. Requiring `submitted` here halted such
/// a loop, with assertions on in production, and no test covered it.
pub fn next_expired(tables: *Tables) ?u32 {
    const armed = tables.timers.count;
    var popped: u32 = 0;
    while (popped < armed) : (popped += 1) {
        const index = tables.timers.pop_due(tables.now_ns) orelse return null;
        const slot = tables.table.at(index);
        assert(slot.state == .queued or slot.state == .submitted);
        if (slot.tag != .timer) {
            slot.flags.timed_out = true;
            return index;
        }
        tables.fire(index);
    }
    return null;
}

/// Finishes every timer that is due, and hands `request` every operation whose deadline passed,
/// marked `timed_out`, to cancel (decision 5, rule 4). Every backend's tick runs it, with its
/// own cancel as `request` and its loop as `backend`. At most the heap's entries can be due,
/// which bounds the loop.
pub fn expire(
    tables: *Tables,
    backend: anytype,
    comptime request: fn (@TypeOf(backend), u32, *Slot) void,
) void {
    const armed = tables.timers.count;
    var expired: u32 = 0;
    while (expired < armed) : (expired += 1) {
        const index = next_expired(tables) orelse break;
        request(backend, index, tables.table.at(index));
    }
    assert(tables.timers.count <= armed);
}

/// A tick's last step, after its reap: `Tables.expire`, then hand over what is finished into
/// `events`. The reap comes first, so an operation whose result was ready when the tick began ends
/// with that result and not with `timeout`: the loop's own cancel loses that race, as decision 5,
/// rule 2 says a cancel can (decision 11, point 1, amended 2026-11-01). Returns how many events it
/// wrote. A tick with nothing due returns at once, and leaves what its reap finished for the next
/// tick's drain, as it did before.
pub fn expire_after_reap(
    tables: *Tables,
    backend: anytype,
    comptime request: fn (@TypeOf(backend), u32, *Slot) void,
    events: []Event,
) u32 {
    const earliest_ns = tables.timers.earliest_ns() orelse return 0;
    if (earliest_ns > tables.now_ns) return 0;
    tables.expire(backend, request);
    return tables.drain_finished(events);
}

/// Schedules a repeating timer's next fire from the deadline it just fired for, never from
/// the clock, so a loop that was late does not make the period late (decision 14, rule 3).
/// A deadline already past is armed anyway and fires at the next tick: rule 4 hands the
/// caller an event per missed period rather than swallowing them.
pub fn rearm(tables: *Tables, index: u32, slot: *Slot) void {
    assert(slot.tag == .timer and slot.flags.multishot);
    assert(slot.timeout_ns >= 1);
    slot.buffer +%= slot.timeout_ns;
    slot.state = .submitted;
    tables.timers.arm(index, slot.buffer);
}

const testing = std.testing;
const Completion = @import("../dispatch/dispatch.zig").Completion;
const Handle = @import("../handle.zig").Handle;
const Heartbeat = @import("../stall.zig").Heartbeat;
const Operation = @import("../operation.zig").Operation;
const TimerHeap = @import("../timer_heap.zig").TimerHeap;

/// Slots of the tests below: room for every operation one of them submits.
const test_slots = 4;

/// The user data of the operation that names no record.
const plain_user_data = 9;

/// Tables over memory the test owns, as a backend's loop holds them.
const TestTables = struct {
    slots: [test_slots]Slot,
    entries: [test_slots]TimerHeap.Entry,
    starts: [test_slots]u64,
    heartbeat: Heartbeat,
    tables: Tables,

    fn init(fixture: *TestTables) void {
        const tables = &fixture.tables;
        tables.init(&fixture.slots, &fixture.entries, &fixture.starts, &fixture.heartbeat, .{});
    }
};

/// A record that no tick calls here: the drain only marks the events of its operations.
fn ignore(completion: *Completion, event: Event) void {
    _ = completion;
    _ = event;
}

/// The static entry of a record written by hand (decision 28).
const ignore_call: Completion.Call = .{ .name = "ignore", .function = &ignore };

/// What a readiness backend's cancel does to an operation whose deadline passed: it ends it.
fn end_now(tables: *Tables, index: u32, slot: *Slot) void {
    assert(slot.flags.timed_out);
    slot.flags.cancel_requested = true;
    tables.finish_canceled(index);
}

test "a timer the loop fires hands its final event and its repeats to the record" {
    var fixture: TestTables = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var record: Completion = .{ .call = &ignore_call };
    const timers = [_]Operation{
        Operation.timer(0, 1, 0).completion(&record),
        Operation.timer(0, 1, 5).completion(&record),
        Operation.timer(plain_user_data, 1, 0),
    };
    try testing.expectEqual(@as(u32, timers.len), tables.submit(&timers, &.{}));
    // The flush arms every timer and hands none of them to a kernel.
    try testing.expectEqual(@as(?u32, null), tables.next_pending());
    tables.now_ns = 1;
    finish_due_timers(tables);
    var events: [test_slots]Event = undefined;
    try testing.expectEqual(@as(u32, timers.len), tables.drain_finished(&events));
    var repeats: u32 = 0;
    for (events[0..timers.len]) |event| {
        try testing.expectEqual(event.user_data != plain_user_data, event.flags.dispatched);
        repeats += @intFromBool(event.flags.more);
    }
    try testing.expectEqual(@as(u32, 1), repeats);
}

test "a deadline and a cancel in the queue end the operation with an event for its record" {
    var fixture: TestTables = undefined;
    fixture.init();
    const tables = &fixture.tables;
    var record: Completion = .{ .call = &ignore_call };
    var bytes: [8]u8 = @splat(0);
    var timed = Operation.receive(0, 3, &bytes);
    timed.timeout_ns = 1;
    const queued = Operation.receive(0, 4, &bytes);
    var handles: [2]Handle = undefined;
    _ = tables.submit(&.{ timed.completion(&record), queued.completion(&record) }, &handles);
    // The first goes to the kernel and arms its deadline. The second is cancelled in the queue.
    const index = tables.next_pending().?;
    tables.take_pending(index);
    tables.hand_over(index, tables.table.at(index));
    _ = tables.request_cancel(handles[1].index, tables.cancellable(handles[1]).?);
    try testing.expectEqual(@as(?u32, null), tables.next_pending());
    tables.now_ns = 1;
    var events: [test_slots]Event = undefined;
    try testing.expectEqual(@as(u32, 2), expire_after_reap(tables, tables, end_now, &events));
    for (events[0..2]) |event| {
        try testing.expect(event.flags.dispatched and event.is_final());
    }
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectError(error.Timeout, events[1].outcome());
}
