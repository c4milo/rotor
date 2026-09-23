//! The submit path: `core.Tables.submit` claims a slot per operation and queues it, and `flush`
//! here turns queued slots into submission entries. `prepare` is the pure part, a slot in and a
//! submission entry out, and it is tested on every host.
//!
//! One of the six hot files decision 7 names. This is the plain version: no technique of that
//! decision's list is used, and docs/hot-path-ledger.md has no row for this file.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const address_module = @import("uring_address.zig");
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
    /// For `post`: the target loop's ring.
    target_ring: core.Descriptor = -1,
    /// For `receive_from` and `send_to`: the scratch that holds the `msghdr` the kernel reads
    /// while `io_uring_enter` runs, and the control block a send attaches (decision 15).
    message: ?*datagram.Message = null,
    /// The group's reserve, which fixes where a received datagram's bytes start.
    group: core.datagram.GroupOptions = .{},
};

/// Hands queued slots to the kernel, oldest first, until the submission ring is full. A timer
/// takes no entry: it is armed in the heap. A slot cancelled while it waited finishes here,
/// and the kernel never sees it (decision 5, rule 2).
pub fn flush(loop: *Loop) void {
    const tables = &loop.tables;
    const queued = tables.pending.count;
    var visited: u32 = 0;
    while (visited < queued) : (visited += 1) {
        const index = tables.pending.peek() orelse break;
        const slot = tables.table.at(index);
        assert(slot.state == .queued);
        if (slot.flags.cancel_requested) {
            _ = tables.pending.pop(tables.table.slots);
            tables.finish_local(index, core.event.result_of(core.tables.cancel_code(slot)));
        } else if (slot.code == .timer) {
            _ = tables.pending.pop(tables.table.slots);
            slot.state = .submitted;
            tables.arm(index, slot);
        } else if (!flush_entry(loop, index, slot)) {
            break;
        }
    }
    assert(tables.pending.count <= queued);
}

/// Fills the entry, or the two entries of a `close`, for one slot. False when the submission
/// ring lacks the room, and the slot stays queued.
fn flush_entry(loop: *Loop, index: u32, slot: *Slot) bool {
    const entries_needed: u32 = if (slot.code == .close) entries_per_close else 1;
    if (loop.ring.sqe_space() < entries_needed) return false;
    var extra: Extra = .{};
    switch (slot.code) {
        .connect => extra = connect_extra(loop, slot),
        .receive_from, .send_to => extra = datagram_extra(loop),
        .post => {
            extra.target_ring = loop.registry_descriptor(slot);
            if (extra.target_ring < 0) {
                _ = loop.tables.pending.pop(loop.tables.table.slots);
                loop.tables.finish_local(index, core.event.result_of(.loop_not_found));
                return true;
            }
        },
        .close => prepare_close_cancel(loop.ring.get_sqe().?, slot.descriptor),
        else => {},
    }
    _ = loop.tables.pending.pop(loop.tables.table.slots);
    const user_data = loop.tables.table.handle_of(index).to_bits();
    prepare(loop.ring.get_sqe().?, slot, user_data, extra);
    slot.state = .submitted;
    loop.tables.arm(index, slot);
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
    const address: *const core.Address = @ptrFromInt(slot.buffer);
    const len = address_module.to_kernel(address, storage);
    return .{ .address = @intFromPtr(storage), .address_len = len };
}

/// Fills `sqe` from `slot`. Every field of the entry is written: the ring hands out entries
/// that still hold what their last use left.
pub fn prepare(sqe: *linux.io_uring_sqe, slot: *const Slot, user_data: u64, extra: Extra) void {
    assert(!Handle.from_bits(user_data).is_none());
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    sqe.user_data = user_data;
    sqe.fd = slot.descriptor;
    switch (slot.code) {
        .accept => prepare_accept(sqe, slot),
        .connect => {
            sqe.opcode = .CONNECT;
            sqe.addr = extra.address;
            sqe.off = extra.address_len;
        },
        .receive => prepare_receive(sqe, slot),
        .send => {
            sqe.opcode = .SEND;
            sqe.addr = slot.buffer;
            sqe.len = slot.len;
            // Without it, a send to a peer that closed raises SIGPIPE and ends the process.
            sqe.rw_flags = linux.MSG.NOSIGNAL;
        },
        .shutdown => {
            sqe.opcode = .SHUTDOWN;
            sqe.len = slot.len;
        },
        .close => sqe.opcode = .CLOSE,
        .read, .write => prepare_file_transfer(sqe, slot),
        .fdatasync => {
            sqe.opcode = .FSYNC;
            sqe.rw_flags = linux.IORING_FSYNC_DATASYNC;
        },
        .post => {
            const message: core.Message = .{ .payload = slot.buffer, .tag = slot.len };
            prepare_message(sqe, extra.target_ring, message);
        },
        .nop => sqe.opcode = .NOP,
        .receive_from => datagram.prepare_receive(sqe, extra.message.?, slot, extra.group),
        .send_to => {
            const out: *const core.datagram.Outbound = @ptrFromInt(slot.offset);
            // `assert_send_to` bounds what a caller may ask for, so the control block fits.
            assert(datagram.prepare_send(sqe, extra.message.?, slot, out));
        },
        .timer => unreachable,
    }
    if (slot.flags.descriptor_registered) {
        // `fd` holds the index, which `Operation.assert_valid` allows for no kind that puts
        // something else there.
        assert(slot.code != .post and slot.code != .close);
        sqe.flags |= linux.IOSQE_FIXED_FILE;
    }
}

fn prepare_accept(sqe: *linux.io_uring_sqe, slot: *const Slot) void {
    sqe.opcode = .ACCEPT;
    sqe.rw_flags = linux.SOCK.CLOEXEC;
    if (slot.flags.multishot) sqe.ioprio = linux.IORING_ACCEPT_MULTISHOT;
}

fn prepare_receive(sqe: *linux.io_uring_sqe, slot: *const Slot) void {
    sqe.opcode = .RECV;
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
        sqe.opcode = if (is_read) .READ_FIXED else .WRITE_FIXED;
        sqe.buf_index = slot.buffer_index;
    } else {
        sqe.opcode = if (is_read) .READ else .WRITE;
    }
}

/// Makes `sqe` send `message` to the loop that owns `target_ring`, where `uring_reap.zig`'s
/// `message_of` reads it back. A loop's own post and a `Remote`'s post both build it here.
pub fn prepare_message(
    sqe: *linux.io_uring_sqe,
    target_ring: core.Descriptor,
    message: core.Message,
) void {
    assert(target_ring >= 0);
    sqe.opcode = .MSG_RING;
    sqe.fd = target_ring;
    sqe.addr = @intFromEnum(linux.IORING_MSG_RING_COMMAND.DATA);
    sqe.len = message.tag | constants.message_result_flag;
    sqe.off = message.payload;
}

/// The entry that asks the kernel to cancel the operation whose `user_data` is `target`. The
/// backend consumes its completion: the target's final event is the answer (decision 5, rule 2).
pub fn prepare_cancel(sqe: *linux.io_uring_sqe, target: u64) void {
    assert(!Handle.from_bits(target).is_none());
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    sqe.opcode = .ASYNC_CANCEL;
    sqe.fd = -1;
    sqe.addr = target;
    sqe.user_data = constants.user_data_cancel;
}

/// The first entry of a `close`: cancels every operation in flight for `descriptor`, and is
/// hard-linked to the entry that follows it.
pub fn prepare_close_cancel(sqe: *linux.io_uring_sqe, descriptor: core.Descriptor) void {
    assert(descriptor >= 0);
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    sqe.opcode = .ASYNC_CANCEL;
    sqe.fd = descriptor;
    sqe.rw_flags = linux.IORING_ASYNC_CANCEL_FD | linux.IORING_ASYNC_CANCEL_ALL;
    sqe.flags = linux.IOSQE_IO_HARDLINK;
    sqe.user_data = constants.user_data_close_cancel;
}
