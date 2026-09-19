//! The synchronous calls of decision 2: a socket or a listener made ready for the ring, a file
//! opened, measured and preallocated, a directory synced. They run at start-up and once per
//! connection, never per transfer, so they are plain: one raw syscall at a time, every return
//! value checked, every errno mapped to a named error, with `Unexpected` for the rest.
//!
//! Each map is a function of the errno alone, so a test on any host covers the refusals the kernel
//! will not produce on demand (decision 10, point 3). Every other test runs under Linux alone.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const uring_address = @import("uring_address.zig");

const Address = core.Address;
const Descriptor = core.Descriptor;

/// The permission bits of a file `open_file` creates: its owner reads and writes it, everyone
/// else reads it. The process's umask narrows them.
const file_mode: linux.mode_t = 0o644;

/// `socket(2)` refused. `AddressFamilyUnsupported`: the host carries no stack for the family, as
/// with IPv6 switched off. `DescriptorLimit` is EMFILE or ENFILE, and `SystemResources` is ENOMEM
/// or ENOBUFS, as in `core.Code`.
pub const SocketError = error{
    AddressFamilyUnsupported,
    DescriptorLimit,
    SystemResources,
    Unexpected,
};

/// `bind(2)` or `listen(2)` refused. `AddressInUse`: another socket listens on the address, and
/// one of the two did not ask for `reuse_port`. `AddressNotAvailable`: no interface of this host
/// has the address. `AccessDenied`: only a privileged process may bind the port.
pub const ListenError = SocketError || error{ AddressInUse, AddressNotAvailable, AccessDenied };

/// `getsockname(2)` refused, or the socket's family is one rotor does not carry.
pub const AddressError = error{ NotSocket, AddressFamilyUnsupported, Unexpected };

/// `setsockopt(2)` refused.
pub const OptionError = error{ NotSocket, Unexpected };

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

/// A TCP socket of `family`, closed on exec. It blocks: the ring does the waiting, so the socket
/// needs no SOCK_NONBLOCK.
pub fn open_socket(family: Address.Family) SocketError!Descriptor {
    const domain: u32 = switch (family) {
        .ipv4 => linux.AF.INET,
        .ipv6 => linux.AF.INET6,
    };
    const rc = linux.socket(domain, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) return socket_error(errno);
    return descriptor_of(rc);
}

pub const ListenOptions = struct {
    /// Connections the kernel queues for `accept`, at least 1, capped at `net.core.somaxconn`.
    backlog: u31,
    /// SO_REUSEPORT: several listeners bind one address, and the kernel picks one for each
    /// connection by a hash of the connection's addresses (decision 4, `listener_per_core`).
    reuse_port: bool,
};

/// socket, SO_REUSEADDR, SO_REUSEPORT when asked, bind, listen. SO_REUSEADDR lets a restarted
/// server bind its port while connections of the last run still sit in TIME_WAIT. Closes the
/// socket again on any failure after it was opened. An `address` with port 0 takes a port the
/// kernel chooses, which `local_address` reports.
pub fn listen(address: *const Address, options: ListenOptions) ListenError!Descriptor {
    assert(options.backlog >= 1);
    const socket = try open_socket(address.family);
    errdefer close_now(socket);
    // A socket this function just opened has both options, so a refusal here has no name.
    set_option(socket, linux.SOL.SOCKET, linux.SO.REUSEADDR, true) catch return error.Unexpected;
    if (options.reuse_port) {
        set_option(socket, linux.SOL.SOCKET, linux.SO.REUSEPORT, true) catch
            return error.Unexpected;
    }
    var storage: uring_address.Storage = undefined;
    const len = uring_address.to_kernel(address, &storage);
    const bind_errno = linux.errno(linux.bind(socket, @ptrCast(&storage), len));
    if (bind_errno != .SUCCESS) return listen_error(bind_errno);
    // Two sockets that both set SO_REUSEADDR can bind one port while neither listens, so the
    // second of them meets EADDRINUSE here and not at bind.
    const listen_errno = linux.errno(linux.listen(socket, options.backlog));
    if (listen_errno != .SUCCESS) return listen_error(listen_errno);
    return socket;
}

/// getsockname: how a caller that bound port 0 learns the port the kernel chose.
pub fn local_address(descriptor: Descriptor) AddressError!Address {
    assert(descriptor >= 0);
    var storage = std.mem.zeroes(uring_address.Storage);
    var len: linux.socklen_t = @sizeOf(uring_address.Storage);
    const errno = linux.errno(linux.getsockname(descriptor, @ptrCast(&storage), &len));
    if (errno != .SUCCESS) return socket_call_error(errno);
    assert(len >= @sizeOf(linux.sa_family_t));
    return uring_address.from_kernel(&storage, len) orelse error.AddressFamilyUnsupported;
}

/// TCP_NODELAY: when `enabled`, the kernel sends a small segment at once (Nagle's algorithm off).
pub fn set_no_delay(descriptor: Descriptor, enabled: bool) OptionError!void {
    return set_option(descriptor, linux.IPPROTO.TCP, linux.TCP.NODELAY, enabled);
}

/// close(2), for a descriptor with no operation in flight: start-up, shutdown and tests. A
/// descriptor with operations in flight is closed with the `close` operation (decision 5, rule 6).
/// Linux frees the descriptor whatever close(2) answers, EINTR and EIO included, so there is
/// nothing to retry and no error a caller could act on. EBADF is the exception: a double close,
/// which in a process with other threads closes a descriptor one of them just opened. It halts.
pub fn close_now(descriptor: Descriptor) void {
    assert(descriptor >= 0);
    const errno = linux.errno(linux.close(descriptor));
    assert(errno != .BADF);
}

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

fn set_option(descriptor: Descriptor, level: i32, name: u32, enabled: bool) OptionError!void {
    assert(descriptor >= 0);
    const value: c_int = @intFromBool(enabled);
    const rc = linux.setsockopt(descriptor, level, name, std.mem.asBytes(&value), @sizeOf(c_int));
    const errno = linux.errno(rc);
    if (errno != .SUCCESS) return socket_call_error(errno);
}

/// The descriptor a successful `socket(2)` or `open(2)` returned.
fn descriptor_of(rc: usize) Descriptor {
    assert(linux.errno(rc) == .SUCCESS);
    assert(rc <= std.math.maxInt(Descriptor));
    return @intCast(rc);
}

fn socket_error(errno: linux.E) SocketError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .MFILE, .NFILE => error.DescriptorLimit,
        .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

/// The errno of a `bind(2)` or of a `listen(2)`.
fn listen_error(errno: linux.E) ListenError {
    assert(errno != .SUCCESS);
    return switch (errno) {
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// The errno of a call that takes a socket: `getsockname(2)` or `setsockopt(2)`.
fn socket_call_error(errno: linux.E) error{ NotSocket, Unexpected } {
    assert(errno != .SUCCESS);
    return if (errno == .NOTSOCK) error.NotSocket else error.Unexpected;
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

test "every errno maps to its named error, any other to Unexpected, on every host" {
    for ([_]struct { E, SocketError }{
        .{ .AFNOSUPPORT, error.AddressFamilyUnsupported }, .{ .MFILE, error.DescriptorLimit },
        .{ .NFILE, error.DescriptorLimit },                .{ .NOMEM, error.SystemResources },
        .{ .NOBUFS, error.SystemResources },               .{ .ACCES, error.Unexpected },
    }) |case| try testing.expectEqual(case[1], socket_error(case[0]));
    for ([_]struct { E, ListenError }{
        .{ .ADDRINUSE, error.AddressInUse }, .{ .ADDRNOTAVAIL, error.AddressNotAvailable },
        .{ .ACCES, error.AccessDenied },     .{ .BADF, error.Unexpected },
    }) |case| try testing.expectEqual(case[1], listen_error(case[0]));
    try testing.expectEqual(error.NotSocket, socket_call_error(.NOTSOCK));
    try testing.expectEqual(error.Unexpected, socket_call_error(.BADF));
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

fn expect_option(descriptor: Descriptor, level: i32, name: u32, expected: c_int) !void {
    var value: c_int = -1;
    var len: linux.socklen_t = @sizeOf(c_int);
    const rc = linux.getsockopt(descriptor, level, name, std.mem.asBytes(&value), &len);
    try testing.expectEqual(E.SUCCESS, linux.errno(rc));
    try testing.expectEqual(expected, value);
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
    const probe = try open_socket(.ipv4);
    close_now(probe);
    return probe;
}

/// A connected client of the listener at `address`. The kernel completes the handshake from the
/// listener's backlog, so a blocking connect returns with no accept.
fn connect_to(address: *const Address) !Descriptor {
    const client = try open_socket(address.family);
    errdefer close_now(client);
    var storage: uring_address.Storage = undefined;
    const len = uring_address.to_kernel(address, &storage);
    try testing.expectEqual(E.SUCCESS, linux.errno(linux.connect(client, &storage, len)));
    return client;
}

const alone: ListenOptions = .{ .backlog = 1, .reuse_port = false };
const sharing: ListenOptions = .{ .backlog = 1, .reuse_port = true };
const existing: OpenOptions = .{ .create = false, .direct = false };
const creating: OpenOptions = .{ .create = true, .direct = false };

test "a listener on port 0 reports the port the kernel chose, and a client connects to it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var loopback6: [Address.ipv6_bytes]u8 = @splat(0);
    loopback6[Address.ipv6_bytes - 1] = 1;
    const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    for ([_]Address{ loopback, Address.ipv6(loopback6, 0, 0) }) |any_port| {
        const listener = listen(&any_port, alone) catch |err| {
            // A host with IPv6 switched off cannot run the second round.
            const no_stack = err == error.AddressFamilyUnsupported or
                err == error.AddressNotAvailable;
            return if (any_port.family == .ipv6 and no_stack) error.SkipZigTest else err;
        };
        defer close_now(listener);
        const bound = try local_address(listener);
        try testing.expectEqual(any_port.family, bound.family);
        try testing.expect(bound.port != 0);
        try testing.expectEqualSlices(u8, &any_port.bytes, &bound.bytes);
        try expect_option(listener, linux.SOL.SOCKET, linux.SO.ACCEPTCONN, 1);
        try expect_option(listener, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
        try expect_option(listener, linux.SOL.SOCKET, linux.SO.REUSEPORT, 0);
        const client = try connect_to(&bound);
        defer close_now(client);
        try testing.expect((try local_address(client)).port != bound.port);
    }
}

test "listeners share a port only when all ask, and a refused listen closes its socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const first = try listen(&loopback, sharing);
    defer close_now(first);
    const shared_address = try local_address(first);
    const second = try listen(&shared_address, sharing);
    defer close_now(second);
    try testing.expectEqual(shared_address.port, (try local_address(second)).port);
    const third = try listen(&loopback, alone);
    defer close_now(third);
    const third_address = try local_address(third);
    // A socket a refused listen left open would hold the number the first probe had.
    const probe_before = try probe_descriptor();
    try testing.expectError(error.AddressInUse, listen(&shared_address, alone));
    try testing.expectError(error.AddressInUse, listen(&third_address, alone));
    try testing.expectError(error.AddressInUse, listen(&third_address, sharing));
    // 192.0.2.1 is a documentation address (RFC 5737), which no interface carries.
    const nowhere = Address.ipv4(.{ 192, 0, 2, 1 }, 0);
    try testing.expectError(error.AddressNotAvailable, listen(&nowhere, alone));
    try testing.expectEqual(probe_before, try probe_descriptor());
}

test "a socket closes on exec and takes TCP_NODELAY; a file and a unix socket are refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const socket = try open_socket(.ipv4);
    try testing.expect(!(try open_flags(socket)).NONBLOCK);
    try set_no_delay(socket, true);
    try expect_option(socket, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);
    try set_no_delay(socket, false);
    try expect_option(socket, linux.IPPROTO.TCP, linux.TCP.NODELAY, 0);
    close_now(socket);
    // The descriptor is free again: close_now closed it and did not only forget it.
    try testing.expectEqual(E.BADF, linux.errno(linux.fcntl(socket, linux.F.GETFD, 0)));
    var buffer: [test_path_bytes_max]u8 = undefined;
    const path = try test_path(&buffer, "option");
    const file = try open_file(path, creating);
    defer close_now(file);
    defer remove(path);
    try testing.expectError(error.NotSocket, set_no_delay(file, true));
    try testing.expectError(error.NotSocket, local_address(file));
    const unix_socket = descriptor_of(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0));
    defer close_now(unix_socket);
    try testing.expectError(error.AddressFamilyUnsupported, local_address(unix_socket));
}

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
