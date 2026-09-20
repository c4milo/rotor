//! Cancellation on kqueue (decisions 5 and 12, point 7). An operation the tables cannot end
//! themselves is one that waits for readiness, in user space, so its cancel always wins and has
//! no race: the slot leaves its descriptor's list and ends with `canceled`, or with `timeout`
//! when the loop asked. The event is still handed over by the next tick, never by `cancel`.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const perform = @import("kqueue_perform.zig");
const submit_module = @import("kqueue_submit.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const Handle = core.Handle;
const Slot = core.Slot;

/// Asks for the operation `handle` names to be cancelled. A handle gone stale names nothing, and
/// that is legal (decision 5, rule 2).
pub fn cancel(loop: *Loop, handle: Handle) void {
    const slot = loop.tables.cancellable(handle) orelse return;
    request(loop, handle.index, slot);
}

/// Marks `slot` for cancellation and ends it when it waits for readiness. The loop calls this
/// itself when a deadline passes, with `flags.timed_out` already set.
pub fn request(loop: *Loop, index: u32, slot: *Slot) void {
    const tables = &loop.tables;
    if (tables.request_cancel(index, slot) != .backend) return;
    assert(slot.state == .submitted);
    const filter = perform.filter_of(slot.code);
    const removed = loop.waiters.remove(tables.table.slots, slot.descriptor, filter, index);
    assert(removed);
    // A kept filter would report for ever with nobody to serve. A one-shot filter is left to
    // fire: the reap finds no waiter and does nothing.
    if (slot.flags.multishot) submit_module.unregister(loop, slot.descriptor, filter);
    tables.finish_local(index, core.event.result_of(core.tables.cancel_code(slot)));
}
