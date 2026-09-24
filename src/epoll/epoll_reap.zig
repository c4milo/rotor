//! The reap: what `tick` does with the descriptors the kernel reported ready. For each direction
//! that is ready and has an operation waiting, the oldest one is tried again, and its event is
//! written straight into the caller's events.
//!
//! This is `kqueue_reap.zig` with three differences. The first two come from epoll reporting a
//! descriptor and not a filter:
//!
//! - **One readiness can serve both directions.** It carries every bit that is set, so a socket
//!   that is readable and writable at once yields up to two events. The reap stops serving when the
//!   caller's events are full, and nothing is lost: registrations are level triggered, so a
//!   direction left unserved is reported again by the next wait.
//! - **The read direction stays registered between operations; the write direction does not.** A
//!   receive or an accept that completes leaves reading registered, because the next one on that
//!   descriptor is the common case and finds the registration there, which saves it a call. The
//!   write direction is taken out as soon as nobody waits on it, because a socket is writable
//!   almost all the time: a write registration left in place ends the very next wait, for nobody.
//!   The conformance suite caught that on 2026-09-22, with a connect that completed and a tick that
//!   then could not sleep. A multishot operation that ends takes its direction out at once, as a
//!   cancel does (`epoll_cancel.zig`), because nothing follows it. And a direction the kernel
//!   reports ready with nobody waiting on it is taken out here, or it would be reported on every
//!   wait.
//! - **A readiness serves one operation per direction.** kqueue's readiness carries the amount that
//!   is ready, and its reap serves until that is used. epoll's carries no amount, so serving more
//!   ends with a call that answers EAGAIN, and at one message in flight that cost more than the
//!   ticks it saved (decision 20, "A readiness serves one operation per direction").
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const perform = @import("epoll_perform.zig");
const queue_module = @import("epoll_queue.zig");
const submit_module = @import("epoll_submit.zig");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
const Event = core.Event;
const Filter = core.waiters.Filter;
const Readiness = queue_module.Event;

/// The bits that make a waiting receive or accept worth trying: data, a half close, a full close or
/// an error. Every one of them either transfers something or ends the operation.
const read_bits: u32 = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.HUP | linux.EPOLL.ERR;

/// The bits that make a waiting send or connect worth trying.
const write_bits: u32 = linux.EPOLL.OUT | linux.EPOLL.HUP | linux.EPOLL.ERR;

/// Turns readiness into events, at most `events.len` of them.
pub fn reap(loop: *Loop, readiness: []const Readiness, events: []Event) u32 {
    var produced: u32 = 0;
    for (readiness) |*ready| {
        if (ready.data.u64 == constants.wake_user_data) {
            // The wake names no operation. Its counter is emptied, or a level-triggered eventfd
            // would end every wait at once.
            loop.queue.drain_wake();
            continue;
        }
        const descriptor: core.Descriptor = @intCast(ready.data.u64);
        produced += serve_ready(loop, descriptor, ready.events, events[produced..]);
    }
    assert(produced <= events.len);
    return produced;
}

/// Serves one readiness: the oldest reader when a read bit is set, the oldest writer when a write
/// bit is, as long as there is room for their events. Returns how many events it wrote.
fn serve_ready(loop: *Loop, descriptor: core.Descriptor, bits: u32, events: []Event) u32 {
    // Counted before serving, so a list this reap empties is not mistaken for one nobody used.
    const readers = loop.waiters.count(descriptor, .read);
    const writers = loop.waiters.count(descriptor, .write);
    var produced: u32 = 0;
    if (bits & read_bits != 0 and readers != 0 and produced < events.len) {
        if (serve(loop, descriptor, .read)) |event| {
            events[produced] = event;
            produced += 1;
        }
    }
    if (bits & write_bits != 0 and writers != 0 and produced < events.len) {
        if (serve(loop, descriptor, .write)) |event| {
            events[produced] = event;
            produced += 1;
        }
    }
    if (is_unwatched(bits, readers, writers)) settle(loop, descriptor);
    return produced;
}

/// True when the kernel reported a direction nobody waits on, which a level-triggered registration
/// would go on reporting. `HUP` and `ERR` arrive whatever was asked for, so they count only when
/// nobody waits at all: while someone does, serving them ends that operation.
fn is_unwatched(bits: u32, readers: u32, writers: u32) bool {
    const read_asked = linux.EPOLL.IN | linux.EPOLL.RDHUP;
    if (bits & read_asked != 0 and readers == 0) return true;
    if (bits & linux.EPOLL.OUT != 0 and writers == 0) return true;
    const either = linux.EPOLL.HUP | linux.EPOLL.ERR;
    return bits & either != 0 and readers == 0 and writers == 0;
}

/// Leaves the kernel reporting `descriptor` for the directions an operation still waits on, and
/// for nothing else. A refusal here leaves the registration as it was: the worst that does is one
/// more report of a direction nobody waits on, which comes back here.
fn settle(loop: *Loop, descriptor: core.Descriptor) void {
    submit_module.register(loop, descriptor) catch {};
}

/// Tries the oldest waiter of `descriptor` in `filter`'s direction again. Null when the call would
/// still block, which a readiness that another reader answered first can leave behind.
fn serve(loop: *Loop, descriptor: core.Descriptor, filter: Filter) ?Event {
    const tables = &loop.tables;
    const index = loop.waiters.first(descriptor, filter) orelse return null;
    const slot = tables.table.at(index);
    assert(slot.state == .submitted);
    const attempt = perform.attempt(loop, slot);
    // A file never waits, so nothing that reaches the reap is handed to an offload.
    assert(attempt.outcome != .offloaded);
    // Not ready after all. The registration is level triggered and stays, so it reports again.
    if (attempt.outcome != .done) return null;
    var event: Event = .{ .user_data = slot.user_data, .result = attempt.result, .flags = .{} };
    if (attempt.buffer_id) |buffer_id| {
        event.flags.buffer = true;
        event.flags.buffer_id = buffer_id;
    }
    // A multishot operation goes on after a success, and ends at its first failure or at the end
    // of its stream.
    if (slot.flags.multishot and core.attempt.goes_on(slot.code, attempt.result)) {
        event.flags.more = true;
        return event;
    }
    const popped = loop.waiters.pop(tables.table.slots, descriptor, filter);
    assert(popped == index);
    const emptied = loop.waiters.count(descriptor, filter) == 0;
    if (emptied and keeps_nothing(filter, slot.flags.multishot)) settle(loop, descriptor);
    tables.finish(index, slot);
    return event;
}

/// True when a direction whose last waiter just ended should leave the kernel's registration now,
/// rather than wait for the reap to find it reported for nobody: see the file's comment.
fn keeps_nothing(filter: Filter, multishot: bool) bool {
    return multishot or filter == .write;
}

const testing = std.testing;

test "a direction reported with nobody waiting is taken out, and one being served is not" {
    const in = linux.EPOLL.IN;
    const out = linux.EPOLL.OUT;
    // Readable, a reader waits: served, and the registration stays.
    try testing.expect(!is_unwatched(in, 1, 0));
    // Readable, nobody reads: a level-triggered registration would report it for ever.
    try testing.expect(is_unwatched(in, 0, 1));
    // Writable with nobody writing, which is almost every socket almost all the time.
    try testing.expect(is_unwatched(out, 1, 0));
    try testing.expect(!is_unwatched(in | out, 1, 1));
    // A half close is asked for with reading, so it counts with the readers.
    try testing.expect(is_unwatched(linux.EPOLL.RDHUP, 0, 1));
    try testing.expect(!is_unwatched(linux.EPOLL.RDHUP, 1, 0));
    // A hang-up comes unasked: while anyone waits, serving it ends that operation.
    try testing.expect(!is_unwatched(linux.EPOLL.HUP, 0, 1));
    try testing.expect(!is_unwatched(linux.EPOLL.ERR, 1, 0));
    try testing.expect(is_unwatched(linux.EPOLL.HUP, 0, 0));
    try testing.expect(is_unwatched(linux.EPOLL.ERR, 0, 0));
}

test "only a one-shot reader leaves its direction registered for the next operation" {
    try testing.expect(!keeps_nothing(.read, false));
    // Writable almost always, so a write registration left behind ends the next wait for nobody.
    try testing.expect(keeps_nothing(.write, false));
    // Nothing follows a multishot operation that ended, whichever direction it waited in.
    try testing.expect(keeps_nothing(.read, true));
    try testing.expect(keeps_nothing(.write, true));
}

test "every bit that ends or advances an operation wakes the direction it belongs to" {
    try testing.expect(read_bits & linux.EPOLL.IN != 0);
    try testing.expect(read_bits & linux.EPOLL.RDHUP != 0);
    try testing.expect(write_bits & linux.EPOLL.OUT != 0);
    // A hang-up and an error end an operation in either direction.
    for ([_]u32{ linux.EPOLL.HUP, linux.EPOLL.ERR }) |either| {
        try testing.expect(read_bits & either != 0);
        try testing.expect(write_bits & either != 0);
    }
    // Being writable says nothing of being readable, and the other way round.
    try testing.expect(read_bits & linux.EPOLL.OUT == 0);
    try testing.expect(write_bits & linux.EPOLL.IN == 0);
}
