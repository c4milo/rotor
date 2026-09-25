//! The `linux_shared` module: what both Linux backends, `uring` and `epoll`, need and do the same
//! way. It names Linux's own types, which is why it is not in `core`, and it takes no `*Loop`, so
//! either backend's loop can use it. It imports `core` alone. The owner approved this edge of the
//! module graph on 2026-09-23; until then each Linux backend kept its own copy of these files.
pub const address = @import("linux_shared_address.zig");
pub const clock = @import("linux_shared_clock.zig");
pub const datagram = @import("linux_shared_datagram.zig");
pub const group = @import("linux_shared_group.zig");
pub const sync_file = @import("linux_shared_sync_file.zig");
pub const sync_socket = @import("linux_shared_sync_socket.zig");
pub const testing = @import("linux_shared_testing.zig");

test {
    _ = address;
    _ = clock;
    _ = datagram;
    _ = group;
    _ = sync_file;
    _ = sync_socket;
    _ = testing;
}
