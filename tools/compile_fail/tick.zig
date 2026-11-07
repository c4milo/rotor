//! A library ticks the loop it shares, through its view of the loop.
//! `zig build test-compile-fail` requires this file to fail to compile with the message of
//! `SharedLoop.tick` (decision 28).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop) void {
    var events: [1]rotor.Event = undefined;
    _ = shared.tick(&events, 0) catch {};
}

test "a library ticks the loop it shares" {
    _ = &library;
}
