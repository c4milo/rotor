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
const datagram = @import("uring_datagram.zig");

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
    send_wakes(loop);
    assert(tables.pending.count <= queued);
}

/// Fills the entry, or the two entries of a `close`, for one slot. False when the submission
/// ring lacks the room, and the slot stays queued. A post takes no entry, and ends here.
fn flush_entry(loop: *Loop, index: u32, slot: *Slot) bool {
    if (slot.code == .post) {
        loop.tables.take_pending(index);
        const result = core.remote.post(loop.inbox.registry, loop.tables.id, slot, &loop.wakes);
        loop.tables.finish_local(index, result);
        return true;
    }
    const entries_needed: u32 = if (slot.code == .close) entries_per_close else 1;
    if (loop.ring.sqe_space() < entries_needed) return false;
    var extra: Extra = .{};
    switch (slot.code) {
        .connect => extra = connect_extra(loop, slot),
        .receive_from, .send_to => extra = datagram_extra(loop),
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
fn datagram_extra(loop: *Loop) Extra {
    assert(loop.messages_used < loop.messages.len);
    const message = &loop.messages[loop.messages_used];
    loop.messages_used += 1;
    return .{ .message = message, .group = loop.datagram_group };
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
    switch (slot.code) {
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
        assert(slot.code != .close);
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
    const is_read = slot.code == .read;
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
/// registry, and nothing wakes it.
fn send_wakes(loop: *Loop) void {
    const registry = loop.inbox.registry orelse return;
    const noted = loop.wakes;
    var targets = noted.targets.iterator(.{});
    while (targets.next()) |target| {
        const ring = registry.get(@intCast(target));
        if (ring >= 0) {
            const sqe = loop.ring.get_sqe() orelse return;
            prepare_wake(sqe, ring);
        }
        loop.wakes.targets.unset(target);
    }
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
