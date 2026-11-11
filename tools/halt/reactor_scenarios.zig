//! Halt scenarios for the module `reactor` (decision 33): one per assertion of the reactor that a
//! caller's mistake can reach, and one per assertion a scenario reaches through a function's own
//! parameters. Each runs the reactor's state over a loop of the port alone, `Port` of
//! `reactor_scenarios_call.zig`, and enters no kernel. Moved from the core's scenarios at step 3 of
//! decision 33, when the code moved.
const std = @import("std");
const scenario = @import("scenario.zig");

const scenarios = @import("reactor_scenarios_dispatch.zig").scenarios ++
    @import("reactor_scenarios_tasks.zig").scenarios ++
    @import("reactor_scenarios_scheduling.zig").scenarios;

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
