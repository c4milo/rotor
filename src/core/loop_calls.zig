//! The calls that every backend's `Loop` exports, written once: `wait_limit`, `wait_until` and
//! `heartbeat` of the core's surface, five names of the port of decision 33, and the slow path of
//! the drain. Each backend declares `tick_backend`, `take_kept_error` and `assert_owner`, the other
//! three names of the port, itself.
//!
//! `Loop` has a `tables: Tables` field, an `inbox: Inbox` field, a `kept_error` field, a
//! `tick_error.Kept`, and a `wake_target` function that makes the backend's own wake of a loop that
//! sleeps, as its `post` does.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core.zig");
const inbox_module = @import("inbox.zig");
const reserved = @import("reserved.zig");
const stall = @import("stall.zig");
const stall_watch = @import("stall_watch.zig");

const Event = core.Event;
const Heartbeat = stall.Heartbeat;
const HeartbeatView = stall_watch.HeartbeatView;
const Inbox = inbox_module.Inbox;
const LoopId = core.LoopId;
const Message = core.Message;
const WaitLimit = core.WaitLimit;

pub fn Calls(comptime Loop: type) type {
    return struct {
        /// The host's last call before it sleeps in its own wait (decision 29). Returns how long it
        /// may sleep: `.now` while work is left, `.at` the nearest timer or the stored limit, and
        /// `.none` when neither exists. It reads no clock and changes no state. Program only (class
        /// B). A kept tick error is work left: the next tick returns it, and a host that slept first
        /// would not see it (decision 5, amendment of 2026-11-06).
        pub fn wait_limit(loop: *Loop) WaitLimit {
            loop.tables.assert_owner();
            if (loop.kept_error.failure != null) return .now;
            const limit = loop.tables.wait_limit();
            if (limit == .now) return .now;
            if (loop.inbox.holds_messages(loop.tables.id)) return .now;
            return limit;
        }

        /// Bounds the wait of each tick that follows at `limit`, until the next call (decision 33).
        /// `.none`, the value at init, bounds nothing, and `.now` makes each tick wait 0 ns. The
        /// tick compares the limit with its own stamp after R1, as it compares the nearest timer
        /// (decision 29, item 2). Program only (class B). A reactor refuses it at compile time: its
        /// pollers bound its wait, and only its own code writes the stored limit.
        pub fn wait_until(loop: *Loop, limit: WaitLimit) void {
            loop.tables.assert_owner();
            loop.tables.stored_limit = limit;
        }

        /// The loop's heartbeat, for a thread that the program starts (decision 28). It is valid
        /// until `deinit`, which halts while a watch reads it. Program only.
        pub fn heartbeat(loop: *Loop) *HeartbeatView {
            loop.tables.assert_owner();
            return stall_watch.view_of(loop.tables.heartbeat);
        }

        // The port of decision 33: the reactor calls these names, and a plain caller must not. All
        // but `attach_reserved` make no owner check, so the reactor's tick reaches each word at a
        // fixed offset from its own address. Each backend declares `take_kept_error` itself, with
        // the cold hint that decision 7 allows in its file.

        /// The word that takes a tick off the fast path while it is above 0. The core raises it for
        /// a kept error, and the reactor for each record in flight, each queued task and each call.
        pub fn outstanding(loop: *Loop) *u32 {
            return &loop.tables.outstanding;
        }

        /// The stored limit that bounds the wait of each tick. On a reactor only the reactor's own
        /// code writes it, for its pollers.
        pub fn stored_limit(loop: *Loop) *WaitLimit {
            return &loop.tables.stored_limit;
        }

        /// The line on which the reactor names each callback that it calls (decision 28).
        pub fn heartbeat_line(loop: *Loop) *Heartbeat {
            return loop.tables.heartbeat;
        }

        /// The function and the context that the drain hands each wake, call and return. It marks
        /// the loop in its registry as one that takes calls, unless the registry is a group's, where
        /// no call goes. Once, on the loop's thread, before the loop's first tick (class B).
        pub fn attach_reserved(loop: *Loop, context: *anyopaque, take: *const reserved.Take) void {
            loop.tables.assert_owner();
            assert(loop.tables.hook.take == reserved.Hook.none.take);
            loop.tables.hook = .{ .take = take, .context = context };
            const registry = loop.inbox.registry orelse return;
            if (!registry.group) registry.mark_calls(loop.tables.id);
        }

        /// Pushes `message`, a call or a return, into the ring from this loop to `target`, then
        /// wakes `target` when it sleeps (`reserved.push`). Returns the count of calls out of that
        /// ring, which the reactor raises after the push of a call.
        pub fn push_reserved(loop: *Loop, target: LoopId, message: Message) reserved.PushError!*u32 {
            const pushed = try reserved.push(loop.inbox.registry, loop.tables.id, target, message);
            if (pushed.wake != reserved.no_wake) loop.wake_target(target, pushed.wake);
            return pushed.calls_out;
        }

        /// The slow path of the loop's drain (`Inbox.TakeReserved`): `inbox.take_reserved` with the
        /// loop's hook. A backend calls it from its own `take_reserved`, which keeps it out of the
        /// tick (decision 7).
        pub fn take_reserved(
            inbox: *Inbox,
            receiver: LoopId,
            events: []Event,
            first: LoopId,
            written: u32,
        ) u32 {
            const loop: *Loop = @alignCast(@fieldParentPtr("inbox", inbox));
            return inbox_module.take_reserved(inbox, receiver, events, first, written, &loop.tables.hook);
        }
    };
}

const testing = std.testing;
const Slot = core.Slot;
const Tables = core.Tables;
const TimerHeap = core.timer_heap.TimerHeap;

const capacity = 4;
/// The clock of each test's loop, in ns.
const clock_ns: u64 = 1_000;

/// A loop of no backend: the fields that `Calls(Host)` reads.
const Host = struct {
    slots: [capacity]Slot,
    entries: [capacity]TimerHeap.Entry,
    starts: [capacity]u64,
    heartbeat: Heartbeat,
    tables: Tables,
    inbox: Inbox,
    kept_error: core.tick_error.Kept(error{Unexpected}),

    fn init(host: *Host) void {
        host.tables.init(&host.slots, &host.entries, &host.starts, &host.heartbeat, .{ .id = 0 });
        host.tables.now_ns = clock_ns;
        host.inbox = .init(null, &.{}, null);
        host.kept_error = .none;
    }

    fn wake_target(_: *Host, _: LoopId, _: core.Descriptor) void {}
};

const host_calls = Calls(Host);

test "wait_limit reads now while a tick's kernel error is kept, and the timer once it is taken" {
    var host: Host = undefined;
    host.init();
    host.tables.timers.arm(0, 3_000);
    try testing.expectEqual(WaitLimit.at(3_000), host_calls.wait_limit(&host));
    // A kernel call failed after the tick produced 2 events (decision 5, amendment of 2026-11-06).
    const outstanding = &host.tables.outstanding;
    try testing.expectEqual(@as(u32, 2), try host.kept_error.keep(outstanding, error.Unexpected, 2));
    try testing.expectEqual(WaitLimit.now, host_calls.wait_limit(&host));
    // The next tick takes the error first, and then the host may sleep until the timer.
    try testing.expectError(error.Unexpected, host.kept_error.take(outstanding));
    try testing.expectEqual(WaitLimit.at(3_000), host_calls.wait_limit(&host));
}

test "wait_until stores the limit that a tick which would block reads, until the next call" {
    var host: Host = undefined;
    host.init();
    const tables = &host.tables;
    // `.none` at init bounds nothing.
    try testing.expectEqual(WaitLimit.none, tables.stored_limit);
    try testing.expectEqual(@as(?u64, 10_000), tables.wait_bound(10_000));
    // The clock reads 1_000, so a limit at 5_000 leaves a wait of 4_000, in each tick.
    host_calls.wait_until(&host, .at(5_000));
    try testing.expectEqual(WaitLimit.at(5_000), tables.stored_limit);
    try testing.expectEqual(@as(?u64, 4_000), tables.wait_bound(10_000));
    try testing.expectEqual(@as(?u64, 4_000), tables.wait_bound(10_000));
    try testing.expectEqual(WaitLimit.at(5_000), host_calls.wait_limit(&host));
    // A timer before the limit ends the wait first.
    tables.timers.arm(0, 3_000);
    try testing.expectEqual(@as(?u64, 2_000), tables.wait_bound(10_000));
    _ = tables.timers.pop_due(3_000);
    // `.now`, or a limit at or before the clock, gives no wait.
    host_calls.wait_until(&host, .now);
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(10_000));
    host_calls.wait_until(&host, .at(1_000));
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(10_000));
    host_calls.wait_until(&host, .none);
    try testing.expectEqual(@as(?u64, 10_000), tables.wait_bound(10_000));
}

fn ignore_reserved(_: *anyopaque, _: LoopId, _: Message) void {}

test "the port's words are the tables' and the heartbeat's, and the hook is stored once" {
    var host: Host = undefined;
    host.init();
    try testing.expectEqual(&host.tables.outstanding, host_calls.outstanding(&host));
    try testing.expectEqual(&host.tables.stored_limit, host_calls.stored_limit(&host));
    try testing.expectEqual(&host.heartbeat, host_calls.heartbeat_line(&host));
    try testing.expectEqual(reserved.Hook.none, host.tables.hook);
    var context: u8 = 0;
    host_calls.attach_reserved(&host, &context, ignore_reserved);
    try testing.expectEqual(@as(*anyopaque, &context), host.tables.hook.context);
    try testing.expectEqual(@as(*const reserved.Take, ignore_reserved), host.tables.hook.take);
}
