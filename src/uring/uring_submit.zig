//! The submit path: `submit` claims a slot per operation and queues it, and `flush` turns queued
//! slots into submission entries. `prepare` is the pure part, a slot in and a submission entry
//! out, and it is tested on every host.
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

const Loop = uring.Loop;
const Slot = core.Slot;
const Operation = core.Operation;
const Handle = core.Handle;

/// What `prepare` needs beside the slot, because the slot cannot hold it.
pub const Extra = struct {
    /// For `connect`: where the address sits in the kernel's form, and its length. The kernel
    /// reads it while `io_uring_enter` runs (recalled; the conformance suite connects with
    /// storage it reuses after the call), so the storage lives until `enter` returns.
    address: u64 = 0,
    address_len: u32 = 0,
    /// For `post`: the target loop's ring.
    target_ring: core.Descriptor = -1,
};

/// Claims a slot for each operation, in order, until the table is full, and returns how many it
/// took. Writes each taken operation's handle to `handles` when the caller passed any. Makes no
/// system call: the next `tick` submits.
pub fn submit(loop: *Loop, operations: []const Operation, handles: []Handle) u32 {
    assert(operations.len <= core.constants.batch_max);
    assert(handles.len == 0 or handles.len == operations.len);
    var taken: u32 = 0;
    for (operations) |*operation| {
        operation.assert_valid();
        const index = loop.table.claim() orelse break;
        const slot = loop.table.at(index);
        slot.fill(operation);
        // A loop that posts to itself would wait on a completion only its own tick can reap.
        assert(slot.code != .post or slot.descriptor != loop.id);
        loop.pending.push(loop.table.slots, index);
        if (handles.len != 0) handles[taken] = loop.table.handle_of(index);
        taken += 1;
    }
    loop.operation_sequence +%= taken;
    assert(taken <= operations.len);
    return taken;
}

/// Hands queued slots to the kernel, oldest first, until the submission ring is full. A timer
/// takes no entry: it is armed in the heap. A slot cancelled while it waited finishes here,
/// and the kernel never sees it (decision 5, rule 2).
pub fn flush(loop: *Loop) void {
    const queued = loop.pending.count;
    var visited: u32 = 0;
    while (visited < queued) : (visited += 1) {
        const index = loop.pending.peek() orelse break;
        const slot = loop.table.at(index);
        assert(slot.state == .queued);
        if (slot.flags.cancel_requested) {
            _ = loop.pending.pop(loop.table.slots);
            loop.finish_local(index, core.event.result_of(loop.cancel_code(slot)));
        } else if (slot.code == .timer) {
            _ = loop.pending.pop(loop.table.slots);
            slot.state = .submitted;
            loop.timers.arm(index, loop.now_ns + slot.offset);
        } else if (!flush_entry(loop, index, slot)) {
            break;
        }
    }
    assert(loop.pending.count <= queued);
}

/// Fills the entry, or the two entries of a `close`, for one slot. False when the submission
/// ring lacks the room, and the slot stays queued.
fn flush_entry(loop: *Loop, index: u32, slot: *Slot) bool {
    const entries_needed: u32 = if (slot.code == .close) entries_per_close else 1;
    if (loop.ring.sqe_space() < entries_needed) return false;
    var extra: Extra = .{};
    switch (slot.code) {
        .connect => extra = connect_extra(loop, slot),
        .post => {
            extra.target_ring = loop.registry_descriptor(slot);
            if (extra.target_ring < 0) {
                _ = loop.pending.pop(loop.table.slots);
                loop.finish_local(index, core.event.result_of(.loop_not_found));
                return true;
            }
        },
        .close => prepare_close_cancel(loop.ring.get_sqe().?, slot.descriptor),
        else => {},
    }
    _ = loop.pending.pop(loop.table.slots);
    prepare(loop.ring.get_sqe().?, slot, loop.table.handle_of(index).to_bits(), extra);
    slot.state = .submitted;
    if (slot.timeout_ns != 0 and !loop.timers.is_armed(index)) {
        loop.timers.arm(index, loop.now_ns + slot.timeout_ns);
    }
    return true;
}

/// A `close` takes two entries: the cancel of everything in flight for its descriptor, and the
/// close itself, hard-linked so the close runs whatever the cancel found (decision 5, rule 6).
const entries_per_close: u32 = 2;

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
    assert(user_data >> handle_generation_shift != 0);
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
            assert(extra.target_ring >= 0);
            sqe.opcode = .MSG_RING;
            sqe.fd = extra.target_ring;
            sqe.addr = @intFromEnum(linux.IORING_MSG_RING_COMMAND.DATA);
            sqe.len = slot.len | constants.message_result_flag;
            sqe.off = slot.buffer;
        },
        .nop => sqe.opcode = .NOP,
        .timer => unreachable,
    }
}

/// A handle's generation is the high half of its 64 bits, and it is never 0.
const handle_generation_shift = 32;

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

/// The entry that asks the kernel to cancel the operation whose `user_data` is `target`. The
/// backend consumes its completion: the target's final event is the answer (decision 5, rule 2).
pub fn prepare_cancel(sqe: *linux.io_uring_sqe, target: u64) void {
    assert(target >> handle_generation_shift != 0);
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
