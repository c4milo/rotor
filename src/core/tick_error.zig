//! A kernel error that a tick meets after it produced events (decision 5, amendment of
//! 2026-11-06). Those events released their slots, so a tick that returned only the error would
//! drop final events, and a record operation would leave `callbacks_outstanding` high. So the tick returns
//! the events, and the loop keeps the error. The next tick returns it before it drains anything. A
//! tick that produced nothing returns the error at once.
//!
//! Each backend's `Loop` holds one `Kept` of its own `TickError`. It is the same on every kernel,
//! so it lives in `core`. A kept error adds 1 to the dispatch's `callbacks_outstanding`, which takes
//! the next tick off the fast path, and `tick_dispatched` takes the error first. So a tick with no
//! error kept pays nothing for it: `idle()` reads the same two words as before.
const std = @import("std");
const assert = std.debug.assert;
const Dispatch = @import("dispatch.zig").Dispatch;

/// The kept error of a loop whose tick fails with `TickError`.
pub fn Kept(comptime TickError: type) type {
    return struct {
        const KeptError = @This();

        /// The error a tick met after it produced events, or null.
        failure: ?TickError,

        pub const none: KeptError = .{ .failure = null };

        /// Returns the kept error, if there is one, and clears it. `tick_dispatched` calls it
        /// before `begin`, so the error comes before any poller and any event.
        pub fn take(kept: *KeptError, dispatch: *Dispatch) TickError!void {
            const failure = kept.failure orelse return;
            kept.failure = null;
            dispatch.callbacks_outstanding -= 1;
            return failure;
        }

        /// What a tick returns when its kernel call failed with `failure` after it produced
        /// `produced` events: the error when `produced` is 0, and otherwise the events, with the
        /// error kept for the next tick. Halts when an error is kept already: the next tick takes
        /// it first, so a second one means a tick did not call `take`.
        pub fn keep(
            kept: *KeptError,
            dispatch: *Dispatch,
            failure: TickError,
            produced: u32,
        ) TickError!u32 {
            assert(kept.failure == null);
            if (produced == 0) return failure;
            kept.failure = failure;
            dispatch.callbacks_outstanding += 1;
            return produced;
        }
    };
}

const testing = std.testing;

const TestError = error{ SystemResources, Unexpected };

test "a failure after no event returns at once, and keeps nothing" {
    var dispatch: Dispatch = .empty;
    var kept: Kept(TestError) = .none;
    try testing.expectError(error.Unexpected, kept.keep(&dispatch, error.Unexpected, 0));
    try testing.expectEqual(@as(?TestError, null), kept.failure);
    try testing.expect(dispatch.idle());
    try kept.take(&dispatch);
}

test "a failure after events returns the events, and the next take returns the error once" {
    var dispatch: Dispatch = .empty;
    var kept: Kept(TestError) = .none;
    try testing.expectEqual(@as(u32, 3), try kept.keep(&dispatch, error.SystemResources, 3));
    // The next tick leaves the fast path, where it takes the error.
    try testing.expect(!dispatch.idle());
    try testing.expectError(error.SystemResources, kept.take(&dispatch));
    try testing.expect(dispatch.idle());
    // The error is returned once: the tick after it runs as usual.
    try kept.take(&dispatch);
    try testing.expectEqual(@as(?TestError, null), kept.failure);
    try testing.expect(dispatch.idle());
}
