//! Every named limit of the `epoll` module. A limit `core` also reads lives in `core`.
//!
//! Most of these are the `kqueue` module's, because decision 20 makes this backend that one's shape
//! with a different readiness call. Where a number differs from kqueue's, the doc comment says why.
const std = @import("std");

/// The most readiness events one `epoll_pwait2` call carries out. A tick makes one call, so
/// descriptors that became ready beyond this many are reported by the next call, which loses no
/// readiness: epoll is level triggered here, so one still ready is still reported.
pub const readiness_max: u32 = 256;

/// There is no changelist. kqueue carries up to `changes_max` registrations in the call that waits;
/// `epoll_ctl` takes one descriptor per call and has no batched form, so a registration is made as
/// it is needed and nothing accumulates (decision 20, "The shape"). The constant kqueue needs for
/// its changelist has no counterpart here, and its absence is the difference.
pub const registrations_per_tick_max: u32 = readiness_max;

/// The alignment of the memory a provided-buffer group's bookkeeping sits in: what the uring
/// backend asks for its buffer ring, so one declaration in a caller's code serves every backend.
pub const buffer_ring_alignment = 64 * 1024;

/// The bytes of bookkeeping per buffer of a group: the size of one entry of an io_uring buffer
/// ring, so every backend asks a caller for the same amount.
pub const buffer_ring_entry_bytes = 16;

/// Times the backend makes a system call again after a signal interrupted it (EINTR) before it
/// reports the operation as failed. A signal storm is the only way to reach it.
pub const interrupt_retries_max: u32 = 64;

/// What the readiness of a loop's own eventfd carries as its `user_data`, so the reap tells a wake
/// from an operation without consulting a table. No slot can hold it: `core.constants` reserves the
/// value, and the comptime assert below holds that.
pub const wake_user_data: u64 = std.math.maxInt(u64);

comptime {
    const assert = std.debug.assert;
    assert(readiness_max >= 1);
    assert(registrations_per_tick_max >= 1);
    assert(interrupt_retries_max >= 1);
    assert(std.math.isPowerOfTwo(buffer_ring_alignment));
}
