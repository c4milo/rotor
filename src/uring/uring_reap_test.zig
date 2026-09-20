//! The reap path under completion entries a test builds itself (decision 10, point 3): the
//! orders and the errors the kernel will not produce on demand. The loop here has tables and no
//! ring, so every test runs on every host.
//!
//! Decision 5's rules are what these tests hold: one final event per operation and the slot
//! released with it (rule 1), the three outcomes of a cancel in both orders of arrival (rule 2),
//! and `timeout` in place of `canceled` when the loop's own deadline asked (rule 4).
const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const cancel_module = @import("uring_cancel.zig");
const reap_module = @import("uring_reap.zig");
const uring = @import("uring.zig");

const Loop = uring.Loop;
const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;

const options: Loop.Options = .{ .operations = 8, .entries = 8 };

/// What a completion the backend consumes yields.
const none: ?Event = null;
const memory_bytes = Loop.memory_bytes(options);

/// Room for the default prefix and a small datagram.
const datagram_buffer_bytes = 512;

const Fixture = struct {
    memory: [memory_bytes]u8 align(core.layout.memory_alignment),
    loop: Loop,
    buffer: [64]u8,
    /// A datagram's buffer holds the prefix in front of the bytes, which `assert_receive_from`
    /// requires and the 64-byte buffer above cannot.
    datagram_buffer: [datagram_buffer_bytes]u8,

    fn init(fixture: *Fixture) void {
        fixture.loop.init_tables(&fixture.memory, options);
        fixture.buffer = @splat(0);
        fixture.datagram_buffer = @splat(0);
    }

    /// Submits `operation` and puts its slot where `flush` would: off the pending list, in
    /// state `submitted`, with its deadline armed.
    fn start(fixture: *Fixture, operation: Operation) Handle {
        var handles: [1]Handle = undefined;
        const taken = fixture.loop.submit(&.{operation}, &handles);
        std.debug.assert(taken == 1);
        const tables = &fixture.loop.tables;
        const index = tables.pending.pop(tables.table.slots).?;
        const slot = tables.table.at(index);
        slot.state = .submitted;
        tables.arm(index, slot);
        return handles[0];
    }

    fn receive(fixture: *Fixture, user_data: u64) Handle {
        return fixture.start(.{ .user_data = user_data, .kind = .{ .receive = .{
            .socket = 5,
            .target = .{ .buffer = .{ .bytes = &fixture.buffer } },
        } } });
    }

    fn complete(fixture: *Fixture, user_data: u64, result: i32, flags: u32) ?Event {
        const cqe: linux.io_uring_cqe = .{ .user_data = user_data, .res = result, .flags = flags };
        return reap_module.complete(&fixture.loop, &cqe);
    }

    /// The kernel's answer to a cancel request, which the backend consumes.
    fn cancel_answer(fixture: *Fixture, user_data: u64, errno: ?linux.E) ?Event {
        const result = if (errno) |value| -@as(i32, @intFromEnum(value)) else 0;
        return fixture.complete(user_data, result, 0);
    }

    fn timed_receive(fixture: *Fixture, user_data: u64) Handle {
        return fixture.start(.{
            .user_data = user_data,
            .timeout_ns = core.constants.ns_per_ms,
            .kind = .{ .receive = .{
                .socket = 5,
                .target = .{ .buffer = .{ .bytes = &fixture.buffer } },
            } },
        });
    }

    fn fail(fixture: *Fixture, handle: Handle, errno: linux.E) ?Event {
        return fixture.complete(handle.to_bits(), -@as(i32, @intFromEnum(errno)), 0);
    }

    /// A datagram receive, which takes a group and is multishot: io_uring writes rotor's layout
    /// only for a multishot receive (`tools/uring_probe_datagram.zig`, 2026-09-20).
    fn receive_from(fixture: *Fixture, user_data: u64) Handle {
        return fixture.start(.{ .user_data = user_data, .kind = .{ .receive_from = .{
            .socket = 5,
            .group = 0,
        } } });
    }
};

test "a completion yields one final event with the caller's user data and frees the slot" {
    var fixture: Fixture = undefined;
    fixture.init();
    const handle = fixture.receive(0xC0DE);
    try testing.expectEqual(@as(u32, 1), fixture.loop.in_flight());
    const event = fixture.complete(handle.to_bits(), 17, 0).?;
    try testing.expectEqual(@as(u64, 0xC0DE), event.user_data);
    try testing.expectEqual(@as(u32, 17), try event.outcome());
    try testing.expect(event.is_final());
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
    try testing.expectEqual(@as(?*core.Slot, null), fixture.loop.tables.table.lookup(handle));
}

test "EAGAIN resubmits without an event, and past the bound the caller hears would_block" {
    var fixture: Fixture = undefined;
    fixture.init();
    const handle = fixture.receive(1);
    const loop = &fixture.loop;
    var round: u32 = 0;
    while (round < core.constants.transfer_retries_max) : (round += 1) {
        try testing.expectEqual(@as(?Event, null), fixture.fail(handle, .AGAIN));
        const slot = loop.tables.table.lookup(handle).?;
        try testing.expectEqual(core.Slot.State.queued, slot.state);
        try testing.expectEqual(round + 1, slot.retries);
        // What `flush` does to a queued slot.
        _ = loop.tables.pending.pop(loop.tables.table.slots).?;
        slot.state = .submitted;
    }
    const event = fixture.fail(handle, .INTR).?;
    try testing.expectError(error.WouldBlock, event.outcome());
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}

test "a cancel that wins ends the operation with canceled, whichever completion comes first" {
    var fixture: Fixture = undefined;
    fixture.init();
    // The cancel's own answer first, then the target's.
    var handle = fixture.receive(1);
    fixture.loop.cancel(handle);
    // A second cancel of an operation already marked asks the kernel nothing more.
    fixture.loop.cancel(handle);
    try testing.expectEqual(@as(u32, 1), fixture.loop.cancels.count);
    try testing.expectEqual(none, fixture.cancel_answer(constants.user_data_cancel, null));
    try testing.expectEqual(@as(u32, 1), fixture.loop.in_flight());
    try testing.expectError(error.Canceled, fixture.fail(handle, .CANCELED).?.outcome());
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());

    // The target's first, then the cancel's answer, which finds nothing and changes nothing.
    handle = fixture.receive(2);
    fixture.loop.cancel(handle);
    try testing.expectError(error.Canceled, fixture.fail(handle, .CANCELED).?.outcome());
    try testing.expectEqual(none, fixture.cancel_answer(constants.user_data_cancel, .NOENT));
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
}

test "an operation a cancel waits for is not resubmitted: the caller hears canceled" {
    var fixture: Fixture = undefined;
    fixture.init();
    const handle = fixture.receive(1);
    fixture.loop.cancel(handle);
    const event = fixture.fail(handle, .AGAIN).?;
    try testing.expectError(error.Canceled, event.outcome());
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
    try testing.expectEqual(@as(u32, 0), fixture.loop.tables.pending.count);
}

test "bytes that moved win over a cancel, and an operation that finished first keeps its result" {
    var fixture: Fixture = undefined;
    fixture.init();
    const handle = fixture.receive(1);
    fixture.loop.cancel(handle);
    const event = fixture.complete(handle.to_bits(), 5, 0).?;
    try testing.expectEqual(@as(u32, 5), try event.outcome());
    try testing.expectEqual(none, fixture.cancel_answer(constants.user_data_cancel, .ALREADY));
    // A second cancel of the same handle names nothing now, and that is legal.
    fixture.loop.cancel(handle);
    try testing.expectEqual(@as(u32, 1), fixture.loop.cancels.count);
}

test "a cancel the loop issued for a deadline says timeout, and a completion disarms the deadline" {
    var fixture: Fixture = undefined;
    fixture.init();
    const timed = fixture.timed_receive(1);
    const loop = &fixture.loop;
    try testing.expectEqual(@as(u32, 1), loop.tables.timers.count);
    const slot = loop.tables.table.lookup(timed).?;
    // What `expire` does when the deadline passes.
    const due = loop.tables.timers.pop_due(core.constants.ns_per_ms);
    try testing.expectEqual(@as(?u32, timed.index), due);
    slot.flags.timed_out = true;
    cancel_module.request(loop, timed.index, slot);
    try testing.expectError(error.Timeout, fixture.fail(timed, .CANCELED).?.outcome());

    const in_time = fixture.timed_receive(2);
    try testing.expectEqual(@as(u32, 1), loop.tables.timers.count);
    try testing.expectEqual(@as(u32, 9), try fixture.complete(in_time.to_bits(), 9, 0).?.outcome());
    try testing.expectEqual(@as(u32, 0), loop.tables.timers.count);
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}

test "a multishot operation keeps its slot while more follows and ends with one final event" {
    var fixture: Fixture = undefined;
    fixture.init();
    const handle = fixture.start(.{ .user_data = 7, .kind = .{ .receive = .{
        .socket = 5,
        .target = .{ .group = 1 },
        .multishot = true,
    } } });
    const buffer_three = linux.IORING_CQE_F_BUFFER | (3 << linux.IORING_CQE_BUFFER_SHIFT);
    const first = fixture.complete(handle.to_bits(), 100, linux.IORING_CQE_F_MORE | buffer_three).?;
    try testing.expect(first.flags.more and first.flags.buffer and !first.is_final());
    try testing.expectEqual(@as(u16, 3), first.flags.buffer_id);
    try testing.expectEqual(@as(u32, 1), fixture.loop.in_flight());

    const last = fixture.fail(handle, .NOBUFS).?;
    try testing.expect(last.is_final());
    try testing.expectError(error.BuffersExhausted, last.outcome());
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
}

test "a posted message is an event of no operation, even when its payload reads as a handle" {
    var fixture: Fixture = undefined;
    fixture.init();
    const handle = fixture.receive(1);
    const tag: u32 = 42;
    const result: i32 = @bitCast(tag | constants.message_result_flag);
    const event = fixture.complete(handle.to_bits(), result, 0).?;
    try testing.expect(event.flags.message and !event.is_final());
    try testing.expectEqual(handle.to_bits(), event.user_data);
    try testing.expectEqual(@as(i32, 42), event.result);
    try testing.expectEqual(@as(u32, 1), fixture.loop.in_flight());
    try testing.expect(fixture.loop.tables.table.lookup(handle) != null);
}

test "the completions the backend consumes itself yield no event" {
    var fixture: Fixture = undefined;
    fixture.init();
    _ = fixture.receive(1);
    const close_cancel = constants.user_data_close_cancel;
    try testing.expectEqual(none, fixture.cancel_answer(close_cancel, null));
    try testing.expectEqual(none, fixture.cancel_answer(close_cancel, .NOENT));
    try testing.expectEqual(@as(u32, 1), fixture.loop.in_flight());
}

test "a timer cancels at once with no kernel involved, and a queued operation at its flush" {
    var fixture: Fixture = undefined;
    fixture.init();
    const loop = &fixture.loop;
    const timer = fixture.start(.{ .user_data = 9, .kind = .{ .timer = .{ .after_ns = 5 } } });
    try testing.expectEqual(@as(u32, 1), loop.tables.timers.count);
    loop.cancel(timer);
    try testing.expectEqual(@as(u32, 0), loop.tables.timers.count);
    try testing.expectEqual(@as(u32, 0), loop.cancels.count);
    try testing.expectEqual(@as(u32, 1), loop.tables.finished.count);
    const slot = loop.tables.table.lookup(timer).?;
    try testing.expectEqual(core.Slot.State.finishing, slot.state);
    try testing.expectEqual(core.event.result_of(.canceled), slot.result);
    // The final event is not delivered from inside `cancel`: the slot stays claimed until a tick.
    try testing.expectEqual(@as(u32, 1), loop.in_flight());
}

test "a deadline that passes while a retried operation is queued does not halt the loop" {
    var fixture: Fixture = undefined;
    fixture.init();
    const handle = fixture.timed_receive(1);
    const loop = &fixture.loop;
    const tables = &loop.tables;

    // EAGAIN puts the slot back on the pending list for the next flush, and its deadline stays
    // armed, because the deadline belongs to the operation and not to one attempt of it.
    try testing.expectEqual(@as(?Event, null), fixture.fail(handle, .AGAIN));
    const slot = tables.table.lookup(handle).?;
    try testing.expectEqual(core.Slot.State.queued, slot.state);
    try testing.expect(tables.timers.is_armed(handle.index));

    // The deadline now passes before the flush that would resubmit it. `tick` reaches exactly
    // here: it reaps, the reap produces no event because the operation was retried, and it then
    // expires a second time against a clock it has just read again.
    tables.now_ns += 2 * core.constants.ns_per_ms;
    const expired = tables.next_expired().?;
    try testing.expectEqual(handle.index, expired);
    try testing.expect(slot.flags.timed_out);

    // The backend cancels it as it does any expired operation. The kernel never got this
    // attempt, so the cancel only marks it and the next flush is what ends it.
    cancel_module.request(loop, expired, slot);
    try testing.expect(slot.flags.cancel_requested);
    try testing.expectEqual(core.Slot.State.queued, slot.state);
    uring.submit_module.flush(loop);
    try testing.expectEqual(core.Slot.State.finishing, slot.state);

    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), tables.drain_finished(&events));
    try testing.expectError(error.Timeout, events[0].outcome());
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}

/// `IORING_CQE_F_MORE`, which a multishot completion carries.
const more_flag: u32 = 1 << 1;

test "a datagram completion reports the datagram's bytes and not the prefix in front of them" {
    var fixture: Fixture = undefined;
    fixture.init();
    const handle = fixture.receive_from(0xDA7A);
    // What the kernel counts is the prefix plus the datagram, which the probe measured on
    // 2026-09-20: a 20-byte datagram in a group reserving 112 gave `cqe.res` 132.
    const prefix: i32 = @intCast(core.datagram.prefix_bytes(.{}));
    const payload_bytes: i32 = 20;
    // Flagged `more`, as every event of a multishot operation but the last is.
    const event = fixture.complete(handle.to_bits(), prefix + payload_bytes, more_flag).?;
    // The caller sees the datagram, never the prefix (decision 15).
    try testing.expectEqual(@as(u32, @intCast(payload_bytes)), try event.outcome());
    try testing.expect(event.flags.more);
}

test "a stream receive's completion keeps every byte the kernel counted" {
    var fixture: Fixture = undefined;
    fixture.init();
    const handle = fixture.receive(0xC0DE);
    const counted: i32 = 40;
    // The same count on a `receive` is the caller's answer untouched: only a datagram subtracts.
    const event = fixture.complete(handle.to_bits(), counted, 0).?;
    try testing.expectEqual(@as(u32, @intCast(counted)), try event.outcome());
}
