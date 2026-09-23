//! The synchronous calls of decision 2: a socket or a listener made ready for the loop, a file
//! opened, measured and preallocated, a directory synced. They run at start-up and once per
//! connection, never per transfer.
//!
//! This file is the surface, and `uring_sync.zig` and `kqueue_sync.zig` are its twins name for
//! name and type for type, because the conformance suite calls `backend.sync` on whichever backend
//! the build hands it (decision 10). The calls are in `epoll_sync_socket.zig` and
//! `epoll_sync_file.zig`, each with its own tests.
const std = @import("std");
const core = @import("core");
const socket_calls = @import("epoll_sync_socket.zig");
const file_calls = @import("epoll_sync_file.zig");

pub const SocketError = socket_calls.SocketError;
pub const ListenError = socket_calls.ListenError;
pub const AddressError = socket_calls.AddressError;
pub const OptionError = socket_calls.OptionError;
pub const ListenOptions = socket_calls.ListenOptions;
pub const open_socket = socket_calls.open_socket;
pub const listen = socket_calls.listen;
pub const local_address = socket_calls.local_address;
pub const set_no_delay = socket_calls.set_no_delay;
pub const close_now = socket_calls.close_now;
pub const SocketBuffer = socket_calls.SocketBuffer;
pub const BufferError = socket_calls.BufferError;
pub const socket_buffer_bytes_max = socket_calls.socket_buffer_bytes_max;
pub const set_buffer_bytes = socket_calls.set_buffer_bytes;
pub const DatagramOptions = socket_calls.DatagramOptions;
pub const open_datagram = socket_calls.open_datagram;

pub const OpenError = file_calls.OpenError;
pub const FileSizeError = file_calls.FileSizeError;
pub const SyncDirectoryError = file_calls.SyncDirectoryError;
pub const OpenOptions = file_calls.OpenOptions;
pub const open_file = file_calls.open_file;
pub const file_size = file_calls.file_size;
pub const set_file_size = file_calls.set_file_size;
pub const sync_directory = file_calls.sync_directory;

/// This file's public declarations, which `uring_sync.zig` and `kqueue_sync.zig` carry too, name
/// for name. Its own test writes the surface out, and this one holds the count they share.
const declarations = 24;

const expect = std.testing.expect;

test "the surface is the one uring_sync.zig and kqueue_sync.zig present, name for name" {
    const Address = core.Address;
    const Descriptor = core.Descriptor;
    const Path = [*:0]const u8;
    try expect(@typeInfo(@This()).@"struct".decls.len == declarations);
    try expect(@TypeOf(open_socket) == fn (Address.Family) SocketError!Descriptor);
    try expect(@TypeOf(listen) == fn (*const Address, ListenOptions) ListenError!Descriptor);
    try expect(@TypeOf(local_address) == fn (Descriptor) AddressError!Address);
    try expect(@TypeOf(set_no_delay) == fn (Descriptor, bool) OptionError!void);
    try expect(@TypeOf(close_now) == fn (Descriptor) void);
    const buffer_type = fn (Descriptor, SocketBuffer, u32) BufferError!u32;
    try expect(@TypeOf(set_buffer_bytes) == buffer_type);
    try expect(@typeInfo(SocketBuffer).@"enum".fields.len == 2);
    try expect(socket_buffer_bytes_max == std.math.maxInt(i32));
    const Bind = ?*const Address;
    const open_datagram_type = fn (Address.Family, Bind, DatagramOptions) ListenError!Descriptor;
    try expect(@TypeOf(open_datagram) == open_datagram_type);
    try expect(@TypeOf(open_file) == fn (Path, OpenOptions) OpenError!Descriptor);
    try expect(@TypeOf(file_size) == fn (Descriptor) FileSizeError!u64);
    try expect(@TypeOf(set_file_size) == fn (Descriptor, u64) FileSizeError!void);
    try expect(@TypeOf(sync_directory) == fn (Path) SyncDirectoryError!void);
    try expect(@typeInfo(ListenOptions).@"struct".fields.len == 2);
    try expect(@FieldType(ListenOptions, "backlog") == u31);
    try expect(@FieldType(ListenOptions, "reuse_port") == bool);
    try expect(@typeInfo(OpenOptions).@"struct".fields.len == 2);
    try expect(@FieldType(OpenOptions, "create") == bool);
    try expect(@FieldType(OpenOptions, "direct") == bool);
}

test {
    _ = socket_calls;
    _ = file_calls;
}
