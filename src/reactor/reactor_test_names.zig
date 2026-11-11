//! The names that the compiler prints for each type of the module (decision 33, "Where each type
//! is declared"). A program reads them in each compile error, so a declaration that moves and
//! changes a printed name fails `zig build test`. Each type is declared in `reactor.zig`, the
//! module's root, or inside another such type. Only `reactor.Reactor` repeats its module's name,
//! which the ruling of 2026-11-09 accepts.
const std = @import("std");
const reactor = @import("reactor.zig");
const Twin = @import("reactor_test.zig").Twin;

const testing = std.testing;

const Reactor = reactor.Reactor(Twin);

/// The context of a service whose handler answers at once, for the names of a reactor's call
/// types.
const Echo = struct {
    fn handle(_: *Echo, record: *Reactor.CallRecord(u64, u64)) reactor.Answer(u64) {
        return .{ .now = record.request_of().* };
    }
};

test "each type of the root prints the root's name, and each type of a reactor its reactor's" {
    try testing.expectEqualStrings("reactor.Completion", @typeName(reactor.Completion));
    try testing.expectEqualStrings("reactor.Poller", @typeName(reactor.Poller));
    try testing.expectEqualStrings("reactor.Task", @typeName(reactor.Task));
    try testing.expectEqualStrings("reactor.NamedSchedulingGroup", @typeName(reactor.NamedSchedulingGroup));
    try testing.expectEqualStrings("reactor.Answer(u64)", @typeName(reactor.Answer(u64)));
    try testing.expectEqualStrings("reactor.CallResult(u64)", @typeName(reactor.CallResult(u64)));
    try testing.expectEqualStrings("reactor.CallOptions", @typeName(reactor.CallOptions));
    try testing.expectEqualStrings("reactor.CallLink", @typeName(reactor.CallLink));
    try testing.expectEqualStrings("reactor.CallStation", @typeName(reactor.CallStation));
    try testing.expectEqualStrings("reactor.Reactor(reactor_test.Twin)", @typeName(Reactor));
    try testing.expectEqualStrings("reactor.Reactor(reactor_test.Twin).SharedLoop", @typeName(Reactor.SharedLoop));
    try testing.expectEqualStrings(
        "reactor.Reactor(reactor_test.Twin).CallRecord(u64,u64)",
        @typeName(Reactor.CallRecord(u64, u64)),
    );
    const service_name = @typeName(Reactor.Service(Echo, u64, u64, Echo.handle));
    try testing.expect(std.mem.startsWith(u8, service_name, "reactor.Reactor(reactor_test.Twin).Service("));
}
