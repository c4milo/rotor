//! The `kqueue` module: the macOS backend (decisions 1 and 12), over kqueue. It imports `core`
//! and nothing else. kqueue reports readiness, so this backend performs each operation itself
//! when its descriptor is ready, and presents the caller the behaviour `uring` presents: the
//! conformance suite runs against both.
pub const constants = @import("constants.zig");
pub const address = @import("kqueue_address.zig");
pub const errno = @import("kqueue_errno.zig");
pub const mailbox = @import("kqueue_mailbox.zig");
pub const sync = @import("kqueue_sync.zig");
pub const testing = @import("kqueue_testing.zig");
pub const waiters = @import("kqueue_waiters.zig");

/// True on a host whose kernel this backend can run on. The conformance suite skips elsewhere.
pub const supported = @import("builtin").os.tag.isDarwin();

test {
    _ = constants;
    _ = address;
    _ = errno;
    _ = mailbox;
    _ = sync;
    _ = testing;
    _ = waiters;
    _ = @import("kqueue_waiters_test.zig");
}
