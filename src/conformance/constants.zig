//! Every named limit of the `conformance` module that more than one scenario file reads.
const std = @import("std");
const core = @import("core");

/// The most CPU time that one record, poller or task callback of a scenario may use, in
/// nanoseconds. A callback that uses more holds the loop, and `conformance_stall.zig` fails the
/// scenario. Seastar reports such a task as a reactor stall. rotor's bound on a run of tasks is in
/// tasks and not in time (decision 27), and `core` reads no clock, so the harness holds this check.
///
/// The callbacks of the scenarios count events, submit one operation or queue one task. Each of
/// these costs microseconds in Debug, and some tens of microseconds under ThreadSanitizer. The
/// check reads the thread's CPU clock, by Camilo's ruling of 2026-11-07 (decision 28, its amendment
/// of that day). It read the wall clock before, and other work on the machine then tripped it: on
/// `mac` at a load of 19 to 104, the kernel took a thread off the processor for a mean of 125 ms
/// and at most 844 ms. One callback measured 60.6 ms of wall time and 8 µs of CPU time. A callback
/// with a large job trips the limit. A callback that blocks in a wait does not trip it, because a
/// wait uses no CPU time: this check does not catch such a callback.
pub const callback_stall_ns_max: u64 = 50 * core.constants.ns_per_ms;

comptime {
    std.debug.assert(callback_stall_ns_max >= 10 * core.constants.ns_per_ms);
    std.debug.assert(callback_stall_ns_max < core.constants.ns_per_s);
}

/// The descriptors `conformance_registry.zig` counts, from 0: it asks the kernel whether each one is
/// open. The kernel gives each open the lowest number free. The scenario that holds the most,
/// `conformance_wake_reuse.zig`, holds about 130 (an estimate from its code, not measured), so
/// every number a scenario opens is below this. A count costs one call per descriptor, and a
/// registry's life counts twice.
pub const descriptors_counted_max: u32 = 1024;

comptime {
    std.debug.assert(descriptors_counted_max >= 256);
    std.debug.assert(descriptors_counted_max <= 1 << 16);
}

/// The loops of the registry of `conformance_fair.zig`: `L` of W3's main scenario. The loop under
/// test, one loop that never ticks, and three remotes that post to the loop under test. At this
/// count a sender with messages is visited within 4 ticks at `fair_events` (W3, section 3.6).
pub const fair_loops: u16 = 5;

/// The events of one tick of the loop under test in `conformance_fair.zig`: `N` of W3's main
/// scenario.
pub const fair_events: u32 = 64;

/// The slots of the loop under test in `conformance_fair.zig`. The harness loop has 64, too few to
/// keep the finished list long.
pub const fair_operations: u32 = 1024;

/// The posts the loop under test keeps in flight to the loop that never ticks. Each ends at the
/// flush, so the finished list holds about this many entries at each tick.
pub const fair_posts: u32 = 960;

/// The events of the tick of the give-back scenario, and the entries its finished list holds.
pub const fair_give_back_events: u32 = 16;

/// The 1-byte receives the loop under test of `conformance_fair_readiness.zig` keeps in flight on
/// one socket. Each one the flush completes inline.
pub const fair_inline_receives: u32 = 960;

/// The bytes the peer of `conformance_fair_readiness.zig` writes before the check. They fit the
/// default buffer of a socket pair (recalled, not measured).
pub const fair_backlog_bytes: u32 = 4096;

comptime {
    std.debug.assert(fair_loops >= 3);
    std.debug.assert(fair_events >= core.constants.fair_events_min);
    std.debug.assert(fair_events <= core.constants.batch_max);
    std.debug.assert(fair_posts + 2 <= fair_operations);
    std.debug.assert(fair_inline_receives + 2 <= fair_operations);
    std.debug.assert(fair_give_back_events >= core.constants.fair_events_min);
    std.debug.assert(fair_backlog_bytes >= fair_inline_receives);
}
