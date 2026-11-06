//! A loop that several libraries share (decision 26). An operation may name a `Completion`, a
//! record in the library's own memory, and the tick calls it for each event of that operation. A
//! library may also add a `Poller`, which the loop calls once in each tick. An event whose operation
//! named no record goes back to the caller of `tick`, as before.
//!
//! The records and the pollers live in memory the library owns, so the loop allocates nothing. The
//! loop calls through a record's address and never decides anything from its value
//! (non-negotiable 2). The callbacks run in the order of the events.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("assertion_class.zig").assert_class_a;
const constants = @import("constants.zig");
const Event = @import("event.zig").Event;

/// What an operation names to have the tick call `callback` for each of its events. The library
/// puts it inside its own struct. `init` writes the callback that finds that struct again.
pub const Completion = struct {
    callback: *const fn (completion: *Completion, event: Event) void,

    /// A record at `field` of `Parent` that calls `handler` with its parent for each event. The
    /// compiler checks the field, the parent and the handler, and the callback it makes costs the
    /// same indirect call as one written by hand.
    pub fn init(
        comptime Parent: type,
        comptime field: []const u8,
        comptime handler: fn (parent: *Parent, event: Event) void,
    ) Completion {
        comptime assert(@FieldType(Parent, field) == Completion);
        return .{ .callback = struct {
            fn call(completion: *Completion, event: Event) void {
                const parent: *Parent = @alignCast(@fieldParentPtr(field, completion));
                handler(parent, event);
            }
        }.call };
    }
};

/// What a library adds to have the loop call `poll` once in each tick, before the tick waits.
/// `poll` returns true when the tick must not block, for example because work is left: the tick
/// then waits 0 ns. True means nothing else.
pub const Poller = struct {
    poll: *const fn (poller: *Poller) bool,

    /// A poller at `field` of `Parent` that calls `handler` with its parent.
    pub fn init(
        comptime Parent: type,
        comptime field: []const u8,
        comptime handler: fn (parent: *Parent) bool,
    ) Poller {
        comptime assert(@FieldType(Parent, field) == Poller);
        return .{ .poll = struct {
            fn call(poller: *Poller) bool {
                const parent: *Parent = @alignCast(@fieldParentPtr(field, poller));
                return handler(parent);
            }
        }.call };
    }
};

pub const AddPollerError = error{PollersFull};

/// The state of the dispatch, which `Tables` holds.
pub const Dispatch = struct {
    pollers: [constants.pollers_max]*Poller,
    poller_count: u8,
    /// Operations in flight that named a record. With no poller, the tick walks the events only
    /// while this is above 0, so a program that names no record pays two compares in each tick.
    records_in_flight: u32,
    /// True from `begin` to `end`: a callback or a poller that calls `tick` halts.
    ticking: bool,
    /// True while `begin` calls the pollers: a poller that adds or removes a poller halts, because
    /// the loop is walking the table. A callback may add or remove one.
    polling: bool,

    pub const empty: Dispatch = .{
        .pollers = undefined,
        .poller_count = 0,
        .records_in_flight = 0,
        .ticking = false,
        .polling = false,
    };

    pub fn add_poller(dispatch: *Dispatch, poller: *Poller) AddPollerError!void {
        assert(!dispatch.polling);
        assert(dispatch.poller_count <= constants.pollers_max);
        for (dispatch.pollers[0..dispatch.poller_count]) |added| assert(added != poller);
        if (dispatch.poller_count == constants.pollers_max) return error.PollersFull;
        dispatch.pollers[dispatch.poller_count] = poller;
        dispatch.poller_count += 1;
    }

    /// Removes `poller`, which must have been added. The pollers after it keep their order.
    pub fn remove_poller(dispatch: *Dispatch, poller: *Poller) void {
        assert(!dispatch.polling);
        const count = dispatch.poller_count;
        const found = std.mem.indexOfScalar(*Poller, dispatch.pollers[0..count], poller);
        assert(found != null);
        const index = found orelse return;
        const after = dispatch.pollers[index + 1 .. count];
        std.mem.copyForwards(*Poller, dispatch.pollers[index .. count - 1], after);
        dispatch.poller_count = count - 1;
    }

    /// Halts when a poller is still added: what `deinit` checks, because the poller is memory the
    /// library owns and may free once the loop has ended.
    pub fn assert_empty(dispatch: *const Dispatch) void {
        assert(dispatch.poller_count == 0);
    }

    /// Counts the `records` operations with a record that one `submit` took.
    pub fn note_submitted(dispatch: *Dispatch, records: u32) void {
        dispatch.records_in_flight += records;
    }

    /// True when no poller is added and no operation with a record is in flight: no callback can
    /// run in the next tick, so the tick skips `begin` and `end`.
    pub fn idle(dispatch: *const Dispatch) bool {
        return dispatch.poller_count == 0 and dispatch.records_in_flight == 0;
    }

    /// The start of a tick: halts inside another tick, then calls every poller once. Returns the
    /// wait the tick may block for: 0 when a poller did work, and `wait_ns` when none did.
    pub fn begin(dispatch: *Dispatch, wait_ns: u64) u64 {
        assert_class_a(!dispatch.ticking);
        dispatch.ticking = true;
        dispatch.polling = true;
        var worked = false;
        for (dispatch.pollers[0..dispatch.poller_count]) |poller| {
            if (poller.poll(poller)) worked = true;
        }
        dispatch.polling = false;
        return if (worked) 0 else wait_ns;
    }

    /// The end of a tick: calls the record of each event that has one, and moves the other events
    /// to the front of `events`, in order. Returns how many are at the front.
    pub fn end(dispatch: *Dispatch, events: []Event) u32 {
        assert_class_a(dispatch.ticking);
        defer dispatch.ticking = false;
        return dispatch.call_records(events);
    }

    /// Ends a tick that failed, so the next tick may begin.
    pub fn abandon(dispatch: *Dispatch) void {
        assert(dispatch.ticking);
        dispatch.ticking = false;
    }

    fn call_records(dispatch: *Dispatch, events: []Event) u32 {
        var kept: u32 = 0;
        for (events) |event| {
            if (!event.flags.dispatched) {
                events[kept] = event;
                kept += 1;
                continue;
            }
            // The subtraction's overflow check halts on a final event the count never saw.
            if (!event.flags.more) dispatch.records_in_flight -= 1;
            const record: *Completion = @ptrFromInt(event.user_data);
            record.callback(record, event);
        }
        assert(kept <= events.len);
        return kept;
    }
};

const testing = std.testing;

const Counting = struct {
    /// A field before the record, so the parent's address differs from the record's.
    events: u32 = 0,
    completion: Completion = .init(Counting, "completion", called),
    last_result: i32 = 0,

    fn called(counting: *Counting, event: Event) void {
        counting.events += 1;
        counting.last_result = event.result;
    }
};

fn dispatched_event(record: *Completion, result: i32, more: bool) Event {
    return .{ .user_data = @intFromPtr(record), .result = result, .flags = .{ .more = more, .dispatched = true } };
}

test "events with a record reach it, and the rest keep their order at the front" {
    var dispatch: Dispatch = .empty;
    var counting: Counting = .{};
    dispatch.note_submitted(1);
    var events = [_]Event{
        .{ .user_data = 1, .result = 0, .flags = .{} },
        dispatched_event(&counting.completion, 5, true),
        .{ .user_data = 2, .result = 0, .flags = .{} },
        dispatched_event(&counting.completion, 6, false),
    };
    try testing.expectEqual(@as(u64, 7), dispatch.begin(7));
    const kept = dispatch.end(&events);
    try testing.expectEqual(@as(u32, 2), kept);
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u64, 2), events[1].user_data);
    try testing.expectEqual(@as(u32, 2), counting.events);
    try testing.expectEqual(@as(i32, 6), counting.last_result);
    // The `more` event kept the operation in flight, and the final one ended it.
    try testing.expectEqual(@as(u32, 0), dispatch.records_in_flight);
    try testing.expect(!dispatch.ticking);
}

const Polling = struct {
    calls: u32 = 0,
    poller: Poller = .init(Polling, "poller", polled),
    worked: bool = false,

    fn polled(polling: *Polling) bool {
        polling.calls += 1;
        return polling.worked;
    }
};

test "each poller runs once a tick, and one that did work makes the tick wait 0 ns" {
    var dispatch: Dispatch = .empty;
    var idle: Polling = .{};
    var busy: Polling = .{ .worked = true };
    try dispatch.add_poller(&idle.poller);
    try testing.expectEqual(@as(u64, 9), dispatch.begin(9));
    _ = dispatch.end(&.{});
    try dispatch.add_poller(&busy.poller);
    try testing.expectEqual(@as(u64, 0), dispatch.begin(9));
    _ = dispatch.end(&.{});
    try testing.expectEqual(@as(u32, 2), idle.calls);
    try testing.expectEqual(@as(u32, 1), busy.calls);
    dispatch.remove_poller(&busy.poller);
    try testing.expectEqual(@as(u64, 9), dispatch.begin(9));
    _ = dispatch.end(&.{});
    try testing.expectEqual(@as(u32, 1), busy.calls);
    try testing.expectEqual(@as(u32, 3), idle.calls);
}

test "a full table of pollers refuses one more, and a removal keeps the order of the rest" {
    var dispatch: Dispatch = .empty;
    var pollers: [constants.pollers_max + 1]Polling = @splat(.{});
    for (pollers[0..constants.pollers_max]) |*polling| try dispatch.add_poller(&polling.poller);
    try testing.expectError(error.PollersFull, dispatch.add_poller(&pollers[constants.pollers_max].poller));
    dispatch.remove_poller(&pollers[1].poller);
    try testing.expectEqual(&pollers[0].poller, dispatch.pollers[0]);
    try testing.expectEqual(&pollers[2].poller, dispatch.pollers[1]);
    try dispatch.add_poller(&pollers[constants.pollers_max].poller);
}
