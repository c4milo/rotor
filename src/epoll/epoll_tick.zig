//! `tick`: one turn of the loop. In order: read the clock once, try the queued operations and
//! register the ones that must wait, finish the timers that are due and end the operations whose
//! deadline passed, hand over the events the loop produced itself and the messages other loops
//! posted, make the one `epoll_pwait2` call, and perform what became ready.
//!
//! This is `kqueue_tick.zig` less two things. There is no changelist to carry into the wait,
//! because the flush registered each descriptor as it went. And there is no poll trigger: macOS
//! parks a `kevent` that finds nothing ready for about 12 µs even with a zero timeout, and the
//! trigger is how the kqueue backend avoids that. Whether Linux's `epoll_pwait2` does anything like
//! it has not been measured, so this file does not work around it; `conformance_cost.zig`'s poll
//! bound is what would say so.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const cancel_module = @import("epoll_cancel.zig");
const queue_module = @import("epoll_queue.zig");
const reap_module = @import("epoll_reap.zig");
const offload_module = @import("epoll_offload.zig");
const submit_module = @import("epoll_submit.zig");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
const Event = core.Event;

pub const TickError = queue_module.WaitError;

/// Writes up to `events.len` events and returns how many. With `wait_ns` above 0 and nothing to
/// hand over at once, blocks until a descriptor is ready, a message arrives, the nearest deadline
/// passes, or the wait does.
pub fn tick(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
    const tables = &loop.tables;
    tables.begin_tick(events.len, wait_ns);
    tables.now_ns = clock_ns();
    submit_module.flush(loop);
    loop.tables.expire(loop, cancel_module.request);
    // Before the finished list is drained, so a result a worker pushed becomes its operation's
    // final event in this tick and not the next (decision 18).
    _ = offload_module.drain(loop);
    var produced = tables.drain_finished(events);
    produced += loop.drain_mailboxes(events[produced..]);

    const wait = if (produced == 0) loop.settle_to_sleep(tables.wait_bound(wait_ns)) else null;
    const room = @min(events.len - produced, constants.readiness_max);
    // A tick whose events are already full asks the kernel nothing: what is ready now is ready at
    // the next tick too, because every registration is level triggered. Nor does a poll with no
    // operation waiting for readiness: the kernel could report only this loop's own eventfd, and
    // what a wake announces is read from its ring above and below. A wake another loop wrote stays
    // readable for the next call that waits, which then ends at once, as decision 12, point 6
    // allows.
    const idle = wait == null and loop.waiters.used == 0;
    const nothing: TickError!u32 = 0;
    const readiness = loop.readiness[0..room];
    const ready = if (room == 0 or idle) nothing else loop.queue.wait(readiness, wait orelse 0);
    loop.wake_up();
    const ready_count = try ready;

    produced += reap_module.reap(loop, loop.readiness[0..ready_count], events[produced..]);
    // A worker may have answered while this tick waited, and the wake is what ended the wait.
    if (offload_module.drain(loop) != 0) {
        produced += tables.drain_finished(events[produced..]);
    }
    produced += loop.drain_mailboxes(events[produced..]);
    if (produced == 0 and wait != null) {
        // The wait may have ended because a deadline came due.
        tables.now_ns = clock_ns();
        loop.tables.expire(loop, cancel_module.request);
        produced += tables.drain_finished(events[produced..]);
    }
    assert(produced <= events.len);
    return produced;
}

/// The monotonic clock both Linux backends read (`linux_shared_clock.zig`).
const clock_ns = @import("linux_shared").clock.clock_ns;

const testing = std.testing;

test "a tick with a message to hand over and nothing waiting on a socket polls nothing" {
    if (!epoll.supported) return error.SkipZigTest;
    const loops = 2;
    const receiver: core.LoopId = 1;
    const sender: core.LoopId = 0;
    var registry_memory: [epoll.Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: epoll.Registry = undefined;
    registry.init(&registry_memory, loops);
    const sizing: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(sizing)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, .{ .operations = 2, .id = receiver, .registry = &registry });
    defer loop.deinit();

    // Another loop posts, and wakes this one as a post to a loop that sleeps does.
    try testing.expect(registry.mailbox(sender, receiver).push(.{ .tag = 7, .payload = 1 }));
    queue_module.Queue.wake(loop.queue.wake_descriptor);

    // The message is handed over. No operation waits for readiness, so the kernel could report
    // only the wake, and the tick does not ask it: the wake stays unread for the next tick that
    // waits. A tick that polled would have read the wake's counter back to 0.
    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expect(events[0].flags.message);
    var counter: u64 = 0;
    const read = linux.read(loop.queue.wake_descriptor, std.mem.asBytes(&counter), @sizeOf(u64));
    try testing.expectEqual(@as(usize, @sizeOf(u64)), read);
}
