//! A program bounds the wait of its reactor with the plain loop's call. `zig build test-compile-fail`
//! requires this file to fail to compile with the message of `Reactor.wait_until`: a reactor bounds
//! its wait with a poller (decision 33).
const rotor = @import("rotor");

fn program(reactor: *rotor.Reactor(rotor.Loop)) void {
    reactor.wait_until(.now);
}

test "a program bounds the wait of its reactor with wait_until" {
    _ = &program;
}
