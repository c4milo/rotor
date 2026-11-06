//! `kqueue_tick.zig` under a `kevent` call that fails: the events it returns (decision 5, amendment
//! of 2026-11-06) and the registrations it keeps (decision 12, point 10, proposed on 2026-11-06).
//! Split from that file for the 500-line limit.
const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const core = @import("core");
const kqueue = @import("kqueue.zig");
const submit_module = @import("kqueue_submit.zig");

const Loop = kqueue.Loop;
const Event = core.Event;
const Operation = core.Operation;

const testing = std.testing;

/// A record that counts the final events it receives (decision 26).
const Record = struct {
    completion: core.Completion = .init(Record, "completion", called),
    finals: u32 = 0,

    fn called(record: *Record, event: Event) void {
        assert(!event.flags.more);
        record.finals += 1;
    }
};

test "a tick whose call fails after it produced events returns them, and the next tick fails" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    const ends = try kqueue.testing.nonblocking_pair();
    defer for (ends) |end| {
        _ = std.c.close(end);
    };

    // A receive waits for readiness, so a tick that polls asks the kernel.
    var buffer: [8]u8 = undefined;
    var events: [4]Event = undefined;
    const receive = Operation.receive(1, ends[0], &buffer);
    try testing.expectEqual(@as(u32, 1), loop.submit(&.{receive}, &.{}));
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 0));

    // Two timers end in the next tick before its call: one with a record, one without. A socket
    // in place of the kqueue makes the call fail.
    var record: Record = .{};
    const timers = [_]Operation{
        .timer(2, 0, 0),
        Operation.timer(0, 0, 0).completion(&record.completion),
    };
    try testing.expectEqual(@as(u32, 2), loop.submit(&timers, &.{}));
    const queue = loop.queue.descriptor;
    const saved = std.c.dup(queue);
    try testing.expect(saved >= 0);
    try testing.expectEqual(queue, std.c.dup2(ends[1], queue));

    // The tick hands over the timer without a record and calls the other's record. The kept
    // error takes the next tick off the fast path.
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expectEqual(@as(u64, 2), events[0].user_data);
    try testing.expectEqual(@as(u32, 1), record.finals);
    try testing.expect(!loop.tables.dispatch.idle());
    // The next tick returns the kept error before anything else. A tick that produced nothing
    // returns its own error at once.
    try testing.expectError(error.Unexpected, loop.tick(&events, 0));
    try testing.expect(loop.tables.dispatch.idle());
    try testing.expectError(error.Unexpected, loop.tick(&events, 0));

    _ = std.c.dup2(saved, queue);
    _ = std.c.close(saved);
    // A failed tick that produced nothing keeps nothing, so this tick runs, and the receive ends.
    try testing.expectEqual(@as(isize, 1), std.c.write(ends[1], "x", 1));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}

/// Puts `replacement` in place of the loop's kqueue, so the next `kevent` call fails with EBADF,
/// and answers a copy of the kqueue for `restore`.
fn break_queue(loop: *const Loop, replacement: core.Descriptor) !core.Descriptor {
    const queue = loop.queue.descriptor;
    const saved = std.c.dup(queue);
    try testing.expect(saved >= 0);
    try testing.expectEqual(queue, std.c.dup2(replacement, queue));
    return saved;
}

fn restore(loop: *const Loop, saved: core.Descriptor) !void {
    try testing.expectEqual(loop.queue.descriptor, std.c.dup2(saved, loop.queue.descriptor));
    _ = std.c.close(saved);
}

test "a failed call keeps the registration it carried, and the receive ends when the kqueue is back" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    const ends = try kqueue.testing.nonblocking_pair();
    defer for (ends) |end| {
        _ = std.c.close(end);
    };

    // The receive would block, so the tick puts its registration on the list for its call.
    var buffer: [8]u8 = undefined;
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 1), loop.submit(&.{Operation.receive(1, ends[0], &buffer)}, &.{}));
    const saved = try break_queue(&loop, ends[1]);

    // A tick that waits fails. The registration stays, without a receipt, and the timer goes.
    try testing.expectError(error.Unexpected, loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u32, 1), loop.changes_used);
    try testing.expectEqual(@as(u16, 0), loop.changes[0].flags & std.c.EV.RECEIPT);
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
    // A tick that polls fails the same way, and its trigger goes.
    try testing.expectError(error.Unexpected, loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 1), loop.changes_used);

    // The kqueue is back. The next call carries the registration, and the byte ends the receive.
    try restore(&loop, saved);
    try testing.expectEqual(@as(isize, 1), std.c.write(ends[1], "x", 1));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}

test "a change refused with no room for its answer loses no registration behind it" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    const ends = try kqueue.testing.nonblocking_pair();
    const other = try kqueue.testing.nonblocking_pair();
    defer for (ends ++ other) |end| {
        _ = std.c.close(end);
    };

    // A delete of a filter that is not there, which the kernel refuses with ENOENT, comes first on
    // the list. The receive's registration follows it.
    submit_module.unregister(&loop, other[0], .read);
    var buffer: [8]u8 = undefined;
    const operations = [_]Operation{ .receive(1, ends[0], &buffer), .timer(2, 0, 0) };
    try testing.expectEqual(@as(u32, 2), loop.submit(&operations, &.{}));

    // The timer fills the one event, so the call has no room for the refusal and fails at it,
    // before it applies the registration. The tick applies the list again and returns the timer.
    var one: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try loop.tick(&one, 0));
    try testing.expectEqual(@as(u64, 2), one[0].user_data);
    // The refused delete is back on the list, for the next call to report.
    try testing.expectEqual(@as(u32, 1), loop.changes_used);
    try testing.expectEqual(@as(usize, @intCast(other[0])), loop.changes[0].ident);

    // The next call reports the refusal, which names no waiter, and returns before it reads any
    // readiness. The call after it finds the receive's filter ready.
    try testing.expectEqual(@as(isize, 1), std.c.write(ends[1], "x", 1));
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}
