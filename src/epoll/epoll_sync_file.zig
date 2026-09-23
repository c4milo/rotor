//! The synchronous file calls of decision 2: a file opened with O_DIRECT, measured, preallocated,
//! and a directory synced. They run at start-up, never per transfer, so they are plain: one raw
//! syscall at a time, every return value checked, every errno mapped to a named error, with
//! `Unexpected` for the rest.
//!
//! Each map is a function of the errno alone, so a test on any host covers the refusals the kernel
//! will not produce on demand (decision 10, point 3). Every other test runs under Linux alone.
//!
//! This is `src/uring/uring_sync_file.zig`, copied: a file opens, sizes and syncs the same way
//! whichever Linux backend reads it afterwards, and O_NONBLOCK means nothing for a regular file.
//! The graph has no module the two Linux backends share (`epoll_address.zig` says why).
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const socket_calls = @import("epoll_sync_socket.zig");

const Descriptor = core.Descriptor;
const close_now = socket_calls.close_now;
const descriptor_of = socket_calls.descriptor_of;

/// The permission bits of a file `open_file` creates: its owner reads and writes it, everyone
/// else reads it. The process's umask narrows them.
const file_mode: linux.mode_t = 0o644;

/// `open(2)` refused. `DirectIoUnsupported`: the filesystem does not carry O_DIRECT.
pub const OpenError = error{
    FileNotFound,
    PathAlreadyExists,
    AccessDenied,
    DirectIoUnsupported,
    Unexpected,
};

/// `NoSpaceLeft`: the disk refused to reserve the file's extents. `Unsupported`: the filesystem,
/// or this kind of file, has no `fallocate(2)`.
pub const FileSizeError = error{ NoSpaceLeft, Unsupported, Unexpected };

/// The directory's `open(2)` refused, or its `fsync(2)` did, which is `Unexpected`.
pub const SyncDirectoryError = error{ FileNotFound, AccessDenied, NotDirectory, Unexpected };

pub const OpenOptions = struct {
    /// Create the file, refusing a path that exists.
    create: bool,
    /// O_DIRECT: transfers bypass the page cache, and every buffer, offset and length must be
    /// aligned to the device's logical block (decision 6).
    direct: bool,
};

/// O_RDWR and O_CLOEXEC; O_DIRECT when `direct` (EINVAL then means error.DirectIoUnsupported);
/// O_CREAT and O_EXCL when `create`. Never O_DSYNC: durability is an explicit fdatasync.
pub fn open_file(path: [*:0]const u8, options: OpenOptions) OpenError!Descriptor {
    assert(path[0] != 0);
    const flags: linux.O = .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
        .DIRECT = options.direct,
        .CREAT = options.create,
        .EXCL = options.create,
    };
    const rc = linux.openat(linux.AT.FDCWD, path, flags, file_mode);
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) return open_error(errno, options.direct);
    return descriptor_of(rc);
}

/// The file's size in bytes, by statx.
pub fn file_size(descriptor: Descriptor) FileSizeError!u64 {
    assert(descriptor >= 0);
    var stat = std.mem.zeroes(linux.Statx);
    const rc = linux.statx(descriptor, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stat);
    if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
    // The size is one of the basic fields, which the kernel fills for every filesystem.
    assert(stat.mask.SIZE);
    return stat.size;
}

/// fallocate from 0 to `size` in mode 0: the extents are reserved and read as zeros, so a later
/// write into them cannot fail for lack of space and allocates nothing. ftruncate would leave a
/// sparse file instead: the first write to each block would claim its space, so a full disk would
/// surface inside a write, and every fdatasync would commit an extent conversion. It never
/// shrinks a file: one already longer than `size` keeps its length.
pub fn set_file_size(descriptor: Descriptor, size: u64) FileSizeError!void {
    assert(descriptor >= 0);
    assert(size >= 1);
    assert(size <= std.math.maxInt(i64));
    const rc = linux.fallocate(descriptor, 0, 0, @intCast(size));
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) return file_size_error(errno);
}

/// Opens the directory, fsyncs it, closes it: a file created and synced is not findable after a
/// power loss until its directory is synced too.
pub fn sync_directory(path: [*:0]const u8) SyncDirectoryError!void {
    assert(path[0] != 0);
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const rc = linux.openat(linux.AT.FDCWD, path, flags, 0);
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) return directory_open_error(errno);
    const directory = descriptor_of(rc);
    defer close_now(directory);
    if (linux.errno(linux.fsync(directory)) != .SUCCESS) return error.Unexpected;
}

fn open_error(errno: linux.E, direct: bool) OpenError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .ACCES, .PERM => error.AccessDenied,
        // open(2) answers EINVAL for O_DIRECT on a filesystem that does not carry it.
        .INVAL => if (direct) error.DirectIoUnsupported else error.Unexpected,
        else => error.Unexpected,
    };
}

/// The errno of a `fallocate(2)`.
fn file_size_error(errno: linux.E) FileSizeError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .NOSPC, .DQUOT => error.NoSpaceLeft,
        .OPNOTSUPP, .NOSYS => error.Unsupported,
        else => error.Unexpected,
    };
}

fn directory_open_error(errno: linux.E) SyncDirectoryError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOTDIR => error.NotDirectory,
        else => error.Unexpected,
    };
}

const testing = std.testing;
const E = linux.E;

test "every file errno maps to its named error, any other to Unexpected, on every host" {
    for ([_]struct { E, FileSizeError }{
        .{ .NOSPC, error.NoSpaceLeft }, .{ .DQUOT, error.NoSpaceLeft },
        .{ .NOSYS, error.Unsupported }, .{ .OPNOTSUPP, error.Unsupported },
        .{ .BADF, error.Unexpected },
    }) |case| try testing.expectEqual(case[1], file_size_error(case[0]));
    for ([_]struct { E, SyncDirectoryError }{
        .{ .NOENT, error.FileNotFound }, .{ .ACCES, error.AccessDenied },
        .{ .PERM, error.AccessDenied },  .{ .NOTDIR, error.NotDirectory },
        .{ .MFILE, error.Unexpected },
    }) |case| try testing.expectEqual(case[1], directory_open_error(case[0]));
    for ([_]struct { E, OpenError }{
        .{ .NOENT, error.FileNotFound }, .{ .EXIST, error.PathAlreadyExists },
        .{ .ACCES, error.AccessDenied }, .{ .PERM, error.AccessDenied },
        .{ .ISDIR, error.Unexpected },
    }) |case| {
        try testing.expectEqual(case[1], open_error(case[0], false));
        try testing.expectEqual(case[1], open_error(case[0], true));
    }
    // open(2)'s EINVAL names O_DIRECT only when the caller asked for it.
    try testing.expectEqual(@as(OpenError, error.DirectIoUnsupported), open_error(.INVAL, true));
    try testing.expectEqual(@as(OpenError, error.Unexpected), open_error(.INVAL, false));
}

/// Bytes a test's path may take: the directory, the test's name, the process id, the terminator.
const test_path_bytes_max = 96;

/// A path no other test and no other run uses, removed first in case a crashed run left it.
fn test_path(buffer: *[test_path_bytes_max]u8, comptime name: []const u8) ![:0]const u8 {
    const format = "/tmp/rotor_sync_" ++ name ++ "_{d}";
    const path = try std.fmt.bufPrintZ(buffer, format, .{linux.getpid()});
    _ = linux.unlink(path.ptr);
    return path;
}

fn remove(path: [:0]const u8) void {
    assert(linux.errno(linux.unlink(path.ptr)) == .SUCCESS);
}

/// The descriptor's open flags, after checking that the descriptor closes on exec.
fn open_flags(descriptor: Descriptor) !linux.O {
    const descriptor_flags = linux.fcntl(descriptor, linux.F.GETFD, 0);
    try testing.expectEqual(E.SUCCESS, linux.errno(descriptor_flags));
    try testing.expect(descriptor_flags & linux.FD_CLOEXEC != 0);
    const rc = linux.fcntl(descriptor, linux.F.GETFL, 0);
    try testing.expectEqual(E.SUCCESS, linux.errno(rc));
    return @bitCast(@as(u32, @intCast(rc)));
}

/// The kernel hands out the lowest free descriptor, so two probes with no descriptor opened and
/// left open between them get one number.
fn probe_descriptor() !Descriptor {
    const probe = try socket_calls.open_socket(.ipv4);
    close_now(probe);
    return probe;
}

const existing: OpenOptions = .{ .create = false, .direct = false };
const creating: OpenOptions = .{ .create = true, .direct = false };

test "open_file creates once, reopens what exists and refuses what is missing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var buffer: [test_path_bytes_max]u8 = undefined;
    const path = try test_path(&buffer, "open");
    try testing.expectError(error.FileNotFound, open_file(path, existing));
    const created = try open_file(path, creating);
    defer close_now(created);
    defer remove(path);
    try testing.expectError(error.PathAlreadyExists, open_file(path, creating));
    const flags = try open_flags(created);
    try testing.expect(flags.ACCMODE == .RDWR);
    try testing.expect(!flags.DIRECT and !flags.DSYNC and !flags.SYNC);
    const direct: OpenOptions = .{ .create = false, .direct = true };
    const reopened = try open_file(path, direct);
    defer close_now(reopened);
    try testing.expect((try open_flags(reopened)).DIRECT);
    // procfs carries no O_DIRECT: the same file opens without it and is refused with it.
    close_now(try open_file("/proc/self/comm", existing));
    try testing.expectError(error.DirectIoUnsupported, open_file("/proc/self/comm", direct));
}

test "set_file_size reserves what file_size then reports, and never shrinks" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var buffer: [test_path_bytes_max]u8 = undefined;
    const path = try test_path(&buffer, "size");
    const file = try open_file(path, creating);
    defer remove(path);
    try testing.expectEqual(@as(u64, 0), try file_size(file));
    try set_file_size(file, 65536);
    try testing.expectEqual(@as(u64, 65536), try file_size(file));
    // Reserved, not sparse: the blocks are the file's already. ftruncate would leave none.
    var stat = std.mem.zeroes(linux.Statx);
    const rc = linux.statx(file, "", linux.AT.EMPTY_PATH, .{ .BLOCKS = true, .MODE = true }, &stat);
    try testing.expectEqual(E.SUCCESS, linux.errno(rc));
    try testing.expect(stat.mask.BLOCKS and stat.blocks * 512 >= 65536);
    // The owner reads and writes the file, whatever the umask took from everyone else.
    try testing.expect(stat.mask.MODE and stat.mode & 0o700 == 0o600);
    try set_file_size(file, 4096);
    try testing.expectEqual(@as(u64, 65536), try file_size(file));
    // A closed descriptor and a procfs file: each call reads the kernel's answer.
    close_now(file);
    try testing.expectError(error.Unexpected, file_size(file));
    const proc_file = try open_file("/proc/self/comm", existing);
    defer close_now(proc_file);
    try testing.expectError(error.Unsupported, set_file_size(proc_file, 4096));
}

test "sync_directory syncs a directory and refuses a missing path, a file and procfs" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var buffer: [test_path_bytes_max]u8 = undefined;
    const path = try test_path(&buffer, "directory");
    try testing.expectError(error.FileNotFound, sync_directory(path));
    const file = try open_file(path, creating);
    defer close_now(file);
    defer remove(path);
    try testing.expectError(error.NotDirectory, sync_directory(path));
    // Both paths close the directory again. procfs has no fsync for a directory, so its refusal
    // shows that the fsync is issued and that its answer is read.
    const probe_before = try probe_descriptor();
    try sync_directory("/tmp");
    try testing.expectError(error.Unexpected, sync_directory("/proc"));
    try testing.expectEqual(probe_before, try probe_descriptor());
}
