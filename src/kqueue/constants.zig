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

comptime {
    const assert = std.debug.assert;
    assert(changes_max >= 1);
    assert(readiness_max >= 1);
    assert(descriptor_entries_per_slot >= 2);
    assert(std.math.isPowerOfTwo(mailbox_messages));
    assert(std.math.isPowerOfTwo(mailbox_index_alignment));
}
