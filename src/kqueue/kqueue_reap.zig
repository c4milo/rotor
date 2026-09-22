//! The reap: what `tick` does with the descriptors the kernel reported ready. For each, the
//! oldest operation waiting on that descriptor and filter is tried again, and its event is
//! written straight into the caller's events. A tick asks the kernel for no more readiness than
//! it has room for events, so nothing here needs a queue (decision 12, point 3).
//!
//! One of the six hot files decision 7 names. This is the plain version.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("constants.zig");
const perform = @import("kqueue_perform.zig");
const queue_module = @import("kqueue_queue.zig");
const submit_module = @import("kqueue_submit.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const Event = core.Event;
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
    if (slot.flags.multishot) {
        submit_module.unregister(loop, descriptor, filter);
    } else if (loop.waiters.count(descriptor, filter) != 0) {
        // The one-shot filter fired for this operation, and another still waits behind it.
        submit_module.register(loop, descriptor, filter, false);
    }
    tables.finish(index, slot);
    return event;
}
