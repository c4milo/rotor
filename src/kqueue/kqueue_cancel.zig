//! Cancellation on kqueue (decisions 5 and 12, point 7). An operation the tables cannot end
//! themselves is one that waits for readiness, in user space, so its cancel always wins and has
//! no race: the slot leaves its descriptor's list and ends with `canceled`, or with `timeout`
//! when the loop asked. The event is still handed over by the next tick, never by `cancel`.
//!
//! **An offloaded file operation is the one exception, and it is the only racy cancel here.** It is
//! out on a thread the caller owns, so this file records the cancel and leaves the operation to end
//! when the worker answers (decision 18).
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const offload_module = @import("kqueue_offload.zig");
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
    // An offloaded operation is out on one of the caller's threads, and a `pread` already running
    // cannot be stopped. So the cancel is recorded and nothing else happens here: the worker's
    // answer is what ends the operation, carrying whatever the call returned. Decision 5 already
    // says a cancel that loses its race ends the operation with its own result, and decision 18's
    // open question 2 says the same of a worker.
    //
    // It follows that a caller must keep its offload running until the loop is drained. One that
    // stops its threads first leaves an operation that can never end, and `drain` reports it as
    // `StillInFlight` rather than hanging.
    if (offload_module.on_a_worker(loop, slot)) return;
    const filter = perform.filter_of(slot.code);
    const removed = loop.waiters.remove(tables.table.slots, slot.descriptor, filter, index);
    assert(removed);
    // A kept filter goes, and an operation that waited behind this one gets a one-shot filter of
    // its own. A one-shot filter is left to fire: the reap finds no waiter, or the next one.
    if (slot.flags.multishot) submit_module.after_leaving(loop, slot.descriptor, filter, true);
    tables.finish_canceled(index);
}
