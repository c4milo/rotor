//! The reap: what `tick` does with the descriptors the kernel reported ready. For each, the
//! oldest operation waiting on that descriptor and filter is tried again, and its event is
//! written straight into the caller's events. A tick asks the kernel for no more readiness than
//! it has room for events, so nothing here needs a queue (decision 12, point 3).
//!
//! One of the six hot files decision 7 names. This is the plain version.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const perform = @import("kqueue_perform.zig");
const queue_module = @import("kqueue_queue.zig");
const submit_module = @import("kqueue_submit.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const Event = core.Event;
const Operation = core.Operation;
const Filter = core.waiters.Filter;
const Kevent = queue_module.Kevent;

/// Turns readiness into events. Each readiness yields at most one event, and `events` has room
/// for every one of them: the tick sized its request by it.
pub fn reap(loop: *Loop, readiness: []const Kevent, events: []Event) u32 {
    assert(readiness.len <= events.len);
    var produced: u32 = 0;
    for (readiness) |*ready| {
        const filter = filter_of(ready) orelse continue;
        const descriptor: core.Descriptor = @intCast(ready.ident);
        if (serve(loop, descriptor, filter)) |event| {
            events[produced] = event;
            produced += 1;
        }
    }
    assert(produced <= readiness.len);
    return produced;
}

/// The filter a readiness names, or null for the wake event, which carries no operation.
fn filter_of(ready: *const Kevent) ?Filter {
    if (ready.filter == std.c.EVFILT.READ) return .read;
    if (ready.filter == std.c.EVFILT.WRITE) return .write;
    assert(ready.filter == std.c.EVFILT.USER);
    return null;
}

/// Tries the oldest waiter of `descriptor` on `filter` again. Null when nobody waits, because
/// the waiter was cancelled and its one-shot filter fired all the same, or when the call would
/// still block.
fn serve(loop: *Loop, descriptor: core.Descriptor, filter: Filter) ?Event {
    const tables = &loop.tables;
    const index = loop.waiters.first(descriptor, filter) orelse return null;
    const slot = tables.table.at(index);
    assert(slot.state == .submitted);
    const attempt = perform.attempt(loop, slot);
    if (attempt.outcome != .done) {
        // Not ready after all. A kept filter reports again; a one-shot filter has fired, and is
        // registered again.
        if (!slot.flags.multishot) submit_module.register(loop, descriptor, filter, false);
        return null;
    }
    var event: Event = .{ .user_data = slot.user_data, .result = attempt.result, .flags = .{} };
    if (attempt.buffer_id) |buffer_id| {
        event.flags.buffer = true;
        event.flags.buffer_id = buffer_id;
    }
    // A multishot operation goes on after a success, and ends at its first failure.
    if (slot.flags.multishot and attempt.result >= 0) {
        event.flags.more = true;
        return event;
    }
    const popped = loop.waiters.pop(tables.table.slots, descriptor, filter);
    assert(popped == index);
    submit_module.after_leaving(loop, descriptor, filter, slot.flags.multishot);
    tables.finish(index, slot);
    return event;
}

const testing = std.testing;

test "an operation behind a multishot receive that ran out of buffers is still served" {
    if (!@import("builtin").os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    const group_id = 1;
    const buffer_bytes = 8;
    const group_bytes = comptime kqueue.buffers.group_bytes(1, buffer_bytes);
    var group_memory: [group_bytes]u8 align(kqueue.buffers.group_alignment) = undefined;
    try loop.provide_buffers(group_id, &group_memory, 1, buffer_bytes);
    const pair = try @import("kqueue_testing.zig").nonblocking_pair();
    defer for (pair) |descriptor| {
        _ = std.c.close(descriptor);
    };

    // The multishot receive waits first and keeps the filter; the one-shot receive waits behind.
    var own: [buffer_bytes]u8 = undefined;
    const waiting = [_]Operation{
        Operation.receive_group(1, pair[0], group_id),
        Operation.receive(2, pair[0], &own),
    };
    try testing.expectEqual(@as(u32, 2), loop.submit(&waiting, &.{}));
    var events: [2]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 0));

    // The first byte takes the group's one buffer, and the caller keeps it.
    try testing.expectEqual(@as(isize, 1), std.c.write(pair[1], "a", 1));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expect(events[0].flags.more);

    // The second finds no buffer, so the multishot receive ends and its kept filter goes.
    try testing.expectEqual(@as(isize, 1), std.c.write(pair[1], "b", 1));
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectError(error.BuffersExhausted, events[0].outcome());

    // The receive behind it has a filter of its own, and takes the byte that is waiting.
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, core.constants.ns_per_s));
    try testing.expectEqual(@as(u64, 2), events[0].user_data);
    try testing.expectEqual(@as(u32, 1), try events[0].outcome());
    try testing.expectEqual(@as(u8, 'b'), own[0]);
}
