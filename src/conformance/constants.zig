//! Every named limit of the `conformance` module that more than one scenario file reads.
const std = @import("std");
const core = @import("core");

/// The longest that one record, poller or task callback of a scenario may run, in nanoseconds.
/// A callback that runs longer holds the loop, and `conformance_stall.zig` fails the scenario.
/// Seastar reports such a task as a reactor stall. rotor's bound on a run of tasks is in tasks and
/// not in time (decision 27), and `core` reads no clock, so this check lives in the harness.
///
/// The callbacks of the scenarios count events, submit one operation or queue one task. Each of
/// these costs microseconds in Debug, and some tens of microseconds under ThreadSanitizer. A loaded
/// runner can take the thread away for a scheduler quantum or more: about 10 ms on macOS and a few
/// milliseconds on Linux (recalled, not measured). 50 ms is several quanta, so other work on the
/// machine does not trip the limit. A callback that blocks on a wait or on a large job trips it.
pub const callback_stall_ns_max: u64 = 50 * core.constants.ns_per_ms;

comptime {
    std.debug.assert(callback_stall_ns_max >= 10 * core.constants.ns_per_ms);
    std.debug.assert(callback_stall_ns_max < core.constants.ns_per_s);
}
