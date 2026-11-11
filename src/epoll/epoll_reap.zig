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
//!   ticks it saved (decision 20, "A readiness serves one operation per direction"). A multishot
//!   datagram receive is the exception: one `recvmmsg` takes up to `receive_batch_max` datagrams,
//!   and a count below the request shows the socket is empty without that call.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = core.assertion_class.assert_class_a;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const perform = @import("epoll_perform.zig");
const queue_module = @import("epoll_queue.zig");
const submit_module = @import("epoll_submit.zig");
const epoll = @import("epoll.zig");
const shared_datagram = @import("linux_shared").datagram;
const datagram = @import("epoll_datagram.zig");

const Loop = epoll.Loop;
const Event = core.Event;
const Filter = core.waiters.Filter;
const Readiness = queue_module.Event;
const Attempt = perform.Attempt;
const Slot = core.Slot;

/// The bits that make a waiting receive or accept worth trying: data, a half close, a full close or
/// an error. Every one of them either transfers something or ends the operation.
const read_bits: u32 = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.HUP | linux.EPOLL.ERR;

/// The bits that make a waiting send or connect worth trying.
const write_bits: u32 = linux.EPOLL.OUT | linux.EPOLL.HUP | linux.EPOLL.ERR;

/// Turns readiness into events, at most `events.len` of them. The events of a split datagram that
/// did not fit the last reap go first (decision 15, amendment of 2026-11-05). A readiness this reap
/// leaves unserved is level triggered, so the kernel reports it again.
pub fn reap(loop: *Loop, readiness: []const Readiness, events: []Event) u32 {
    var produced: u32 = 0;
    loop.reaps +%= 1;
    // Read only while a split waits, so a reap with none touches nothing of it.
    if (loop.split.pending()) {
        produced = loop.split.take(events);
        if (loop.split.pending()) return produced;
    }
    for (readiness) |*ready| {
        if (ready.data.u64 == constants.wake_user_data) {
            // The wake names no operation. Its counter is emptied, or a level-triggered eventfd
            // would end every wait at once.
            loop.queue.drain_wake();
            continue;
        }
        if (ready.data.u64 == constants.wait_timer_user_data) {
            // The timer that bounds a wait (decision 20, "The wait timer"), which names no
            // operation. It fires once, so it is no longer armed.
            loop.wait_timer_deadline_ns = 0;
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
        produced += serve_read(loop, descriptor, events[produced..]);
    }
    if (bits & write_bits != 0 and writers != 0 and produced < events.len) {
        if (serve(loop, descriptor, .write)) |event| produced += place(loop, event, events[produced..]);
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

/// Writes `event` into `events`, or the first events of its split when it began one. Returns how
/// many it wrote.
fn place(loop: *Loop, event: Event, events: []Event) u32 {
    assert(events.len >= 1);
    // Only an event that names a buffer can have begun a split, and the bit is in hand.
    if (event.flags.buffer and loop.split.pending()) return loop.split.take(events);
    events[0] = event;
    return 1;
}

/// Starts splitting `event` when it is a datagram receive's and its buffer holds a coalesced
/// datagram: the kernel wrote the datagrams' size into the control block in front of them.
fn begin_split(loop: *Loop, group_id: ?u16, event: Event) void {
    const id = group_id orelse return;
    if (!event.flags.buffer) return;
    const group = &loop.groups[id];
    const buffer = group.bytes_of(event.flags.buffer_id);
    const segment_bytes = shared_datagram.segment_bytes_of(buffer, loop.datagram_shape.options);
    _ = loop.split.begin(event, segment_bytes, group.holders);
}

/// Serves the oldest reader of `descriptor`: a batch of datagrams when it is a multishot datagram
/// receive that `batch_size` lets batch, one operation otherwise. The reader is found once, so a
/// receive that does not batch costs what it cost before batches existed. Returns how many events
/// it wrote.
fn serve_read(loop: *Loop, descriptor: core.Descriptor, events: []Event) u32 {
    const index = loop.waiters.first(descriptor, .read) orelse return 0;
    const slot = loop.tables.table.at(index);
    if (slot.tag == .receive_from and slot.flags.multishot) {
        const size = batch_size(loop.reaps, slot);
        if (size > 1) {
            if (serve_batch(loop, descriptor, index, size, events)) |produced| return produced;
        }
    }
    const event = serve_slot(loop, descriptor, .read, index) orelse return 0;
    return place(loop, event, events);
}

/// Receives up to `size` datagrams for the multishot datagram receive in slot `index` with one
/// `recvmmsg`. Null when the group or the caller's events hold room for fewer than two, which
/// `serve_slot` handles. Returns how many events it wrote.
fn serve_batch(loop: *Loop, descriptor: core.Descriptor, index: u32, size: u32, events: []Event) ?u32 {
    const slot = loop.tables.table.at(index);
    assert_class_a(slot.tag == .receive_from and slot.flags.multishot);
    const group = &loop.groups[slot.buffer_index];
    const count = @min(size, batch_count(events.len, group.free_count));
    // One datagram is `serve`'s, whose single `recvmsg` costs less than a batch of one.
    if (count <= 1) return null;
    assert_class_a(slot.state == .submitted);
    const batch = &loop.batch;
    for (batch.ids[0..count], batch.buffers[0..count]) |*id, *buffer| {
        id.* = group.take().?;
        buffer.* = group.bytes_of(id.*);
    }
    const answer = datagram.receive_many(descriptor, batch, count, loop.datagram_shape.options);
    const received: u32 = if (answer.would_block or answer.result < 0) 0 else @intCast(answer.result);
    // Given back from the top, so the group's free stack is as the takes found it.
    var unused = count;
    while (unused > received) : (unused -= 1) group.give_back(batch.ids[unused - 1]);
    // Not ready after all. The registration is level triggered and stays, so it reports again.
    if (answer.would_block) return 0;
    if (answer.result < 0) {
        // `recvmmsg` took the socket's error, so a second call would not see it: the error ends
        // the receive here, as `serve` would end it.
        events[0] = conclude(loop, descriptor, .read, index, Attempt.done(answer.result));
        return 1;
    }
    var produced: u32 = 0;
    for (batch.ids[0..received], batch.lengths[0..received]) |id, length| {
        assert_class_a(core.attempt.goes_on(.receive_from, @intCast(length)));
        const event: Event = .{
            .user_data = slot.user_data,
            .result = @intCast(length),
            .flags = .{ .buffer = true, .buffer_id = id, .more = true, .dispatched = slot.flags.dispatched },
        };
        begin_split(loop, slot.buffer_index, event);
        produced += place(loop, event, events[produced..]);
    }
    assert(produced <= events.len);
    return produced;
}

/// The batch a multishot datagram receive asks for. A receive the reap before also served has a
/// socket that stays ready, so its batch doubles, from 2 up to `receive_batch_max`. Any other asks
/// for 1, which `serve` makes as one `recvmsg`: one datagram at a time then makes the calls it made
/// before batches existed. The reap that last served it and its size are kept in `Slot.offset`,
/// which a receive does not use.
fn batch_size(reaps: u32, slot: *Slot) u32 {
    const last: u32 = @truncate(slot.offset >> @bitSizeOf(u32));
    const previous: u32 = @truncate(slot.offset);
    var size: u32 = 1;
    if (reaps -% last == 1) size = @min(constants.receive_batch_max, @max(previous, 1) << 1);
    slot.offset = (@as(u64, reaps) << @bitSizeOf(u32)) | size;
    return size;
}

/// How many datagrams one batch can hold: at most `receive_batch_max`, at most the group's free
/// buffers, and few enough that every one could be a coalesced datagram whose events all fit.
fn batch_count(room: usize, free: u16) u32 {
    const by_room: u32 = @intCast(@min(room / core.constants.coalesced_segments_max, constants.receive_batch_max));
    return @min(by_room, free);
}

/// Tries the oldest waiter of `descriptor` in `filter`'s direction again. Null when the call would
/// still block, which a readiness that another reader answered first can leave behind.
fn serve(loop: *Loop, descriptor: core.Descriptor, filter: Filter) ?Event {
    const index = loop.waiters.first(descriptor, filter) orelse return null;
    return serve_slot(loop, descriptor, filter, index);
}

/// Tries the operation in slot `index`, the oldest waiter of `descriptor` in `filter`'s direction.
fn serve_slot(loop: *Loop, descriptor: core.Descriptor, filter: Filter, index: u32) ?Event {
    const slot = loop.tables.table.at(index);
    assert_class_a(slot.state == .submitted);
    const attempt = perform.attempt(loop, slot);
    // A file never waits, so nothing that reaches the reap is handed to an offload.
    assert_class_a(attempt.outcome != .offloaded);
    // Not ready after all. The registration is level triggered and stays, so it reports again.
    if (attempt.outcome != .done) return null;
    return conclude(loop, descriptor, filter, index, attempt);
}

/// The event of an attempt that is done. A multishot operation stays after a success; any other
/// leaves its descriptor's list and frees its slot.
fn conclude(loop: *Loop, descriptor: core.Descriptor, filter: Filter, index: u32, attempt: Attempt) Event {
    const tables = &loop.tables;
    const slot = tables.table.at(index);
    assert_class_a(attempt.outcome == .done);
    var event: Event = .{ .user_data = slot.user_data, .result = attempt.result, .flags = .{ .dispatched = slot.flags.dispatched } };
    if (attempt.buffer_id) |buffer_id| {
        event.flags.buffer = true;
        event.flags.buffer_id = buffer_id;
    }
    // Read before the slot can be released below.
    const datagram_group: ?u16 = if (slot.tag == .receive_from) slot.buffer_index else null;
    // A multishot operation goes on after a success, and ends at its first failure or at the end
    // of its stream.
    if (slot.flags.multishot and core.attempt.goes_on(slot.tag, attempt.result)) {
        event.flags.more = true;
        begin_split(loop, datagram_group, event);
        return event;
    }
    const popped = loop.waiters.pop(tables.table.slots, descriptor, filter);
    assert(popped == index);
    const emptied = loop.waiters.count(descriptor, filter) == 0;
    if (emptied and keeps_nothing(filter, slot.flags.multishot)) settle(loop, descriptor);
    tables.finish(index, slot);
    begin_split(loop, datagram_group, event);
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

test "a receive served reap after reap doubles its batch, and one that skips a reap asks for one" {
    var slot = std.mem.zeroes(Slot);
    // One datagram at a time: served every other reap, so it never batches.
    try testing.expectEqual(@as(u32, 1), batch_size(10, &slot));
    try testing.expectEqual(@as(u32, 1), batch_size(12, &slot));
    // A socket that stays ready: 2, 4, 8, and no more than `receive_batch_max`.
    try testing.expectEqual(@as(u32, 2), batch_size(13, &slot));
    try testing.expectEqual(@as(u32, 4), batch_size(14, &slot));
    try testing.expectEqual(@as(u32, 8), batch_size(15, &slot));
    try testing.expectEqual(constants.receive_batch_max, batch_size(16, &slot));
    // One reap missed starts it again from one.
    try testing.expectEqual(@as(u32, 1), batch_size(18, &slot));
    // The reap count wraps, and the reap after the last one still counts as the next.
    slot.offset = (@as(u64, std.math.maxInt(u32)) << @bitSizeOf(u32)) | 1;
    try testing.expectEqual(@as(u32, 2), batch_size(0, &slot));
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

test "the wait timer's readiness makes no event and leaves the timer disarmed" {
    // A loop with tables and no epoll instance: the timer's readiness enters no kernel.
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, &options);
    loop.wait_timer_deadline_ns = 1;
    const readiness = [1]Readiness{.{
        .events = linux.EPOLL.IN,
        .data = .{ .u64 = constants.wait_timer_user_data },
    }};
    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), reap(&loop, &readiness, &events));
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
}

/// The user data of a reactor's record, which no tick here calls: the loop copies the bit into the
/// events of the operation, and reads neither (decision 33, open question 5).
const record_user_data = 0x1000;

/// `operation` with the bit and the user data that a reactor's `Completion.mark` writes.
fn marked(operation: core.Operation) core.Operation {
    var named = operation;
    named.user_data = record_user_data;
    named.dispatched = true;
    return named;
}

/// Hands the queued slot at the head of the list to `descriptor`'s readers, as a flush does.
fn wait_to_read(loop: *Loop, descriptor: core.Descriptor) u32 {
    const index = loop.tables.next_pending().?;
    loop.tables.take_pending(index);
    loop.tables.hand_over(index, loop.tables.table.at(index));
    _ = loop.waiters.add(loop.tables.table.slots, descriptor, .read, index);
    return index;
}

test "an attempt that is done marks the events of an operation that names a record" {
    // A loop with tables and no epoll instance: neither event below enters the kernel.
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, &options);
    var bytes: [8]u8 = @splat(0);
    const descriptor = 5;
    const group = try loop.reserve_buffer_group();
    try testing.expectEqual(@as(u32, 2), loop.submit(&.{
        marked(core.Operation.receive(0, descriptor, &bytes)),
        marked(core.Operation.receive_group(0, descriptor, group)),
    }, &.{}));
    const single = wait_to_read(&loop, descriptor);
    const multishot = wait_to_read(&loop, descriptor);
    // The single receive ends, and the multishot one behind it stays on the list.
    const last = conclude(&loop, descriptor, .read, single, Attempt.done(bytes.len));
    try testing.expect(last.flags.dispatched and last.is_final());
    try testing.expectEqual(@as(u64, record_user_data), last.user_data);
    const filled: Attempt = .{ .outcome = .done, .result = 4, .buffer_id = 0 };
    const more = conclude(&loop, descriptor, .read, multishot, filled);
    try testing.expect(more.flags.dispatched and more.flags.more and more.flags.buffer);
}

/// The group of the batch test, which holds every datagram that test sends.
const batch_buffers = 4;
const batch_buffer_bytes = 2048;

/// Datagrams the batch test sends: two, the smallest batch `serve_batch` makes.
const batch_datagrams = 2;

/// Room for a batch of two: `batch_count` keeps room for every datagram to be coalesced.
const batch_events = batch_datagrams * core.constants.coalesced_segments_max;

/// Sends `batch_datagrams` datagrams of one byte from `sender` to `socket`.
fn send_batch(sender: core.Descriptor, socket: core.Descriptor) !void {
    const to = try epoll.sync.local_address(socket);
    var storage: epoll.address.Storage = undefined;
    const len = epoll.address.to_kernel(&to, &storage);
    for (0..batch_datagrams) |_| {
        const rc = linux.sendto(sender, "d", 1, 0, @ptrCast(&storage), len);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    }
}

test "one recvmmsg batch marks each event of a datagram receive that names a record" {
    if (!epoll.supported) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
    defer loop.deinit();
    const group_bytes = comptime epoll.buffers.group_bytes(batch_buffers, batch_buffer_bytes);
    var group_memory: [group_bytes]u8 align(epoll.buffers.group_alignment) = undefined;
    const count = batch_buffers;
    const group = try loop.reserve_buffer_group();
    try loop.provide_datagram_buffers(group, &group_memory, count, batch_buffer_bytes, .{});
    defer loop.release_buffers(group);
    const loopback = core.Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const socket = try epoll.sync.open_datagram(.ipv4, &loopback, .{ .coalesce = false });
    defer epoll.sync.close_now(socket);
    const sender = try epoll.sync.open_datagram(.ipv4, &loopback, .{});
    defer epoll.sync.close_now(sender);

    const receive = marked(core.Operation.receive_from(0, socket, group));
    var handles: [1]core.Handle = undefined;
    try testing.expectEqual(@as(u32, 1), loop.submit(&.{receive}, &handles));
    var events: [batch_events]Event = undefined;
    // The flush finds no datagram, so the receive waits for its socket to be readable.
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 0));
    try send_batch(sender, socket);
    // The reap before this one served the receive, so this reap asks for a batch of two.
    const slot = loop.tables.table.at(handles[0].index);
    slot.offset = (@as(u64, loop.reaps) << @bitSizeOf(u32)) | 1;
    const ready = [_]Readiness{.{ .events = linux.EPOLL.IN, .data = .{ .u64 = @intCast(socket) } }};
    const produced = reap(&loop, &ready, &events);
    var flagged: u32 = 0;
    for (events[0..produced]) |event| {
        flagged += @intFromBool(event.flags.dispatched and event.flags.more and event.flags.buffer);
        if (event.flags.buffer) loop.give_back_buffer(group, event.flags.buffer_id);
    }
    // The cancel's final event goes to the caller of the drain, so the loop ends empty, and a
    // check that fails below fails without a halt in the `defer`s.
    loop.cancel(handles[0]);
    try loop.drain(events[produced..]);
    try testing.expectEqual(@as(u32, batch_datagrams), produced);
    try testing.expectEqual(produced, flagged);
    try testing.expectEqual(@as(u64, record_user_data), events[0].user_data);
}
