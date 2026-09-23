//! The flush: what `tick` does with the slots `core.Tables.submit` queued. An operation is tried
//! at once, and only one that would block is registered with the kernel and left to wait
//! (decision 12, point 1). Whatever ends here ends on the tables' finished list, so its event is
//! handed over by the same tick, and never by `submit` or `cancel` (decision 5, rule 2).
//!
//! One of the six hot files decision 7 names. This is the plain version.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("constants.zig");
const descriptors_module = @import("kqueue_descriptors.zig");
const offload_module = @import("kqueue_offload.zig");
const perform = @import("kqueue_perform.zig");
const queue_module = @import("kqueue_queue.zig");
const sync = @import("kqueue_sync.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const Slot = core.Slot;
const Filter = core.waiters.Filter;

/// Handles queued slots, oldest first, until none is left or the tick's changes are full.
pub fn flush(loop: *Loop) void {
    const tables = &loop.tables;
    const queued = tables.pending.count;
    var visited: u32 = 0;
    while (visited < queued) : (visited += 1) {
        const index = tables.pending.peek() orelse break;
        // An operation that has to wait needs room for its registration.
        if (loop.changes_used == constants.changes_max) break;
        _ = tables.pending.pop(tables.table.slots);
        flush_one(loop, index, tables.table.at(index));
    }
    assert(tables.pending.count <= queued);
}

fn flush_one(loop: *Loop, index: u32, slot: *Slot) void {
    assert(slot.state == .queued);
    const tables = &loop.tables;
    if (slot.flags.cancel_requested) {
        return tables.finish_local(index, core.event.result_of(core.tables.cancel_code(slot)));
    }
    switch (slot.code) {
        .timer => {
            slot.state = .submitted;
            tables.arm(index, slot);
        },
        .post => tables.finish_local(index, post(loop, slot)),
        .close => tables.finish_local(index, close(loop, slot)),
        else => start(loop, index, slot),
    }
}

/// Tries the operation now. Two kinds are not tried and go straight to waiting, so that the reap
/// produces their events: a multishot operation, whose events are many, and a receive from a
/// group, whose event names a buffer, which the finished list has no room to carry.
fn start(loop: *Loop, index: u32, slot: *Slot) void {
    if (slot.flags.descriptor_registered) descriptors_module.resolve(loop, slot);
    if (slot.flags.multishot or slot.flags.buffer_group) {
        return wait(loop, index, slot, perform.filter_of(slot.code));
    }
    const attempt = perform.attempt(loop, slot);
    // The caller's offload has it now, and a worker's ring carries the result back (decision 18).
    // The slot stays the loop's until then, which is decision 5, rule 3 for its buffer.
    if (attempt.outcome == .offloaded) return offload_module.hand_out(loop, index, slot);
    if (attempt.outcome != .done) return wait(loop, index, slot, attempt.filter());
    assert(attempt.buffer_id == null);
    loop.tables.finish_local(index, attempt.result);
}

/// Puts the slot on the list of its descriptor and filter, and registers the filter when the
/// slot is the first there. A multishot operation keeps its filter; every other is one-shot.
pub fn wait(loop: *Loop, index: u32, slot: *Slot, filter: Filter) void {
    const tables = &loop.tables;
    if (slot.flags.multishot) assert(loop.waiters.count(slot.descriptor, filter) == 0);
    const first = loop.waiters.add(tables.table.slots, slot.descriptor, filter, index);
    if (first) register(loop, slot.descriptor, filter, slot.flags.multishot);
    slot.state = .submitted;
    tables.arm(index, slot);
}

/// Adds the change that asks the kernel to report `descriptor` ready on `filter`: once, or for
/// as long as the filter stays when `keep` is set.
pub fn register(loop: *Loop, descriptor: core.Descriptor, filter: Filter, keep: bool) void {
    assert(loop.changes_used < constants.changes_max);
    const once: u16 = if (keep) 0 else std.c.EV.ONESHOT;
    loop.changes[loop.changes_used] = queue_module.descriptor_event(
        descriptor,
        kernel_filter(filter),
        std.c.EV.ADD | once,
    );
    loop.changes_used += 1;
}

/// Adds the change that removes a filter a multishot operation kept.
pub fn unregister(loop: *Loop, descriptor: core.Descriptor, filter: Filter) void {
    assert(loop.changes_used < constants.changes_max);
    loop.changes[loop.changes_used] = queue_module.descriptor_event(
        descriptor,
        kernel_filter(filter),
        std.c.EV.DELETE,
    );
    loop.changes_used += 1;
}

pub fn kernel_filter(filter: Filter) i16 {
    return switch (filter) {
        .read => std.c.EVFILT.READ,
        .write => std.c.EVFILT.WRITE,
    };
}

/// Writes the message into the ring this loop has to the target, and wakes the target when it
/// sleeps (decision 12, point 6). The result is the post's own final event.
fn post(loop: *Loop, slot: *const Slot) i32 {
    const registry = loop.registry orelse return core.event.result_of(.loop_not_found);
    const target: core.LoopId = @intCast(slot.descriptor);
    const message: core.Message = .{ .payload = slot.buffer, .tag = slot.len };
    const wake = core.remote.send(registry, loop.tables.id, target, message) catch |err| {
        return core.event.result_of(core.remote.code_of(err));
    };
    if (wake) |descriptor| queue_module.Queue.wake(descriptor);
    return 0;
}

/// Ends every operation that waits on the descriptor with `canceled`, then closes it. The
/// finished list keeps their order, so the caller sees each of them before the close
/// (decision 5, rule 6). Closing the descriptor removes its filters from the kqueue.
fn close(loop: *Loop, slot: *const Slot) i32 {
    const tables = &loop.tables;
    const limit = tables.table.capacity();
    var ended: u32 = 0;
    while (ended < limit) : (ended += 1) {
        const index = loop.waiters.pop_any(tables.table.slots, slot.descriptor) orelse break;
        const waiting = tables.table.at(index);
        waiting.flags.cancel_requested = true;
        tables.finish_local(index, core.event.result_of(core.tables.cancel_code(waiting)));
    }
    sync.close_now(slot.descriptor);
    return 0;
}
