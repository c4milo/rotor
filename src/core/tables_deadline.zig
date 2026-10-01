//! When the tables' deadlines run: arming an operation's deadline or a timer's delay, where each
//! starts, and how long a tick may block before the nearest one. Split from `tables.zig` for the
//! 500-line limit; `Tables` declares each of these, so a caller writes `tables.arm(...)`.
const std = @import("std");
const assert = std.debug.assert;
const assert_class_a = @import("assertion_class.zig").assert_class_a;
const constants = @import("constants.zig");
const slot_module = @import("slot.zig");
const tables_module = @import("tables.zig");

const Slot = slot_module.Slot;
const Tables = tables_module.Tables;

/// Arms the deadline of a slot the backend has just handed to the kernel, or the delay of a timer.
/// A slot being resubmitted keeps the deadline it has.
pub fn arm(tables: *Tables, index: u32, slot: *Slot) void {
    const after_ns = if (slot.code == .timer) slot.offset else slot.timeout_ns;
    assert_class_a(after_ns <= constants.timeout_ns_max);
    if (slot.code != .timer and after_ns == 0) return;
    if (tables.timers.is_armed(index)) return;
    const due_ns = start_ns(tables, slot) + after_ns;
    // A repeating timer measures every later period from this deadline (decision 14, rule 3).
    if (slot.code == .timer) slot.buffer = due_ns;
    tables.timers.arm(index, due_ns);
}

/// When a delay or a deadline starts running. A timer's starts at the reading the caller saw when
/// it submitted the timer, which `submit` kept in `Slot.buffer`, as libuv's and libxev's timers
/// start at the loop's cached time: a timer re-armed while the caller works through a batch does
/// not also wait out the rest of the batch (decision 14, rule 6). A timer submitted before any
/// tick read the clock, and an operation's deadline, start at this tick's reading.
fn start_ns(tables: *const Tables, slot: *const Slot) u64 {
    if (slot.code != .timer or slot.buffer == 0) return tables.now_ns;
    // The clock only moves forward, so the reading at submit is at or before this one.
    assert(slot.buffer <= tables.now_ns);
    return slot.buffer;
}

/// How long a tick may block: not at all while queued work waits for the next flush, and never
/// past the nearest deadline. Null means do not block.
pub fn wait_bound(tables: *const Tables, wait_ns: u64) ?u64 {
    assert(wait_ns <= constants.wait_ns_max);
    if (wait_ns == 0) return null;
    if (tables.pending.count != 0 or tables.finished.count != 0) return null;
    const earliest = tables.timers.earliest_ns() orelse return wait_ns;
    if (earliest <= tables.now_ns) return null;
    return @min(wait_ns, earliest - tables.now_ns);
}
