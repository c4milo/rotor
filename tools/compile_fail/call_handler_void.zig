//! A handler that returns nothing, so the call would have no answer. `zig build test-compile-fail`
//! requires this file to fail to compile: a handler returns an `Answer` (decision 32).
const rotor = @import("rotor");

const Context = struct {
    fn handle(_: *Context, _: *rotor.CallRecord(u64, u64)) void {}
};

test "a handler that returns nothing" {
    _ = rotor.Service(Context, u64, u64, Context.handle);
}
