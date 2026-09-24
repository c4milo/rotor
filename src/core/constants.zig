//! Every named limit of the `core` module. A limit two modules share lives here; a comptime
//! assert stays with the constant it pins. `core` may not name `std.time` (tools/lint
//! determinism), so the time units it needs are declared here.
const std = @import("std");

pub const ns_per_us: u64 = 1_000;
pub const ns_per_ms: u64 = 1_000 * ns_per_us;
pub const ns_per_s: u64 = 1_000 * ns_per_ms;
const seconds_per_day: u64 = 24 * 60 * 60;

/// The size and the alignment in bytes of one `Slot`, the record of one in-flight operation: one
/// cache line of the x86-64 servers rotor targets, and half of one on Apple silicon, which
/// reports 128 (decision 3, source 7). `slot.zig` holds the struct to it with a comptime assert.
pub const slot_bytes: u32 = 64;

/// The size in bytes of one `Event`: the size of an io_uring completion entry, so a reap of 32
/// events reads 512 contiguous bytes (decision 1). `event.zig` holds the struct to it.
pub const event_bytes: u32 = 16;

/// The most operations one loop may hold in flight, which is the most slots `init` may be asked
/// for. 2^20 slots are 64 MiB of table. A slot index is 32 bits, so the ceiling is far above it.
pub const operations_max: u32 = 1 << 20;

/// The most operations one `submit` call takes, and the most events one `tick` call returns.
pub const batch_max: u32 = 4096;

/// Entries of the table that maps a descriptor to the operations waiting on it, per slot of the
/// slot table: two, so the open-addressing table of `waiters.zig` stays at most half full
/// (decision 12, point 2). Both readiness backends read it, which is why it is here.
pub const descriptor_entries_per_slot: u32 = 2;

/// Messages one mailbox ring of `mailbox.zig` holds, a power of two. A sender that finds its ring
/// to a loop full hears `mailbox_full` (decision 12, point 6). Both readiness backends read it.
pub const mailbox_messages: u32 = 256;

/// Messages a readiness loop moves out of one ring at a time, from another loop's mailbox or from
/// an offload worker's. A ring that still holds messages then is drained by the next tick, which
/// does not wait while one does.
pub const messages_per_drain: u32 = 32;

/// The alignment that keeps a mailbox's producer index and consumer index on separate cache
/// lines: Apple silicon reports 128-byte lines, and 128 also clears the 64-byte lines of x86-64.
pub const mailbox_index_alignment = 128;

/// Children per node of the timer heap (decision 5, rule 5).
pub const timer_heap_arity: u32 = 4;

/// The first generation a slot carries. Generation 0 is never valid, so the all-zero `Handle`
/// names no operation, and no kernel `user_data` rotor writes is 0.
pub const generation_first: u32 = 1;

/// The longest one `tick` may block, in nanoseconds.
pub const wait_ns_max: u64 = 10 * ns_per_s;

/// The longest spin budget a loop may be given, in nanoseconds: how long a tick may poll without
/// waiting before it blocks (decision 13). A millisecond is twenty times the 50 µs that record
/// measured, and a thousand times what a cross-core message costs a loop that is awake (C19), so a
/// longer budget buys nothing but burnt CPU.
pub const spin_budget_ns_max: u64 = ns_per_ms;

/// The most polls one spin makes. Each poll is a whole tick without a wait, which reads the clock at
/// least once, so a spin as long as `spin_budget_ns_max` makes far fewer than this. The bound keeps
/// the loop finite if the clock stood still.
pub const spin_rounds_max: u32 = 100_000;

/// The longest deadline an operation may carry and the longest timer, in nanoseconds: one day. A
/// longer wait is the application's to build from shorter ones, and the bound keeps every
/// deadline sum far below what 64 bits hold.
pub const timeout_ns_max: u64 = seconds_per_day * ns_per_s;

/// The most bytes one transfer may name. Linux caps one read or write at 2^31 - 4096 bytes
/// (recalled: `MAX_RW_COUNT`), and a rotor result is a non-negative `i32`.
pub const transfer_bytes_max: u32 = 0x7fff_f000;

/// The most loops and remotes one process may hold, which bounds a `LoopId` (decision 4).
pub const loops_max: u16 = 256;

/// The most worker threads a caller's offload may have, which is the mailboxes a loop holds for it
/// (decision 18). One ring per worker keeps each a single-producer queue, so the hand-back needs no
/// multi-producer structure and no lock. A caller with more threads than this runs more loops.
pub const offload_workers_max: u16 = 64;

/// The largest tag a `Message` may carry. io_uring delivers a posted message as a completion
/// whose 32-bit result is the sender's to choose, and a result in [-4095, -1] is an errno. The
/// uring backend sets the top bit of the tag, so a message's result is below -4095 and never
/// reads as an operation's. A tag at or below this value leaves that range clear on Linux 5.18
/// and later, with no kernel flag to depend on.
pub const message_tag_max: u32 = 0x7fff_f000;

/// The most ticks one `drain` makes before it gives up, each waiting `drain_wait_ns` at most. A
/// cancelled operation ends within a tick or two, so a loop that is still not empty after this
/// many holds an operation the kernel will not give back.
pub const drain_rounds_max: u32 = 1024;
pub const drain_wait_ns: u64 = 10 * ns_per_ms;

/// Buckets a sampled latency falls in, one per power of two of nanoseconds (decision 9). The
/// last holds everything above it, and 2^31 nanoseconds is 2.1 seconds, past which a latency is
/// a fault and not a measurement.
pub const latency_buckets: u32 = 32;

/// One operation in 32 is sampled unless the caller says otherwise: the Hints' advice, and what
/// decision 9 costs its arithmetic with. A mask, so the test is one AND and one compare.
pub const sample_mask_default: u32 = 31;

/// Descriptors one loop can register (`register_descriptors`). An operation names one by its
/// index, which a 16-bit field would hold many times over; the limit is what fits the oldest
/// io_uring table, 1,024 entries (recalled), so one number holds on every kernel from the floor up.
pub const registered_descriptors_max: u32 = 1024;

/// Times a backend resubmits one operation after the kernel completes it with EAGAIN or EINTR
/// having transferred nothing, before the caller hears of it (decision 6, kept from stompy).
pub const transfer_retries_max: u8 = 16;

/// The most buffers one loop may register (decision 3, source 1).
pub const registered_buffers_max: u16 = 1024;

/// The most provided-buffer groups one loop may hold, and the most buffers in one group. 32768 is
/// the most entries an io_uring buffer ring takes (recalled).
pub const buffer_groups_max: u16 = 16;
pub const buffers_per_group_max: u16 = 32768;

/// The alignment of the memory a provided-buffer group sits in. io_uring's buffer ring sits at the
/// front of it, and the kernel wants that aligned to a page. A page is 4, 16 or 64 KiB depending on
/// how the kernel was built, so rotor asks for the largest and is right on all three. kqueue and
/// epoll ask for the same, so one declaration in a caller's code serves every backend.
pub const buffer_ring_alignment = 64 * 1024;

/// The bytes of bookkeeping per buffer of a group: the size of one entry of an io_uring buffer
/// ring, so every backend asks a caller for the same amount. `uring_buffers.zig` asserts the size.
pub const buffer_ring_entry_bytes = 16;

/// Times kqueue and epoll make a system call again after a signal interrupted it (EINTR) before
/// they report the operation as failed. A signal storm is the only way to reach it.
pub const interrupt_retries_max: u32 = 64;

/// The largest size `sync.set_buffer_bytes` carries for a socket buffer, which is what
/// `setsockopt` takes. It is not a size any kernel grants: each refuses or caps long before it, in
/// its own way, which is what the call answers and `SizeRefused` reports.
pub const socket_buffer_bytes_max: u32 = std.math.maxInt(i32);

/// The largest errno Linux returns, so the most negative result an operation can have.
pub const errno_max: u32 = 4095;

comptime {
    const assert = std.debug.assert;
    assert(std.math.isPowerOfTwo(slot_bytes));
    assert(std.math.isPowerOfTwo(event_bytes));
    assert(operations_max >= batch_max);
    assert(batch_max >= 1);
    assert(timer_heap_arity >= 2);
    assert(descriptor_entries_per_slot >= 2);
    assert(std.math.isPowerOfTwo(mailbox_messages));
    assert(mailbox_messages % messages_per_drain == 0);
    assert(std.math.isPowerOfTwo(mailbox_index_alignment));
    assert(generation_first >= 1);
    assert(timeout_ns_max >= wait_ns_max);
    assert(spin_budget_ns_max < wait_ns_max);
    assert(spin_rounds_max >= 1);
    assert(transfer_bytes_max <= std.math.maxInt(i32));
    assert(loops_max >= 2);
    assert(message_tag_max < 1 << 31);
    assert((1 << 31) - message_tag_max > errno_max);
    assert(transfer_retries_max >= 1);
    assert(std.math.isPowerOfTwo(buffers_per_group_max));
    assert(std.math.isPowerOfTwo(buffer_ring_alignment));
    assert(buffer_ring_entry_bytes >= @sizeOf(u16));
    assert(interrupt_retries_max >= 1);
}

test "the hot structure sizes are one cache line and one completion entry" {
    try std.testing.expectEqual(64, slot_bytes);
    try std.testing.expectEqual(16, event_bytes);
}

/// Datagrams one segmented send may be cut into (decision 15). A QUIC stack sends a burst and
/// not a stream, and a kernel that refuses a larger count answers EINVAL after the loop has
/// already claimed a slot, so the limit is rotor's and is checked before the kernel sees it.
pub const segments_max: u32 = 64;
