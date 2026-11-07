//! A library cancels every operation of the loop it shares, through its view of the loop.
//! `zig build test-compile-fail` requires this file to fail to compile with the message of
//! `SharedLoop.cancel_all` (decision 28).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop) void {
    shared.cancel_all();
}

test "a library cancels every operation of the loop it shares" {
    _ = &library;
}
