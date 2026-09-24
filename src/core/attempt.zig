//! What a readiness backend's attempt at an operation comes to. kqueue and epoll make each system
//! call themselves, at flush and again when the descriptor becomes ready (decision 12, point 1, and
//! decision 20). The calls are each backend's own. What a call comes to, the direction an operation
//! waits in, and what the file policy does with a file operation are the same on both, so they are
//! here.
const std = @import("std");
const assert = std.debug.assert;
const errno_module = @import("errno.zig");
const event = @import("event.zig");
const offload = @import("offload.zig");
const operation = @import("operation.zig");
const waiters = @import("waiters.zig");

const Filter = waiters.Filter;

pub const Attempt = struct {
    outcome: Outcome,
    /// The final result when `done`: a count or a descriptor, or the negation of a `Code`.
    result: i32 = 0,
    /// The provided buffer that holds the bytes of a receive from a group.
    buffer_id: ?u16 = null,

    pub const Outcome = enum { done, wait_read, wait_write, offloaded };

    /// The operation is the caller's offload's now, and its result arrives on a worker's ring
    /// (decision 18). Only a file operation under the `offload` policy answers this, and only from
    /// the flush: a file needs no readiness, so nothing here is reached from the reap.
    pub const handed_out: Attempt = .{ .outcome = .offloaded };

    /// What a call that a signal interrupted every time the bound allows comes to: nothing moved,
    /// and only a signal storm gets here.
    pub const interrupted: Attempt = .{ .outcome = .done, .result = event.result_of(.would_block) };

    pub fn done(result: i32) Attempt {
        return .{ .outcome = .done, .result = result };
    }

    /// The operation's result for an errno of the backend's own errno type.
    pub fn failed(errno: anytype) Attempt {
        return done(event.result_of(errno_module.code_of(errno)));
    }

    /// The direction an attempt that must wait asks for.
    pub fn filter(attempt: Attempt) Filter {
        assert(attempt.outcome == .wait_read or attempt.outcome == .wait_write);
        return if (attempt.outcome == .wait_read) .read else .write;
    }
};

/// The direction an operation of this kind waits on when it cannot complete at once.
pub fn filter_of(code: operation.Operation.Code) Filter {
    return switch (code) {
        .accept, .receive, .receive_from => .read,
        .connect, .send, .send_to => .write,
        else => unreachable,
    };
}

/// What a successful attempt took from what the kernel reported ready: one connection for an
/// accept, and the bytes it moved for a transfer. A failure and a connect take nothing. A reap that
/// serves one readiness more than once counts with it (decision 12, point 3).
pub fn used(code: operation.Operation.Code, result: i32) u32 {
    if (result < 0) return 0;
    return switch (code) {
        .accept => 1,
        .receive, .receive_from, .send, .send_to => @intCast(result),
        else => 0,
    };
}

/// What the loop's policy says to do with a file operation (decision 18), or null when it is to be
/// made inline. `refuse` is the default, because a stall nobody asked for is the complaint that
/// record answers.
pub fn policy_attempt(policy: offload.FilePolicy) ?Attempt {
    return switch (policy) {
        .refuse => Attempt.done(event.result_of(.unsupported)),
        .blocking => null,
        .offload => Attempt.handed_out,
    };
}

/// What one socket call answered, with EINTR folded into `retry` and EAGAIN into `would_block`.
/// `E` is the backend's errno type, as in `file_call.Answer`.
pub fn Answer(comptime E: type) type {
    return union(enum) { value: usize, retry, would_block, errno: E };
}

const testing = std.testing;

test "an operation waits on the direction its call would block in" {
    try testing.expectEqual(Filter.read, filter_of(.accept));
    try testing.expectEqual(Filter.read, filter_of(.receive));
    try testing.expectEqual(Filter.read, filter_of(.receive_from));
    try testing.expectEqual(Filter.write, filter_of(.connect));
    try testing.expectEqual(Filter.write, filter_of(.send));
    try testing.expectEqual(Filter.write, filter_of(.send_to));
    const read_wait: Attempt = .{ .outcome = .wait_read };
    const write_wait: Attempt = .{ .outcome = .wait_write };
    try testing.expectEqual(Filter.read, read_wait.filter());
    try testing.expectEqual(Filter.write, write_wait.filter());
}

test "an accept uses one connection, a transfer its bytes, and a failure or a connect nothing" {
    // The descriptor an accept returns is not an amount.
    try testing.expectEqual(@as(u32, 1), used(.accept, 7));
    try testing.expectEqual(@as(u32, 100), used(.receive, 100));
    try testing.expectEqual(@as(u32, 1200), used(.receive_from, 1200));
    try testing.expectEqual(@as(u32, 64), used(.send, 64));
    try testing.expectEqual(@as(u32, 1400), used(.send_to, 1400));
    try testing.expectEqual(@as(u32, 0), used(.send, 0));
    try testing.expectEqual(@as(u32, 0), used(.connect, 0));
    try testing.expectEqual(@as(u32, 0), used(.receive, event.result_of(.connection_reset)));
    try testing.expectEqual(@as(u32, 0), used(.accept, event.result_of(.would_block)));
}

test "the file policy refuses, runs inline, or hands the operation out" {
    try testing.expectEqual(event.result_of(.unsupported), policy_attempt(.refuse).?.result);
    try testing.expectEqual(@as(?Attempt, null), policy_attempt(.blocking));
    try testing.expectEqual(Attempt.Outcome.offloaded, policy_attempt(.offload).?.outcome);
    try testing.expectEqual(event.result_of(.would_block), Attempt.interrupted.result);
}
