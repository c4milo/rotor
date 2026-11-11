//! The functions of what a library hands the reactor to have it call back (decision 26): a
//! `Completion` that an operation names, and a `Poller` that the reactor calls once in each tick. A
//! poller answers with a `WaitLimit` (decision 29). `reactor.zig` declares both types, so the
//! compiler prints `reactor.Completion` and `reactor.Poller` (decision 33, "Where each type is
//! declared"), and each method there is an alias of a function here.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const reactor_module = @import("../reactor.zig");

const Completion = reactor_module.Completion;
const Event = core.Event;
const Operation = core.Operation;
const Poller = reactor_module.Poller;
const WaitLimit = core.WaitLimit;

/// The name of the callback at `field` of `Parent`, for example `colibri.client.Client.receive`.
pub const name_of = core.stall.name_of;

/// A record at `field` of `Parent` that calls `handler` with its parent for each event. The
/// compiler checks the field, the parent and the handler, and the callback it makes costs the
/// same indirect call as one written by hand, after one load of the static `Call`.
pub fn completion_init(
    comptime Parent: type,
    comptime field: []const u8,
    comptime handler: fn (parent: *Parent, event: Event) void,
) Completion {
    comptime assert(@FieldType(Parent, field) == Completion);
    const Static = struct {
        fn function(completion: *Completion, event: Event) void {
            const parent: *Parent = @alignCast(@fieldParentPtr(field, completion));
            handler(parent, event);
        }
        const call: Completion.Call = .{ .name = name_of(Parent, field), .function = function };
    };
    return .{ .call = &Static.call };
}

/// `operation` with its events sent to `record`, which stays valid until the final event: the
/// record's address in `user_data`, and the `dispatched` bit set (decision 33, open question 5).
/// Only a reactor calls the record. A plain loop hands each such event to the caller of `tick`.
pub fn mark(record: *Completion, operation: Operation) Operation {
    var named = operation;
    named.user_data = @intFromPtr(record);
    named.dispatched = true;
    return named;
}

/// A poller at `field` of `Parent` that calls `handler` with its parent. A handler that returns
/// `bool`, decision 26's answer, fails to compile.
pub fn poller_init(
    comptime Parent: type,
    comptime field: []const u8,
    comptime handler: fn (parent: *Parent) WaitLimit,
) Poller {
    comptime assert(@FieldType(Parent, field) == Poller);
    const Static = struct {
        fn function(poller: *Poller) WaitLimit {
            const parent: *Parent = @alignCast(@fieldParentPtr(field, poller));
            return handler(parent);
        }
        const call: Poller.Call = .{ .name = name_of(Parent, field), .function = function };
    };
    return .{ .call = &Static.call };
}

comptime {
    assert(@sizeOf(Completion) == 8);
    assert(@sizeOf(Poller) == 8);
}

const testing = std.testing;

/// A library's record of one operation.
const Library = struct {
    completion: Completion = .init(Library, "completion", completed),
    seen: u64 = 0,

    fn completed(library: *Library, event: Event) void {
        library.seen = event.user_data;
    }
};

test "mark writes the record's address and the bit, and keeps the rest of the operation" {
    var library: Library = .{};
    const operation = Operation.timer(7, 1, 0);
    const marked = Completion.mark(&library.completion, operation);
    try testing.expect(marked.dispatched);
    try testing.expectEqual(@as(u64, @intFromPtr(&library.completion)), marked.user_data);
    try testing.expectEqual(operation.timeout_ns, marked.timeout_ns);
    try testing.expect(!operation.dispatched);
    // The record finds its parent again, as the reactor calls it.
    library.completion.call.function(&library.completion, .{ .user_data = 9, .result = 0, .flags = .{} });
    try testing.expectEqual(@as(u64, 9), library.seen);
    try testing.expectEqualStrings(@typeName(Library) ++ ".completion", library.completion.call.name);
}
