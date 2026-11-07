//! The submit path: `core.Tables.submit` claims a slot per operation and queues it, and `flush`
//! here turns queued slots into submission entries. `prepare` is the pure part, a slot in and a
//! submission entry out, and it is tested on every host.
//!
//! One of the six hot files decision 7 names. This is the plain version: no technique of that
//! decision's list is used, and docs/hot-path-ledger.md has no row for this file.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = core.assertion_class.assert_class_a;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const address_module = @import("linux_shared").address;
const ring_module = @import("uring_ring.zig");
const uring = @import("uring.zig");
const group_wake = @import("uring_group.zig");
const group = @import("linux_shared").group;
const datagram = @import("uring_datagram.zig");
const shared_datagram = @import("linux_shared").datagram;

const Loop = uring.Loop;
const Handle = core.Handle;
const Slot = core.Slot;

/// What `prepare` needs beside the slot, because the slot cannot hold it.
pub const Extra = struct {
    /// For `connect`: where the address sits in the kernel's form, and its length. The kernel
    /// reads it while `io_uring_enter` runs (recalled; the conformance suite connects with
    /// storage it reuses after the call), so the storage lives until `enter` returns.
    address: u64 = 0,
    address_len: u32 = 0,
    /// For `receive_from` and `send_to`: the scratch that holds the `msghdr` the kernel reads
    /// while `io_uring_enter` runs, and the control block a send attaches (decision 15).
    message: ?*datagram.Message = null,
    /// The group's reserve, which fixes where a received datagram's bytes start.
    group: core.datagram.GroupOptions = .{},
};

/// Hands queued slots to the kernel, oldest first, until the submission ring is full. A timer
/// takes no entry: it is armed in the heap. Nor does a post: it goes through the mailbox ring the
/// loop has to its target. A slot cancelled while it waited finishes here, and the kernel never
/// sees it (decision 5, rule 2). The wakes the posts need go last.
pub fn flush(loop: *Loop) void {
    const tables = &loop.tables;
    const queued = tables.pending.count;
    var visited: u32 = 0;
    while (visited < queued) : (visited += 1) {
        const index = tables.next_pending() orelse break;
        if (!flush_entry(loop, index, tables.table.at(index))) break;
    }
    // Forced inline: with `deinit` as a second caller, the compiler stopped inlining it here, and
    // each tick paid for the call (docs/hot-path-ledger.md, row H4).
    @call(.always_inline, send_wakes, .{loop});
    group_wake.arm(loop);
    assert(tables.pending.count <= queued);
}

/// Fills the entry, or the two entries of a `close`, for one slot. False when the submission
/// ring lacks the room, and the slot stays queued. A post takes no entry, and ends here.
fn flush_entry(loop: *Loop, index: u32, slot: *Slot) bool {
    if (slot.tag == .post) {
        loop.tables.take_pending(index);
        const result = core.remote.post(loop.inbox.registry, loop.tables.id, slot, &loop.wakes);
        loop.tables.finish_local(index, result);
        return true;
    }
    const entries_needed: u32 = if (slot.tag == .close) entries_per_close else 1;
    if (loop.ring.sqe_space() < entries_needed) return false;
    var extra: Extra = .{};
    switch (slot.tag) {
        .connect => extra = connect_extra(loop, slot),
        .receive_from, .send_to => {
            extra = datagram_extra(loop);
            if (slot.tag == .receive_from) limit_coalescing(loop, slot);
        },
        .close => prepare_close_cancel(loop.ring.get_sqe().?, slot.descriptor),
        else => {},
    }
    loop.tables.take_pending(index);
    const user_data = loop.tables.table.handle_of(index).to_bits();
    prepare(loop.ring.get_sqe().?, slot, user_data, extra);
    loop.tables.hand_over(index, slot);
    return true;
}

/// A `close` takes two entries: the cancel of everything in flight for its descriptor, and the
/// close itself, hard-linked so the close runs whatever the cancel found (decision 5, rule 6).
const entries_per_close: u32 = 2;

/// One message scratch per entry, reused each tick as `connect_extra`'s storage is.
/// A receive from a group whose buffers cannot hold a coalesced datagram turns coalescing off on
/// its socket (decision 15, amendment of 2026-11-05). A registered descriptor is an index and no
/// socket, so its socket keeps the option it was opened with.
fn limit_coalescing(loop: *Loop, slot: *const Slot) void {
    if (slot.flags.descriptor_registered) return;
    const buffer_bytes = loop.groups[slot.buffer_index].buffer_bytes;
    const capacity = core.datagram.payload_capacity(buffer_bytes, loop.datagram_shape.options);
    shared_datagram.limit_coalescing(slot.descriptor, capacity);
}

fn datagram_extra(loop: *Loop) Extra {
    assert(loop.messages_used < loop.messages.len);
    const message = &loop.messages[loop.messages_used];
    loop.messages_used += 1;
    return .{ .message = message, .group = loop.datagram_shape.options };
}

fn connect_extra(loop: *Loop, slot: *const Slot) Extra {
    assert(loop.addresses_used < loop.addresses.len);
    const storage = &loop.addresses[loop.addresses_used];
    loop.addresses_used += 1;
    const address = slot.address();
    const len = address_module.to_kernel(address, storage);
    return .{ .address = @intFromPtr(storage), .address_len = len };
}

/// Fills `sqe` from `slot`. Every field of the entry is written: the ring hands out entries
/// that still hold what their last use left.
pub fn prepare(sqe: *linux.io_uring_sqe, slot: *const Slot, user_data: u64, extra: Extra) void {
    assert_class_a(!Handle.from_bits(user_data).is_none());
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    sqe.user_data = user_data;
    sqe.fd = slot.descriptor;
    switch (slot.tag) {
        .accept => prepare_accept(sqe, slot),
        .connect => {
            ring_module.set_opcode(sqe, .CONNECT);
            sqe.addr = extra.address;
            sqe.off = extra.address_len;
        },
        .receive => prepare_receive(sqe, slot),
        .send => {
            ring_module.set_opcode(sqe, .SEND);
            sqe.addr = slot.buffer;
            sqe.len = slot.len;
            // Without it, a send to a peer that closed raises SIGPIPE and ends the process.
            sqe.rw_flags = linux.MSG.NOSIGNAL;
        },
        .shutdown => {
            ring_module.set_opcode(sqe, .SHUTDOWN);
            sqe.len = slot.len;
        },
        .close => ring_module.set_opcode(sqe, .CLOSE),
        .read, .write => prepare_file_transfer(sqe, slot),
        .fdatasync => {
            ring_module.set_opcode(sqe, .FSYNC);
            sqe.rw_flags = linux.IORING_FSYNC_DATASYNC;
        },
        // The same opcode without the data-only flag: `fsync(2)`, metadata and all.
        .fsync => {
            ring_module.set_opcode(sqe, .FSYNC);
            sqe.rw_flags = 0;
        },
        .nop => ring_module.set_opcode(sqe, .NOP),
        .receive_from => datagram.prepare_receive(sqe, extra.message.?, slot, extra.group),
        .send_to => {
            const out = slot.outbound();
            // `assert_send_to` bounds what a caller may ask for, so the control block fits.
            assert(datagram.prepare_send(sqe, extra.message.?, slot, out));
        },
        .timer, .post => unreachable,
    }
    if (slot.flags.descriptor_registered) {
        // `fd` holds the index, which `Operation.assert_valid` allows for no kind that puts
        // something else there.
        assert(slot.tag != .close);
        sqe.flags |= linux.IOSQE_FIXED_FILE;
    }
}

fn prepare_accept(sqe: *linux.io_uring_sqe, slot: *const Slot) void {
    ring_module.set_opcode(sqe, .ACCEPT);
    sqe.rw_flags = linux.SOCK.CLOEXEC;
    if (slot.flags.multishot) sqe.ioprio = linux.IORING_ACCEPT_MULTISHOT;
}

fn prepare_receive(sqe: *linux.io_uring_sqe, slot: *const Slot) void {
    ring_module.set_opcode(sqe, .RECV);
    if (slot.flags.buffer_group) {
        sqe.flags |= linux.IOSQE_BUFFER_SELECT;
        sqe.buf_index = slot.buffer_index;
    } else {
        sqe.addr = slot.buffer;
        sqe.len = slot.len;
    }
    if (slot.flags.multishot) {
        assert(slot.flags.buffer_group);
        sqe.ioprio = linux.IORING_RECV_MULTISHOT;
    }
}

fn prepare_file_transfer(sqe: *linux.io_uring_sqe, slot: *const Slot) void {
    const is_read = slot.tag == .read;
    sqe.addr = slot.buffer;
    sqe.len = slot.len;
    sqe.off = slot.offset;
    if (slot.flags.buffer_registered) {
        if (is_read) ring_module.set_opcode(sqe, .READ_FIXED) else ring_module.set_opcode(sqe, .WRITE_FIXED);
        sqe.buf_index = slot.buffer_index;
    } else {
        if (is_read) ring_module.set_opcode(sqe, .READ) else ring_module.set_opcode(sqe, .WRITE);
    }
}

/// Sends each wake the posts noted in `loop.wakes`: one `IORING_OP_MSG_RING` per target that said
/// it sleeps, however many messages the flush posted it (decision 12, point 6). A target the
/// submission ring has no room for stays noted, and the tick does not block while one is
/// (`uring_tick.zig`), so no wake is lost. A target that stopped since has no ring in the
/// registry, and nothing wakes it. A group's write the kernel refuses is dropped, and counts in
/// `loop.dropped_wake_count`. The reap counts a refused `MSG_RING` when its answer comes back.
fn send_wakes(loop: *Loop) void {
    const registry = loop.inbox.registry orelse return;
    const noted = loop.wakes;
    var targets = noted.targets.iterator(.{});
    while (targets.next()) |target| {
        const descriptor = registry.get(@intCast(target));
        if (descriptor >= 0) {
            if (registry.group) {
                // In a group the target published its eventfd, and a write to it is the wake
                // (decision 21, point 3).
                if (!group.wake_sent(descriptor)) loop.dropped_wake_count += 1;
            } else {
                const sqe = loop.ring.get_sqe() orelse return;
                prepare_wake(sqe, descriptor);
            }
        }
        loop.wakes.targets.unset(target);
    }
}

/// What `Loop.deinit` enters the ring through when it sends the noted wakes: the kernel itself. It
/// calls `Ring.enter_now` and not `Ring.enter`, so `enter_with` keeps the callers it had, and the
/// compiler keeps it inline in the tick (docs/hot-path-ledger.md, row H4).
pub const KernelEnter = struct {
    pub fn enter(
        _: KernelEnter,
        ring: *ring_module.Ring,
    ) ring_module.EnterError!ring_module.Entered {
        return ring.enter_now();
    }
};

/// Sends every wake still noted in `loop.wakes`, for `Loop.deinit` (decision 4, amended
/// 2026-11-06), and returns how many wakes it dropped. A `Loop.post` notes its wake and the next
/// tick sends it, so a loop that posts and then stops has no next tick. Each enter goes through
/// `enters.enter(&loop.ring)`. In `deinit` that is `KernelEnter`. A test hands it answers the
/// kernel gives only under load, such as `overcommitted` on every pass.
///
/// Each pass drops the completions in the ring, fills the submission ring with wakes and enters
/// once. `deinit` calls it after it asserts that no operation is in flight, so every completion is
/// one the reap drops anyway. The passes go on while a wake is noted or an entry waits in the
/// submission ring. An `overcommitted` enter takes no entry, and an earlier tick can leave its
/// wakes there too. The passes stop at `deinit_wake_passes_max`, or at an enter that fails.
///
/// A wake left after the last pass is dropped. Each message is in its ring, and the target reads
/// it when its wait ends. The result counts the targets still noted and the wakes still in the
/// submission ring. A target can be in both, when a tick left its wake in the ring and a later
/// post noted it again, and then it counts twice: two wakes were dropped. The result also counts
/// each wake the kernel answered below 0, among the answers the passes read and the answers after
/// the last pass (decision 4, fourth amendment of 2026-11-06).
pub fn send_noted_wakes(loop: *Loop, enters: anytype) u32 {
    var refused: u32 = 0;
    var pass: u32 = 0;
    while (pass < constants.deinit_wake_passes_max and wakes_unsent(loop)) : (pass += 1) {
        refused += drop_answers(&loop.ring);
        send_wakes(loop);
        _ = enters.enter(&loop.ring) catch break;
    }
    assert(pass <= constants.deinit_wake_passes_max);
    // The kernel answers a `MSG_RING` when it takes the entry, so the answers to the last pass are
    // in the completion ring now (recalled, not measured: `io_msg_ring` completes at issue).
    refused += drop_answers(&loop.ring);
    const noted: u32 = @intCast(loop.wakes.targets.count());
    assert(noted <= core.constants.loops_max);
    return refused + noted + wakes_in_submission_ring(&loop.ring);
}

/// Drops every completion in the ring, and returns how many of them answer a wake below 0: a wake
/// the kernel refused, for example to a descriptor that is no ring. `deinit` calls it after it
/// asserts that no operation is in flight, so no other completion yields an event.
fn drop_answers(ring: *ring_module.Ring) u32 {
    const ready = ring.cq_ready();
    assert(ready <= ring.io.cq.cqes.len);
    var refused: u32 = 0;
    var offset: u32 = 0;
    while (offset < ready) : (offset += 1) {
        const cqe = ring.cqe_at(offset);
        if (cqe.user_data == constants.user_data_wake and cqe.res < 0) refused += 1;
    }
    ring.cq_advance(ready);
    assert(refused <= ready);
    return refused;
}

/// True while a wake is noted, or an entry waits in the submission ring.
fn wakes_unsent(loop: *Loop) bool {
    return loop.wakes.targets.count() != 0 or loop.ring.sq_ready() != 0;
}

/// The wakes among the entries the kernel has not taken. The ring can also hold an entry that is
/// no wake, such as the wait timer an `overcommitted` tick left, and that is no wake to count.
fn wakes_in_submission_ring(ring: *ring_module.Ring) u32 {
    const waiting = ring.sq_ready();
    var wakes: u32 = 0;
    var offset: u32 = 0;
    while (offset < waiting) : (offset += 1) {
        if (ring.sqe_at(offset).user_data == constants.user_data_wake) wakes += 1;
    }
    assert(wakes <= waiting);
    return wakes;
}

/// Makes `sqe` wake the loop that owns `target_ring`: an `IORING_OP_MSG_RING` that carries no
/// message, only a completion whose `user_data` is `constants.user_data_wake`, which the target's
/// reap drops. It ends the target's wait; the messages are in the mailbox rings. The sender's own
/// answer carries the same `user_data`, and its reap drops it too. A loop's wakes and a `Remote`'s
/// both build it here.
pub fn prepare_wake(sqe: *linux.io_uring_sqe, target_ring: core.Descriptor) void {
    assert(target_ring >= 0);
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    ring_module.set_opcode(sqe, .MSG_RING);
    sqe.fd = target_ring;
    sqe.addr = @intFromEnum(linux.IORING_MSG_RING_COMMAND.DATA);
    sqe.len = 0;
    sqe.off = constants.user_data_wake;
    sqe.user_data = constants.user_data_wake;
}

/// Makes `sqe` arm the loop's wait timer (decision 6, amended 2026-09-27): a timeout that fires once
/// at the absolute time `timespec` holds, on `CLOCK_MONOTONIC`, the clock the tick reads. Absolute,
/// so an entry that waits in the submission ring past its tick still fires at its deadline. The
/// kernel reads `timespec` when it takes the entry. The timer's completion, ETIME, carries
/// `constants.user_data_wait_timer`, and the reap drops it.
pub fn prepare_wait_timer(sqe: *linux.io_uring_sqe, timespec: *const linux.kernel_timespec) void {
    assert(timespec.sec >= 0 and timespec.nsec >= 0);
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    ring_module.set_opcode(sqe, .TIMEOUT);
    sqe.fd = -1;
    sqe.addr = @intFromPtr(timespec);
    sqe.len = 1;
    // A count of 0: the timeout waits for no completions, only for its time.
    sqe.off = 0;
    sqe.rw_flags = linux.IORING_TIMEOUT_ABS;
    sqe.user_data = constants.user_data_wait_timer;
}

/// Makes `sqe` move the armed wait timer to the absolute time `timespec` holds. Its completion
/// carries `constants.user_data_wait_timer_update`: 0 when the timer moved, and ENOENT when it had
/// fired already, whose own completion then follows. The reap drops both.
pub fn prepare_wait_timer_update(
    sqe: *linux.io_uring_sqe,
    timespec: *const linux.kernel_timespec,
) void {
    assert(timespec.sec >= 0 and timespec.nsec >= 0);
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    ring_module.set_opcode(sqe, .TIMEOUT_REMOVE);
    sqe.fd = -1;
    sqe.addr = constants.user_data_wait_timer;
    // The kernel's `addr2`, where the new time is, shares `off`.
    sqe.off = @intFromPtr(timespec);
    sqe.rw_flags = linux.IORING_TIMEOUT_UPDATE | linux.IORING_TIMEOUT_ABS;
    sqe.user_data = constants.user_data_wait_timer_update;
}

/// The entry that asks the kernel to cancel the operation whose `user_data` is `target`. The
/// backend consumes its completion: the target's final event is the answer (decision 5, rule 2).
pub fn prepare_cancel(sqe: *linux.io_uring_sqe, target: u64) void {
    assert(!Handle.from_bits(target).is_none());
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    ring_module.set_opcode(sqe, .ASYNC_CANCEL);
    sqe.fd = -1;
    sqe.addr = target;
    sqe.user_data = constants.user_data_cancel;
}

/// The first entry of a `close`: cancels every operation in flight for `descriptor`, and is
/// hard-linked to the entry that follows it.
pub fn prepare_close_cancel(sqe: *linux.io_uring_sqe, descriptor: core.Descriptor) void {
    assert(descriptor >= 0);
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    ring_module.set_opcode(sqe, .ASYNC_CANCEL);
    sqe.fd = descriptor;
    sqe.rw_flags = linux.IORING_ASYNC_CANCEL_FD | linux.IORING_ASYNC_CANCEL_ALL;
    sqe.flags = linux.IOSQE_IO_HARDLINK;
    sqe.user_data = constants.user_data_close_cancel;
}
