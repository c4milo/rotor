//! A library ends the loop it shares, through its view of the loop.
//! `zig build test-compile-fail` requires this file to fail to compile with the message of
//! `SharedLoop.deinit` (decision 28).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop) void {
    shared.deinit();
}

test "a library ends the loop it shares" {
    _ = &library;
}
