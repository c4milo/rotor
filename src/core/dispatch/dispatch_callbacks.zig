//! What a library hands the loop to have it call back (decision 26): a `Completion` that an
//! operation names, and a `Poller` that the loop calls once in each tick. A poller answers with a
//! `WaitLimit` (decision 29). Split from `dispatch.zig` for the 500-line limit. `dispatch.zig`
//! declares each public name, so a caller writes `dispatch.Poller`.
const std = @import("std");
const assert = std.debug.assert;
const Event = @import("../event.zig").Event;

/// The name of the callback at `field` of `Parent`, for example `colibri.client.Client.receive`.
pub const name_of = @import("../stall.zig").name_of;

/// What an operation names to have the tick call its function for each of its events. The library
/// puts it inside its own struct. `init` points it at a static `Call` that finds that struct again.
/// Size 8 B, alignment 8.
pub const Completion = struct {
    call: *const Call,

    /// A static entry: the callback's name and its function (decision 28). `init` makes one,
    /// named `@typeName(Parent) ++ "." ++ field`. A `Call` written by hand is a container-level
    /// `const` with a literal name: another thread may read the name after a library frees its
    /// record, so it must be static data, and the compiler cannot refuse one on the stack.
    pub const Call = struct {
        name: [:0]const u8,
        function: *const fn (completion: *Completion, event: Event) void,
    };

    /// A record at `field` of `Parent` that calls `handler` with its parent for each event. The
    /// compiler checks the field, the parent and the handler, and the callback it makes costs the
    /// same indirect call as one written by hand, after one load of the static `Call`.
    pub fn init(
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
            const call: Call = .{ .name = name_of(Parent, field), .function = function };
        };
        return .{ .call = &Static.call };
    }
};

/// How long a tick may wait, on the loop's clock (`now_ns`). A poller returns it, and a host reads
/// it from `Loop.wait_limit` (decision 29). Size 8 B: it comes back in one register.
pub const WaitLimit = enum(u64) {
    /// Work is left: do not wait. Decision 26's `true`.
    now = 0,
    /// Nothing here bounds the wait. Decision 26's `false`.
    none = std.math.maxInt(u64),
    _,

    /// Wait until `at_ns` at the latest. `.at(0)` is `.now`, and `.at(maxInt(u64))` is `.none`.
    /// Each value means one thing, and no value is wrong, so `at` has no assertion.
    pub fn at(at_ns: u64) WaitLimit {
        return @enumFromInt(at_ns);
    }
};

/// What a library adds to have the loop call its function once in each tick, before the tick waits.
/// The function returns a `WaitLimit`: `.now` when the tick must not block, for example because
/// work is left, `.at(ns)` for a deadline on the loop's clock, and `.none` otherwise. The tick
/// bounds its wait at the least limit of all pollers (decision 29). Size 8 B, alignment 8.
pub const Poller = struct {
    call: *const Call,

    /// A static entry, as `Completion.Call` is.
    pub const Call = struct {
        name: [:0]const u8,
        function: *const fn (poller: *Poller) WaitLimit,
    };

    /// A poller at `field` of `Parent` that calls `handler` with its parent. A handler that
    /// returns `bool`, decision 26's answer, fails to compile.
    pub fn init(
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
            const call: Call = .{ .name = name_of(Parent, field), .function = function };
        };
        return .{ .call = &Static.call };
    }
};

comptime {
    assert(@sizeOf(Completion) == 8);
    assert(@sizeOf(Poller) == 8);
    assert(@sizeOf(WaitLimit) == 8);
}

const testing = std.testing;

test "a limit at the two ends of the clock is now and none" {
    try testing.expectEqual(WaitLimit.now, WaitLimit.at(0));
    try testing.expectEqual(WaitLimit.none, WaitLimit.at(std.math.maxInt(u64)));
    try testing.expectEqual(@as(u64, 5), @intFromEnum(WaitLimit.at(5)));
}
