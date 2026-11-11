//! Tests of the wait limit of decision 29 on a reactor: what `Dispatch.begin` folds from the
//! pollers into the loop's stored limit, what `end`, `remove_poller` and a wake store, and what the
//! core's `Tables.wait_bound` and `Tables.wait_limit` read of it. In a file of their own for the
//! 500-line limit of `dispatch.zig`. The core's tests of `wait_until` and of the port's words are
//! in `core/loop_calls.zig`.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const dispatch_module = @import("dispatch.zig");
const reactor_module = @import("../reactor.zig");

const Completion = reactor_module.Completion;
const Dispatch = dispatch_module.Dispatch;
const Event = core.Event;
const Groups = reactor_module.Groups;
const Heartbeat = core.Heartbeat;
const Poller = reactor_module.Poller;
const Slot = core.Slot;
const Tables = core.tables.Tables;
const Task = reactor_module.Task;
const TimerHeap = core.timer_heap.TimerHeap;
const WaitLimit = core.WaitLimit;

/// A poller that answers `limit`.
const Answering = struct {
    poller: Poller = .init(Answering, "poller", polled),
    limit: WaitLimit,

    fn polled(answering: *Answering) WaitLimit {
        return answering.limit;
    }
};

/// A record and a task that do nothing.
const Quiet = struct {
    completion: Completion = .init(Quiet, "completion", completed),
    task: Task = .init(Quiet, "task", ran),

    fn completed(_: *Quiet, _: Event) void {}
    fn ran(_: *Quiet) void {}
};

const capacity = 4;

/// A loop of no backend: its tables, and the core's calls of the port over them. A reactor's state
/// beside it, as a reactor holds one.
const Host = struct {
    slots: [capacity]Slot,
    entries: [capacity]TimerHeap.Entry,
    starts: [capacity]u64,
    heartbeat: Heartbeat,
    tables: Tables,
    inbox: core.inbox.Inbox,
    kept_error: core.tick_error.Kept(error{Unexpected}),
    groups: Groups,
    dispatch: Dispatch,

    const calls = core.loop_calls.Calls(Host);
    pub const outstanding = calls.outstanding;
    pub const stored_limit = calls.stored_limit;
    pub const heartbeat_line = calls.heartbeat_line;
    pub const wait_limit = calls.wait_limit;
    pub const push_reserved = calls.push_reserved;

    pub fn assert_owner(host: *const Host) void {
        host.tables.assert_owner();
    }

    /// No loop sleeps here, so no push wakes one.
    pub fn wake_target(_: *Host, _: core.LoopId, _: core.Descriptor) void {
        unreachable;
    }

    fn init(host: *Host) void {
        host.tables.init(&host.slots, &host.entries, &host.starts, &host.heartbeat, .{ .id = 0 });
        host.tables.now_ns = 1_000;
        host.inbox = .init(null, &.{}, null);
        host.kept_error = .none;
        host.dispatch.start(&host.groups, .{ .id = 0, .in_group = false, .named_groups = &.empty });
    }

    /// One `begin` and an `end` with no events. Returns the wait `begin` gave.
    fn tick(host: *Host, wait_ns: u64) u64 {
        const wait = host.dispatch.begin(host, wait_ns);
        _ = host.dispatch.end(host, &.{});
        return wait;
    }

    fn add_poller(host: *Host, answering: *Answering) !void {
        try host.dispatch.add_poller(host, &answering.poller);
    }

    fn remove_poller(host: *Host, answering: *Answering) void {
        host.dispatch.remove_poller(host, &answering.poller);
    }

    /// The hook of the reserved tags, with a wake from loop 1.
    fn wake(host: *Host) void {
        host.dispatch.take_reserved(host, 1, core.Message.wake);
    }
};

test "begin keeps the least limit of its pollers, and blocks only when it is not now" {
    var host: Host = undefined;
    host.init();
    const limit = &host.tables.stored_limit;
    var first: Answering = .{ .limit = .none };
    try host.add_poller(&first);
    try testing.expectEqual(@as(u64, 9), host.tick(9));
    try testing.expectEqual(WaitLimit.none, limit.*);
    // A limit in the future, and one in the past, both leave the wait to `wait_bound`.
    first.limit = .at(500);
    try testing.expectEqual(@as(u64, 9), host.tick(9));
    try testing.expectEqual(WaitLimit.at(500), limit.*);
    first.limit = .at(1);
    try testing.expectEqual(@as(u64, 9), host.tick(9));
    try testing.expectEqual(WaitLimit.at(1), limit.*);
    // Two pollers: the least limit wins, in either order of the table.
    var second: Answering = .{ .limit = .at(200) };
    try host.add_poller(&second);
    first.limit = .at(300);
    _ = host.tick(9);
    try testing.expectEqual(WaitLimit.at(200), limit.*);
    first.limit = .at(100);
    _ = host.tick(9);
    try testing.expectEqual(WaitLimit.at(100), limit.*);
    second.limit = .now;
    try testing.expectEqual(@as(u64, 0), host.tick(9));
    try testing.expectEqual(WaitLimit.now, limit.*);
}

test "end stores now after a record or a task while a poller is in the table, and not otherwise" {
    var host: Host = undefined;
    host.init();
    const limit = &host.tables.stored_limit;
    var quiet: Quiet = .{};
    var answering: Answering = .{ .limit = .at(700) };
    try host.add_poller(&answering);
    // No callback: the limit stays the pollers' answer.
    _ = host.tick(9);
    try testing.expectEqual(WaitLimit.at(700), limit.*);
    // A record, which the reactor's `submit` counted.
    host.tables.outstanding += 1;
    var events = [_]Event{.{
        .user_data = @intFromPtr(&quiet.completion),
        .result = 0,
        .flags = .{ .dispatched = true },
    }};
    _ = host.dispatch.begin(&host, 9);
    _ = host.dispatch.end(&host, &events);
    try testing.expectEqual(WaitLimit.now, limit.*);
    // A task.
    try host.dispatch.schedule(&host, &quiet.task);
    _ = host.tick(9);
    try testing.expectEqual(WaitLimit.now, limit.*);
    // With no poller, a task stores nothing.
    host.remove_poller(&answering);
    try host.dispatch.schedule(&host, &quiet.task);
    _ = host.tick(9);
    try testing.expectEqual(WaitLimit.none, limit.*);
    try testing.expectEqual(@as(u32, 0), host.tables.outstanding);
}

test "a removal that empties the table resets the limit, and a wake stores now only with a poller" {
    var host: Host = undefined;
    host.init();
    const limit = &host.tables.stored_limit;
    var first: Answering = .{ .limit = .at(40) };
    var second: Answering = .{ .limit = .at(50) };
    try host.add_poller(&first);
    try host.add_poller(&second);
    _ = host.tick(9);
    host.remove_poller(&first);
    try testing.expectEqual(WaitLimit.at(40), limit.*);
    host.wake();
    try testing.expectEqual(WaitLimit.now, limit.*);
    host.remove_poller(&second);
    try testing.expectEqual(WaitLimit.none, limit.*);
    host.wake();
    try testing.expectEqual(WaitLimit.none, limit.*);
}

test "wait_bound stops at a poller's limit before the nearest timer, and at the timer otherwise" {
    var host: Host = undefined;
    host.init();
    const tables = &host.tables;
    try testing.expectEqual(@as(?u64, 5_000), tables.wait_bound(5_000));
    tables.timers.arm(0, 3_000);
    try testing.expectEqual(@as(?u64, 2_000), tables.wait_bound(5_000));
    var answering: Answering = .{ .limit = .at(1_500) };
    try host.add_poller(&answering);
    _ = host.tick(9);
    try testing.expectEqual(@as(?u64, 500), tables.wait_bound(5_000));
    answering.limit = .at(4_000);
    _ = host.tick(9);
    try testing.expectEqual(@as(?u64, 2_000), tables.wait_bound(5_000));
    // A limit at the tick's stamp gives no wait.
    answering.limit = .at(1_000);
    _ = host.tick(9);
    try testing.expectEqual(@as(?u64, null), tables.wait_bound(5_000));
    // A removal that empties the table leaves the timer alone in the bound.
    host.remove_poller(&answering);
    try testing.expectEqual(@as(?u64, 2_000), tables.wait_bound(5_000));
}

test "a reactor's wait_limit reads now while work is left, and the least limit or none otherwise" {
    var host: Host = undefined;
    host.init();
    const tables = &host.tables;
    const dispatch = &host.dispatch;
    var quiet: Quiet = .{};
    try testing.expectEqual(WaitLimit.none, dispatch.wait_limit(&host));
    tables.timers.arm(0, 3_000);
    try testing.expectEqual(WaitLimit.at(3_000), dispatch.wait_limit(&host));
    var answering: Answering = .{ .limit = .at(2_000) };
    try host.add_poller(&answering);
    _ = host.tick(9);
    try testing.expectEqual(WaitLimit.at(2_000), dispatch.wait_limit(&host));
    // A poller that returned now.
    answering.limit = .now;
    _ = host.tick(9);
    try testing.expectEqual(WaitLimit.now, dispatch.wait_limit(&host));
    // A wake that the last tick took.
    answering.limit = .none;
    _ = host.tick(9);
    try testing.expectEqual(WaitLimit.at(3_000), dispatch.wait_limit(&host));
    host.wake();
    try testing.expectEqual(WaitLimit.now, dispatch.wait_limit(&host));
    // A task queued, and then the task that the last tick called.
    _ = host.tick(9);
    try dispatch.schedule(&host, &quiet.task);
    try testing.expectEqual(WaitLimit.now, dispatch.wait_limit(&host));
    _ = host.tick(9);
    try testing.expectEqual(WaitLimit.now, dispatch.wait_limit(&host));
    // A timer that is due.
    _ = host.tick(9);
    tables.now_ns = 3_000;
    try testing.expectEqual(WaitLimit.now, dispatch.wait_limit(&host));
    host.remove_poller(&answering);
}
