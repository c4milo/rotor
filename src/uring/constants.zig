//! Every named limit of the `uring` module. A limit `core` also reads lives in `core`.
const std = @import("std");

/// Submission ring entries a loop may be initialised with: a power of two in [1, entries_max],
/// which is io_uring's own bound.
pub const entries_max: u16 = 32768;

/// Times one `tick` re-enters the ring after a signal (EINTR) or a transient EAGAIN interrupts
/// `io_uring_enter`. The submission tail and every pending completion survive the interruption,
/// so re-entering is safe; past this bound `tick` fails with `SystemResources` (decision 6, kept
/// from stompy).
pub const enter_retries_max: u32 = 64;

/// The most kernel worker threads of each kind, bounded and unbounded, the ring may start
/// (`IORING_REGISTER_IOWQ_MAX_WORKERS`). Version one is built to need them rarely, and the cap
/// keeps a hidden pool from growing without bound (decision 4, How cores talk).
pub const kernel_workers_max: u32 = 2;

/// The `user_data` of a completion the backend consumes itself and turns into no event: the
/// kernel's answer to a cancel request. Its generation half is 0, which no `Handle` has.
pub const user_data_cancel: u64 = 1;

/// The `user_data` of the cancel a `close` issues for every operation of its descriptor before
/// the close itself (decision 5, rule 6). Consumed like `user_data_cancel`.
pub const user_data_close_cancel: u64 = 2;

/// The `user_data` of a wake: the `IORING_OP_MSG_RING` a post sends a target that sleeps, which
/// carries no message (decision 4, amended 2026-09-25). The target's completion and the sender's
/// answer both carry it, and both reaps drop it, as they drop `user_data_cancel`.
pub const user_data_wake: u64 = 3;

/// Submission entries the ring a `Remote` creates holds: it submits only wakes, one at a time, in
/// an enter of its own, so one is enough, and the kernel's completion ring of two holds the answers
/// the next wake drops before it is submitted.
pub const remote_entries: u16 = 1;

/// The largest errno Linux returns, `core`'s, as the signed result a completion carries. A
/// completion's result in [-errno_max, -1] is an operation that failed.
pub const errno_max: i32 = @import("core").constants.errno_max;

comptime {
    const assert = std.debug.assert;
    assert(std.math.isPowerOfTwo(entries_max));
    assert(remote_entries >= 1);
    assert(remote_entries <= entries_max);
    assert(std.math.isPowerOfTwo(remote_entries));
    assert(enter_retries_max >= 1);
    assert(kernel_workers_max >= 1);
    assert(user_data_cancel >> 32 == 0);
    assert(user_data_close_cancel >> 32 == 0);
    assert(user_data_cancel != user_data_close_cancel);
    assert(user_data_wake >> 32 == 0);
    assert(user_data_wake != user_data_cancel and user_data_wake != user_data_close_cancel);
}
