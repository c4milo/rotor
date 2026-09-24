//! Decision 8's class A: the assertions that run once per operation on the submit, flush and reap
//! paths. Every build compiles them except `uring_nop_no_class_a`, the benchmark that measures what
//! they cost against `uring_nop_safe` (decision 8, The experiment, step 2). The switch arrives as
//! the `assertion_options` import, which `build/modules.zig` generates; build.zig offers no option
//! for it, so a consumer cannot turn an assertion off.
//!
//! The sites that call `assert_class_a` are the class A assertions a `nop` passes through on
//! io_uring, in `core` and `uring`. The per-operation assertions of the other kinds still call
//! `std.debug.assert`, so this switch measures the `nop` path and nothing wider (decision 8,
//! results of 2026-09-24).
const std = @import("std");

/// False only in the one benchmark build.
pub const enabled: bool = @import("assertion_options").class_a;

/// Asserts `ok`, as `std.debug.assert` does, in every build where `enabled` is true.
pub fn assert_class_a(ok: bool) void {
    if (enabled) std.debug.assert(ok);
}

test "every graph a test runs in compiles class A" {
    try std.testing.expect(enabled);
}
