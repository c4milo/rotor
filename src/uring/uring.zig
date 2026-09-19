//! The `uring` module: the Linux backend (decision 1), over io_uring. It imports `core` and
//! nothing else. Its pure parts, which turn a slot into a submission entry and a completion entry
//! into an event, compile and are tested on every host, with completion entries a test builds
//! itself (decision 10). Everything that enters the kernel is tested under Linux alone, by
//! `tools/linux_test.sh`.
pub const constants = @import("constants.zig");
pub const address = @import("uring_address.zig");
pub const errno = @import("uring_errno.zig");
pub const sync = @import("uring_sync.zig");

test {
    _ = constants;
    _ = address;
    _ = errno;
    _ = sync;
}
