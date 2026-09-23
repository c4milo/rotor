//! A file operation's system call on a readiness backend: `read`, `write` or `fdatasync`. The loop
//! thread makes it inline under the `blocking` policy, and one of the caller's workers makes it
//! under `offload` (decision 18). Both paths call `result`, so the policy decides which thread
//! makes the call and nothing else. Until 2026-09-23 each path had its own copy, and the copies
//! differed: kqueue's sync never made its call again after EINTR, and no worker mapped EAGAIN, so
//! either errno reached `errno.code_of`'s assertion and halted the loop or the worker.
//!
//! What a call can answer, and what the operation's result is then:
//!
//! - A count: the bytes transferred, or 0 for a sync. The count is the result.
//! - EINTR: a signal interrupted the call before it transferred anything, so the call is made
//!   again, at most `retries_max` more times. Only a signal storm uses them all, and the operation
//!   then ends with `would_block`.
//! - EAGAIN: the descriptor is non-blocking and the call would have waited. A file operation does
//!   not wait for readiness, so it ends with `would_block`.
//! - Any other errno: its code, through `errno.code_of`.
//!
//! The backend supplies the call, so this file names no kernel type. `kqueue` and `epoll` need the
//! same loop, so it lives here. A test supplies a call of its own that answers errnos the kernel
//! will not produce on demand (decision 10, point 3).
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const errno_module = @import("errno.zig");
const event = @import("event.zig");
const offload = @import("offload.zig");
const operation = @import("operation.zig");
const slot_module = @import("slot.zig");

const Slot = slot_module.Slot;
const Work = offload.Work;

/// The file operations: the ones an offload is handed, because they are the ones that block.
pub const Code = Work.Code;

/// One file operation, as either path hands it to `result`.
pub const Request = struct {
    code: Code,
    descriptor: operation.Descriptor,
    /// The bytes to transfer. Empty for `fdatasync`, and for nothing else.
    bytes: []u8,
    offset: u64,
};

/// What one system call answered: the count it returned, or its errno. `E` is the backend's errno
/// type: `std.posix.E` on kqueue, `std.os.linux.E` on epoll. The two are different types on a
/// macOS build, and every errno named here is a tag of both.
pub fn Answer(comptime E: type) type {
    return union(enum) { count: usize, errno: E };
}

/// Makes the request's system call through `calls` and returns the operation's result: a count,
/// or the negation of a `Code`. `calls.answer(request)` makes the call once and returns an
/// `Answer`. In a backend it is the kernel; in a test it is a list of answers.
pub fn result(calls: anytype, request: Request, comptime retries_max: u32) i32 {
    comptime assert(retries_max >= 1);
    assert((request.code == .fdatasync) == (request.bytes.len == 0));
    var retry: u32 = 0;
    while (retry <= retries_max) : (retry += 1) {
        switch (calls.answer(request)) {
            .count => |count| {
                // A call transfers at most the bytes it was given, which also keeps the count
                // inside an `i32`: a slot's length is at most `transfer_bytes_max`.
                assert(count <= request.bytes.len);
                return @intCast(count);
            },
            .errno => |errno| {
                if (errno == .INTR) continue;
                if (errno == .AGAIN) return event.result_of(.would_block);
                return event.result_of(errno_module.code_of(errno));
            },
        }
    }
    return event.result_of(.would_block);
}

/// The request of a slot that holds a file operation, built on the loop thread.
pub fn request_of_slot(slot: *const Slot) Request {
    const code: Code = offload.code_of(slot.code).?;
    // A sync's slot holds no buffer, so `bytes` would fail its own check.
    const bytes: []u8 = if (code == .fdatasync) &.{} else slot.bytes();
    return .{ .code = code, .descriptor = slot.descriptor, .bytes = bytes, .offset = slot.offset };
}

/// The request of a handed-out operation, built on the worker's thread from what the loop copied
/// out of the slot. It reads no slot.
pub fn request_of_work(work: *const Work) Request {
    var request: Request = .{
        .code = work.code,
        .descriptor = work.descriptor,
        .bytes = &.{},
        .offset = work.offset,
    };
    if (work.code != .fdatasync) {
        const buffer: [*]u8 = @ptrFromInt(work.buffer);
        request.bytes = buffer[0..work.length];
    }
    return request;
}

const testing = std.testing;

/// The bound the tests pass. Small, so a test can list every answer up to it and one past it.
const test_retries_max = 3;

/// A call that answers from a list a test wrote, and counts the times it was made.
fn Script(comptime E: type) type {
    return struct {
        answers: []const Answer(E),
        made: u32 = 0,

        pub fn answer(script: *@This(), request: Request) Answer(E) {
            _ = request;
            const answered = script.answers[script.made];
            script.made += 1;
            return answered;
        }
    };
}

const PosixScript = Script(std.posix.E);
const intr: Answer(std.posix.E) = .{ .errno = .INTR };

/// The descriptor a test's request names. The script never passes it to a kernel.
const test_descriptor = 3;
const test_bytes_len = 8;
var test_bytes: [test_bytes_len]u8 = undefined;

fn read_request() Request {
    return .{ .code = .read, .descriptor = test_descriptor, .bytes = &test_bytes, .offset = 0 };
}

test "a call a signal interrupted is made again, and its count is the result" {
    var script: PosixScript = .{ .answers = &.{ intr, intr, .{ .count = 5 } } };
    try testing.expectEqual(@as(i32, 5), result(&script, read_request(), test_retries_max));
    try testing.expectEqual(@as(u32, 3), script.made);
}

test "the last call the bound allows still counts" {
    // `test_retries_max` interruptions, then the count: the call is made once more than the bound.
    var script: PosixScript = .{ .answers = &.{ intr, intr, intr, .{ .count = 5 } } };
    try testing.expectEqual(@as(i32, 5), result(&script, read_request(), test_retries_max));
    try testing.expectEqual(@as(u32, test_retries_max + 1), script.made);
}

test "a call interrupted past the bound ends with would_block, and is not made again" {
    // The list holds a count after the last interruption the bound allows, so a loop that ran one
    // call too far would return it rather than read past the list.
    var script: PosixScript = .{ .answers = &.{ intr, intr, intr, intr, .{ .count = 5 } } };
    const would_block = event.result_of(.would_block);
    try testing.expectEqual(would_block, result(&script, read_request(), test_retries_max));
    try testing.expectEqual(@as(u32, test_retries_max + 1), script.made);
}

test "EAGAIN ends a file operation with would_block, and the call is not made again" {
    var script: PosixScript = .{ .answers = &.{ .{ .errno = .AGAIN }, .{ .count = 5 } } };
    const would_block = event.result_of(.would_block);
    try testing.expectEqual(would_block, result(&script, read_request(), test_retries_max));
    try testing.expectEqual(@as(u32, 1), script.made);
}

test "any other errno ends the operation with its code, after one call" {
    const Row = struct { errno: std.posix.E, code: event.Code };
    const rows = [_]Row{
        .{ .errno = .NOSPC, .code = .no_space_left },
        .{ .errno = .IO, .code = .input_output },
        .{ .errno = .BADF, .code = .unexpected },
    };
    for (rows) |row| {
        var script: PosixScript = .{ .answers = &.{.{ .errno = row.errno }} };
        const expected = event.result_of(row.code);
        try testing.expectEqual(expected, result(&script, read_request(), test_retries_max));
        try testing.expectEqual(@as(u32, 1), script.made);
    }
}

test "a sync a signal interrupted is made again, and ends with 0" {
    var script: PosixScript = .{ .answers = &.{ intr, .{ .count = 0 } } };
    const request: Request = .{
        .code = .fdatasync,
        .descriptor = test_descriptor,
        .bytes = &.{},
        .offset = 0,
    };
    try testing.expectEqual(@as(i32, 0), result(&script, request, test_retries_max));
    try testing.expectEqual(@as(u32, 2), script.made);
}

test "the loop reads a Linux errno on a macOS build, which is what the epoll backend hands it" {
    const LinuxScript = Script(std.os.linux.E);
    var interrupted: LinuxScript = .{ .answers = &.{ .{ .errno = .INTR }, .{ .count = 5 } } };
    try testing.expectEqual(@as(i32, 5), result(&interrupted, read_request(), test_retries_max));
    var blocked: LinuxScript = .{ .answers = &.{.{ .errno = .AGAIN }} };
    const would_block = event.result_of(.would_block);
    try testing.expectEqual(would_block, result(&blocked, read_request(), test_retries_max));
    var full: LinuxScript = .{ .answers = &.{.{ .errno = .NOSPC }} };
    const no_space = event.result_of(.no_space_left);
    try testing.expectEqual(no_space, result(&full, read_request(), test_retries_max));
}

test "a slot's request carries its buffer, and a sync's carries none" {
    var slot: Slot = std.mem.zeroes(Slot);
    slot.state = .queued;
    slot.generation = constants.generation_first;
    slot.fill(&.{ .user_data = 1, .kind = .{ .write = .{
        .file = 6,
        .buffer = .{ .bytes = &test_bytes },
        .offset = 4096,
    } } });
    const write = request_of_slot(&slot);
    try testing.expectEqual(Code.write, write.code);
    try testing.expectEqual(@as(operation.Descriptor, 6), write.descriptor);
    try testing.expectEqual(@as(usize, @intFromPtr(&test_bytes)), @intFromPtr(write.bytes.ptr));
    try testing.expectEqual(test_bytes.len, write.bytes.len);
    try testing.expectEqual(@as(u64, 4096), write.offset);

    slot.fill(&.{ .user_data = 2, .kind = .{ .fdatasync = .{ .file = 7 } } });
    const sync = request_of_slot(&slot);
    try testing.expectEqual(Code.fdatasync, sync.code);
    try testing.expectEqual(@as(operation.Descriptor, 7), sync.descriptor);
    try testing.expectEqual(@as(usize, 0), sync.bytes.len);
}

test "a work's request carries the bytes the loop copied, and a sync's carries none" {
    const read: Work = .{
        .run = undefined,
        .owner = undefined,
        .index = 0,
        .code = .read,
        .descriptor = 6,
        .buffer = @intFromPtr(&test_bytes),
        .length = test_bytes.len,
        .offset = 512,
    };
    const request = request_of_work(&read);
    try testing.expectEqual(Code.read, request.code);
    try testing.expectEqual(@as(usize, @intFromPtr(&test_bytes)), @intFromPtr(request.bytes.ptr));
    try testing.expectEqual(test_bytes.len, request.bytes.len);
    try testing.expectEqual(@as(u64, 512), request.offset);

    // A sync's buffer is never turned into a pointer, so an address of 0 is not read.
    var sync = read;
    sync.code = .fdatasync;
    sync.buffer = 0;
    sync.length = 0;
    try testing.expectEqual(@as(usize, 0), request_of_work(&sync).bytes.len);
}
