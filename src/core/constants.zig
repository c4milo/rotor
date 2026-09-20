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

/// Children per node of the timer heap (decision 5, rule 5).
pub const timer_heap_arity: u32 = 4;

/// The first generation a slot carries. Generation 0 is never valid, so the all-zero `Handle`
/// names no operation, and no kernel `user_data` rotor writes is 0.
pub const generation_first: u32 = 1;

/// The longest one `tick` may block, in nanoseconds.
pub const wait_ns_max: u64 = 10 * ns_per_s;

/// The longest deadline an operation may carry and the longest timer, in nanoseconds: one day. A
/// longer wait is the application's to build from shorter ones, and the bound keeps every
/// deadline sum far below what 64 bits hold.
pub const timeout_ns_max: u64 = seconds_per_day * ns_per_s;

/// The most bytes one transfer may name. Linux caps one read or write at 2^31 - 4096 bytes
/// (recalled: `MAX_RW_COUNT`), and a rotor result is a non-negative `i32`.
pub const transfer_bytes_max: u32 = 0x7fff_f000;

/// The most loops and remotes one process may hold, which bounds a `LoopId` (decision 4).
pub const loops_max: u16 = 256;

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

/// Times a backend resubmits one operation after the kernel completes it with EAGAIN or EINTR
/// having transferred nothing, before the caller hears of it (decision 6, kept from stompy).
pub const transfer_retries_max: u8 = 16;

/// The most buffers one loop may register (decision 3, source 1).
pub const registered_buffers_max: u16 = 1024;

/// The most provided-buffer groups one loop may hold, and the most buffers in one group. 32768 is
/// the most entries an io_uring buffer ring takes (recalled).
pub const buffer_groups_max: u16 = 16;
pub const buffers_per_group_max: u16 = 32768;

/// The largest errno Linux returns, so the most negative result an operation can have.
const errno_max: u32 = 4095;

comptime {
    const assert = std.debug.assert;
    assert(std.math.isPowerOfTwo(slot_bytes));
    assert(std.math.isPowerOfTwo(event_bytes));
    assert(operations_max >= batch_max);
    assert(batch_max >= 1);
    assert(timer_heap_arity >= 2);
    assert(generation_first >= 1);
    assert(timeout_ns_max >= wait_ns_max);
    assert(transfer_bytes_max <= std.math.maxInt(i32));
    assert(loops_max >= 2);
    assert(message_tag_max < 1 << 31);
    assert((1 << 31) - message_tag_max > errno_max);
    assert(transfer_retries_max >= 1);
    assert(std.math.isPowerOfTwo(buffers_per_group_max));
}

test "the hot structure sizes are one cache line and one completion entry" {
    try std.testing.expectEqual(64, slot_bytes);
    try std.testing.expectEqual(16, event_bytes);
}
