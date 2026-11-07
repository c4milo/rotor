//! Halt scenarios for the public module, `rotor`: the checks that `src/rotor/` makes itself, and
//! not through a backend's call. `Loop.shared` checks the thread itself, because it casts the loop
//! to the view without a call into the backend (decision 28).
//!
//! A scenario starts a loop of the host's backend on the main thread and calls into it from a
//! second thread. With its check deleted, each call returns, and each scenario says how.
const std = @import("std");
const rotor = @import("rotor");
const scenario = @import("scenario.zig");

const Loop = rotor.Loop;

const options: Loop.Options = .{ .operations = 4 };

var memory: [Loop.memory_bytes(&options)]u8 align(rotor.memory_alignment) = undefined;
var loop: Loop align(@alignOf(Loop)) = undefined;

/// Runs `call` on a second thread and waits for it. A scenario whose thread cannot start returns
/// without the marker, and the check counts that as a failure.
fn on_another_thread(comptime call: fn () void) void {
    const thread = std.Thread.spawn(.{}, call, .{}) catch return;
    thread.join();
}

/// `shared` from a second thread. With the check deleted, the call returns the view.
fn hand_out_the_view_from_another_thread() void {
    loop.init(&memory, &options) catch return;
    on_another_thread(hand_out_the_view_on_this_thread);
}

fn hand_out_the_view_on_this_thread() void {
    scenario.reached_violation();
    _ = loop.shared();
}

const scenarios = [_]scenario.Scenario{
    .{
        .name = "rotor: hand out the view from another thread",
        .run = hand_out_the_view_from_another_thread,
    },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
