//! A file operation's system call on Linux: `pread`, `pwrite`, `fdatasync` or `fsync`.
//! `core.file_call.result` makes the call again after EINTR and maps what it answered. The inline
//! attempt of `epoll_perform.zig` and the worker of `epoll_offload.zig` both call `result` here, so
//! the `file_policy` decides which thread makes the call and nothing else (decision 18).
//!
//! This is `kqueue_file_call.zig` with Linux's calls. Linux has `fdatasync` itself, so there is no
//! `F_FULLFSYNC` and no plain `fsync` to fall back to.
const std = @import("std");
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");

const Request = core.file_call.Request;
const Answer = core.file_call.Answer(linux.E);

/// The operation's result: a count, or the negation of a `core.Code`.
pub fn result(request: Request) i32 {
    return core.file_call.result(Kernel{}, request, core.constants.interrupt_retries_max);
}

/// The system calls themselves, each made once.
const Kernel = struct {
    pub fn answer(_: Kernel, request: Request) Answer {
        return answer_of(call(Calls{}, request));
    }
};

/// Makes the one call `request` names through `calls`, and returns the word it returned. A test
/// hands `calls` of its own to see which call each file operation makes: `fdatasync` and `fsync`
/// promise different things and answer the same way, so no other test can tell them apart.
fn call(calls: anytype, request: Request) usize {
    const bytes = request.bytes;
    const offset: i64 = @intCast(request.offset);
    return switch (request.code) {
        .read => calls.pread(request.descriptor, bytes.ptr, bytes.len, offset),
        .write => calls.pwrite(request.descriptor, bytes.ptr, bytes.len, offset),
        .fdatasync => calls.fdatasync(request.descriptor),
        .fsync => calls.fsync(request.descriptor),
    };
}

/// Linux's calls, as `call` takes them.
const Calls = struct {
    pub fn pread(_: Calls, descriptor: i32, bytes: [*]u8, len: usize, offset: i64) usize {
        return linux.pread(descriptor, bytes, len, offset);
    }
    pub fn pwrite(_: Calls, descriptor: i32, bytes: [*]const u8, len: usize, offset: i64) usize {
        return linux.pwrite(descriptor, bytes, len, offset);
    }
    pub fn fdatasync(_: Calls, descriptor: i32) usize {
        return linux.fdatasync(descriptor);
    }
    pub fn fsync(_: Calls, descriptor: i32) usize {
        return linux.fsync(descriptor);
    }
};

/// A Linux system call returns a count, or the errno negated, in one word.
fn answer_of(rc: usize) Answer {
    const errno = linux.errno(rc);
    if (errno == .SUCCESS) return .{ .count = rc };
    return .{ .errno = errno };
}

const testing = std.testing;

/// Words a test wrote, as a Linux system call returns them, handed to `answer_of` one per call. The
/// test covers the decoding and the loop together, which is the path a kernel's answer takes. The
/// kernel will not produce these errnos on demand (decision 10, point 3).
const Returns = struct {
    words: []const usize,
    made: u32 = 0,

    pub fn answer(returns: *Returns, request: Request) Answer {
        _ = request;
        const word = returns.words[returns.made];
        returns.made += 1;
        return answer_of(word);
    }
};

fn negated(errno: linux.E) usize {
    return @bitCast(-@as(isize, @intFromEnum(errno)));
}

test "an interrupted pread is made again, and one that would block ends with would_block" {
    var bytes: [8]u8 = undefined;
    const request: Request = .{ .code = .read, .descriptor = 0, .bytes = &bytes, .offset = 0 };
    const limit = core.constants.interrupt_retries_max;

    var interrupted: Returns = .{ .words = &.{ negated(.INTR), 4 } };
    try testing.expectEqual(@as(i32, 4), core.file_call.result(&interrupted, request, limit));
    try testing.expectEqual(@as(u32, 2), interrupted.made);

    var blocked: Returns = .{ .words = &.{ negated(.AGAIN), 4 } };
    const would_block = core.event.result_of(.would_block);
    try testing.expectEqual(would_block, core.file_call.result(&blocked, request, limit));
    try testing.expectEqual(@as(u32, 1), blocked.made);
}

/// Calls that record which one was made, and make none.
const Recorded = struct {
    made: ?enum { pread, pwrite, fdatasync, fsync } = null,

    pub fn pread(recorded: *Recorded, _: i32, _: [*]u8, _: usize, _: i64) usize {
        recorded.made = .pread;
        return 0;
    }
    pub fn pwrite(recorded: *Recorded, _: i32, _: [*]const u8, _: usize, _: i64) usize {
        recorded.made = .pwrite;
        return 0;
    }
    pub fn fdatasync(recorded: *Recorded, _: i32) usize {
        recorded.made = .fdatasync;
        return 0;
    }
    pub fn fsync(recorded: *Recorded, _: i32) usize {
        recorded.made = .fsync;
        return 0;
    }
};

test "each file operation makes its own call, and fsync is not fdatasync" {
    var bytes: [4]u8 = undefined;
    const cases = .{
        .{ Request{ .code = .read, .descriptor = 3, .bytes = &bytes, .offset = 0 }, .pread },
        .{ Request{ .code = .write, .descriptor = 3, .bytes = &bytes, .offset = 0 }, .pwrite },
        .{ Request{ .code = .fdatasync, .descriptor = 3, .bytes = &.{}, .offset = 0 }, .fdatasync },
        .{ Request{ .code = .fsync, .descriptor = 3, .bytes = &.{}, .offset = 0 }, .fsync },
    };
    inline for (cases) |case| {
        var recorded: Recorded = .{};
        _ = call(&recorded, case[0]);
        try testing.expectEqual(case[1], recorded.made.?);
    }
}

test "an interrupted fdatasync is made again, and its other errnos end it with their code" {
    const request: Request = .{ .code = .fdatasync, .descriptor = 0, .bytes = &.{}, .offset = 0 };
    const limit = core.constants.interrupt_retries_max;

    var interrupted: Returns = .{ .words = &.{ negated(.INTR), 0 } };
    try testing.expectEqual(@as(i32, 0), core.file_call.result(&interrupted, request, limit));
    try testing.expectEqual(@as(u32, 2), interrupted.made);

    var failed: Returns = .{ .words = &.{negated(.IO)} };
    const input_output = core.event.result_of(.input_output);
    try testing.expectEqual(input_output, core.file_call.result(&failed, request, limit));
}
