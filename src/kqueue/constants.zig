//! Every named limit of the `kqueue` module. A limit `core` also reads lives in `core`.
const std = @import("std");

/// The most registrations one `kevent` call carries in, and the most readiness events it carries
/// out. A tick makes one call, so operations that must wait beyond this many stay queued for the
/// next tick.
pub const changes_max: u32 = 256;
pub const readiness_max: u32 = 256;

/// The identifier of the one `EVFILT_USER` event of a loop's kqueue: the event another loop
/// triggers to wake it for a message (decision 12, point 6).
pub const wake_identifier: usize = 1;

/// The most bytes a loop of a group reads from its wake pipe per wake (decision 21, point 3). Each
/// wake is one byte, and a sender writes only to a loop that said it sleeps, so a read rarely finds
/// more than a few; what is left keeps the pipe ready and the next tick reads it.
pub const group_wake_drain_bytes: usize = 64;

comptime {
    const assert = std.debug.assert;
    assert(changes_max >= readiness_max);
    assert(readiness_max >= 1);
}
