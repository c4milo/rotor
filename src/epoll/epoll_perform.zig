//! Performing an operation: on epoll the backend makes each system call itself, at flush and again
//! when the descriptor becomes ready (decision 20). `attempt` makes the call once and says what
//! came of it: a result, or a direction to wait on because the call would block.
//!
//! This is `kqueue_perform.zig` with Linux's calls, and Linux has three things macOS lacks, each of
//! which removes a call: `accept4` hands back a socket already non-blocking and closed on exec,
//! `MSG_NOSIGNAL` keeps a send to a closed peer from raising SIGPIPE, and `fdatasync` is the
//! kernel's own call rather than `F_FULLFSYNC`.
//!
//! EINTR transferred nothing, so the call is made again, a bounded number of times. Every other
//! errno is the operation's result, through `core.errno.code_of`. A file operation's call is
//! `epoll_file_call.zig`'s, which the offload's worker makes too.
//!
//! Everything here enters the kernel, so it is tested under Linux alone, through the loop.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const file_call = @import("epoll_file_call.zig");
const address_module = @import("linux_shared").address;
const datagram = @import("epoll_datagram.zig");
const socket_calls = @import("epoll_sync_socket.zig");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
const Slot = core.Slot;
const Filter = core.waiters.Filter;

pub const Attempt = core.attempt.Attempt;

pub const filter_of = core.attempt.filter_of;

/// Makes the operation's system call once.
pub fn attempt(loop: *Loop, slot: *Slot) Attempt {
    assert(slot.state == .queued or slot.state == .submitted);
    // The flush swapped a registered index for its descriptor before it came here.
    assert(!slot.flags.descriptor_registered);
    return switch (slot.code) {
        .accept => attempt_accept(slot),
        .connect => attempt_connect(slot),
        .receive => attempt_receive(loop, slot),
        .send => attempt_send(slot),
        .shutdown => attempt_shutdown(slot),
        .read, .write, .fdatasync => attempt_file(loop, slot),
        .nop => Attempt.done(0),
        .receive_from => attempt_receive_from(loop, slot),
        .send_to => attempt_send_to(slot),
        .close, .timer, .post => unreachable,
    };
}

/// What one socket call answered, with EINTR folded into `retry` and EAGAIN into `would_block`.
const Answer = core.attempt.Answer(linux.E);

fn answer_of(rc: usize) Answer {
    return switch (linux.errno(rc)) {
        .SUCCESS => .{ .value = rc },
        .INTR => .retry,
        .AGAIN => .would_block,
        else => |errno| .{ .errno = errno },
    };
}

/// `accept4` gives the new socket both flags the loop needs in the call that makes it, so there is
/// no window in which it blocks or survives an exec, and no second call as on macOS.
fn attempt_accept(slot: *const Slot) Attempt {
    var retry: u32 = 0;
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        const rc = linux.accept4(slot.descriptor, null, null, socket_calls.socket_flags);
        switch (answer_of(rc)) {
            .retry => continue,
            .would_block => return .{ .outcome = .wait_read },
            .errno => |errno| {
                if (connection_already_gone(errno)) continue;
                return Attempt.failed(errno);
            },
            .value => |accepted| return Attempt.done(@intCast(accepted)),
        }
    }
    return Attempt.interrupted;
}

/// True for the errnos Linux's `accept4` answers when the connection it was about to hand over
/// failed while it waited in the backlog. The listener is still good and the next connection may be
/// too, so the call is made again, as the manual advises: treat them like EAGAIN. The list is
/// ENETDOWN, EPROTO, ENOPROTOOPT, EHOSTDOWN, ENONET, EHOSTUNREACH, EOPNOTSUPP and ENETUNREACH,
/// recalled from accept(2) and not read for this file. macOS reports them on the new socket
/// instead, which is why the kqueue backend has no such list.
fn connection_already_gone(errno: linux.E) bool {
    return switch (errno) {
        .NETDOWN, .PROTO, .NOPROTOOPT, .HOSTDOWN, .NONET => true,
        .HOSTUNREACH, .OPNOTSUPP, .NETUNREACH => true,
        else => false,
    };
}

/// A connect has two calls. The first starts it and answers EINPROGRESS. When the socket becomes
/// writable the connect is over, and SO_ERROR says how it ended. `Slot.retries` tells the two
/// apart: it is 0 until the first call has been made.
fn attempt_connect(slot: *Slot) Attempt {
    if (slot.retries != 0) return connect_outcome(slot);
    slot.retries = 1;
    const address = slot.address();
    var storage: address_module.Storage = undefined;
    const len = address_module.to_kernel(address, &storage);
    const rc = linux.connect(slot.descriptor, @ptrCast(&storage), len);
    return switch (linux.errno(rc)) {
        .SUCCESS, .ISCONN => Attempt.done(0),
        // A signal does not stop a connect that has started: it goes on, as EINPROGRESS says.
        .INPROGRESS, .INTR => .{ .outcome = .wait_write },
        // A non-blocking connect on Linux can also answer EAGAIN when the local ports run out.
        // Waiting would never end it, so it is the operation's result.
        .AGAIN => Attempt.done(core.event.result_of(.system_resources)),
        else => |errno| Attempt.failed(errno),
    };
}

fn connect_outcome(slot: *const Slot) Attempt {
    var pending: c_int = 0;
    var len: linux.socklen_t = @sizeOf(c_int);
    const rc = linux.getsockopt(
        slot.descriptor,
        linux.SOL.SOCKET,
        linux.SO.ERROR,
        std.mem.asBytes(&pending),
        &len,
    );
    if (linux.errno(rc) != .SUCCESS) return Attempt.failed(linux.errno(rc));
    if (pending == 0) return Attempt.done(0);
    const errno: linux.E = @enumFromInt(@as(u16, @intCast(pending)));
    return Attempt.failed(errno);
}

/// The buffer a receive writes into: its own, or one taken from its group. Null when the group has
/// none left, which ends the operation with `buffers_exhausted`.
const Target = struct { bytes: []u8, buffer_id: ?u16 };

fn target_of(loop: *Loop, slot: *const Slot) ?Target {
    if (!slot.flags.buffer_group) return .{ .bytes = slot.bytes(), .buffer_id = null };
    const group = &loop.groups[slot.buffer_index];
    const buffer_id = group.take() orelse return null;
    return .{ .bytes = group.bytes_of(buffer_id), .buffer_id = buffer_id };
}

/// Gives a group's buffer back when nothing was received into it.
fn release(loop: *Loop, slot: *const Slot, target: Target) void {
    if (target.buffer_id) |id| loop.groups[slot.buffer_index].give_back(id);
}

fn attempt_receive(loop: *Loop, slot: *const Slot) Attempt {
    const target = target_of(loop, slot) orelse {
        return Attempt.done(core.event.result_of(.buffers_exhausted));
    };
    const result = receive_into(slot.descriptor, target.bytes);
    if (result.outcome == .done and result.result >= 0) {
        return .{ .outcome = .done, .result = result.result, .buffer_id = target.buffer_id };
    }
    release(loop, slot, target);
    return result;
}

fn receive_into(descriptor: core.Descriptor, bytes: []u8) Attempt {
    var retry: u32 = 0;
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        switch (answer_of(linux.recvfrom(descriptor, bytes.ptr, bytes.len, 0, null, null))) {
            .retry => continue,
            .would_block => return .{ .outcome = .wait_read },
            .errno => |errno| return Attempt.failed(errno),
            .value => |count| return Attempt.done(@intCast(count)),
        }
    }
    return Attempt.interrupted;
}

/// One datagram in. The buffer holds the head, the address and the control block in front of the
/// datagram, so the result is the datagram's own bytes and no prefix is subtracted later: the
/// uring backend gets that layout from the kernel and this one writes it (decision 15).
fn attempt_receive_from(loop: *Loop, slot: *const Slot) Attempt {
    const target = target_of(loop, slot) orelse {
        return Attempt.done(core.event.result_of(.buffers_exhausted));
    };
    const answer = datagram.receive_into(slot.descriptor, target.bytes, loop.datagram_group);
    if (!answer.would_block and answer.result >= 0) {
        return .{ .outcome = .done, .result = answer.result, .buffer_id = target.buffer_id };
    }
    release(loop, slot, target);
    if (answer.would_block) return .{ .outcome = .wait_read };
    return Attempt.done(answer.result);
}

/// One datagram out. Unlike the kqueue backend, a segmented send is carried: Linux has
/// `UDP_SEGMENT`, and `linux_shared_datagram.zig` writes it into the control block.
fn attempt_send_to(slot: *const Slot) Attempt {
    const out = slot.outbound();
    const answer = datagram.send_from(slot.descriptor, slot.bytes(), out);
    if (answer.would_block) return .{ .outcome = .wait_write };
    return Attempt.done(answer.result);
}

fn attempt_send(slot: *const Slot) Attempt {
    const bytes = slot.bytes();
    var retry: u32 = 0;
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        // A closed peer answers EPIPE and raises no SIGPIPE, which would end the process.
        const rc = linux.sendto(slot.descriptor, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);
        switch (answer_of(rc)) {
            .retry => continue,
            .would_block => return .{ .outcome = .wait_write },
            .errno => |errno| return Attempt.failed(errno),
            .value => |count| return Attempt.done(@intCast(count)),
        }
    }
    return Attempt.interrupted;
}

fn attempt_shutdown(slot: *const Slot) Attempt {
    const rc = linux.shutdown(slot.descriptor, @intCast(slot.len));
    if (linux.errno(rc) == .SUCCESS) return Attempt.done(0);
    return Attempt.failed(linux.errno(rc));
}

/// A file operation under the `blocking` policy runs inline and blocks the loop for its duration
/// (decisions 2 and 20). Under `refuse` it never runs, and under `offload` a worker runs it through
/// the same `file_call.result`.
fn attempt_file(loop: *const Loop, slot: *const Slot) Attempt {
    if (core.attempt.policy_attempt(loop.file_policy)) |decided| return decided;
    return Attempt.done(file_call.result(core.file_call.request_of_slot(slot)));
}

comptime {
    // `Operation.How` holds the kernel's own values, so a shutdown passes it through.
    assert(@intFromEnum(core.Operation.How.receive) == linux.SHUT.RD);
    assert(@intFromEnum(core.Operation.How.send) == linux.SHUT.WR);
    assert(@intFromEnum(core.Operation.How.both) == linux.SHUT.RDWR);
}

const testing = std.testing;

test "a network error that belongs to the next connection is skipped, not the listener's end" {
    for ([_]linux.E{ .NETDOWN, .PROTO, .NOPROTOOPT, .HOSTDOWN, .NONET }) |errno| {
        try testing.expect(connection_already_gone(errno));
    }
    for ([_]linux.E{ .HOSTUNREACH, .OPNOTSUPP, .NETUNREACH }) |errno| {
        try testing.expect(connection_already_gone(errno));
    }
    // A refusal of the listener's own is the operation's result as the kernel said it.
    for ([_]linux.E{ .MFILE, .NFILE, .NOMEM, .BADF, .INVAL, .CONNABORTED }) |errno| {
        try testing.expect(!connection_already_gone(errno));
    }
}

test "a call's answer tells a retry, a wait and a refusal apart from a count" {
    try testing.expectEqual(Answer{ .value = 7 }, answer_of(7));
    const intr: usize = @bitCast(-@as(isize, @intFromEnum(linux.E.INTR)));
    const again: usize = @bitCast(-@as(isize, @intFromEnum(linux.E.AGAIN)));
    const reset: usize = @bitCast(-@as(isize, @intFromEnum(linux.E.CONNRESET)));
    try testing.expectEqual(Answer.retry, answer_of(intr));
    try testing.expectEqual(Answer.would_block, answer_of(again));
    try testing.expectEqual(Answer{ .errno = .CONNRESET }, answer_of(reset));
}
