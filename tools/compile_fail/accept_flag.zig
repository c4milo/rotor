//! A caller asks for a multishot accept with a flag, as `accept` took one before 2026-11-07.
//! `zig build test-compile-fail` requires this file to fail to compile: `accept` and
//! `accept_multishot` are two calls, as `receive` and `receive_group` are (decision 1, amendment of
//! 2026-11-07).
const rotor = @import("rotor");

fn caller(listener: rotor.Descriptor) rotor.Operation {
    return rotor.Operation.accept(1, listener, true);
}

test "a caller asks for a multishot accept with a flag" {
    _ = &caller;
}
