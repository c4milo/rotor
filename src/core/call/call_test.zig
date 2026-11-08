//! The unit tests of the cross-core call (decision 32, "How it would be checked", unit tests 1 to
//! 7), with no `Loop`: model loops of `call_test_fixture.zig` on one registry, ticked on this
//! thread.
const std = @import("std");
const testing = std.testing;
const constants = @import("../constants.zig");
const fixture = @import("call_test_fixture.zig");
const statistics_module = @import("../statistics.zig");
const Task = @import("../tasks.zig").Task;
const SchedulingGroup = @import("../scheduling/scheduling.zig").SchedulingGroup;

const Client = fixture.Client;
const Declared = fixture.Declared;
const EchoService = fixture.EchoService;
const EchoCall = fixture.EchoCall;
const Event = fixture.Event;
const Pair = fixture.Pair(2);

const caller: fixture.LoopId = 0;
const target: fixture.LoopId = 1;

/// Room for every message of one visit.
const events_len = 2 * constants.messages_per_drain;

fn send(pair: *Pair, client: *Client, request: u64, group: @TypeOf(Declared.group(.low))) fixture.CallError!void {
    return pair.service.send(&pair.loops[caller], target, &client.call, &request, .{ .group = group });
}

test "a return finds a slot while the posts fill their share of the ring" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.stop();
    var clients: [constants.calls_per_pair_max]Client = @splat(.{});
    for (&clients, 0..) |*client, index| try send(&pair, client, index, .default);
    // The target's posts to the caller fill their share: 224 of 256.
    const ring = pair.registry.mailbox(target, caller);
    var posts: u32 = 0;
    while (ring.push_post(.{ .payload = posts, .tag = 1 })) posts += 1;
    try testing.expectEqual(constants.mailbox_posts_max, posts);
    // The target answers all 32: each return push finds a slot, or the push halts.
    var events: [events_len]Event = undefined;
    _ = pair.loops[target].tick(&events);
    try testing.expectEqual(@as(u32, constants.calls_per_pair_max), pair.echoes[target].handled);
    try testing.expect(!ring.push(.{ .payload = 0, .tag = 1 }));
    // The caller takes the posts as events and the returns as tasks.
    var all: [constants.mailbox_messages]Event = undefined;
    var taken: u32 = 0;
    for (0..constants.mailbox_messages) |_| taken += pair.loops[caller].tick(&all);
    try testing.expectEqual(constants.mailbox_posts_max, taken);
    for (&clients, 0..) |*client, index| {
        try testing.expectEqual(@as(u32, 1), client.replied);
        try testing.expectEqual(@as(u64, index + 1), client.last_reply);
    }
}

test "the 33rd call to one target is refused, and finish lowers the count where the drain does not" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.stop();
    var clients: [constants.calls_per_pair_max + 1]Client = @splat(.{});
    for (clients[0..constants.calls_per_pair_max]) |*client| try send(&pair, client, 7, .default);
    const extra = &clients[constants.calls_per_pair_max];
    try testing.expectError(error.CallsFull, send(&pair, extra, 7, .default));
    try testing.expect(!extra.call.is_out());
    try testing.expectEqual(constants.calls_per_pair_max, pair.calls_out(caller, target));
    var events: [events_len]Event = undefined;
    _ = pair.loops[target].tick(&events);
    // The caller's drain takes every return, and the count stays: no `finish` has run.
    const model = &pair.loops[caller];
    _ = model.dispatch.begin(&model.heartbeat, 0);
    try testing.expectEqual(@as(u32, 0), model.inbox.drain_mailboxes(caller, &events, fixture.Model.take));
    try testing.expectEqual(constants.calls_per_pair_max, pair.calls_out(caller, target));
    try testing.expectError(error.CallsFull, send(&pair, extra, 7, .default));
    // Each `finish` lowers it, in the task run of the same tick.
    _ = model.dispatch.end(&model.heartbeat, &model.groups, events[0..0]);
    try testing.expectEqual(@as(u32, 0), pair.calls_out(caller, target));
    try send(&pair, extra, 7, .default);
    try testing.expectEqual(@as(u32, 1), pair.calls_out(caller, target));
    _ = pair.loops[target].tick(&events);
    _ = pair.loops[caller].tick(&events);
    try testing.expectEqual(@as(u32, 1), extra.replied);
}

test "the drain takes a call and a return as tasks, with the service's entry and then finish's" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.stop();
    var client: Client = .{};
    try send(&pair, &client, 41, .default);
    const link = &client.call.link;
    try testing.expectEqual(&EchoService.entry, link.task.call);
    var events: [events_len]Event = undefined;
    const tasks_before = pair.loops[target].dispatch.tasks.count;
    const owner = &pair.loops[target];
    _ = owner.dispatch.begin(&owner.heartbeat, 0);
    try testing.expectEqual(@as(u32, 0), owner.inbox.drain_mailboxes(target, &events, fixture.Model.take));
    try testing.expectEqual(tasks_before + 1, owner.dispatch.tasks.count);
    try testing.expect(owner.dispatch.tasks.holds(&link.task));
    try testing.expectEqual(&EchoService.entry, link.task.call);
    try testing.expectEqual(@as(u32, 0), owner.dispatch.end(&owner.heartbeat, &owner.groups, events[0..0]));
    // The return comes back as a task with the `finish` entry, and no event.
    const back = &pair.loops[caller];
    _ = back.dispatch.begin(&back.heartbeat, 0);
    try testing.expectEqual(@as(u32, 0), back.inbox.drain_mailboxes(caller, &events, fixture.Model.take));
    try testing.expect(back.dispatch.tasks.holds(&link.task));
    try testing.expectEqual(link.finish, link.task.call);
    try testing.expect(link.task.call.call_record);
    _ = back.dispatch.end(&back.heartbeat, &back.groups, events[0..0]);
    try testing.expectEqual(@as(u64, 42), client.last_reply);
    try testing.expectEqual(@as(u32, 0), back.dispatch.callbacks_outstanding);
    try testing.expectEqual(@as(u32, 0), owner.dispatch.callbacks_outstanding);
}

/// A client that reads, inside `finish`, the state and the count it sees.
const Watcher = struct {
    call: EchoCall = .init(Watcher, "call", finished),
    out_seen: bool = true,
    count_seen: u32 = std.math.maxInt(u32),
    result: ?std.meta.Tag(fixture.CallResult(u64)) = null,

    fn finished(watcher: *Watcher, result: fixture.CallResult(u64)) void {
        watcher.out_seen = watcher.call.is_out();
        watcher.count_seen = watcher.call.link.calls_out.*;
        watcher.result = result;
    }
};

test "a past deadline and a stopped station answer with no handler run, and finish sees the count fall" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    var events: [events_len]Event = undefined;
    var watcher: Watcher = .{};
    pair.loops[target].clock_ns = 500;
    try pair.service.send(&pair.loops[caller], target, &watcher.call, &@as(u64, 1), .{ .group = .default, .deadline_ns = 500 });
    _ = pair.loops[target].tick(&events);
    _ = pair.loops[caller].tick(&events);
    try testing.expectEqual(@as(u32, 0), pair.echoes[target].handled);
    try testing.expectEqual(.expired, watcher.result.?);
    try testing.expect(!watcher.out_seen);
    try testing.expectEqual(@as(u32, 0), watcher.count_seen);
    // A deadline after the target's clock lets the handler run.
    try pair.service.send(&pair.loops[caller], target, &watcher.call, &@as(u64, 1), .{ .group = .default, .deadline_ns = 501 });
    _ = pair.loops[target].tick(&events);
    _ = pair.loops[caller].tick(&events);
    try testing.expectEqual(@as(u32, 1), pair.echoes[target].handled);
    try testing.expectEqual(.replied, watcher.result.?);
    // A target that stopped answers `target_stopped`.
    pair.service.stop_serving(&pair.loops[target]);
    try pair.service.send(&pair.loops[caller], target, &watcher.call, &@as(u64, 1), .{ .group = .default });
    _ = pair.loops[target].tick(&events);
    _ = pair.loops[caller].tick(&events);
    try testing.expectEqual(@as(u32, 1), pair.echoes[target].handled);
    try testing.expectEqual(.target_stopped, watcher.result.?);
    pair.service.stop_serving(&pair.loops[caller]);
}

test "a station that stops after its drain took a call answers target_stopped with no handler run" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.service.stop_serving(&pair.loops[caller]);
    var client: Client = .{};
    try send(&pair, &client, 6, .default);
    // The target's drain takes the call while the station serves, so the call's task is queued.
    const owner = &pair.loops[target];
    var events: [events_len]Event = undefined;
    _ = owner.dispatch.begin(&owner.heartbeat, 0);
    try testing.expectEqual(@as(u32, 0), owner.inbox.drain_mailboxes(target, &events, fixture.Model.take));
    try testing.expect(owner.dispatch.tasks.holds(&client.call.link.task));
    // The station stops before the task runs, so the task's verdict answers the call.
    pair.service.stop_serving(owner);
    _ = owner.dispatch.end(&owner.heartbeat, &owner.groups, events[0..0]);
    try testing.expectEqual(@as(u32, 0), pair.echoes[target].handled);
    _ = pair.loops[caller].tick(&events);
    try testing.expectEqual(@as(u32, 1), client.stopped);
    try testing.expectEqual(@as(u32, 0), client.replied);
    try testing.expectEqual(@as(u32, 0), pair.calls_out(caller, target));
    try testing.expectEqual(@as(u32, 0), owner.dispatch.callbacks_outstanding);
}

test "a call to self whose station stops before its task runs answers target_stopped" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.service.stop_serving(&pair.loops[target]);
    const model = &pair.loops[caller];
    var client: Client = .{};
    // The station serves at the send, so the call's task is queued.
    try pair.service.send(model, caller, &client.call, &@as(u64, 6), .{ .group = .default });
    try testing.expect(model.dispatch.tasks.holds(&client.call.link.task));
    pair.service.stop_serving(model);
    var events: [events_len]Event = undefined;
    _ = model.tick(&events);
    _ = model.tick(&events);
    try testing.expectEqual(@as(u32, 0), pair.echoes[caller].handled);
    try testing.expectEqual(@as(u32, 1), client.stopped);
    try testing.expectEqual(@as(u32, 0), client.replied);
    try testing.expectEqual(@as(u32, 0), model.dispatch.callbacks_outstanding);
}

test "a call in a named group runs the handler and finish in that group, on a loop that only calls" {
    var pair: Pair = undefined;
    pair.init(&Declared.table);
    // The caller serves nothing: it only calls.
    pair.service.stop_serving(&pair.loops[caller]);
    defer pair.service.stop_serving(&pair.loops[target]);
    var events: [events_len]Event = undefined;
    for ([_]@TypeOf(Declared.group(.low)){ Declared.group(.high), Declared.group(.low), .default }) |group| {
        var client: Client = .{ .model = &pair.loops[caller] };
        try send(&pair, &client, 3, group);
        _ = pair.loops[target].tick(&events);
        try testing.expectEqual(@intFromEnum(group), pair.echoes[target].last_group);
        _ = pair.loops[caller].tick(&events);
        try testing.expectEqual(@as(u32, 1), client.replied);
        try testing.expectEqual(@intFromEnum(group), client.last_group);
    }
}

/// A task of the program that does nothing.
fn nothing(_: *Task) void {}
const nothing_call: Task.Call = .{ .name = "test.nothing", .function = nothing };

/// The program's tasks that fill one group to its cap.
var fillers: [constants.tasks_queued_max]Task align(@alignOf(Task)) = undefined;

test "a group that the program filled refuses schedule_in, and its drain still takes a call" {
    var pair: Pair = undefined;
    pair.init(&Declared.table);
    defer pair.stop();
    const owner = &pair.loops[target];
    const high = Declared.group(.high).scheduling_group();
    for (&fillers) |*filler| {
        filler.* = .{ .call = &nothing_call };
        try owner.dispatch.schedule_in(&owner.groups, high, filler);
    }
    var spare: Task = .{ .call = &nothing_call };
    try testing.expectError(error.TasksFull, owner.dispatch.schedule_in(&owner.groups, high, &spare));
    var client: Client = .{};
    try send(&pair, &client, 9, Declared.group(.high));
    var events: [events_len]Event = undefined;
    _ = owner.tick(&events);
    try testing.expect(client.call.link.state == .held or client.call.link.state == .answered);
    var ticks: u32 = 0;
    while (client.replied == 0 and ticks < constants.tasks_queued_max) : (ticks += 1) {
        _ = owner.tick(&events);
        _ = pair.loops[caller].tick(&events);
    }
    try testing.expectEqual(@as(u32, 1), client.replied);
    while (owner.queued() != 0) _ = owner.tick(&events);
}

test "a stall of a call's task names the service on the target and the field of finish on the caller" {
    var pair: Pair = undefined;
    pair.init(&Declared.table);
    defer pair.stop();
    var starts: [1]u64 = .{0};
    var statistics: statistics_module.Statistics = undefined;
    statistics.init(.{}, &starts);
    var client: Client = .{};
    try send(&pair, &client, 5, Declared.group(.low));
    var events: [events_len]Event = undefined;
    for ([_]fixture.LoopId{ target, caller }, [_][]const u8{ @typeName(EchoService), "call_test_fixture.Client.call" }) |id, name| {
        const model = &pair.loops[id];
        model.heartbeat = .init(10);
        model.heartbeat.note_clock(&statistics, &model.dispatch.pollers, 100);
        _ = model.tick(&events);
        model.heartbeat.note_clock(&statistics, &model.dispatch.pollers, 200);
        try testing.expectEqual(@as(u32, 1), statistics.last_stall.callbacks);
        try testing.expectEqual(@as(?SchedulingGroup, Declared.group(.low).scheduling_group()), statistics.last_stall.group);
        try testing.expect(std.mem.endsWith(u8, std.mem.span(statistics.last_stall.name.?), name));
    }
    try testing.expectEqual(@as(u32, 1), client.replied);
}

test "a call to self takes no ring, counts twice, and ends with one finish" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.stop();
    var client: Client = .{};
    const model = &pair.loops[caller];
    try pair.service.send(model, caller, &client.call, &@as(u64, 20), .{ .group = .default });
    try testing.expectEqual(@as(u32, 3), model.dispatch.callbacks_outstanding);
    try testing.expect(pair.registry.mailbox(caller, caller).is_empty());
    var events: [events_len]Event = undefined;
    _ = model.tick(&events);
    _ = model.tick(&events);
    try testing.expectEqual(@as(u32, 1), client.replied);
    try testing.expectEqual(@as(u64, 21), client.last_reply);
    try testing.expectEqual(@as(u32, 0), model.dispatch.callbacks_outstanding);
    try testing.expectEqual(@as(u32, 0), pair.service.stations[caller].self_out);
    try testing.expectEqual(@as(u32, 0), pair.echoes[target].handled);
}

test "a held call answered later returns once, and the record may go out again from finish" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.stop();
    pair.echoes[target].mode = .later;
    var client: Client = .{};
    try send(&pair, &client, 10, .default);
    var events: [events_len]Event = undefined;
    _ = pair.loops[target].tick(&events);
    _ = pair.loops[caller].tick(&events);
    try testing.expectEqual(@as(u32, 0), client.finishes);
    try testing.expectEqual(@as(u32, 1), pair.service.stations[target].held);
    pair.echoes[target].answer_oldest();
    try testing.expectEqual(@as(u32, 1), pair.loops[caller].dispatch.callbacks_outstanding);
    _ = pair.loops[caller].tick(&events);
    try testing.expectEqual(@as(u32, 1), client.replied);
    try testing.expectEqual(@as(u64, 11), client.last_reply);
    try testing.expectEqual(@as(u32, 0), pair.loops[target].dispatch.callbacks_outstanding);
}

test "a call wakes a target that said it sleeps, and the answer wakes the caller" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.stop();
    var client: Client = .{};
    pair.registry.begin_sleep(target);
    try send(&pair, &client, 1, .default);
    try testing.expectEqual(@as(u32, 1), pair.loops[caller].wakes);
    pair.registry.end_sleep(target);
    pair.registry.begin_sleep(caller);
    var events: [events_len]Event = undefined;
    _ = pair.loops[target].tick(&events);
    try testing.expectEqual(@as(u32, 1), pair.loops[target].wakes);
    pair.registry.end_sleep(caller);
    _ = pair.loops[caller].tick(&events);
    try testing.expectEqual(@as(u32, 1), client.replied);
}
