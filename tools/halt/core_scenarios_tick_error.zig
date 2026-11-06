//! Halt scenarios for the error a tick keeps (decision 5, amendment of 2026-11-06). Only rotor's
//! own code reaches the assertion: a tick takes a kept error before it can keep another. The
//! scenario reaches it through the function's own parameter, the `Kept` it is called on. Split from
//! `core_scenarios.zig` for the 500-line limit.
//!
//! With the assertion deleted, `keep` replaces the first error and returns the events.
const core = @import("core");
const scenario = @import("scenario.zig");

const Kept = core.tick_error.Kept(error{Unexpected});

fn keep_an_error_while_one_is_kept() void {
    var dispatch: core.dispatch.Dispatch = .empty;
    var kept: Kept = .none;
    _ = kept.keep(&dispatch, error.Unexpected, 1) catch unreachable;
    scenario.reached_violation();
    _ = kept.keep(&dispatch, error.Unexpected, 1) catch unreachable;
}

pub const scenarios = [_]scenario.Scenario{
    .{
        .name = "tick error: keep an error while one is kept",
        .run = keep_an_error_while_one_is_kept,
    },
};
