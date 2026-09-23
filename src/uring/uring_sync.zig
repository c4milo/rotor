//! The synchronous calls of decision 2: a socket or a listener made ready for the ring, a file
//! opened, measured and preallocated, a directory synced. They run at start-up and once per
//! connection, never per transfer.
//!
//! This file is the surface, and `kqueue_sync.zig` is its twin name for name and type for type,
//! because the conformance suite calls `backend.sync` on whichever backend the build hands it
//! (decision 10). The calls are `linux_shared`'s, shared with the epoll backend: the sockets through
//! `uring_sync_socket.zig`, which passes this backend's socket flags, and the files as they are.
const std = @import("std");
const core = @import("core");
const socket_calls = @import("uring_sync_socket.zig");
const file_calls = @import("linux_shared").sync_file;

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
