//! The scheduling groups of decision 30 on every backend. Each library schedules its tasks in its
//! own group, and the loop serves the groups by their shares in cost units. Records and timers
//! still arrive beside groups that never stop, and `drain` and `discard_tasks` cover every group.
//!
//! `conformance_stall.zig` makes every task here, and the harness ticks the loop, so a task that
//! holds the loop past its limit fails the scenario.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const stall = @import("conformance_stall.zig");
const post_scenarios = @import("conformance_post.zig");
const tcp = @import("conformance_tcp.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const SchedulingGroup = core.SchedulingGroup;

const constants = core.constants;
const ms = constants.ns_per_ms;

/// Ticks a scenario may take. A queued task keeps every tick from blocking, so a tick is short.
const ticks_max = 1_000_000;

/// A wait that a tick must not take while a task is queued.
const long_wait_ns = 2 * constants.ns_per_s;

/// The tasks of each library that never stops: enough that a tick's 64 starts never run a group
/// out of its snapshot, so the shares alone decide.
const tasks_per_library = constants.tasks_per_tick_max;

/// A task of a library that schedules itself again in its group on every run.
fn Forever(comptime cost: u16) type {
    return struct {
        const Self = @This();
        task: core.Task = stall.task_cost(Self, "task", ran, cost),
        library: *Library,

        fn ran(forever: *Self) void {
            forever.library.runs += 1;
            forever.library.harness.loop.schedule_in(forever.library.group, &forever.task) catch unreachable;
        }
    };
}

/// One library on the loop: its group, and the runs of its tasks.
const Library = struct {
    harness: *Harness,
    group: SchedulingGroup,
    runs: u64 = 0,
};

/// A library with a timer and a receive that each name no record: what the tick hands its caller.
fn tick_until_both(harness: *Harness, timer_user_data: u64, receive_user_data: u64) !u32 {
    var events: [8]Event = undefined;
    var timer_seen = false;
    var receive_seen = false;
    var ticks: u32 = 0;
    while (!(timer_seen and receive_seen) and ticks < ticks_max) : (ticks += 1) {
        const count = try harness.tick(&events, long_wait_ns);
        for (events[0..count]) |event| {
            if (event.user_data == timer_user_data) timer_seen = true;
            if (event.user_data == receive_user_data) receive_seen = true;
        }
    }
    if (!(timer_seen and receive_seen)) return error.EventsMissing;
    return ticks;
}

test "two libraries at shares 100 and 300 are served 1 to 3 beside a receive and a timer" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    var low: Library = .{ .harness = &harness, .group = try harness.loop.reserve_scheduling_group(100) };
    var high: Library = .{ .harness = &harness, .group = try harness.loop.reserve_scheduling_group(300) };
    var lows: [tasks_per_library]Forever(1) = @splat(.{ .library = &low });
    var highs: [tasks_per_library]Forever(1) = @splat(.{ .library = &high });
    // A failed check returns with tasks queued, and `deinit` halts on them: the test must fail
    // and not halt.
    errdefer _ = harness.loop.discard_tasks();
    for (&lows) |*one| try harness.loop.schedule_in(low.group, &one.task);
    for (&highs) |*one| try harness.loop.schedule_in(high.group, &one.task);

    const listener = try tcp.Listener.open();
    defer backend.sync.close_now(listener.descriptor);
    // The pair's accept and connect take their own ticks, in which the groups run too.
    const pair = try tcp.connected_pair(&harness, &listener);
    defer for (pair) |descriptor| backend.sync.close_now(descriptor);
    var received: [8]u8 = undefined;
    try harness.submit(&.{
        Operation.receive(1, pair[1], &received),
        Operation.send(2, pair[0], "ping"),
        Operation.timer(3, 5 * ms, 0),
    }, &.{});
    _ = try tick_until_both(&harness, 3, 1);
    // G3: each group's units differ from its share of the rounds by less than a charge of the
    // largest cost. Here every task costs 1, so the ratio is 1 to 3 within one round.
    const expected_high = 3 * low.runs;
    const gap = if (high.runs > expected_high) high.runs - expected_high else expected_high - high.runs;
    try testing.expect(gap < constants.task_charge_max);
    try testing.expect(low.runs >= tasks_per_library / 4);
    var scratch: [8]Event = undefined;
    try testing.expectError(error.TasksStillQueued, harness.drain(&scratch));
    try testing.expectEqual(@as(u32, 2 * tasks_per_library), harness.loop.discard_tasks());
    try testing.expectEqual(@as(u32, 0), harness.loop.tasks_queued());
}

/// What a tick of the tested loop handed over in one round: the timer, and the post of the peer.
const Arrivals = struct {
    timer: bool = false,
    post: bool = false,

    fn note(arrivals: *Arrivals, events: []const Event, round: u64) void {
        for (events) |event| {
            if (event.flags.message) {
                const ping = event.result == post_scenarios.tag_ping;
                arrivals.post = arrivals.post or (ping and event.user_data == round);
            } else {
                arrivals.timer = arrivals.timer or event.user_data == round;
            }
        }
    }
};

test "a group of tasks of cost 64 leaves a group of unit tasks its share, and a timer and a post their tick" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const registry_alignment = core.layout.memory_alignment;
    var registry_memory: [backend.Registry.memory_bytes(2)]u8 align(registry_alignment) = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, 2);
    defer life.end();
    var harness: Harness = undefined;
    try harness.init(0, &registry);
    defer harness.deinit();
    // A peer loop on this thread posts to the tested loop once in each round.
    var peer: Harness = undefined;
    try peer.init(1, &registry);
    defer peer.deinit();
    var costly: Library = .{ .harness = &harness, .group = try harness.loop.reserve_scheduling_group(100) };
    var unit: Library = .{ .harness = &harness, .group = try harness.loop.reserve_scheduling_group(100) };
    var costlies: [tasks_per_library]Forever(constants.task_charge_max) = @splat(.{ .library = &costly });
    var units: [tasks_per_library]Forever(1) = @splat(.{ .library = &unit });
    errdefer _ = harness.loop.discard_tasks();
    for (&costlies) |*one| try harness.loop.schedule_in(costly.group, &one.task);
    for (&units) |*one| try harness.loop.schedule_in(unit.group, &one.task);
    var events: [8]Event = undefined;
    for (0..8) |round| {
        // A timer that is due at once, and a post, arrive within 2 ticks, whatever the groups
        // hold. The peer's tick carries the wake that a post on io_uring leaves for it.
        try harness.submit(&.{Operation.timer(round, 0, 0)}, &.{});
        try peer.loop.post(0, .{ .payload = round, .tag = post_scenarios.tag_ping });
        _ = try peer.tick(&events, 0);
        var arrivals: Arrivals = .{};
        for (0..2) |_| {
            const count = try harness.tick(&events, long_wait_ns);
            arrivals.note(events[0..count], round);
        }
        try testing.expect(arrivals.timer);
        try testing.expect(arrivals.post);
    }
    // Each costly start buys 63 rounds of debt, in which the unit group takes one start each, so
    // in 16 ticks the unit group has at least 63 starts for each costly one, less one tick's.
    try testing.expect(costly.runs >= 1);
    try testing.expect(unit.runs + constants.tasks_per_tick_max >= 63 * costly.runs);
    try testing.expectEqual(@as(u32, 2 * tasks_per_library), harness.loop.discard_tasks());
}

/// A task that runs once.
const Once = struct {
    task: core.Task = stall.task(Once, "task", ran),
    runs: u32 = 0,

    fn ran(once: *Once) void {
        once.runs += 1;
    }
};

test "drain runs the tasks of every group, and discard_tasks unlinks every group" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const first = try harness.loop.reserve_scheduling_group(100);
    const second = try harness.loop.reserve_scheduling_group(1000);
    var onces: [3][4]Once = @splat(@splat(.{}));
    const groups = [_]SchedulingGroup{ .default, first, second };
    for (&onces, groups) |*row, group| {
        for (row) |*once| try harness.loop.schedule_in(group, &once.task);
    }
    try testing.expectEqual(@as(u32, 12), harness.loop.tasks_queued());
    var scratch: [8]Event = undefined;
    try harness.drain(&scratch);
    for (&onces) |*row| for (row) |*once| try testing.expectEqual(@as(u32, 1), once.runs);
    // Tasks that never stop in two groups: the drain gives up, and the program discards them.
    var library: Library = .{ .harness = &harness, .group = first };
    var other: Library = .{ .harness = &harness, .group = second };
    var forevers: [2]Forever(1) = .{ .{ .library = &library }, .{ .library = &other } };
    errdefer _ = harness.loop.discard_tasks();
    try harness.loop.schedule_in(first, &forevers[0].task);
    try harness.loop.schedule_in(second, &forevers[1].task);
    try testing.expectError(error.TasksStillQueued, harness.drain(&scratch));
    try testing.expectEqual(@as(u32, 2), harness.loop.discard_tasks());
    for (&forevers) |*forever| try testing.expect(!harness.loop.is_scheduled(&forever.task));
}

test "a loop's init reserves the named groups of its options, and an empty table none" {
    if (conformance.unsupported()) return error.SkipZigTest;
    const Declared = core.scheduling.Named(.{ .quic = 400, .dns = 100 });
    var harness: Harness = undefined;
    try harness.init_named(&Declared.table);
    const groups = harness.loop.tables.groups;
    try testing.expectEqual(@as(u8, 2), groups.named);
    try testing.expectEqual(@as(u16, 400), groups.lanes[1].shares);
    try testing.expectEqual(@as(u16, 100), groups.lanes[2].shares);
    try testing.expectEqual(@as(u8, 3), @intFromEnum(try harness.loop.reserve_scheduling_group(50)));
    // A named group holds tasks as a reserved one does.
    var once: Once = .{};
    try harness.loop.schedule_in(Declared.group(.dns).scheduling_group(), &once.task);
    var events: [4]Event = undefined;
    _ = try harness.tick(&events, 0);
    try testing.expectEqual(@as(u32, 1), once.runs);
    harness.deinit();

    try harness.init_named(&.empty);
    defer harness.deinit();
    try testing.expectEqual(@as(u8, 0), harness.loop.tables.groups.named);
    try testing.expectEqual(@as(u8, 1), @intFromEnum(try harness.loop.reserve_scheduling_group(100)));
}

test "a library schedules through its view in its group, and charges its task's cost" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    const Charging = struct {
        task: core.Task = stall.task(@This(), "task", ran),
        shared: *core.shared_loop.SharedLoop(backend.Loop),
        budget: u32 = 0,

        fn ran(charging: *@This()) void {
            charging.budget = charging.shared.task_budget_left();
            charging.shared.charge_task(9);
        }
    };
    const shared = harness.loop.shared();
    const group = try harness.loop.reserve_scheduling_group(1000);
    var charging: Charging = .{ .shared = shared };
    try shared.schedule_in(group, &charging.task);
    var onces: [2]Once = @splat(.{});
    for (&onces) |*once| try shared.schedule_in(.default, &once.task);
    var events: [4]Event = undefined;
    _ = try harness.tick(&events, 0);
    for (&onces) |*once| try testing.expectEqual(@as(u32, 1), once.runs);
    // `.default` was still ready beside the group: the visit's 1000 less the task's 100 leave 9
    // units.
    try testing.expectEqual(@as(u32, 9), charging.budget);
    // The charge of 9 took the rest: the visit closed at 0.
    try testing.expectEqual(@as(i32, 0), harness.loop.tables.groups.lanes[@intFromEnum(group)].deficit);
}
