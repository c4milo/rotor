//! Every named limit of the `kqueue` module. A limit `core` also reads lives in `core`.
const std = @import("std");

/// The most registrations one `kevent` call carries in, and the most readiness events it carries
/// out. A tick makes one call, so operations that must wait beyond this many stay queued for the
/// next tick.
pub const changes_max: u32 = 256;
pub const readiness_max: u32 = 256;

/// Times the backend makes a system call again after a signal interrupted it (EINTR) before it
/// reports the operation as failed. A signal storm is the only way to reach it.
pub const interrupt_retries_max: u32 = 64;

/// The identifier of the one `EVFILT_USER` event of a loop's kqueue: the event another loop
/// triggers to wake it for a message (decision 12, point 6).
pub const wake_identifier: usize = 1;

comptime {
    const assert = std.debug.assert;
    assert(changes_max >= readiness_max);
    assert(interrupt_retries_max >= 1);
    assert(readiness_max >= 1);
}
