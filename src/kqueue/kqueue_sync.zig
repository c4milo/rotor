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
//! `prepare_accepted`, which the loop's accept path calls because macOS has no `accept4`
//! (decision 12, point 8), stays in `kqueue_sync_socket.zig` and off this surface: the loop
//! makes that call, and a consumer never does.
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

// Every backend's `sync` carries the surface `core/sync.zig` writes out, and this holds it there.
comptime {
    core.sync.check(@This());
}

test {
    _ = socket_calls;
    _ = file_calls;
}
