//! Halt scenarios for the `epoll` module that need a Linux kernel. `zig build test-linux` builds
//! this file and `tools/halt_check.zig` for Linux, and `tools/linux_test.sh` runs the check on it
//! in Docker under the default seccomp profile, which refuses io_uring: the environment the epoll
//! backend exists for (decision 20). `zig build halt-check` does not run it.
//!
//! A scenario proves an assertion only if the scenario returns once that assertion is deleted. Each
//! scenario here runs on a loop with a real epoll instance (`Loop.init`), so with the assertion
//! deleted the loop makes its Linux calls and the scenario returns. On a Mac those calls run other
//! system calls (`epoll_scenarios.zig`), and that is why the scenarios are here.
const std = @import("std");
const core = @import("core");
const epoll = @import("epoll");
const scenario = @import("scenario.zig");

const Loop = epoll.Loop;

const options: Loop.Options = .{ .operations = 4, .entries = 4 };

var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
var loop: Loop = undefined;

/// A loop belongs to the thread that initialised it (decision 4). An epoll instance has no owning
/// thread, so with the owner check deleted the second thread's `epoll_pwait2` returns at once with
/// nothing ready, `tick` returns 0, and the scenario returns.
fn tick_from_another_thread() void {
    loop.init(&memory, options) catch return;
    const thread = std.Thread.spawn(.{}, tick_on_this_thread, .{}) catch return;
    thread.join();
}

fn tick_on_this_thread() void {
    var events: [1]core.Event = undefined;
    scenario.reached_violation();
    _ = loop.tick(&events, 0) catch {};
}

/// A descriptor no process has open. It is high rather than 0 so that `fcntl` answers `EBADF` for
/// it, whatever the container left open.
const closed_descriptor: core.Descriptor = 4096;

/// With the owner check deleted, the second thread's `fcntl` of the closed descriptor fails,
/// `register_descriptors` returns `DescriptorInvalid`, and the scenario returns.
fn register_descriptors_from_another_thread() void {
    loop.init(&memory, options) catch return;
    const thread = std.Thread.spawn(.{}, register_descriptors_on_this_thread, .{}) catch return;
    thread.join();
}

fn register_descriptors_on_this_thread() void {
    const descriptors = [_]core.Descriptor{closed_descriptor};
    scenario.reached_violation();
    loop.register_descriptors(&descriptors) catch {};
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "owner: tick from another thread", .run = tick_from_another_thread },
    .{
        .name = "owner: register descriptors from another thread",
        .run = register_descriptors_from_another_thread,
    },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
