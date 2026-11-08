//! A call that names no group. `zig build test-compile-fail` requires this file to fail to compile:
//! a call names its group, `.default` included (decision 32).
const rotor = @import("rotor");

const Context = struct {
    fn handle(_: *Context, call: *rotor.CallRecord(u64, u64)) rotor.Answer(u64) {
        return .{ .now = call.request_of().* + 1 };
    }
};

const Echo = rotor.Service(Context, u64, u64, Context.handle);

const Caller = struct {
    call: rotor.CallRecord(u64, u64) = .init(Caller, "call", finished),

    fn finished(_: *Caller, _: rotor.CallResult(u64)) void {}
};

fn send(service: *Echo, shared: *rotor.SharedLoop, caller: *Caller) void {
    service.send(shared, 1, &caller.call, 7, .{}) catch {};
}

test "a call with no group" {
    _ = &send;
}
