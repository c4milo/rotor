//! `sync` on Linux: the calls a caller makes before it has a loop, for the backend this process runs.
//! Split from `rotor.zig` for the 500-line limit.
//!
//! Every call is the uring backend's, which are the same Linux calls the epoll backend makes, except
//! the three that open a socket: those open it the way the process's backend needs, blocking for
//! uring, whose ring does the waiting, and not blocking for epoll, whose loop makes each call itself.
const core = @import("core");
const uring = @import("uring");
const epoll = @import("epoll");
const loop_module = @import("rotor_loop.zig");

const Address = core.Address;
const Descriptor = core.Descriptor;

const from = uring.sync;

pub const SocketError = from.SocketError;
pub const ListenError = from.ListenError;
pub const AddressError = from.AddressError;
pub const OptionError = from.OptionError;
pub const ListenOptions = from.ListenOptions;
pub const local_address = from.local_address;
pub const set_no_delay = from.set_no_delay;
pub const close_now = from.close_now;
pub const SocketBuffer = from.SocketBuffer;
pub const BufferError = from.BufferError;
pub const socket_buffer_bytes_max = from.socket_buffer_bytes_max;
pub const set_buffer_bytes = from.set_buffer_bytes;
pub const DatagramOptions = from.DatagramOptions;
pub const OpenError = from.OpenError;
pub const FileSizeError = from.FileSizeError;
pub const SyncDirectoryError = from.SyncDirectoryError;
pub const OpenOptions = from.OpenOptions;
pub const open_file = from.open_file;
pub const file_size = from.file_size;
pub const set_file_size = from.set_file_size;
pub const sync_directory = from.sync_directory;

/// A TCP socket of `family`, closed on exec, for the backend this process runs.
pub fn open_socket(family: Address.Family) SocketError!Descriptor {
    return switch (loop_module.chosen()) {
        .uring => uring.sync.open_socket(family),
        .epoll => epoll.sync.open_socket(family),
    };
}

/// socket, SO_REUSEADDR, SO_REUSEPORT when asked, bind, listen, for the backend this process
/// runs.
pub fn listen(address: *const Address, options: ListenOptions) ListenError!Descriptor {
    return switch (loop_module.chosen()) {
        .uring => uring.sync.listen(address, options),
        .epoll => epoll.sync.listen(address, options),
    };
}

/// A UDP socket of `family`, closed on exec, bound to `bind_to` when one is given, for the
/// backend this process runs.
pub fn open_datagram(
    family: Address.Family,
    bind_to: ?*const Address,
    options: DatagramOptions,
) ListenError!Descriptor {
    return switch (loop_module.chosen()) {
        .uring => uring.sync.open_datagram(family, bind_to, options),
        .epoll => epoll.sync.open_datagram(family, bind_to, options),
    };
}
