//! The flush: what `tick` does with the slots `core.Tables.submit` queued. An operation is tried at
//! once, and only one that would block is added to the waiters of its descriptor and left to wait
//! (decision 20, after decision 12, point 1). Whatever ends here ends on the tables' finished list,
//! so its event is handed over by the same tick, and never by `submit` or `cancel` (decision 5,
//! rule 2).
//!
//! This is `kqueue_submit.zig` with the registration made at once rather than written into a
//! changelist: `epoll_ctl` has no batched form, so the first waiter in a direction makes one call
//! (`epoll_queue.zig` says why it asks the kernel rather than a record of its own). The flush needs
//! no bound of its own for that reason; the pending list it walks is the bound.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const descriptors_module = @import("epoll_descriptors.zig");
const offload_module = @import("epoll_offload.zig");
const perform = @import("epoll_perform.zig");
const queue_module = @import("epoll_queue.zig");
const sync = @import("epoll_sync.zig");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
const Slot = core.Slot;
const Filter = core.waiters.Filter;

/// Handles queued slots, oldest first, until none is left.
pub fn flush(loop: *Loop) void {
    const tables = &loop.tables;
    const queued = tables.pending.count;
    var visited: u32 = 0;
    while (visited < queued) : (visited += 1) {
        const index = tables.next_pending() orelse break;
        tables.take_pending(index);
        flush_one(loop, index, tables.table.at(index));
    }
    assert(tables.pending.count <= queued);
}

fn flush_one(loop: *Loop, index: u32, slot: *Slot) void {
    assert(slot.state == .queued);
    const tables = &loop.tables;
    switch (slot.code) {
        .post => tables.finish_local(index, post(loop, slot)),
        .close => tables.finish_local(index, close(loop, slot)),
        else => start(loop, index, slot),
    }
}

/// Tries the operation now. Two kinds are not tried and go straight to waiting, so that the reap
/// produces their events: a multishot operation, whose events are many, and a receive from a group,
/// whose event names a buffer, which the finished list has no room to carry. epoll reports a
/// descriptor that is already ready as soon as it is registered, so neither waits longer for it.
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

/// Puts the slot on the list of its descriptor and direction, and registers the direction when the
/// slot is the first there. A kernel that refuses the registration ends the operation at once: it
/// would otherwise wait for a readiness nothing will report.
fn wait(loop: *Loop, index: u32, slot: *Slot, filter: Filter) void {
    const tables = &loop.tables;
    if (slot.flags.multishot) assert(loop.waiters.count(slot.descriptor, filter) == 0);
    const first = loop.waiters.add(tables.table.slots, slot.descriptor, filter, index);
    if (first) {
        register(loop, slot.descriptor) catch |err| {
            const removed = loop.waiters.remove(tables.table.slots, slot.descriptor, filter, index);
            assert(removed);
            const code: core.Code = switch (err) {
                error.SystemResources => .system_resources,
                error.Unexpected => .unexpected,
            };
            return tables.finish_local(index, core.event.result_of(code));
        };
    }
    tables.hand_over(index, slot);
}

/// Makes the kernel report `descriptor` for exactly the directions an operation waits on, or
/// removes it when none does. The reap calls it too, when a direction was reported that nobody
/// waits on.
pub fn register(loop: *Loop, descriptor: core.Descriptor) queue_module.ControlError!void {
    const read = loop.waiters.count(descriptor, .read) != 0;
    const write = loop.waiters.count(descriptor, .write) != 0;
    const interest = queue_module.Interest.of(read, write) orelse {
        loop.queue.disarm(descriptor);
        return;
    };
    return loop.queue.arm(descriptor, interest);
}

/// Writes the message into the ring this loop has to the target, and wakes the target when it
/// sleeps (decision 12, point 6). The registry holds each epoll loop's eventfd, which is what one
/// write wakes. The result is the post's own final event.
fn post(loop: *Loop, slot: *const Slot) i32 {
    const registry = loop.registry orelse return core.event.result_of(.loop_not_found);
    const target = slot.post_target();
    const wake = core.remote.send(registry, loop.tables.id, target, slot.message()) catch |err| {
        return core.event.result_of(core.remote.code_of(err));
    };
    if (wake) |descriptor| queue_module.Queue.wake(descriptor);
    return 0;
}

/// Ends every operation that waits on the descriptor with `canceled`, then closes it. The finished
/// list keeps their order, so the caller sees each of them before the close (decision 5, rule 6).
/// Closing the descriptor takes its registration out of the epoll instance, as the kernel removes a
/// file from every instance when its last descriptor closes.
fn close(loop: *Loop, slot: *const Slot) i32 {
    loop.tables.end_waiters(&loop.waiters, slot.descriptor);
    sync.close_now(slot.descriptor);
    return 0;
}
