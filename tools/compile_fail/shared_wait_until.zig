//! A library bounds the wait of the reactor it shares with the plain loop's call.
//! `zig build test-compile-fail` requires this file to fail to compile with the message of
//! `SharedLoop.wait_until`: a library bounds the wait with a poller (decision 33).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop) void {
    shared.wait_until(.now);
}

test "a library bounds the wait of the reactor it shares with wait_until" {
    _ = &library;
}
