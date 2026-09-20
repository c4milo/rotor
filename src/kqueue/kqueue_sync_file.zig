//! The file half of `kqueue_sync.zig`: a file opened, measured and preallocated, and a directory
//! synced. macOS has no O_DIRECT and no `fallocate(2)`: `open_file` sets F_NOCACHE after it
//! opens, and `set_file_size` reserves blocks with F_PREALLOCATE and then sets the length
//! (decision 2, "The correction: files on macOS"; decision 12, point 5).
//!
//! Each errno map is a function of the errno alone, so its test runs on every host. Every other
//! test enters the kernel and runs under macOS alone.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const core = @import("core");
const close_now = @import("kqueue_sync_socket.zig").close_now;

const Descriptor = core.Descriptor;
const E = posix.E;

/// The permission bits of a file `open_file` creates: its owner reads and writes it, everyone
/// else reads it. The process's umask narrows them.
const file_mode: c_uint = 0o644;

/// `fstore_t` of <sys/fcntl.h>, which `std.c` does not carry: what F_PREALLOCATE reads, and
/// where it writes how many bytes it reserved.
const Fstore = extern struct {
    flags: c_uint,
    position_mode: c_int,
    offset: c.off_t,
    length: c.off_t,
    bytes_allocated: c.off_t,
};

/// F_ALLOCATECONTIG: reserve one contiguous run of blocks.
const allocate_contiguous: c_uint = 0x2;
/// F_ALLOCATEALL: reserve every byte asked for, or none.
const allocate_all: c_uint = 0x4;
/// F_PEOFPOSMODE: reserve from the physical end of the file, which takes an offset of 0.
const from_physical_end: c_int = 3;

/// `open(2)` refused, or `fcntl(F_NOCACHE)` did, which is `DirectIoUnsupported`. The kernel
/// keeps F_NOCACHE as a flag of the open file and asks no filesystem, so it refuses only a path
/// that opens something that is no file, as `/dev/fd/N` does when descriptor N is a socket.
pub const OpenError = error{
    FileNotFound,
    PathAlreadyExists,
    AccessDenied,
    DirectIoUnsupported,
    Unexpected,
};

/// `NoSpaceLeft`: the disk refused to reserve the file's blocks. `Unsupported`: the filesystem,
/// or this kind of file, has no F_PREALLOCATE.
pub const FileSizeError = error{ NoSpaceLeft, Unsupported, Unexpected };

/// The directory's `open(2)` refused, or its `fsync(2)` did, which is `Unexpected`.
pub const SyncDirectoryError = error{ FileNotFound, AccessDenied, NotDirectory, Unexpected };

pub const OpenOptions = struct {
    /// Create the file, refusing a path that exists.
    create: bool,
    /// F_NOCACHE, the nearest macOS has to O_DIRECT: transfers bypass the buffer cache when
    /// every buffer, offset and length is aligned to the device's logical block (decision 6),
    /// and the kernel copies through the cache when one is not.
    direct: bool,
};

/// O_RDWR and O_CLOEXEC; O_CREAT and O_EXCL when `create`; then fcntl(F_NOCACHE) when `direct`,
/// closing the file again if that is refused. Never O_DSYNC: durability is an explicit fdatasync.
pub fn open_file(path: [*:0]const u8, options: OpenOptions) OpenError!Descriptor {
    assert(path[0] != 0);
    const flags: c.O = .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
        .CREAT = options.create,
        .EXCL = options.create,
    };
    const rc = c.open(path, flags, file_mode);
    const errno = posix.errno(rc);
    if (errno != .SUCCESS) return open_error(errno);
    assert(rc >= 0);
    errdefer close_now(rc);
    if (options.direct) try set_no_cache(rc);
    return rc;
}

/// The file's size in bytes, by fstat.
pub fn file_size(descriptor: Descriptor) FileSizeError!u64 {
    assert(descriptor >= 0);
    var stat = std.mem.zeroes(c.Stat);
    if (posix.errno(c.fstat(descriptor, &stat)) != .SUCCESS) return error.Unexpected;
    assert(stat.size >= 0);
    return @intCast(stat.size);
}

/// Reserves the blocks from the file's length to `size` with F_PREALLOCATE, then sets the length
/// with ftruncate, because F_PREALLOCATE reserves blocks and leaves the length as it was. The
/// new bytes read as zeros, and a later write into them cannot fail for lack of space. ftruncate
/// alone would leave a sparse file, whose first write to each block claims its space. It never
/// shrinks a file: one already as long as `size` is left as it is, its blocks included.
pub fn set_file_size(descriptor: Descriptor, size: u64) FileSizeError!void {
    assert(descriptor >= 0);
    assert(size >= 1);
    assert(size <= std.math.maxInt(c.off_t));
    const size_now = try file_size(descriptor);
    if (size <= size_now) return;
    try preallocate(descriptor, size - size_now);
    const errno = posix.errno(c.ftruncate(descriptor, @intCast(size)));
    if (errno != .SUCCESS) return file_size_error(errno);
}

/// Opens the directory, fsyncs it, closes it: a file created and synced is not findable after a
/// power loss until its directory is synced too. The sync is a plain fsync, because some
/// filesystems refuse F_FULLFSYNC on a directory descriptor: measured on Darwin 25.6, devfs
/// answers ENOTSUP and autofs EINVAL. The loop's `fdatasync` operation is what issues
/// F_FULLFSYNC, on a file (decision 12, point 5).
pub fn sync_directory(path: [*:0]const u8) SyncDirectoryError!void {
    assert(path[0] != 0);
    const flags: c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const rc = c.open(path, flags);
    const errno = posix.errno(rc);
    if (errno != .SUCCESS) return directory_open_error(errno);
    assert(rc >= 0);
    defer close_now(rc);
    if (posix.errno(c.fsync(rc)) != .SUCCESS) return error.Unexpected;
}

/// fcntl(F_NOCACHE, 1). The kernel refuses it for a descriptor that is not a file, with EBADF.
fn set_no_cache(file: Descriptor) error{DirectIoUnsupported}!void {
    assert(file >= 0);
    const rc = c.fcntl(file, c.F.NOCACHE, @as(c_int, 1));
    if (posix.errno(rc) != .SUCCESS) return error.DirectIoUnsupported;
}

/// Reserves `bytes` beyond the blocks the file has: as one contiguous run when the disk has
/// one, and as any blocks when it does not, as is conventional. Either way all of them or none.
fn preallocate(descriptor: Descriptor, bytes: u64) FileSizeError!void {
    assert(descriptor >= 0);
    assert(bytes >= 1);
    assert(bytes <= std.math.maxInt(c.off_t));
    var store: Fstore = .{
        .flags = allocate_contiguous | allocate_all,
        .position_mode = from_physical_end,
        .offset = 0,
        .length = @intCast(bytes),
        .bytes_allocated = 0,
    };
    if (posix.errno(c.fcntl(descriptor, c.F.PREALLOCATE, &store)) == .SUCCESS) return;
    store.flags = allocate_all;
    const errno = posix.errno(c.fcntl(descriptor, c.F.PREALLOCATE, &store));
    if (errno != .SUCCESS) return file_size_error(errno);
}

fn open_error(errno: E) OpenError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .ACCES, .PERM => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// The errno of a `fcntl(F_PREALLOCATE)` or of an `ftruncate(2)`. macOS answers ENOTSUP for a
/// file with no F_PREALLOCATE, which `std.c` spells OPNOTSUPP.
fn file_size_error(errno: E) FileSizeError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .NOSPC, .DQUOT => error.NoSpaceLeft,
        .OPNOTSUPP, .NOSYS => error.Unsupported,
        else => error.Unexpected,
    };
}

fn directory_open_error(errno: E) SyncDirectoryError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOTDIR => error.NotDirectory,
        else => error.Unexpected,
    };
}

const testing = std.testing;

test "every errno of a file call maps to its named error, any other to Unexpected" {
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
    // open(2) takes no O_DIRECT here, so its EINVAL has no name, unlike the `uring` backend's.
    for ([_]struct { E, OpenError }{
        .{ .NOENT, error.FileNotFound }, .{ .EXIST, error.PathAlreadyExists },
        .{ .ACCES, error.AccessDenied }, .{ .PERM, error.AccessDenied },
        .{ .ISDIR, error.Unexpected },   .{ .INVAL, error.Unexpected },
    }) |case| try testing.expectEqual(case[1], open_error(case[0]));
}

/// Bytes a test's path may take: the directory, the test's name, the process id, the terminator.
const test_path_bytes_max = 96;

/// The kernel keeps F_NOCACHE as FNOCACHE among the flags of the open file, and fcntl(F_GETFL)
/// reports those flags whole. <sys/fcntl.h> names FNOCACHE for the kernel alone, so this is what
/// Darwin 25.6 was seen to answer, not a documented promise.
const no_cache_flag: c_int = 0x40000;

/// The unit `st_blocks` counts in, whatever the filesystem's own block is.
const stat_block_bytes = 512;

/// A path no other test and no other run uses, removed first in case a crashed run left it.
fn test_path(buffer: *[test_path_bytes_max]u8, comptime name: []const u8) ![:0]const u8 {
    const format = "/tmp/rotor_kqueue_sync_" ++ name ++ "_{d}";
    const path = try std.fmt.bufPrintZ(buffer, format, .{c.getpid()});
    _ = c.unlink(path.ptr);
    return path;
}

fn remove(path: [:0]const u8) void {
    assert(posix.errno(c.unlink(path.ptr)) == .SUCCESS);
}

/// The descriptor's open flags, after checking that the descriptor closes on exec.
fn open_flags(descriptor: Descriptor) !c_int {
    const descriptor_flags = c.fcntl(descriptor, c.F.GETFD, @as(c_int, 0));
    try testing.expectEqual(E.SUCCESS, posix.errno(descriptor_flags));
    try testing.expect(descriptor_flags & c.FD_CLOEXEC != 0);
    const flags = c.fcntl(descriptor, c.F.GETFL, @as(c_int, 0));
    try testing.expectEqual(E.SUCCESS, posix.errno(flags));
    return flags;
}

/// The kernel hands out the lowest free descriptor, so two probes with no descriptor opened and
/// left open between them get one number.
fn probe_descriptor() !Descriptor {
    const probe = try open_file("/dev/null", existing);
    close_now(probe);
    return probe;
}

const existing: OpenOptions = .{ .create = false, .direct = false };
const creating: OpenOptions = .{ .create = true, .direct = false };
const direct: OpenOptions = .{ .create = false, .direct = true };

test "open_file creates once, reopens what exists and refuses what is missing" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var buffer: [test_path_bytes_max]u8 = undefined;
    const path = try test_path(&buffer, "open");
    try testing.expectError(error.FileNotFound, open_file(path, existing));
    const created = try open_file(path, creating);
    defer close_now(created);
    defer remove(path);
    try testing.expectError(error.PathAlreadyExists, open_file(path, creating));
    const flags = try open_flags(created);
    const named: c.O = @bitCast(flags);
    try testing.expect(named.ACCMODE == .RDWR);
    try testing.expect(!named.DSYNC and !named.SYNC and !named.NONBLOCK);
    try testing.expectEqual(@as(c_int, 0), flags & no_cache_flag);
}

test "open_file sets F_NOCACHE when direct, and refuses a path that opens a socket" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var buffer: [test_path_bytes_max]u8 = undefined;
    const path = try test_path(&buffer, "direct");
    close_now(try open_file(path, creating));
    defer remove(path);
    const reopened = try open_file(path, direct);
    defer close_now(reopened);
    const flags = try open_flags(reopened);
    const named: c.O = @bitCast(flags);
    try testing.expectEqual(no_cache_flag, flags & no_cache_flag);
    try testing.expect(named.ACCMODE == .RDWR and !named.DSYNC and !named.SYNC);
    // /dev/fd/N opens descriptor N again, and a socket is no file: the same path opens without
    // F_NOCACHE and is refused with it, and the refused open closes what it opened.
    const socket = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    try testing.expectEqual(E.SUCCESS, posix.errno(socket));
    defer close_now(socket);
    var socket_buffer: [test_path_bytes_max]u8 = undefined;
    const socket_path = try std.fmt.bufPrintZ(&socket_buffer, "/dev/fd/{d}", .{socket});
    close_now(try open_file(socket_path, existing));
    const probe_before = try probe_descriptor();
    try testing.expectError(error.DirectIoUnsupported, open_file(socket_path, direct));
    try testing.expectEqual(probe_before, try probe_descriptor());
}

test "set_file_size reserves what file_size then reports, and never shrinks" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var buffer: [test_path_bytes_max]u8 = undefined;
    const path = try test_path(&buffer, "size");
    const file = try open_file(path, creating);
    defer remove(path);
    try testing.expectEqual(@as(u64, 0), try file_size(file));
    try set_file_size(file, 65536);
    try testing.expectEqual(@as(u64, 65536), try file_size(file));
    // Reserved, not sparse: the blocks are the file's already. ftruncate would leave none.
    var stat = std.mem.zeroes(c.Stat);
    try testing.expectEqual(E.SUCCESS, posix.errno(c.fstat(file, &stat)));
    try testing.expect(stat.blocks * stat_block_bytes >= 65536);
    // The owner reads and writes the file, whatever the umask took from everyone else.
    try testing.expect(stat.mode & 0o700 == 0o600);
    // A smaller size leaves the length, and the same size reserves no block past it.
    try set_file_size(file, 4096);
    try testing.expectEqual(@as(u64, 65536), try file_size(file));
    try set_file_size(file, 65536);
    try testing.expectEqual(@as(u64, 65536), try file_size(file));
    var stat_after = std.mem.zeroes(c.Stat);
    try testing.expectEqual(E.SUCCESS, posix.errno(c.fstat(file, &stat_after)));
    try testing.expectEqual(stat.blocks, stat_after.blocks);
    // A closed descriptor and a device: each call reads the kernel's answer.
    close_now(file);
    try testing.expectError(error.Unexpected, file_size(file));
    const device = try open_file("/dev/null", existing);
    defer close_now(device);
    try testing.expectError(error.Unsupported, set_file_size(device, 4096));
}

test "set_file_size grows a file by the bytes it lacks, and a refused size leaves the length" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var buffer: [test_path_bytes_max]u8 = undefined;
    const path = try test_path(&buffer, "grow");
    const file = try open_file(path, creating);
    defer close_now(file);
    defer remove(path);
    try set_file_size(file, 65536);
    try set_file_size(file, 131072);
    try testing.expectEqual(@as(u64, 131072), try file_size(file));
    var stat = std.mem.zeroes(c.Stat);
    try testing.expectEqual(E.SUCCESS, posix.errno(c.fstat(file, &stat)));
    // Every byte has its block, and the second call reserved the difference, not 131072 more.
    try testing.expect(stat.blocks * stat_block_bytes >= 131072);
    try testing.expect(stat.blocks * stat_block_bytes < 131072 + 65536);
    // No disk holds 1 PiB. The refusal comes before ftruncate, which would have made the file
    // that long and sparse.
    try testing.expectError(error.NoSpaceLeft, set_file_size(file, 1 << 50));
    try testing.expectEqual(@as(u64, 131072), try file_size(file));
}

test "sync_directory syncs a directory and refuses a missing path and a file" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var buffer: [test_path_bytes_max]u8 = undefined;
    const path = try test_path(&buffer, "directory");
    try testing.expectError(error.FileNotFound, sync_directory(path));
    const file = try open_file(path, creating);
    defer close_now(file);
    defer remove(path);
    try testing.expectError(error.NotDirectory, sync_directory(path));
    // The directory is closed again. No directory of this host refuses a plain fsync, so no
    // test here shows that the fsync is issued and its answer read.
    const probe_before = try probe_descriptor();
    try sync_directory("/tmp");
    try testing.expectEqual(probe_before, try probe_descriptor());
}
