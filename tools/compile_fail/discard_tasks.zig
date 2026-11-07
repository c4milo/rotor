//! A library discards the task queue of the loop it shares, through its view of the loop.
//! `zig build test-compile-fail` requires this file to fail to compile with the message of
//! `SharedLoop.discard_tasks` (decision 28).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop) void {
    _ = shared.discard_tasks();
}

test "a library discards the task queue of the loop it shares" {
    _ = &library;
}
