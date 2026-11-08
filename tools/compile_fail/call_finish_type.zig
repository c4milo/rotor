//! A `finish` that takes the result of another reply type. `zig build test-compile-fail` requires
//! this file to fail to compile: `finish` takes the service's `CallResult` (decision 32).
const rotor = @import("rotor");

const Caller = struct {
    call: rotor.CallRecord(u64, u64) = .init(Caller, "call", finished),

    fn finished(_: *Caller, _: rotor.CallResult(u32)) void {}
};

test "a finish of another reply type" {
    const caller: Caller = .{};
    _ = caller;
}
