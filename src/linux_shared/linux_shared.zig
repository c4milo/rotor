//! The `linux_shared` module: what both Linux backends, `uring` and `epoll`, need and do the same
//! way. It names Linux's own types, which is why it is not in `core`, and it takes no `*Loop`, so
//! either backend's loop can use it. It imports `core` alone. The owner approved this edge of the
//! module graph on 2026-09-23; until then each Linux backend kept its own copy of these files.
pub const address = @import("linux_shared_address.zig");
pub const clock = @import("linux_shared_clock.zig");
pub const testing = @import("linux_shared_testing.zig");

test {
    _ = address;
    _ = clock;
    _ = testing;
}
