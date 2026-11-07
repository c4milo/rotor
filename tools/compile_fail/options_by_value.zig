//! A caller sizes a loop's memory with its options by value, as before 2026-11-07.
//! `zig build test-compile-fail` requires this file to fail to compile: `Loop.memory_bytes` and
//! `Loop.init` take `*const Options` (decision 1, amendment of 2026-11-07).
const rotor = @import("rotor");

fn caller(options: rotor.Loop.Options) usize {
    return rotor.Loop.memory_bytes(options);
}

test "a caller sizes a loop's memory with its options by value" {
    _ = &caller;
}
