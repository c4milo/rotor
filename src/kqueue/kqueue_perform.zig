//! Performing an operation: on kqueue the backend makes each system call itself, at flush and
//! again when the descriptor becomes ready (decision 12, point 1). `attempt` makes the call once
//! and says what came of it: a result, or a filter to wait on because the call would block.
//!
//! EINTR transferred nothing, so the call is made again, a bounded number of times. Every other
//! errno is the operation's result, through `core.errno.code_of`. A file operation's call is
//! `kqueue_file_call.zig`'s, which the offload's worker makes too.
//!
//! Everything here enters the kernel, so it is tested under macOS alone, through the loop.
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const core = @import("core");
const datagram = @import("kqueue_datagram.zig");
const constants = @import("constants.zig");
const file_call = @import("kqueue_file_call.zig");
const address_module = @import("kqueue_address.zig");
const sync = @import("kqueue_sync.zig");
const socket_calls = @import("kqueue_sync_socket.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
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
const Answer = core.attempt.Answer(posix.E);

fn answer_of(rc: anytype) Answer {
    if (rc >= 0) return .{ .value = @intCast(rc) };
    return switch (posix.errno(rc)) {
        .INTR => .retry,
        .AGAIN => .would_block,
        else => |errno| .{ .errno = errno },
    };
}

fn attempt_accept(slot: *Slot) Attempt {
    var retry: u32 = 0;
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        switch (answer_of(std.c.accept(slot.descriptor, null, null))) {
            .retry => continue,
            .would_block => return .{ .outcome = .wait_read },
            .errno => |errno| return Attempt.failed(errno),
            .value => |accepted| {
                const descriptor: core.Descriptor = @intCast(accepted);
                // An accepted socket does not inherit what the loop needs of it (decision 12,
                // point 8).
                socket_calls.prepare_accepted(descriptor) catch {
                    sync.close_now(descriptor);
                    return Attempt.done(core.event.result_of(.unexpected));
                };
                return Attempt.done(descriptor);
            },
        }
    }
    return Attempt.interrupted;
}

/// A connect has two calls. The first starts it and answers EINPROGRESS. When the socket
/// becomes writable the connect is over, and SO_ERROR says how it ended. `Slot.retries` tells the
/// two apart: it is 0 until the first call has been made.
fn attempt_connect(slot: *Slot) Attempt {
    if (slot.retries != 0) return connect_outcome(slot);
    slot.retries = 1;
    const address = slot.address();
    var storage: address_module.Storage = undefined;
    const len = address_module.to_kernel(address, &storage);
    const rc = std.c.connect(slot.descriptor, @ptrCast(&storage), len);
    if (rc == 0) return Attempt.done(0);
    return switch (posix.errno(rc)) {
        // A signal does not stop a connect that has started: it goes on, as EINPROGRESS says.
        .INPROGRESS, .INTR => .{ .outcome = .wait_write },
        .ISCONN => Attempt.done(0),
        else => |errno| Attempt.failed(errno),
    };
}

fn connect_outcome(slot: *const Slot) Attempt {
    var pending: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);
    const rc = std.c.getsockopt(slot.descriptor, posix.SOL.SOCKET, posix.SO.ERROR, &pending, &len);
    if (rc != 0) return Attempt.failed(posix.errno(rc));
    if (pending == 0) return Attempt.done(0);
    const errno: posix.E = @enumFromInt(@as(u16, @intCast(pending)));
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

/// Gives a group's buffer back when nothing was received into it: the call failed, would block,
/// or met the end of the stream. io_uring answers the end of a stream without a buffer too.
fn release(loop: *Loop, slot: *const Slot, target: Target) void {
    if (target.buffer_id) |id| loop.groups[slot.buffer_index].give_back(id);
}

fn attempt_receive(loop: *Loop, slot: *Slot) Attempt {
    const target = target_of(loop, slot) orelse {
        return Attempt.done(core.event.result_of(.buffers_exhausted));
    };
    const result = receive_into(slot.descriptor, target.bytes);
    if (result.outcome == .done and result.result > 0) {
        return .{ .outcome = .done, .result = result.result, .buffer_id = target.buffer_id };
    }
    release(loop, slot, target);
    return result;
}

fn receive_into(descriptor: core.Descriptor, bytes: []u8) Attempt {
    var retry: u32 = 0;
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        switch (answer_of(std.c.recv(descriptor, bytes.ptr, bytes.len, 0))) {
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
fn attempt_receive_from(loop: *Loop, slot: *Slot) Attempt {
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

/// One datagram out. A segmented send is refused here: macOS has no `UDP_SEGMENT`.
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
        // SO_NOSIGPIPE is set on every socket the loop sees, so a closed peer is EPIPE and not a
        // signal (decision 12, point 8).
        switch (answer_of(std.c.send(slot.descriptor, bytes.ptr, bytes.len, 0))) {
            .retry => continue,
            .would_block => return .{ .outcome = .wait_write },
            .errno => |errno| return Attempt.failed(errno),
            .value => |count| return Attempt.done(@intCast(count)),
        }
    }
    return Attempt.interrupted;
}

fn attempt_shutdown(slot: *const Slot) Attempt {
    const rc = std.c.shutdown(slot.descriptor, @intCast(slot.len));
    if (rc == 0) return Attempt.done(0);
    return Attempt.failed(posix.errno(rc));
}

/// A file operation under the `blocking` policy runs inline and blocks the loop for its duration
/// (decisions 2 and 12). Under `refuse` it never runs, and under `offload` a worker runs it through
/// the same `file_call.result`.
fn attempt_file(loop: *const Loop, slot: *const Slot) Attempt {
    if (core.attempt.policy_attempt(loop.file_policy)) |decided| return decided;
    return Attempt.done(file_call.result(core.file_call.request_of_slot(slot)));
}

comptime {
    // `Operation.How` holds the kernel's own values, so a shutdown passes it through.
    if (@import("builtin").os.tag.isDarwin()) {
        assert(@intFromEnum(core.Operation.How.receive) == std.c.SHUT.RD);
        assert(@intFromEnum(core.Operation.How.send) == std.c.SHUT.WR);
        assert(@intFromEnum(core.Operation.How.both) == std.c.SHUT.RDWR);
    }
}
