//! A handler that answers `.now` with no reply. `zig build test-compile-fail` requires this file to
//! fail to compile: `.now` carries the reply (decision 32).
const rotor = @import("rotor");

fn handle(_: *u8, _: *rotor.CallRecord(u64, u64)) rotor.Answer(u64) {
    return .now;
}

test "a handler that answers now with no reply" {
    _ = &handle;
}
