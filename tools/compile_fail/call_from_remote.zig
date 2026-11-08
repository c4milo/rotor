//! A thread with no loop calls through its `Remote`. `zig build test-compile-fail` requires this file
//! to fail to compile: only a loop calls, through its `SharedLoop` (decision 32).
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

fn send(service: *Echo, remote: *rotor.Remote, caller: *Caller) void {
    service.send(remote, 1, &caller.call, 7, .{ .group = .default }) catch {};
}

test "a call from a remote" {
    _ = &send;
}
