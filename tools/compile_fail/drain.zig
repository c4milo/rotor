//! A library drains the loop it shares, through its view of the loop.
//! `zig build test-compile-fail` requires this file to fail to compile with the message of
//! `SharedLoop.drain` (decision 28).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop) void {
    var events: [1]rotor.Event = undefined;
    shared.drain(&events) catch {};
}

test "a library drains the loop it shares" {
    _ = &library;
}
