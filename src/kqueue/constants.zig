//! Every named limit of the `kqueue` module. A limit `core` also reads lives in `core`.
const std = @import("std");

/// The most registrations one `kevent` call carries in, and the most readiness events it carries
/// out. A tick makes one call, so operations that must wait beyond this many stay queued for the
/// next tick.
pub const changes_max: u32 = 256;
pub const readiness_max: u32 = 256;

/// Entries of the table that maps a descriptor to the operations waiting on it, per slot of the
/// slot table: two, so the open-addressing table stays at most half full (decision 12, point 2).
pub const descriptor_entries_per_slot: u32 = 2;

/// Messages one mailbox ring holds, a power of two. A sender that finds its ring to a loop full
/// hears `mailbox_full` (decision 12, point 6).
pub const mailbox_messages: u32 = 256;

/// The alignment that keeps a mailbox's producer index and consumer index on separate cache
/// lines: Apple silicon reports 128-byte lines, and 128 also clears the 64-byte lines of x86-64.
pub const mailbox_index_alignment = 128;

/// The alignment of the memory a provided-buffer group's bookkeeping sits in: what the uring
/// backend asks for its buffer ring, so one declaration in a caller's code serves both.
pub const buffer_ring_alignment = 64 * 1024;

/// The bytes of bookkeeping per buffer of a group: the size of one entry of an io_uring buffer
/// ring, so both backends ask a caller for the same amount.
pub const buffer_ring_entry_bytes = 16;

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
    assert(descriptor_entries_per_slot >= 2);
    assert(std.math.isPowerOfTwo(mailbox_messages));
    assert(std.math.isPowerOfTwo(mailbox_index_alignment));
}
