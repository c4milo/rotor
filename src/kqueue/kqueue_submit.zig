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
const Kevent = queue_module.Kevent;

/// Handles queued slots, oldest first, until none is left or the tick's changes are full.
pub fn flush(loop: *Loop) void {
    const tables = &loop.tables;
    const queued = tables.pending.count;
    var visited: u32 = 0;
    while (visited < queued) : (visited += 1) {
        const index = tables.next_pending() orelse break;
        // An operation that has to wait needs room for its registration.
        if (loop.changes_used == constants.changes_max) break;
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
    tables.hand_over(index, slot);
}

/// Adds the change that asks the kernel to report `descriptor` ready on `filter`: once, or for
/// as long as the filter stays when `keep` is set.
pub fn register(loop: *Loop, descriptor: core.Descriptor, filter: Filter, keep: bool) void {
    const once: u16 = if (keep) 0 else std.c.EV.ONESHOT;
    push_change(loop, queue_module.descriptor_event(
        descriptor,
        kernel_filter(filter),
        std.c.EV.ADD | once,
    ));
}

/// Adds the change that removes a filter a multishot operation kept.
pub fn unregister(loop: *Loop, descriptor: core.Descriptor, filter: Filter) void {
    push_change(loop, queue_module.descriptor_event(
        descriptor,
        kernel_filter(filter),
        std.c.EV.DELETE,
    ));
}

/// What `descriptor` needs registered on `filter` once an operation has left its list. When
/// another operation waits there, it needs a one-shot filter. The one that left had either a
/// one-shot filter, which has fired, or a kept filter, which the operation behind it relied on.
/// A kept filter is deleted and a one-shot filter added in its place: macOS keeps a filter kept
/// when EV_ONESHOT is added to it, measured on 2026-09-23. With nobody waiting, a kept filter is
/// deleted too, because it would report for ever with nobody to serve.
pub fn after_leaving(loop: *Loop, descriptor: core.Descriptor, filter: Filter, kept: bool) void {
    if (kept) unregister(loop, descriptor, filter);
    if (loop.waiters.count(descriptor, filter) != 0) register(loop, descriptor, filter, false);
}

/// Adds `change` to the tick's changelist, and applies the list first when it is full.
fn push_change(loop: *Loop, change: Kevent) void {
    if (loop.changes_used == constants.changes_max) apply_early(loop);
    assert(loop.changes_used < constants.changes_max);
    loop.changes[loop.changes_used] = change;
    loop.changes_used += 1;
}

/// Hands a full changelist to the kernel before the tick's own call. A reap, or a run of cancels
/// between two ticks, can add more than `changes_max` changes. That costs one more system call
/// here, where it used to halt. Every change carries EV_RECEIPT, so the kernel answers each one, in
/// order, into a list that holds exactly those answers, and drains no readiness: measured on
/// macOS 26.6.2 on 2026-09-23. A change the kernel refused goes back on the list, so the tick's
/// own call reports the refusal as it reports every other. A call that fails as a whole drops the
/// changes, as `Queue.wake` drops a wake: `exchange` has already made the call again after EINTR.
fn apply_early(loop: *Loop) void {
    comptime assert(constants.changes_max <= constants.readiness_max);
    const changes = loop.changes[0..loop.changes_used];
    for (changes) |*change| change.flags |= std.c.EV.RECEIPT;
    var receipts: [constants.changes_max]Kevent = undefined;
    const answered = loop.queue.exchange(changes, receipts[0..changes.len], null) catch 0;
    assert(answered <= changes.len);
    loop.changes_used = 0;
    for (receipts[0..answered], changes[0..answered]) |receipt, change| {
        assert(receipt.ident == change.ident and receipt.filter == change.filter);
        if (receipt.data == 0) continue;
        var again = change;
        again.flags &= ~@as(u16, std.c.EV.RECEIPT);
        loop.changes[loop.changes_used] = again;
        loop.changes_used += 1;
    }
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
    const registry = loop.inbox.registry orelse return core.event.result_of(.loop_not_found);
    const target = slot.post_target();
    const wake = core.remote.send(registry, loop.tables.id, target, slot.message()) catch |err| {
        return core.event.result_of(core.remote.code_of(err));
    };
    if (wake) |descriptor| queue_module.Queue.wake(descriptor);
    return 0;
}

/// Ends every operation that waits on the descriptor with `canceled`, then closes it. The
/// finished list keeps their order, so the caller sees each of them before the close
/// (decision 5, rule 6). Closing the descriptor removes its filters from the kqueue.
fn close(loop: *Loop, slot: *const Slot) i32 {
    loop.tables.end_waiters(&loop.waiters, slot.descriptor);
    sync.close_now(slot.descriptor);
    return 0;
}

const testing = std.testing;

test "a full changelist is applied early, and a change the kernel refused waits for the tick" {
    if (!@import("builtin").os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 4, .entries = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();
    const pair = try @import("kqueue_testing.zig").nonblocking_pair();
    defer for (pair) |descriptor| {
        _ = std.c.close(descriptor);
    };

    // Every change but the last adds a filter the kernel accepts. The last deletes one that was
    // never added, which the kernel refuses.
    for (0..constants.changes_max - 1) |_| register(&loop, pair[0], .read, false);
    unregister(&loop, pair[1], .read);
    try testing.expectEqual(constants.changes_max, loop.changes_used);

    // One more change applies the list first. The refused delete is put back for the tick, as it
    // was, and the new change follows it.
    register(&loop, pair[0], .write, false);
    try testing.expectEqual(@as(u32, 2), loop.changes_used);
    try testing.expectEqual(@as(usize, @intCast(pair[1])), loop.changes[0].ident);
    try testing.expectEqual(@as(u16, std.c.EV.DELETE), loop.changes[0].flags);
    try testing.expectEqual(@as(usize, @intCast(pair[0])), loop.changes[1].ident);
    try testing.expectEqual(std.c.EVFILT.WRITE, loop.changes[1].filter);
    loop.changes_used = 0;
}
