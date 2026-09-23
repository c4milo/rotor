//! A file operation's system call on macOS: `pread`, `pwrite`, or for `fdatasync`,
//! `fcntl(F_FULLFSYNC)`. `core.file_call.result` makes the call again after EINTR and maps what it
//! answered. The inline attempt of `kqueue_perform.zig` and the worker of `kqueue_offload.zig` both
//! call `result` here, so the `file_policy` decides which thread makes the call and nothing else
//! (decision 18).
//!
//! fsync(2) on macOS lists EINTR, "Its execution is interrupted by a signal". It also says that
//! when a queued I/O operation fails, fsync may answer any errno of read(2) or write(2), and those
//! include EAGAIN. `core.file_call.result` makes the call again after the first and maps the
//! second.
const std = @import("std");
const posix = std.posix;
const core = @import("core");
const constants = @import("constants.zig");

const Request = core.file_call.Request;
const Answer = core.file_call.Answer(posix.E);

/// The operation's result: a count, or the negation of a `core.Code`.
pub fn result(request: Request) i32 {
    return core.file_call.result(Kernel{}, request, core.constants.interrupt_retries_max);
}

/// The system calls themselves, each made once. A test hands `core.file_call.result` a struct of
/// its own with the same methods, which answers what the kernel will not on demand.
const Kernel = struct {
    pub fn answer(kernel: Kernel, request: Request) Answer {
        const bytes = request.bytes;
        const offset: i64 = @intCast(request.offset);
        return switch (request.code) {
            .read => answer_of(std.c.pread(request.descriptor, bytes.ptr, bytes.len, offset)),
            .write => answer_of(std.c.pwrite(request.descriptor, bytes.ptr, bytes.len, offset)),
            .fdatasync => sync_answer(kernel, request.descriptor),
        };
    }

    pub fn full_sync(_: Kernel, descriptor: core.Descriptor) Answer {
        return answer_of(std.c.fcntl(descriptor, std.c.F.FULLFSYNC, @as(c_int, 0)));
    }

    pub fn plain_sync(_: Kernel, descriptor: core.Descriptor) Answer {
        return answer_of(std.c.fsync(descriptor));
    }
};

fn answer_of(rc: anytype) Answer {
    if (rc >= 0) return .{ .count = @intCast(rc) };
    return .{ .errno = posix.errno(rc) };
}

/// `fdatasync` on macOS. `F_FULLFSYNC` is what makes its promise true: a plain `fsync` leaves the
/// bytes in the drive's cache. A filesystem that refuses `F_FULLFSYNC` gets a plain `fsync`
/// (decision 12, point 5).
///
/// When `F_FULLFSYNC` answers EINTR, this returns EINTR, and `core.file_call.result` makes the call
/// again. A plain `fsync` in its place would end the operation with success and a weaker promise,
/// chosen by when a signal arrived. fcntl(2) lists EINTR only for `F_SETLKW` and `F_OFD_SETLKW`.
/// It also says `F_FULLFSYNC` does what fsync(2) does and then flushes the drive, and fsync(2)
/// lists EINTR, so the manual does not rule EINTR out here. No test on this host can make either
/// call answer it.
fn sync_answer(kernel: anytype, descriptor: core.Descriptor) Answer {
    const full = kernel.full_sync(descriptor);
    switch (full) {
        .count => return full,
        .errno => |errno| if (errno == .INTR) return full,
    }
    return kernel.plain_sync(descriptor);
}

const testing = std.testing;

/// A kernel that answers `F_FULLFSYNC` and `fsync` from lists a test wrote, and counts the calls.
/// It names no macOS call, so these tests also run where the race gate builds this module for
/// Linux.
const Syncs = struct {
    full_answers: []const Answer,
    plain_answers: []const Answer,
    full_made: u32 = 0,
    plain_made: u32 = 0,

    pub fn answer(syncs: *Syncs, request: Request) Answer {
        std.debug.assert(request.code == .fdatasync);
        return sync_answer(syncs, request.descriptor);
    }

    pub fn full_sync(syncs: *Syncs, descriptor: core.Descriptor) Answer {
        _ = descriptor;
        const answered = syncs.full_answers[syncs.full_made];
        syncs.full_made += 1;
        return answered;
    }

    pub fn plain_sync(syncs: *Syncs, descriptor: core.Descriptor) Answer {
        _ = descriptor;
        const answered = syncs.plain_answers[syncs.plain_made];
        syncs.plain_made += 1;
        return answered;
    }

    fn sync(syncs: *Syncs) i32 {
        const request: Request = .{
            .code = .fdatasync,
            .descriptor = 0,
            .bytes = &.{},
            .offset = 0,
        };
        return core.file_call.result(syncs, request, core.constants.interrupt_retries_max);
    }
};

const synced: Answer = .{ .count = 0 };
const interrupted: Answer = .{ .errno = .INTR };
/// A filesystem's refusal of `F_FULLFSYNC`. Decision 12, point 5 records autofs answering EINVAL
/// on a directory, and every host has the tag.
const refused: Answer = .{ .errno = .INVAL };

test "an interrupted F_FULLFSYNC is made again, and a plain fsync never stands in for it" {
    var syncs: Syncs = .{ .full_answers = &.{ interrupted, synced }, .plain_answers = &.{synced} };
    try testing.expectEqual(@as(i32, 0), syncs.sync());
    try testing.expectEqual(@as(u32, 2), syncs.full_made);
    try testing.expectEqual(@as(u32, 0), syncs.plain_made);
}

test "an interrupted plain fsync is made again, after F_FULLFSYNC each time" {
    // The call that failed before 2026-09-23: EINTR reached `code_of` and halted.
    var syncs: Syncs = .{
        .full_answers = &.{ refused, refused },
        .plain_answers = &.{ interrupted, synced },
    };
    try testing.expectEqual(@as(i32, 0), syncs.sync());
    try testing.expectEqual(@as(u32, 2), syncs.full_made);
    try testing.expectEqual(@as(u32, 2), syncs.plain_made);
}

test "a filesystem that refuses F_FULLFSYNC gets a plain fsync, and one that takes it does not" {
    var refusing: Syncs = .{ .full_answers = &.{refused}, .plain_answers = &.{synced} };
    try testing.expectEqual(@as(i32, 0), refusing.sync());
    try testing.expectEqual(@as(u32, 1), refusing.plain_made);

    var taking: Syncs = .{ .full_answers = &.{synced}, .plain_answers = &.{synced} };
    try testing.expectEqual(@as(i32, 0), taking.sync());
    try testing.expectEqual(@as(u32, 0), taking.plain_made);
}

test "a plain fsync's EAGAIN ends the sync with would_block, and its other errnos with their code" {
    const again: Answer = .{ .errno = .AGAIN };
    var blocked: Syncs = .{ .full_answers = &.{refused}, .plain_answers = &.{again} };
    try testing.expectEqual(core.event.result_of(.would_block), blocked.sync());
    try testing.expectEqual(@as(u32, 1), blocked.plain_made);

    var failed: Syncs = .{ .full_answers = &.{refused}, .plain_answers = &.{.{ .errno = .IO }} };
    try testing.expectEqual(core.event.result_of(.input_output), failed.sync());
}
