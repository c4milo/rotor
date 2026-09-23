//! The types of the synchronous calls of decision 2, which every backend's `sync` carries name for
//! name: the error sets, the options and the largest socket buffer a call carries. They name no
//! kernel type, so they are `core`'s, and each backend's calls take and return these very types.
//! A caller's options therefore reach whichever backend runs without a field being copied.
//!
//! `check` holds a backend's `sync` to this file at comptime: every name below, each function with
//! the type written here, and nothing else. Each backend runs it on its own `sync`, as it runs
//! `surface.check` on its `Loop`, so a backend that drifts fails to compile on every host.
const std = @import("std");
const constants = @import("constants.zig");
const operation = @import("operation.zig");

const Address = operation.Address;
const Descriptor = operation.Descriptor;

/// `socket(2)` refused. `AddressFamilyUnsupported`: the host carries no stack for the family, as
/// with IPv6 switched off. `DescriptorLimit` is EMFILE or ENFILE, and `SystemResources` is ENOMEM
/// or ENOBUFS, as in `Code`.
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

/// `setsockopt(2)` refused, or on macOS `fcntl(2)` did, which is `Unexpected`.
pub const OptionError = error{ NotSocket, Unexpected };

pub const ListenOptions = struct {
    /// Connections the kernel queues for `accept`, at least 1, capped at the kernel's own limit:
    /// `net.core.somaxconn` on Linux, `kern.ipc.somaxconn` on macOS.
    backlog: u31,
    /// SO_REUSEPORT: several listeners bind one address (decision 4, `listener_per_core`). Linux
    /// picks one for each connection by a hash of the connection's addresses; decision 4 recalls
    /// that macOS does not spread connections across them.
    reuse_port: bool,
};

/// Which of a socket's two kernel buffers `set_buffer_bytes` sizes.
pub const SocketBuffer = enum { receive, send };

pub const socket_buffer_bytes_max = constants.socket_buffer_bytes_max;

/// What `set_buffer_bytes` answers beyond an option call's own errors.
pub const BufferError = OptionError || error{
    /// The kernel would not give a buffer of that size. macOS answers this for a size above its
    /// limit; Linux caps instead and does not refuse.
    SizeRefused,
};

/// Options a datagram socket is opened with (decision 15).
pub const DatagramOptions = struct {
    /// Report the address each datagram was sent to, so a server on a wildcard address can
    /// answer from it, and report the codepoint each carried.
    control: bool = true,
    /// Do not fragment: path MTU discovery needs it, and without it an oversized datagram is cut
    /// up instead of reported.
    dont_fragment: bool = true,
};

/// `open(2)` refused. `DirectIoUnsupported` on Linux: the filesystem does not carry O_DIRECT. On
/// macOS it is `fcntl(F_NOCACHE)` refusing, which the kernel keeps as a flag of the open file
/// without asking the filesystem, so it refuses only a path that opens something that is no file,
/// as `/dev/fd/N` does when descriptor N is a socket.
pub const OpenError = error{
    FileNotFound,
    PathAlreadyExists,
    AccessDenied,
    DirectIoUnsupported,
    Unexpected,
};

/// `NoSpaceLeft`: the disk refused to reserve the file's extents. `Unsupported`: the filesystem,
/// or this kind of file, has no way to reserve them: no `fallocate(2)` on Linux, no F_PREALLOCATE
/// on macOS.
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

/// The declarations above that a backend's `sync` re-exports as they are.
const shared_names = [_][]const u8{
    "SocketError",
    "ListenError",
    "AddressError",
    "OptionError",
    "ListenOptions",
    "SocketBuffer",
    "socket_buffer_bytes_max",
    "BufferError",
    "DatagramOptions",
    "OpenError",
    "FileSizeError",
    "SyncDirectoryError",
    "OpenOptions",
};

const Path = [*:0]const u8;

/// A call of a backend's `sync` and its type.
const Signature = struct { name: []const u8, type: type };

const signatures = [_]Signature{
    .{ .name = "open_socket", .type = fn (Address.Family) SocketError!Descriptor },
    .{ .name = "listen", .type = fn (*const Address, ListenOptions) ListenError!Descriptor },
    .{ .name = "local_address", .type = fn (Descriptor) AddressError!Address },
    .{ .name = "set_no_delay", .type = fn (Descriptor, bool) OptionError!void },
    .{ .name = "close_now", .type = fn (Descriptor) void },
    .{ .name = "set_buffer_bytes", .type = fn (Descriptor, SocketBuffer, u32) BufferError!u32 },
    .{
        .name = "open_datagram",
        .type = fn (Address.Family, ?*const Address, DatagramOptions) ListenError!Descriptor,
    },
    .{ .name = "open_file", .type = fn (Path, OpenOptions) OpenError!Descriptor },
    .{ .name = "file_size", .type = fn (Descriptor) FileSizeError!u64 },
    .{ .name = "set_file_size", .type = fn (Descriptor, u64) FileSizeError!void },
    .{ .name = "sync_directory", .type = fn (Path) SyncDirectoryError!void },
};

/// The first declaration where `Sync` differs from this file: one it lacks, one it gives another
/// type or value, or a declaration beyond them. Null when it carries exactly these.
pub fn first_mismatch(comptime Sync: type) ?[]const u8 {
    inline for (shared_names) |name| {
        if (!@hasDecl(Sync, name)) return name;
        if (@field(Sync, name) != @field(@This(), name)) return name;
    }
    inline for (signatures) |signature| {
        if (!@hasDecl(Sync, signature.name)) return signature.name;
        if (@TypeOf(@field(Sync, signature.name)) != signature.type) return signature.name;
    }
    const declarations = @typeInfo(Sync).@"struct".decls.len;
    if (declarations != shared_names.len + signatures.len) return "a declaration beyond the list";
    return null;
}

/// Fails the compile, naming the first declaration where `Sync` differs from this file.
pub fn check(comptime Sync: type) void {
    if (comptime first_mismatch(Sync)) |name| {
        @compileError("backend sync differs from core/sync.zig at '" ++ name ++ "'");
    }
}

const testing = std.testing;

test "a sync that lacks a declaration, or gives one another type, is named" {
    try testing.expectEqualStrings("SocketError", comptime first_mismatch(struct {}).?);
    const Changed = struct {
        pub const SocketError = error{Unexpected};
    };
    try testing.expectEqualStrings("SocketError", comptime first_mismatch(Changed).?);
}
