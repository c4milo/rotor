//! The datagram paths of the uring backend (decision 15): what a `receive_from` and a `send_to`
//! put in a submission entry, and what a completed receive's buffer holds.
//!
//! **The layout is measured, not recalled.** `tools/uring_probe_datagram.zig` ran it on
//! `orbstack`, Linux 7.0.14, on 2026-09-20. A multishot `recvmsg` writes, into one provided
//! buffer: an `io_uring_recvmsg_out`, the peer address, the control messages, then the datagram.
//! The kernel lays the payload out after the space the submission **reserved** and reports the
//! bytes it **used** in the head, so the two differ whenever the address or the control block is
//! shorter than its reserve — a `sockaddr.in` reports 16 against a reserve of 32. An offset taken
//! from the written lengths lands inside the control block.
//!
//! So the payload sits at a constant offset the group fixes, and `cqe.res` less that constant is
//! the datagram's own bytes. That is the one subtract `uring_reap` makes, with no load into the
//! buffer.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const address_module = @import("linux_shared").address;
const shared = @import("linux_shared").datagram;
const ring_module = @import("uring_ring.zig");

const Address = core.Address;
const Ecn = core.datagram.Ecn;
const Received = core.datagram.Received;
const Outbound = core.datagram.Outbound;
const GroupOptions = core.datagram.GroupOptions;

/// The control blocks are `linux_shared_datagram.zig`'s, shared with the other Linux backend.
pub const control_bytes_max = shared.control_bytes_max;
pub const control_space = shared.control_space;
pub const delivery = shared.delivery;
const write_control = shared.write_control;

/// The scratch one submission entry needs, which the slot cannot hold: the kernel reads the
/// `msghdr` and its vector while `io_uring_enter` runs, so both live until it returns, exactly
/// as `uring_submit.Extra.address` does.
pub const Message = extern struct {
    header: linux.msghdr,
    vector: std.posix.iovec,
    name: address_module.Storage,
    /// The control messages a `send_to` asks the kernel to attach. Read by the protocol when the
    /// send runs, which can be after `enter` returns, so a send keeps it alive to its final
    /// event under decision 5, rule 3 — the same rule its buffer travels under.
    control: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)),
};

/// Fills `message` for a receive and points `sqe` at it. Only the two lengths are read by the
/// kernel: it writes the name and the control block into the provided buffer, not through these.
pub fn prepare_receive(
    sqe: *linux.io_uring_sqe,
    message: *Message,
    slot: *const core.Slot,
    options: GroupOptions,
) void {
    message.header = std.mem.zeroes(linux.msghdr);
    message.header.namelen = options.name_reserve;
    message.header.controllen = options.control_reserve;
    ring_module.set_opcode(sqe, .RECVMSG);
    sqe.addr = @intFromPtr(&message.header);
    sqe.len = 1;
    if (slot.flags.multishot) {
        assert(slot.flags.buffer_group);
        sqe.ioprio = linux.IORING_RECV_MULTISHOT;
    }
    if (slot.flags.buffer_group) {
        sqe.flags |= linux.IOSQE_BUFFER_SELECT;
        sqe.buf_index = slot.buffer_index;
    }
}

/// Fills `message` for a send and points `sqe` at it, writing the control messages `out` asks
/// for. Returns false when they do not fit, which `assert_send_to` has already made impossible
/// for the kinds rotor offers and which a future control message could reach.
pub fn prepare_send(
    sqe: *linux.io_uring_sqe,
    message: *Message,
    slot: *const core.Slot,
    out: *const Outbound,
) bool {
    message.header = std.mem.zeroes(linux.msghdr);
    message.vector = .{ .base = @ptrFromInt(slot.buffer), .len = slot.len };
    message.header.iov = @ptrCast(&message.vector);
    message.header.iovlen = 1;
    if (out.flags.peer) {
        const len = address_module.to_kernel(&out.peer, &message.name);
        message.header.name = @ptrCast(&message.name);
        message.header.namelen = len;
    }
    const written = write_control(&message.control, out) orelse return false;
    if (written != 0) {
        message.header.control = &message.control;
        message.header.controllen = written;
    }
    ring_module.set_opcode(sqe, .SENDMSG);
    sqe.addr = @intFromPtr(&message.header);
    sqe.len = 1;
    // Without it, a send to a peer that closed raises SIGPIPE and ends the process.
    sqe.rw_flags = linux.MSG.NOSIGNAL;
    return true;
}

const testing = std.testing;
