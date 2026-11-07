//! A caller names the generation that follows a handle's.
//! `zig build test-compile-fail` requires this file to fail to compile: the slot table's call is
//! not a declaration of `Handle` (decision 1, amendment of 2026-11-07).
const rotor = @import("rotor");

fn caller() u32 {
    return rotor.Handle.next_generation(1);
}

test "a caller names the generation that follows a handle's" {
    _ = &caller;
}
