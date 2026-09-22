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

/// The alignment of the memory a provided-buffer ring sits in. The kernel wants it aligned to a
/// page, and a page is 4, 16 or 64 KiB depending on how the kernel was built, so rotor asks for
/// the largest and is right on all three.
pub const buffer_ring_alignment = 64 * 1024;

/// Submission entries the ring a `Remote` creates holds (decision 4, "a small ring created for that
/// thread, used only to submit `MSG_RING`"). One, derived and not chosen: a `Remote.post` submits
/// one entry and does not submit another until the kernel has answered it, which `Remote.unanswered`
/// keeps true when the answer is late, so one is enough and the kernel's completion ring of two
/// holds the one answer. A batching mode would change this limit and that field together.
pub const remote_entries: u16 = 1;

/// How long a `Remote.post` waits for the kernel's answer to its `MSG_RING`. On Linux 6.1 and on
/// 6.10 and later the answer is posted inside the `io_uring_enter` that submits, and the wait is
/// nothing. On 6.3 to 6.9 the answer waits for the target's thread to run once (recalled from
/// `io_uring/msg_ring.c`), which takes a scheduling delay, so a second is passed only by a thread
/// that is stopped or starved. After it, the post is `Unanswered` and the message may still land.
pub const remote_wait_ns: u64 = 1 * @import("core").constants.ns_per_s;

/// The largest errno Linux returns. A completion's result in [-errno_max, -1] is an operation
/// that failed; a result below that range is a message another loop posted.
pub const errno_max: i32 = 4095;

/// The bit a `post` sets in the 32 bits io_uring delivers as the message's result, above the tag.
/// It makes the result negative and below `-errno_max` for every tag `core` admits, so the reap
/// tells a message from a failed operation by one compare, on any kernel that has `MSG_RING`.
pub const message_result_flag: u32 = 1 << 31;

comptime {
    const assert = std.debug.assert;
    const tag_max = @import("core").constants.message_tag_max;
    const lowest_message_result: i32 = @bitCast(tag_max | message_result_flag);
    assert(lowest_message_result < -errno_max);
    assert(tag_max & message_result_flag == 0);
    assert(std.math.isPowerOfTwo(entries_max));
    assert(remote_entries >= 1);
    assert(remote_entries <= entries_max);
    assert(std.math.isPowerOfTwo(remote_entries));
    assert(remote_wait_ns >= 1);
    assert(remote_wait_ns <= @import("core").constants.wait_ns_max);
    assert(std.math.isPowerOfTwo(buffer_ring_alignment));
    assert(enter_retries_max >= 1);
    assert(kernel_workers_max >= 1);
    assert(user_data_cancel >> 32 == 0);
    assert(user_data_close_cancel >> 32 == 0);
    assert(user_data_cancel != user_data_close_cancel);
}
