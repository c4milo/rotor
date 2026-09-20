//! The synchronous calls of decision 2 on macOS: a socket or a listener made ready for the loop,
//! a file opened, measured and preallocated, a directory synced. They run at start-up and once
//! per connection, never per transfer, so they are plain: one libc call at a time, every return
//! value checked, every errno mapped to a named error, with `Unexpected` for the rest.
//!
//! This file is the surface, and it is the surface of `uring_sync.zig` name for name and type for
//! type, because the conformance suite calls `backend.sync` on whichever backend the build hands
//! it (decision 10). An error macOS never produces keeps its place in its set. The calls are in
//! `kqueue_sync_socket.zig` and `kqueue_sync_file.zig`, each with its tests.
//!
//! One call is this backend's alone: `prepare_accepted`, which the loop's accept path calls
//! because macOS has no `accept4` (decision 12, point 8).
const std = @import("std");
const core = @import("core");
const socket_calls = @import("kqueue_sync_socket.zig");
const file_calls = @import("kqueue_sync_file.zig");

pub const SocketError = socket_calls.SocketError;
pub const ListenError = socket_calls.ListenError;
pub const AddressError = socket_calls.AddressError;
pub const OptionError = socket_calls.OptionError;
pub const ListenOptions = socket_calls.ListenOptions;
pub const open_socket = socket_calls.open_socket;
pub const listen = socket_calls.listen;
pub const local_address = socket_calls.local_address;
pub const set_no_delay = socket_calls.set_no_delay;
pub const prepare_accepted = socket_calls.prepare_accepted;
pub const close_now = socket_calls.close_now;

pub const OpenError = file_calls.OpenError;
pub const FileSizeError = file_calls.FileSizeError;
pub const SyncDirectoryError = file_calls.SyncDirectoryError;
pub const OpenOptions = file_calls.OpenOptions;
pub const open_file = file_calls.open_file;
pub const file_size = file_calls.file_size;
pub const set_file_size = file_calls.set_file_size;
pub const sync_directory = file_calls.sync_directory;

/// The public declarations of `uring_sync.zig`, and `prepare_accepted`. The module graph keeps
/// `uring` out of this module's reach, so the tests below write its surface out.
const declarations = 19;

const expect = std.testing.expect;

test "the surface is the one uring_sync.zig presents, with prepare_accepted beside it" {
    const Address = core.Address;
    const Descriptor = core.Descriptor;
    const Path = [*:0]const u8;
    try expect(@typeInfo(@This()).@"struct".decls.len == declarations);
    try expect(@TypeOf(open_socket) == fn (Address.Family) SocketError!Descriptor);
    try expect(@TypeOf(listen) == fn (*const Address, ListenOptions) ListenError!Descriptor);
    try expect(@TypeOf(local_address) == fn (Descriptor) AddressError!Address);
    try expect(@TypeOf(set_no_delay) == fn (Descriptor, bool) OptionError!void);
    try expect(@TypeOf(prepare_accepted) == fn (Descriptor) OptionError!void);
    try expect(@TypeOf(close_now) == fn (Descriptor) void);
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

test "every error set has the members of its twin, the ones macOS never produces included" {
    try expect(SocketError == error{
        AddressFamilyUnsupported,
        DescriptorLimit,
        SystemResources,
        Unexpected,
    });
    const listen_refusals = error{ AddressInUse, AddressNotAvailable, AccessDenied };
    try expect(ListenError == SocketError || listen_refusals);
    try expect(AddressError == error{ NotSocket, AddressFamilyUnsupported, Unexpected });
    try expect(OptionError == error{ NotSocket, Unexpected });
    try expect(OpenError == error{
        FileNotFound,
        PathAlreadyExists,
        AccessDenied,
        DirectIoUnsupported,
        Unexpected,
    });
    try expect(FileSizeError == error{ NoSpaceLeft, Unsupported, Unexpected });
    const directory_refusals = error{ FileNotFound, AccessDenied, NotDirectory, Unexpected };
    try expect(SyncDirectoryError == directory_refusals);
}

test {
    _ = socket_calls;
    _ = file_calls;
}
