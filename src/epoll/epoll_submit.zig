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
    // Each loop the posts of this flush must wake is woken once, after the flush (decision 12,
    // point 6).
    var wakes: core.remote.Wakes = .{};
    var visited: u32 = 0;
    while (visited < queued) : (visited += 1) {
        const index = tables.next_pending() orelse break;
        tables.take_pending(index);
        flush_one(loop, index, tables.table.at(index), &wakes);
    }
    if (loop.inbox.registry) |registry| wakes.send(registry, queue_module.Queue.wake);
    assert(tables.pending.count <= queued);
}

fn flush_one(loop: *Loop, index: u32, slot: *Slot, wakes: *core.remote.Wakes) void {
    assert(slot.state == .queued);
    const tables = &loop.tables;
    switch (slot.code) {
        .post => tables.finish_local(index, post(loop, slot, wakes)),
        .close => tables.finish_local(index, close(loop, slot)),
        else => start(loop, index, slot),
    }
}

/// Tries the operation now. A multishot operation is not tried and goes straight to waiting, so
/// that the reap produces its events, which are many. So is a receive from a group whose buffers are
/// all with the caller: it waits for bytes, and fails with `buffers_exhausted` only if the group is
/// still empty when they come. epoll reports a descriptor that is already ready as soon as it is
/// registered, so neither waits longer for it. Until 2026-09-23 every receive from a group waited,
/// because the finished list could not name a buffer, and each paid an `epoll_ctl` (decision 20).
fn start(loop: *Loop, index: u32, slot: *Slot) void {
    if (slot.flags.descriptor_registered) descriptors_module.resolve(loop, slot);
    if (slot.flags.multishot or group_is_empty(loop, slot)) {
        return wait(loop, index, slot, perform.filter_of(slot.code));
    }
    const attempt = perform.attempt(loop, slot);
    // The caller's offload has it now, and a worker's ring carries the result back (decision 18).
    // The slot stays the loop's until then, which is decision 5, rule 3 for its buffer.
    if (attempt.outcome == .offloaded) return offload_module.hand_out(loop, index, slot);
    if (attempt.outcome != .done) return wait(loop, index, slot, attempt.filter());
    const tables = &loop.tables;
    if (attempt.buffer_id) |buffer_id| {
        return tables.finish_local_buffer(index, attempt.result, buffer_id);
    }
    tables.finish_local(index, attempt.result);
}

/// True for a receive from a group none of whose buffers is free.
fn group_is_empty(loop: *const Loop, slot: *const Slot) bool {
    return slot.flags.buffer_group and loop.groups[slot.buffer_index].free_count == 0;
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

/// Writes the message into the ring this loop has to the target, and notes the target in `wakes`
/// when it sleeps, so the flush wakes it once (decision 12, point 6). The result is the post's own
/// final event.
fn post(loop: *Loop, slot: *const Slot, wakes: *core.remote.Wakes) i32 {
    const registry = loop.inbox.registry orelse return core.event.result_of(.loop_not_found);
    const target = slot.post_target();
    const wake = core.remote.send(registry, loop.tables.id, target, slot.message()) catch |err| {
        return core.event.result_of(core.remote.code_of(err));
    };
    if (wake != null) wakes.note(target);
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

const testing = std.testing;
const linux = std.os.linux;
const Event = core.Event;
const Operation = core.Operation;

/// A loop with one group of four 8-byte buffers, and a socket pair. The tests receive on the first
/// end and write to the second.
const Fixture = struct {
    const operations = 8;
    const options: Loop.Options = .{ .operations = operations };
    const group_id = 1;
    const buffer_bytes = 8;
    const buffers = 4;
    const group_bytes = epoll.buffers.group_bytes(buffers, buffer_bytes);
    const pair_ends = 2;

    memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment),
    group_memory: [group_bytes]u8 align(epoll.buffers.group_alignment),
    loop: Loop,
    pair: [pair_ends]i32,

    fn init(fixture: *Fixture) !void {
        try fixture.loop.init(&fixture.memory, options);
        errdefer fixture.loop.deinit();
        try fixture.loop.provide_buffers(group_id, &fixture.group_memory, buffers, buffer_bytes);
        const flags = linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, flags, 0, &fixture.pair)) != .SUCCESS) {
            return error.Unexpected;
        }
    }

    /// Ends whatever still waits, then closes the pair and the loop.
    fn deinit(fixture: *Fixture) void {
        fixture.loop.cancel_all();
        var events: [operations]Event = undefined;
        // A drain that fails leaves operations in flight, and `Loop.deinit` halts on them.
        fixture.loop.drain(&events) catch {};
        for (fixture.pair) |descriptor| sync.close_now(descriptor);
        fixture.loop.deinit();
    }

    /// Writes `count` bytes to the second end, so the first has them to read.
    fn send(fixture: *Fixture, count: usize) !void {
        const bytes: [buffers * buffer_bytes]u8 = @splat('r');
        if (linux.write(fixture.pair[1], &bytes, count) != count) return error.ShortWrite;
    }

    /// A single-shot receive from the group, on the first end.
    fn from_group(fixture: *const Fixture) Operation {
        return .{ .user_data = 1, .kind = .{ .receive = .{
            .socket = fixture.pair[0],
            .target = .{ .group = group_id },
        } } };
    }
};

test "a receive from a group finds its bytes at the flush, and names its buffer unregistered" {
    if (!epoll.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const loop = &fixture.loop;
    try fixture.send(Fixture.buffer_bytes);
    try testing.expectEqual(@as(u32, 1), loop.submit(&.{fixture.from_group()}, &.{}));
    flush(loop);
    // It completed at once: nothing waits, so the descriptor was never registered.
    try testing.expectEqual(@as(u32, 0), loop.waiters.count(fixture.pair[0], .read));

    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expect(events[0].flags.buffer);
    try testing.expectEqual(@as(u32, Fixture.buffer_bytes), try events[0].outcome());
    loop.give_back_buffer(Fixture.group_id, events[0].flags.buffer_id);
}

test "a receive from a group whose buffers are all out waits for bytes and does not fail" {
    if (!epoll.supported) return error.SkipZigTest;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const loop = &fixture.loop;
    // Bytes for every buffer: the first receives take them all at the flush, and the last finds
    // the group empty.
    try fixture.send(Fixture.buffers * Fixture.buffer_bytes);
    const receives = [_]Operation{fixture.from_group()} ** (Fixture.buffers + 1);
    try testing.expectEqual(@as(u32, receives.len), loop.submit(&receives, &.{}));
    flush(loop);
    try testing.expectEqual(@as(u32, 1), loop.waiters.count(fixture.pair[0], .read));
}
