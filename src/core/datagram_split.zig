//! Splitting a coalesced datagram (decision 15, amendment of 2026-11-05). On Linux a socket with
//! UDP_GRO receives several datagrams from one peer as one, with their size in a control message.
//! The loop hands each over as an event of its own, so a caller never sees the coalescing.
//!
//! Every event of a split names the same buffer, with its datagram's index in `Event.flags.segment`
//! and its datagram's length as its result. The group counts the events that still name the
//! buffer (`buffer_group.hold`), and the buffer goes back at the last event's give-back. `view`
//! finds an event's datagram in the buffer. When the caller's events run out first, the rest wait
//! in `Split` for the next tick, before any new completion.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const event_module = @import("event.zig");
const datagram = @import("datagram.zig");
const buffer_group = @import("buffer_group.zig");

const Event = event_module.Event;

/// The datagrams `payload_bytes` of coalesced datagrams of `segment_bytes` each make: 1 for a
/// datagram that is not coalesced.
pub fn segments_of(payload_bytes: u32, segment_bytes: u32) u32 {
    if (segment_bytes == 0 or payload_bytes <= segment_bytes) return 1;
    return std.math.divCeil(u32, payload_bytes, segment_bytes) catch unreachable;
}

/// What is left of the coalesced datagram the loop is splitting, between ticks. 32 bytes.
pub const Split = struct {
    /// The event the coalesced datagram would have been: its user data, its buffer, its `more`.
    whole: Event,
    segment_bytes: u32,
    segments: u32,
    /// The index of the next datagram to hand over.
    next: u32,

    pub const idle: Split = .{
        .whole = .{ .user_data = 0, .result = 0, .flags = .{} },
        .segment_bytes = 0,
        .segments = 0,
        .next = 0,
    };

    comptime {
        assert(@sizeOf(Split) == 32);
    }

    /// True while events of a split wait to be handed over.
    pub fn pending(split: *const Split) bool {
        return split.next < split.segments;
    }

    /// Starts splitting `whole`, a receive's event that names a buffer of coalesced datagrams of
    /// `segment_bytes` each, and holds the buffer for every one. Returns false for a datagram that
    /// is not coalesced, which goes over as it is.
    pub fn begin(split: *Split, whole: Event, segment_bytes: u32, holders: []u8) bool {
        assert(!split.pending());
        assert(whole.flags.buffer);
        assert(whole.result >= 0);
        const segments = segments_of(@intCast(whole.result), segment_bytes);
        if (segments == 1) return false;
        buffer_group.hold(holders, whole.flags.buffer_id, segments);
        split.* = .{ .whole = whole, .segment_bytes = segment_bytes, .segments = segments, .next = 0 };
        return true;
    }

    /// Writes the split's next events into `events`, as many as fit, and returns how many.
    pub fn take(split: *Split, events: []Event) u32 {
        var written: u32 = 0;
        while (split.next < split.segments and written < events.len) : (written += 1) {
            events[written] = split.segment(split.next);
            split.next += 1;
        }
        if (!split.pending()) split.* = idle;
        assert(written <= events.len);
        return written;
    }

    fn segment(split: *const Split, index: u32) Event {
        assert(index < split.segments);
        const last = index + 1 == split.segments;
        const total: u32 = @intCast(split.whole.result);
        var event = split.whole;
        event.result = @intCast(if (last) total - index * split.segment_bytes else split.segment_bytes);
        event.flags.segment = @intCast(index);
        // The last datagram's event is the operation's final one when the coalesced datagram's was.
        event.flags.more = if (last) split.whole.flags.more else true;
        return event;
    }
};

/// The datagram `event` hands over, out of `whole`, what the backend read of the buffer the event
/// names. `capacity` is the payload the buffer holds. A datagram that was not coalesced is `whole`
/// itself. A split one starts at its index times the segment size, has the event's result as its
/// length, and names no segment size, so a caller sees an ordinary datagram.
pub fn view(whole: datagram.Delivery, capacity: usize, event: Event) datagram.Delivery {
    const segment_bytes = whole.from.segment_bytes;
    if (segment_bytes == 0) {
        assert(event.flags.segment == 0);
        return whole;
    }
    const offset = @as(usize, event.flags.segment) * segment_bytes;
    const length: usize = @intCast(event.result);
    assert(offset + length <= capacity);
    var from = whole.from;
    from.segment_bytes = 0;
    return .{ .from = from, .bytes = whole.bytes.ptr[0..capacity][offset..][0..length] };
}

const testing = std.testing;

const test_user_data = 7;
const test_buffer_id = 2;

fn coalesced(total: i32, more: bool) Event {
    return .{
        .user_data = test_user_data,
        .result = total,
        .flags = .{ .buffer = true, .buffer_id = test_buffer_id, .more = more },
    };
}

test "a coalesced datagram splits into one event per datagram, the last one shorter" {
    var holders: [4]u8 = @splat(0);
    var split: Split = .idle;
    try testing.expect(split.begin(coalesced(2500, true), 1000, &holders));
    try testing.expectEqual(@as(u8, 3), holders[2]);
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 3), split.take(&events));
    try testing.expect(!split.pending());
    for (events[0..3], 0..) |event, index| {
        try testing.expectEqual(@as(u64, 7), event.user_data);
        try testing.expectEqual(@as(u16, 2), event.flags.buffer_id);
        try testing.expectEqual(@as(u6, @intCast(index)), event.flags.segment);
        try testing.expect(event.flags.more);
    }
    try testing.expectEqual(@as(i32, 1000), events[0].result);
    try testing.expectEqual(@as(i32, 500), events[2].result);
}

test "the last event of a split is final when the coalesced datagram's was, and waits for room" {
    var holders: [4]u8 = @splat(0);
    var split: Split = .idle;
    try testing.expect(split.begin(coalesced(3000, false), 1000, &holders));
    var one: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), split.take(&one));
    try testing.expect(one[0].flags.more);
    try testing.expectEqual(@as(u32, 1), split.take(&one));
    try testing.expect(split.pending());
    try testing.expectEqual(@as(u32, 1), split.take(&one));
    try testing.expect(!one[0].flags.more);
    try testing.expectEqual(@as(u6, 2), one[0].flags.segment);
    try testing.expect(!split.pending());
}

test "a datagram that is not coalesced is not split and holds nothing" {
    var holders: [4]u8 = @splat(0);
    var split: Split = .idle;
    try testing.expect(!split.begin(coalesced(800, true), 0, &holders));
    try testing.expect(!split.begin(coalesced(800, true), 1000, &holders));
    try testing.expectEqual(@as(u8, 0), holders[2]);
    try testing.expect(!split.pending());
}

test "a split event's view is its own datagram, and names no segment size" {
    var buffer: [64]u8 = undefined;
    for (&buffer, 0..) |*byte, index| byte.* = @intCast(index);
    var from = std.mem.zeroes(datagram.Received);
    from.segment_bytes = 10;
    const whole: datagram.Delivery = .{ .from = from, .bytes = buffer[0..10] };
    var event = coalesced(5, true);
    event.flags.segment = 2;
    const seen = view(whole, buffer.len, event);
    try testing.expectEqual(@as(u16, 0), seen.from.segment_bytes);
    try testing.expectEqualSlices(u8, buffer[20..25], seen.bytes);
    var plain = std.mem.zeroes(datagram.Received);
    plain.segment_bytes = 0;
    const not_split: datagram.Delivery = .{ .from = plain, .bytes = buffer[0..7] };
    try testing.expectEqual(not_split.bytes.ptr, view(not_split, buffer.len, coalesced(7, true)).bytes.ptr);
}
