//! A library changes the shares of a scheduling group of the loop it shares.
//! `zig build test-compile-fail` requires this file to fail to compile with the message of `SharedLoop.set_scheduling_group_shares` (decision 30).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop, task: *rotor.Task) void {
    shared.set_scheduling_group_shares(.default, 100);
}

test "a library changes the shares of a group" {
    _ = &library;
}
