//! A kernel error that a tick meets after it produced events (decision 5, amendment of
//! 2026-11-06). Those events released their slots, so a tick that returned only the error would
//! drop final events, and a reactor's record would leave `outstanding` high. So the tick returns
//! the events, and the loop keeps the error. The next tick returns it before it drains anything. A
//! tick that produced nothing returns the error at once.
//!
//! Each backend's `Loop` holds one `Kept` of its own `TickError`. It is the same on every kernel,
//! so it lives in `core`. A kept error adds 1 to the loop's `outstanding` word, which takes the
//! next tick off the fast path: `tick` below then takes the error first. So a tick with no error
//! kept pays one load and one compare for it (decision 33, "The port").
const std = @import("std");
const assert = std.debug.assert;

/// The kept error of a loop whose tick fails with `TickError`.
pub fn Kept(comptime TickError: type) type {
    return struct {
        const KeptError = @This();

        /// The loop's error set for a tick, which `take` returns.
        pub const Error = TickError;

        /// The error a tick met after it produced events, or null.
        failure: ?TickError,

        pub const none: KeptError = .{ .failure = null };

        /// Returns the kept error, if there is one, and clears it and lowers `outstanding`. A tick
        /// calls it first, so the error comes before any poller and any event.
        pub fn take(kept: *KeptError, outstanding: *u32) TickError!void {
            const failure = kept.failure orelse return;
            kept.failure = null;
            outstanding.* -= 1;
            return failure;
        }

        /// What a tick returns when its kernel call failed with `failure` after it produced
        /// `produced` events: the error when `produced` is 0, and otherwise the events, with the
        /// error kept for the next tick and `outstanding` raised. Halts when an error is kept
        /// already: the next tick takes it first, so a second one means a tick did not call `take`.
        pub fn keep(
            kept: *KeptError,
            outstanding: *u32,
            failure: TickError,
            produced: u32,
        ) TickError!u32 {
            assert(kept.failure == null);
            if (produced == 0) return failure;
            kept.failure = failure;
            outstanding.* += 1;
            return produced;
        }
    };
}

/// The tick of a plain loop (decision 33, "The port"): while `outstanding` is above 0 it takes the
/// kept error first, then it runs the backend's tick. On a plain loop only a kept error raises
/// `outstanding`, so a tick with none pays one load and one compare. Each backend's `tick` is this,
/// over its port's `outstanding`, `take_kept_error` and `tick_backend`.
pub fn tick(loop: anytype, events: anytype, wait_ns: u64) Result(@TypeOf(loop)) {
    if (loop.outstanding().* != 0) try loop.take_kept_error();
    return loop.tick_backend(events, wait_ns);
}

/// What `tick` returns: what the loop's `tick_backend` returns.
fn Result(comptime LoopPointer: type) type {
    const Loop = @typeInfo(LoopPointer).pointer.child;
    return @typeInfo(@TypeOf(Loop.tick_backend)).@"fn".return_type.?;
}

const testing = std.testing;

const TestError = error{ SystemResources, Unexpected };

test "a failure after no event returns at once, and keeps nothing" {
    var outstanding: u32 = 0;
    var kept: Kept(TestError) = .none;
    try testing.expectError(error.Unexpected, kept.keep(&outstanding, error.Unexpected, 0));
    try testing.expectEqual(@as(?TestError, null), kept.failure);
    try testing.expectEqual(@as(u32, 0), outstanding);
    try kept.take(&outstanding);
}

test "a failure after events returns the events, and the next take returns the error once" {
    var outstanding: u32 = 0;
    var kept: Kept(TestError) = .none;
    try testing.expectEqual(@as(u32, 3), try kept.keep(&outstanding, error.SystemResources, 3));
    // The next tick leaves the fast path, where it takes the error.
    try testing.expectEqual(@as(u32, 1), outstanding);
    try testing.expectError(error.SystemResources, kept.take(&outstanding));
    try testing.expectEqual(@as(u32, 0), outstanding);
    // The error is returned once: the tick after it runs as usual.
    try kept.take(&outstanding);
    try testing.expectEqual(@as(?TestError, null), kept.failure);
    try testing.expectEqual(@as(u32, 0), outstanding);
}

/// A loop with no kernel: its backend's tick fails once after it produced events, and counts the
/// ticks that reached it.
const FailingLoop = struct {
    kept_error: Kept(TestError) = .none,
    word: u32 = 0,
    /// The backend's tick that fails, after it produced two events.
    failing_tick: u32 = 1,
    ticks: u32 = 0,

    pub fn outstanding(loop: *FailingLoop) *u32 {
        return &loop.word;
    }

    pub fn take_kept_error(loop: *FailingLoop) TestError!void {
        return loop.kept_error.take(&loop.word);
    }

    pub fn tick_backend(loop: *FailingLoop, events: []u8, wait_ns: u64) TestError!u32 {
        _ = wait_ns;
        loop.ticks += 1;
        if (loop.ticks == loop.failing_tick) {
            return loop.kept_error.keep(&loop.word, error.SystemResources, @intCast(events.len));
        }
        return 0;
    }
};

test "the plain tick returns a kept error first, once, and its outstanding word falls back to 0" {
    var loop: FailingLoop = .{};
    var events: [2]u8 = undefined;
    // The first tick produced two events and met the error: it returns the events.
    try testing.expectEqual(@as(u32, 2), try tick(&loop, &events, 0));
    try testing.expectEqual(@as(u32, 1), loop.word);
    // The next tick returns the error before its backend runs.
    try testing.expectError(error.SystemResources, tick(&loop, &events, 0));
    try testing.expectEqual(@as(u32, 1), loop.ticks);
    try testing.expectEqual(@as(u32, 0), loop.word);
    // The tick after it runs the backend, which produces nothing.
    try testing.expectEqual(@as(u32, 0), try tick(&loop, &events, 0));
    try testing.expectEqual(@as(u32, 2), loop.ticks);
}
