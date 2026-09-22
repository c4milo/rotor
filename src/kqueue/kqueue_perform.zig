//! Performing an operation: on kqueue the backend makes each system call itself, at flush and
//! again when the descriptor becomes ready (decision 12, point 1). `attempt` makes the call once
//! and says what came of it: a result, or a filter to wait on because the call would block.
//!
//! EINTR transferred nothing, so the call is made again, a bounded number of times. Every other
//! errno is the operation's result, through `kqueue_errno.code_of`.
//!
//! Everything here enters the kernel, so it is tested under macOS alone, through the loop.
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const core = @import("core");
const datagram = @import("kqueue_datagram.zig");
const constants = @import("constants.zig");
const address_module = @import("kqueue_address.zig");
const buffers_module = @import("kqueue_buffers.zig");
const errno_module = @import("kqueue_errno.zig");
const sync = @import("kqueue_sync.zig");
const socket_calls = @import("kqueue_sync_socket.zig");
const waiters_module = @import("kqueue_waiters.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const Slot = core.Slot;
const Filter = waiters_module.Filter;

pub const Attempt = struct {
    outcome: Outcome,
    /// The final result when `done`: a count or a descriptor, or the negation of a `core.Code`.
    result: i32 = 0,
    /// The provided buffer that holds the bytes of a receive from a group.
    buffer_id: ?u16 = null,

    pub const Outcome = enum { done, wait_read, wait_write, offloaded };

    /// The operation is the caller's offload's now, and its result arrives on a worker's ring
    /// (decision 18). Only a file operation under the `offload` policy answers this, and only from
    /// the flush: a file needs no readiness, so nothing here is reached from the reap.
    const handed_out: Attempt = .{ .outcome = .offloaded };

    fn done(result: i32) Attempt {
        return .{ .outcome = .done, .result = result };
    }

    fn failed(errno: posix.E) Attempt {
        return done(core.event.result_of(errno_module.code_of(errno)));
    }

    /// The filter an attempt that must wait asks for.
    pub fn filter(attempt_result: Attempt) Filter {
        assert(attempt_result.outcome != .done);
        return if (attempt_result.outcome == .wait_read) .read else .write;
    }
};

/// The filter an operation of this kind waits on when it cannot complete at once.
pub fn filter_of(code: core.Operation.Code) Filter {
    return switch (code) {
        .accept, .receive, .receive_from => .read,
        .connect, .send, .send_to => .write,
        else => unreachable,
    };
}

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
        .read => attempt_file(loop, slot, .read),
        .write => attempt_file(loop, slot, .write),
        .fdatasync => attempt_sync(loop, slot),
        .nop => Attempt.done(0),
        .receive_from => attempt_receive_from(loop, slot),
        .send_to => attempt_send_to(slot),
        .close, .timer, .post => unreachable,
    };
}

/// The errno of a call that answered -1, with EINTR folded into `retry`.
const Answer = union(enum) { value: usize, retry, would_block, errno: posix.E };

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
    while (retry <= constants.interrupt_retries_max) : (retry += 1) {
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
    return Attempt.done(core.event.result_of(.would_block));
}

/// A connect has two calls. The first starts it and answers EINPROGRESS. When the socket
/// becomes writable the connect is over, and SO_ERROR says how it ended. `Slot.retries` tells the
/// two apart: it is 0 until the first call has been made.
fn attempt_connect(slot: *Slot) Attempt {
    if (slot.retries != 0) return connect_outcome(slot);
    slot.retries = 1;
    const address: *const core.Address = @ptrFromInt(slot.buffer);
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

fn attempt_receive(loop: *Loop, slot: *Slot) Attempt {
    var buffer_id: ?u16 = null;
    var bytes: []u8 = undefined;
    if (slot.flags.buffer_group) {
        const group = &loop.groups[slot.buffer_index];
        buffer_id = group.take() orelse {
            return Attempt.done(core.event.result_of(.buffers_exhausted));
        };
        bytes = group.bytes_of(buffer_id.?);
    } else {
        bytes = slot.bytes();
    }
    const result = receive_into(slot.descriptor, bytes);
    if (result.outcome == .done and result.result >= 0) {
        return .{ .outcome = .done, .result = result.result, .buffer_id = buffer_id };
    }
    // Nothing was received, so the buffer goes back to its group.
    if (buffer_id) |id| loop.groups[slot.buffer_index].give_back(id);
    return result;
}

fn receive_into(descriptor: core.Descriptor, bytes: []u8) Attempt {
    var retry: u32 = 0;
    while (retry <= constants.interrupt_retries_max) : (retry += 1) {
        switch (answer_of(std.c.recv(descriptor, bytes.ptr, bytes.len, 0))) {
            .retry => continue,
            .would_block => return .{ .outcome = .wait_read },
            .errno => |errno| return Attempt.failed(errno),
            .value => |count| return Attempt.done(@intCast(count)),
        }
    }
    return Attempt.done(core.event.result_of(.would_block));
}

/// One datagram in. The buffer holds the head, the address and the control block in front of the
/// datagram, so the result is the datagram's own bytes and no prefix is subtracted later: the
/// uring backend gets that layout from the kernel and this one writes it (decision 15).
fn attempt_receive_from(loop: *Loop, slot: *Slot) Attempt {
    var buffer_id: ?u16 = null;
    var bytes: []u8 = undefined;
    if (slot.flags.buffer_group) {
        const group = &loop.groups[slot.buffer_index];
        buffer_id = group.take() orelse {
            return Attempt.done(core.event.result_of(.buffers_exhausted));
        };
        bytes = group.bytes_of(buffer_id.?);
    } else {
        bytes = slot.bytes();
    }
    const answer = datagram.receive_into(slot.descriptor, bytes, loop.datagram_group);
    if (answer.would_block) {
        if (buffer_id) |id| loop.groups[slot.buffer_index].give_back(id);
        return .{ .outcome = .wait_read };
    }
    if (answer.result >= 0) {
        return .{ .outcome = .done, .result = answer.result, .buffer_id = buffer_id };
    }
    if (buffer_id) |id| loop.groups[slot.buffer_index].give_back(id);
    return Attempt.done(answer.result);
}

/// One datagram out. A segmented send is refused here: macOS has no `UDP_SEGMENT`.
fn attempt_send_to(slot: *const Slot) Attempt {
    const out: *const core.datagram.Outbound = @ptrFromInt(slot.offset);
    const answer = datagram.send_from(slot.descriptor, slot.bytes(), out);
    if (answer.would_block) return .{ .outcome = .wait_write };
    return Attempt.done(answer.result);
}

fn attempt_send(slot: *const Slot) Attempt {
    const bytes = slot.bytes();
    var retry: u32 = 0;
    while (retry <= constants.interrupt_retries_max) : (retry += 1) {
        // SO_NOSIGPIPE is set on every socket the loop sees, so a closed peer is EPIPE and not a
        // signal (decision 12, point 8).
        switch (answer_of(std.c.send(slot.descriptor, bytes.ptr, bytes.len, 0))) {
            .retry => continue,
            .would_block => return .{ .outcome = .wait_write },
            .errno => |errno| return Attempt.failed(errno),
            .value => |count| return Attempt.done(@intCast(count)),
        }
    }
    return Attempt.done(core.event.result_of(.would_block));
}

fn attempt_shutdown(slot: *const Slot) Attempt {
    const rc = std.c.shutdown(slot.descriptor, @intCast(slot.len));
    if (rc == 0) return Attempt.done(0);
    return Attempt.failed(posix.errno(rc));
}

const Transfer = enum { read, write };

/// What the loop's policy says to do with a file operation (decision 18). `refuse` is the default,
/// because a stall nobody asked for is the complaint that record answers.
fn policy_attempt(loop: *const Loop) ?Attempt {
    return switch (loop.file_policy) {
        .refuse => Attempt.done(core.event.result_of(.unsupported)),
        .blocking => null,
        .offload => Attempt.handed_out,
    };
}

/// A file transfer under the `blocking` policy runs inline and blocks the loop for its duration
/// (decisions 2 and 12). Under `refuse` it never runs, and under `offload` a worker runs it.
fn attempt_file(loop: *const Loop, slot: *const Slot, transfer: Transfer) Attempt {
    if (policy_attempt(loop)) |decided| return decided;
    const bytes = slot.bytes();
    const offset: i64 = @intCast(slot.offset);
    var retry: u32 = 0;
    while (retry <= constants.interrupt_retries_max) : (retry += 1) {
        const rc = switch (transfer) {
            .read => std.c.pread(slot.descriptor, bytes.ptr, bytes.len, offset),
            .write => std.c.pwrite(slot.descriptor, bytes.ptr, bytes.len, offset),
        };
        switch (answer_of(rc)) {
            .retry => continue,
            .would_block => return Attempt.done(core.event.result_of(.would_block)),
            .errno => |errno| return Attempt.failed(errno),
            .value => |count| return Attempt.done(@intCast(count)),
        }
    }
    return Attempt.done(core.event.result_of(.would_block));
}

/// `F_FULLFSYNC` is what makes the promise of `fdatasync` true on macOS: a plain fsync leaves
/// the bytes in the drive's cache. A filesystem that does not know it gets a plain fsync.
fn attempt_sync(loop: *const Loop, slot: *const Slot) Attempt {
    if (policy_attempt(loop)) |decided| return decided;
    const full = std.c.fcntl(slot.descriptor, std.c.F.FULLFSYNC, @as(c_int, 0));
    if (full == 0) return Attempt.done(0);
    const rc = std.c.fsync(slot.descriptor);
    if (rc == 0) return Attempt.done(0);
    return Attempt.failed(posix.errno(rc));
}

comptime {
    // `Operation.How` holds the kernel's own values, so a shutdown passes it through.
    if (@import("builtin").os.tag.isDarwin()) {
        assert(@intFromEnum(core.Operation.How.receive) == std.c.SHUT.RD);
        assert(@intFromEnum(core.Operation.How.send) == std.c.SHUT.WR);
        assert(@intFromEnum(core.Operation.How.both) == std.c.SHUT.RDWR);
    }
}
