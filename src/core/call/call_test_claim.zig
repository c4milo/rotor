//! The unit tests of a station whose loop ended (decision 32, "What was built", item 8): a later
//! loop that claims the id finds the station as the earlier loop left it. The model loops of
//! `call_test_fixture.zig` stand in for both loops, on one registry, ticked on this thread.
const std = @import("std");
const testing = std.testing;
const constants = @import("../constants.zig");
const fixture = @import("call_test_fixture.zig");

const Client = fixture.Client;
const Event = fixture.Event;
const Model = fixture.Model;
const Pair = fixture.Pair(2);

const caller: fixture.LoopId = 0;
const target: fixture.LoopId = 1;

/// Room for every message of one visit.
const events_len = 2 * constants.messages_per_drain;

/// Loop `id` of `pair` stops serving and ends, and `claimer`, at another address, claims the id
/// and does not serve.
fn claim(pair: *Pair, id: fixture.LoopId, claimer: *Model) void {
    pair.service.stop_serving(&pair.loops[id]);
    pair.registry.clear(id);
    claimer.init(&pair.registry, id, &.empty);
}

test "a loop that claims an id and does not serve answers target_stopped in its drain" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.service.stop_serving(&pair.loops[caller]);
    var claimer: Model = undefined;
    claim(&pair, target, &claimer);
    // The station still names the loop that ended, which the claimer must not reach.
    try testing.expectEqual(@as(?*anyopaque, &pair.loops[target]), pair.service.stations[target].loop);
    var client: Client = .{};
    try pair.service.send(&pair.loops[caller], target, &client.call, &@as(u64, 4), .{ .group = .default });
    pair.registry.begin_sleep(caller);
    var events: [events_len]Event = undefined;
    _ = claimer.tick(&events);
    // The drain answered: no task is queued, nothing is owed, and the caller that sleeps woke.
    try testing.expectEqual(@as(u32, 0), claimer.queued());
    try testing.expectEqual(@as(u32, 0), claimer.dispatch.callbacks_outstanding);
    try testing.expectEqual(@as(u32, 1), claimer.wakes);
    try testing.expectEqual(@as(u32, 0), pair.loops[target].dispatch.callbacks_outstanding);
    pair.registry.end_sleep(caller);
    _ = pair.loops[caller].tick(&events);
    try testing.expectEqual(@as(u32, 1), client.stopped);
    try testing.expectEqual(@as(u32, 0), pair.echoes[target].handled);
    try testing.expectEqual(@as(u32, 0), pair.calls_out(caller, target));
}

test "a loop that claims an id counts a stopped station at its call to self, until the finish" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.service.stop_serving(&pair.loops[target]);
    const station = &pair.service.stations[caller];
    try testing.expectEqual(@as(?*fixture.Groups, &pair.loops[caller].groups), station.attached);
    var claimer: Model = undefined;
    claim(&pair, caller, &claimer);
    // The loop that ended counts no station, so the claimer starts from none.
    try testing.expectEqual(@as(u8, 0), pair.loops[caller].groups.stations);
    try testing.expectEqual(@as(?*fixture.Groups, null), station.attached);
    var client: Client = .{};
    try pair.service.send(&claimer, caller, &client.call, &@as(u64, 8), .{ .group = .default });
    try testing.expectEqual(@as(u8, 1), claimer.groups.stations);
    try testing.expectEqual(@as(?*fixture.Groups, &claimer.groups), station.attached);
    var events: [events_len]Event = undefined;
    _ = claimer.tick(&events);
    try testing.expectEqual(@as(u32, 1), client.stopped);
    try testing.expectEqual(@as(u32, 0), pair.echoes[caller].handled);
    try testing.expectEqual(@as(u8, 0), claimer.groups.stations);
    try testing.expectEqual(@as(?*fixture.Groups, null), station.attached);
    try testing.expectEqual(@as(u32, 0), claimer.dispatch.callbacks_outstanding);
}

test "a station stays counted while it serves or holds a call to self" {
    var pair: Pair = undefined;
    pair.init(&.empty);
    defer pair.service.stop_serving(&pair.loops[target]);
    const model = &pair.loops[caller];
    try testing.expectEqual(@as(u8, 1), model.groups.stations);
    var client: Client = .{};
    try pair.service.send(model, caller, &client.call, &@as(u64, 2), .{ .group = .default });
    pair.service.stop_serving(model);
    // The call to self has not run its finish, so the station stays counted.
    try testing.expectEqual(@as(u8, 1), model.groups.stations);
    var events: [events_len]Event = undefined;
    _ = model.tick(&events);
    _ = model.tick(&events);
    try testing.expectEqual(@as(u32, 1), client.finishes);
    try testing.expectEqual(@as(u8, 0), model.groups.stations);
    // A remote call counts no station on the caller.
    try pair.service.send(model, target, &client.call, &@as(u64, 3), .{ .group = .default });
    try testing.expectEqual(@as(u8, 0), model.groups.stations);
    _ = pair.loops[target].tick(&events);
    _ = model.tick(&events);
    try testing.expectEqual(@as(u32, 2), client.finishes);
}
