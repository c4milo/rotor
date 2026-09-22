//! The `epoll` module: the second Linux backend (decision 20), for a host that refuses io_uring. It
//! imports `core` and nothing else.
//!
//! epoll reports readiness, so this backend is `kqueue`'s shape and not `uring`'s: it performs each
//! operation itself when the descriptor is ready, and emulates multishot and provided buffer groups
//! in user space because epoll has neither. The conformance suite runs against it unchanged, and in
//! Docker under the default seccomp profile, which is the environment that justifies it.
//!
//! **No speed claim is made for this backend.** epoll has none of decision 3's speed sources: no
//! registered descriptors, no provided buffer rings, no multishot, no batched submission. It exists
//! so that rotor runs where io_uring does not, and the comparison gains no row for it.
//!
//! **Under construction.** Decision 20 was accepted on 2026-09-22 and this module is being built
//! organ by organ, `kqueue`'s file by `kqueue`'s file. What is here compiles and is tested; what is
//! not here yet is listed at the end of this comment, so nobody reads the module as finished.
//!
//! Built: `constants.zig`, `epoll_queue.zig`.
//!
//! Not built: the loop and its state, submit, reap, perform, cancel, tick, the waiters table, the
//! mailbox and `Remote`, the buffer groups, the datagram path, the offload, the sync helpers, and
//! `supported` becoming true. Until the last of those, `supported` stays false and the conformance
//! suite skips this backend everywhere, so no gate can pass by accident.
const std = @import("std");

pub const constants = @import("constants.zig");
pub const queue_module = @import("epoll_queue.zig");

/// Whether this backend's file operations block the loop thread, which is what decides whether
/// `Options.file_policy` and an offload mean anything here. epoll reports readiness and never
/// reports a regular file as anything but ready, exactly as kqueue does not report one at all, so
/// this backend makes the `pread`, `pwrite` and `fsync` calls itself and they block the loop thread
/// (decisions 18 and 20).
pub const files_block = true;

/// Whether a `post` can be refused for lack of room at the target (decision 4). The mailbox rings
/// are `core`'s and hold `constants.mailbox_messages`, as on every backend, so a post to a full one
/// is refused with `mailbox_full`.
pub const post_bounded = true;

/// True on a host whose kernel this backend can run on, and only once it can actually run there.
/// **False while the module is under construction**: the conformance suite skips a backend that says
/// false, and a half-built backend that claimed a host would let a gate pass on nothing.
pub const supported = false;

/// What `supported` will read when the module is finished: Linux, where epoll is.
pub const supported_when_built = @import("builtin").os.tag == .linux;

test {
    _ = constants;
    _ = queue_module;
}
