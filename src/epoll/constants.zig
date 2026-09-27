//! Every named limit of the `epoll` module. A limit `core` also reads lives in `core`.
//!
//! Most of these are the `kqueue` module's, because decision 20 makes this backend that one's shape
//! with a different readiness call. Where a number differs from kqueue's, the doc comment says why.
const std = @import("std");

/// The most readiness events one `epoll_pwait2` call carries out. A tick makes one call, so
/// descriptors that became ready beyond this many are reported by the next call, which loses no
/// readiness: epoll is level triggered here, so one still ready is still reported.
pub const readiness_max: u32 = 256;

// There is no changelist and so no `changes_max`. kqueue carries up to that many registrations in
// the call that waits; `epoll_ctl` takes one descriptor per call and has no batched form, so a
// registration is made as it is needed, nothing accumulates, and the flush needs no bound beyond
// the pending list it walks (decision 20, "The shape").

/// What the readiness of a loop's own eventfd carries as its `user_data`, so the reap tells a wake
/// from an operation without consulting a table. Every other registration carries its descriptor,
/// an `i32` that is not negative, so no registration can carry this value: the comptime assert
/// below holds that.
pub const wake_user_data: u64 = std.math.maxInt(u64);

/// What the readiness of a loop's wait timer carries as its `user_data`: the timerfd that bounds a
/// tick's wait, so that the `epoll_pwait2` call that waits carries no timeout (decision 20, "The
/// wait timer"). Above every descriptor for the reason `wake_user_data` is.
pub const wait_timer_user_data: u64 = std.math.maxInt(u64) - 1;

/// The most times one tick arms its wait timer again after the timer fired before the tick's own
/// deadline: kqueue's `wait_timer_rearms_max`, for the same reason. The first such timer is armed
/// for exactly the time left, so it ends the wait unless the kernel's clock and the tick's disagree
/// by a little. A tick that uses them all hands over no event.
pub const wait_timer_rearms_max: u32 = 4;

comptime {
    const assert = std.debug.assert;
    assert(readiness_max >= 1);
    assert(wake_user_data > std.math.maxInt(i32));
    assert(wait_timer_user_data > std.math.maxInt(i32));
    assert(wait_timer_user_data != wake_user_data);
    assert(wait_timer_rearms_max >= 1);
}
