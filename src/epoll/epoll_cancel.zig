//! Cancellation on epoll (decisions 5 and 20). An operation the tables cannot end themselves is one
//! that waits for readiness, in user space, so its cancel always wins and has no race: the slot
//! leaves its descriptor's list and ends with `canceled`, or with `timeout` when the loop asked.
//! The event is still handed over by the next tick, never by `cancel`.
//!
//! This is `kqueue_cancel.zig`, and like it, a cancel that leaves nobody waiting in a direction
//! takes that direction out of the kernel's registration at once, with one `epoll_ctl`. Left in
//! place, a level-triggered registration would report the descriptor the next time it became ready,
//! and end a wait early for nobody: the conformance suite's multishot accept caught exactly that on
//! 2026-09-22, with a connection that arrived after the accept was cancelled. Cancels are rare, so
//! the call is cheap where it is paid; the common case, an operation that completes, leaves the
//! registration for the next one (`epoll_reap.zig`).
//!
//! **An offloaded file operation is the one exception, and it is the only racy cancel here.** It is
//! out on a thread the caller owns, so this file records the cancel and leaves the operation to end
//! when the worker answers (decision 18).
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const offload_module = @import("epoll_offload.zig");
const perform = @import("epoll_perform.zig");
const submit_module = @import("epoll_submit.zig");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
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
    // cannot be stopped. The worker's answer is what ends it, carrying whatever the call returned:
    // decision 5 says a cancel that loses its race ends the operation with its own result.
    if (offload_module.on_a_worker(loop, slot)) return;
    const filter = perform.filter_of(slot.code);
    const removed = loop.waiters.remove(tables.table.slots, slot.descriptor, filter, index);
    assert(removed);
    // A refusal leaves the registration as it was, which costs one early report the reap then
    // settles; the cancel itself has already won.
    if (loop.waiters.count(slot.descriptor, filter) == 0) {
        submit_module.register(loop, slot.descriptor) catch {};
    }
    tables.finish_local(index, core.event.result_of(core.tables.cancel_code(slot)));
}
