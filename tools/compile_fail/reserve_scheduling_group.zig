//! A library reserves a scheduling group of the loop it shares.
//! `zig build test-compile-fail` requires this file to fail to compile with the message of `SharedLoop.reserve_scheduling_group`: shares are the program's
//! policy (decision 30).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop, task: *rotor.Task) void {
    _ = shared.reserve_scheduling_group(100) catch {};
}

test "a library reserves a scheduling group" {
    _ = &library;
}
