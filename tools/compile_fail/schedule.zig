//! A library queues a task with no group, through its view of the loop.
//! `zig build test-compile-fail` requires this file to fail to compile with the message of `SharedLoop.schedule`: a library names its group in each call
//! (decision 30).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop, task: *rotor.Task) void {
    shared.schedule(task) catch {};
}

test "a library queues a task with no group" {
    _ = &library;
}
