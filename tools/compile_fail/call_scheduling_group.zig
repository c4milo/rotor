//! A call that names a group of one loop, a `SchedulingGroup`. `zig build test-compile-fail` requires
//! this file to fail to compile: a call names a group of every loop, a `NamedSchedulingGroup`
//! (decision 32).
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

fn send(service: *Echo, shared: *rotor.SharedLoop, caller: *Caller, group: rotor.SchedulingGroup) void {
    service.send(shared, 1, &caller.call, &@as(u64, 7), .{ .group = group }) catch {};
}

test "a call in a group of one loop" {
    _ = &send;
}
