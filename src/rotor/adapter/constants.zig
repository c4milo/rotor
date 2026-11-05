//! The adapter's named limits (decision 22). The adapter lives in the public module, which has no
//! `constants.zig` of its own, so its limits are here, beside its files.
const std = @import("std");
const assert = std.debug.assert;

/// The most fibers one adapter holds. A fiber's index is a `u16`, and the main context takes
/// index 0, so the limit stays below the largest `u16`, which names no fiber.
pub const fibers_max: u16 = 4096;

/// A stack is a whole number of these bytes, and the memory `init` takes is aligned to it. It is
/// a multiple of every page size rotor's hosts use, 4 KiB, 16 KiB and 64 KiB, so a guard page
/// below each stack can be protected on its own (decision 22, open question 3).
pub const stack_granule_bytes: u32 = 64 * 1024;

/// The smallest stack a fiber takes: one granule. The top of each stack also holds the task's
/// arguments and its result, `closure_bytes`.
pub const stack_bytes_min: u32 = stack_granule_bytes;

/// The largest stack a fiber takes. std's `Kqueue` gives each fiber at least 4 MiB; this allows
/// sixteen times that.
pub const stack_bytes_max: u32 = 64 * 1024 * 1024;

/// The most bytes of arguments `async`, `concurrent` and the group calls copy to a fiber. A task
/// with more runs inline under `async`, and is refused under `concurrent`.
pub const context_bytes_max: u32 = 1024;

/// The most bytes of result a task returns through its fiber. A larger result runs inline under
/// `async`, and is refused under `concurrent`.
pub const result_bytes_max: u32 = 512;

/// The alignment of the arguments and the result at the top of a stack, and the most either may
/// ask for. It is also the stack alignment System V and AAPCS64 require.
pub const closure_alignment: u32 = 16;

/// The bytes at the top of each stack that hold the arguments and the result.
pub const closure_bytes: u32 = context_bytes_max + result_bytes_max;

/// The most events one tick of the adapter hands over.
pub const events_per_tick: u32 = 64;

/// The top 16 bits of the `user_data` of every operation the adapter submits. An event whose
/// top 16 bits differ belongs to the caller's own operations, and goes to the caller's handler.
pub const user_data_tag: u64 = 0xADA7 << user_data_tag_shift;

/// Where the tag starts in `user_data`. The bits below it hold the fiber's index.
pub const user_data_tag_shift: u6 = 48;

comptime {
    assert(fibers_max < std.math.maxInt(u16));
    assert(stack_granule_bytes % (16 * 1024) == 0);
    assert(stack_bytes_min % stack_granule_bytes == 0);
    assert(stack_bytes_max % stack_granule_bytes == 0);
    assert(closure_bytes % closure_alignment == 0);
    assert(closure_bytes < stack_bytes_min / 4);
    assert(@as(u64, fibers_max) < (@as(u64, 1) << user_data_tag_shift));
}
