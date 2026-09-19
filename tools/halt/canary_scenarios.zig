//! The canary of the halt check: scenarios that must make `tools/halt_check.zig` FAIL, so the
//! build can show the check refuses what it should. The first violates nothing and runs to its
//! end. The second dies before it reaches its violation, which is a crash and not a halt of the
//! assertion under test.
const std = @import("std");
const scenario = @import("scenario.zig");

fn violates_nothing() void {
    scenario.reached_violation();
}

fn dies_during_its_set_up() void {
    unreachable;
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "canary: violates nothing", .run = violates_nothing },
    .{ .name = "canary: dies during its set-up", .run = dies_during_its_set_up },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
