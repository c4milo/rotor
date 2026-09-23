//! What every backend's `Remote` shares: the errors `init` and `post` return, and the rules a
//! `Remote` keeps (decision 4, "What another thread may do"). A `Remote` is what a thread that
//! owns no loop holds so it can post a message to a loop.
//!
//! Each backend has its own `Remote`, because the mechanism belongs to its kernel: on kqueue it
//! is the producer end of a mailbox pair, and on io_uring it is a small ring that submits
//! `MSG_RING`. The shared part is here, so one conformance suite drives both (decision 10).
//!
//! A `Remote` returns errors where a loop's `post` produces events. A loop that posts gets a
//! final event with a code such as `mailbox_full` (decision 5, rule 1). A `Remote` owns no loop,
//! so it has no event stream: the return value is the completion. Where the condition is one a
//! loop's `post` also reports, the error has the name `event.error_of` gives that code.
//!
//! A `Remote` sends and never receives. It holds a `LoopId`, so a message can name its sender,
//! and it counts against `constants.loops_max` as decision 4 says, but it publishes no queue. A
//! loop that posts to a remote's id is answered `loop_not_found`, as for any id that runs no loop.
//!
//! A `Remote` belongs to one thread, as a loop does. Every backend records the thread at `init`
//! and halt a `post` or `deinit` from another thread, with the compare `core/tables.zig` makes
//! for a loop.
const std = @import("std");

/// What `Remote.post` answers.
pub const PostError = error{
    /// The target's queue had no room. Nothing was sent, and the caller may try again. On kqueue
    /// the queue is a mailbox of `mailbox_messages`. On io_uring it is the target's completion
    /// ring, which under `IORING_FEAT_NODROP` overflows into a kernel list, so this is answered
    /// only when the kernel cannot allocate the overflow entry. `post_bounded` on each backend
    /// says which of the two it is.
    MailboxFull,
    /// The target names no running loop: an id at or above the count the registry was sized for,
    /// a loop that has not started or has stopped, or another `Remote`.
    LoopNotFound,
    /// io_uring only: the kernel had no memory for the request that carries the message. Nothing
    /// was sent, and the caller may try again. kqueue never answers it.
    SystemResources,
    /// io_uring only: the kernel took the message and had not answered when the post's wait ran
    /// out (`uring/constants.zig`, `remote_wait_ns`). The message may still land, so a caller that
    /// posts it again may deliver it twice. Until the answer arrives, every later post through this
    /// `Remote` is refused with this error and sends nothing. The answer, when it comes, is read
    /// and dropped: its caller has already been told this. kqueue never answers it.
    Unanswered,
    /// io_uring only: the kernel answered with an errno rotor has no meaning for, or refused the
    /// `io_uring_enter` call itself. kqueue never answers it.
    Unexpected,
};

/// What `Remote.init` answers. On io_uring it creates a ring, which the kernel can refuse, and
/// the four errors are the ones `Loop.init` reports for the same call. On kqueue it creates
/// nothing and cannot fail; it takes the same set so the two surfaces match.
pub const InitError = error{
    /// The host has no io_uring, or its io_uring lacks a flag or an opcode rotor needs.
    Unsupported,
    PermissionDenied,
    /// A descriptor or memory limit refused the ring. The caller may try again later.
    SystemResources,
    Unexpected,
};

const testing = std.testing;

test "the errors a post shares with a loop's post carry the names of the matching codes" {
    // A caller that moves work off the loop thread meets the names it knows from a loop's own
    // post: `event.error_of` gives them. The set adds `Unanswered`, which a loop cannot report
    // because a loop never waits for a post's answer.
    const event = @import("event.zig");
    try testing.expectEqual(PostError.MailboxFull, event.error_of(.mailbox_full));
    try testing.expectEqual(PostError.LoopNotFound, event.error_of(.loop_not_found));
    try testing.expectEqual(PostError.SystemResources, event.error_of(.system_resources));
    try testing.expectEqual(PostError.Unexpected, event.error_of(.unexpected));
    const fields = @typeInfo(PostError).error_set.?;
    try testing.expectEqual(@as(usize, 5), fields.len);
}
