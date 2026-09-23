//! The synchronous socket calls on the epoll backend: `linux_shared`'s, with this backend's socket
//! type flags. `linux_shared_sync_socket.zig` holds the calls and their tests.
const std = @import("std");
const linux = std.os.linux;
const core = @import("core");
const shared = @import("linux_shared").sync_socket;

const Address = core.Address;
const Descriptor = core.Descriptor;

// The types are `core/sync.zig`'s, which every backend's calls take and return.
pub const SocketError = core.sync.SocketError;
pub const ListenError = core.sync.ListenError;
pub const AddressError = core.sync.AddressError;
pub const OptionError = core.sync.OptionError;
pub const ListenOptions = core.sync.ListenOptions;
pub const SocketBuffer = core.sync.SocketBuffer;
pub const socket_buffer_bytes_max = core.sync.socket_buffer_bytes_max;
pub const BufferError = core.sync.BufferError;
pub const DatagramOptions = core.sync.DatagramOptions;

/// The type flags every socket this backend opens carries: it closes on exec, and it does not
/// block, because the loop makes each call itself and waits for readiness instead (decision 20).
pub const socket_flags: u32 = linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK;

pub fn open_socket(family: Address.Family) SocketError!Descriptor {
    return shared.open_socket(family, socket_flags);
}

pub fn listen(address: *const Address, options: ListenOptions) ListenError!Descriptor {
    return shared.listen(address, options, socket_flags);
}

pub fn open_datagram(
    family: Address.Family,
    bind_to: ?*const Address,
    options: DatagramOptions,
) ListenError!Descriptor {
    return shared.open_datagram(family, bind_to, options, socket_flags);
}

pub const local_address = shared.local_address;
pub const set_no_delay = shared.set_no_delay;
pub const close_now = shared.close_now;
pub const set_buffer_bytes = shared.set_buffer_bytes;
