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

/// The identifier of the one `EVFILT_TIMER` event of a loop's kqueue: the timer that bounds a
/// tick's wait, so that the `kevent` call that waits carries no timeout (decision 12, point 7).
pub const wait_timer_identifier: usize = 2;

/// The most times one tick arms its wait timer again after the timer fired before the tick's own
/// deadline (decision 12, point 7). The first such timer is armed for exactly the time left, so it
/// ends the wait unless the kernel's clock and the tick's disagree by a little. A tick that uses them
/// all hands over no event.
pub const wait_timer_rearms_max: u32 = 4;

/// The most bytes a loop of a group reads from its wake pipe per wake (decision 21, point 3). Each
/// wake is one byte, and a sender writes only to a loop that said it sleeps, so a read rarely finds
/// more than a few; what is left keeps the pipe ready and the next tick reads it.
pub const group_wake_drain_bytes: usize = 64;

comptime {
    const assert = std.debug.assert;
    assert(changes_max >= readiness_max);
    assert(readiness_max >= 1);
}
