//! Halt scenarios for a loop's `post` with no operation (decision 4, amended 2026-09-29): each
//! backend's `Loop.post` hands its checks to `core.remote.post_now`, so a scenario reaches them
//! through that function's parameters. Split from `core_scenarios.zig` for the 500-line limit.
//!
//! The registry is null, as for a loop that has none. With an assertion deleted, `post_now`
//! answers `LoopNotFound` and returns.
const core = @import("core");
const scenario = @import("scenario.zig");

const message: core.Message = .{ .payload = 1, .tag = 1 };

/// A loop that posts to itself: nothing but its own tick could hand the message over.
fn post_to_the_loop_itself() void {
    scenario.reached_violation();
    _ = core.remote.post_now(null, 3, 3, message) catch {};
}

fn post_a_tag_above_the_limit_with_no_operation() void {
    const above: core.Message = .{ .payload = 1, .tag = core.constants.message_tag_max + 1 };
    scenario.reached_violation();
    _ = core.remote.post_now(null, 0, 1, above) catch {};
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "post: post to the loop itself", .run = post_to_the_loop_itself },
    .{
        .name = "post: post a tag above the limit with no operation",
        .run = post_a_tag_above_the_limit_with_no_operation,
    },
};
