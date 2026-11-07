//! Tests of `inbox.zig`: the sender cursor of `Inbox.drain_mailboxes` (W3, ruled 2026-11-07), and
//! the drain of a `Message.wake` (decision 29). In a file of their own because the property test
//! holds a registry of 64 loops in a static, which a library file may not declare (tools/lint
//! global-state).
const std = @import("std");
const constants = @import("constants.zig");
const event = @import("event.zig");
const inbox_module = @import("inbox.zig");
const mailbox = @import("mailbox.zig");
const operation = @import("operation.zig");

const Dispatch = @import("dispatch/dispatch.zig").Dispatch;
const Event = event.Event;
const Inbox = inbox_module.Inbox;
const Message = operation.Message;
const Poller = @import("dispatch/dispatch.zig").Poller;
const WaitLimit = @import("dispatch/dispatch.zig").WaitLimit;
const LoopId = operation.LoopId;
const Registry = mailbox.Registry;
const testing = std.testing;
const layout = @import("layout.zig");
const Random = @import("random.zig").Random;

/// The loops of the registry the cursor tests build: a receiver and four senders.
const test_loops = 5;
const test_registry_bytes = Registry.memory_bytes(test_loops);

/// A registry of `test_loops` loops on this thread, and the inbox of one of them.
const TestInbox = struct {
    memory: [test_registry_bytes]u8 align(layout.memory_alignment),
    registry: Registry,
    inbox: Inbox,
    dispatch: Dispatch,

    fn init(fixture: *TestInbox) void {
        fixture.registry.init(&fixture.memory, test_loops);
        fixture.inbox = Inbox.init(&fixture.registry, &.{}, null);
        fixture.dispatch = .empty;
    }

    /// Pushes `count` messages from `sender` to `receiver`, each tagged with the sender's id.
    fn fill(fixture: *TestInbox, sender: LoopId, receiver: LoopId, count: u32) !void {
        const ring = fixture.registry.mailbox(sender, receiver);
        for (0..count) |payload| {
            try testing.expect(ring.push(.{ .payload = payload, .tag = sender }));
        }
    }

    /// One drain into `events`. It writes the sender of each event, its tag, to `senders`.
    fn drain(fixture: *TestInbox, receiver: LoopId, events: []Event, senders: []u8) !u32 {
        const count = fixture.inbox.drain_mailboxes(receiver, events, &fixture.dispatch);
        for (events[0..count], senders[0..count]) |message, *sender| {
            try testing.expect(message.flags.message);
            sender.* = '0' + @as(u8, @intCast(message.result));
        }
        return count;
    }
};

test "the senders take turns, and each comes once before any comes again" {
    var fixture: TestInbox = undefined;
    fixture.init();
    for (1..test_loops) |sender| try fixture.fill(@intCast(sender), 0, 8);
    var events: [3]Event = undefined;
    var senders: [36]u8 = undefined;
    var written: u32 = 0;
    for (0..12) |_| written += try fixture.drain(0, &events, senders[written..]);
    // Room for 3 of 8: the drain that the room cuts moves the cursor to the next sender.
    try testing.expectEqualStrings("111222333444111222333444112334" ++ "24", senders[0..written]);
}

test "the cursor moves one past the last sender the drain visited" {
    var fixture: TestInbox = undefined;
    fixture.init();
    for (1..test_loops) |sender| try fixture.fill(@intCast(sender), 0, 8);
    var events: [10]Event = undefined;
    var senders: [10]u8 = undefined;
    try testing.expectEqual(@as(u32, 10), try fixture.drain(0, &events, &senders));
    try testing.expectEqualStrings("1111111122", &senders);
    try testing.expectEqual(@as(LoopId, 3), fixture.inbox.sender_cursor);
    try testing.expectEqual(@as(u32, 1), try fixture.drain(0, events[0..1], &senders));
    try testing.expectEqual(@as(u8, '3'), senders[0]);
}

test "the cursor wraps past the last loop and never visits the receiver" {
    var fixture: TestInbox = undefined;
    fixture.init();
    const receiver: LoopId = 2;
    for (0..test_loops) |sender| {
        if (sender != receiver) try fixture.fill(@intCast(sender), receiver, 4);
    }
    // The ring from a loop to itself is there and unused. A drain that read it would hand this
    // message over.
    try fixture.fill(receiver, receiver, 1);
    fixture.inbox.sender_cursor = 3;
    var events: [3]Event = undefined;
    var senders: [16]u8 = undefined;
    var written: u32 = 0;
    for (0..7) |_| written += try fixture.drain(receiver, &events, senders[written..]);
    try testing.expectEqualStrings("333444000111340" ++ "1", senders[0..written]);
    try testing.expect(!fixture.registry.mailbox(receiver, receiver).is_empty());
    // A drain with room to spare passes the receiver after the wrap, and still skips it.
    for (0..test_loops) |sender| {
        if (sender != receiver) try fixture.fill(@intCast(sender), receiver, 4);
    }
    fixture.inbox.sender_cursor = 3;
    var wide: [20]Event = undefined;
    var wide_senders: [20]u8 = undefined;
    try testing.expectEqual(@as(u32, 16), try fixture.drain(receiver, &wide, &wide_senders));
    try testing.expectEqualStrings("3333444400001111", wide_senders[0..16]);
    try testing.expect(!fixture.registry.mailbox(receiver, receiver).is_empty());
}

test "an empty ring costs a visit and no room" {
    var fixture: TestInbox = undefined;
    fixture.init();
    try fixture.fill(2, 0, 1);
    try fixture.fill(3, 0, 1);
    var events: [1]Event = undefined;
    var senders: [1]u8 = undefined;
    try testing.expectEqual(@as(u32, 1), try fixture.drain(0, &events, &senders));
    try testing.expectEqual(@as(u8, '2'), senders[0]);
    try testing.expectEqual(@as(LoopId, 3), fixture.inbox.sender_cursor);
}

/// A poller that answers `.none`, so the table is not empty.
const Idle = struct {
    poller: Poller = .init(Idle, "poller", polled),

    fn polled(_: *Idle) WaitLimit {
        return .none;
    }
};

test "a wake writes no event, counts in its ring's visit, and stores now only with a poller" {
    var fixture: TestInbox = undefined;
    fixture.init();
    const ring = fixture.registry.mailbox(1, 0);
    for (0..constants.messages_per_drain) |_| try testing.expect(ring.push(Message.wake));
    try fixture.fill(1, 0, 1);
    try fixture.fill(2, 0, 1);
    var events: [2 * constants.messages_per_drain]Event = undefined;
    var senders: [2 * constants.messages_per_drain]u8 = undefined;
    // The wakes fill sender 1's visit, so its message waits, and sender 2's is the one event.
    try testing.expectEqual(@as(u32, 1), try fixture.drain(0, &events, &senders));
    try testing.expectEqual(@as(u8, '2'), senders[0]);
    // With no poller in the table, the wakes store nothing.
    try testing.expectEqual(WaitLimit.none, fixture.dispatch.until_ns);
    try testing.expectEqual(@as(u32, 1), try fixture.drain(0, &events, &senders));
    try testing.expectEqual(@as(u8, '1'), senders[0]);
    // With a poller, a wake stores now.
    var idle: Idle = .{};
    try fixture.dispatch.add_poller(&idle.poller);
    try testing.expect(ring.push(Message.wake));
    try testing.expect(fixture.inbox.holds_messages(0));
    try testing.expectEqual(@as(u32, 0), try fixture.drain(0, &events, &senders));
    try testing.expectEqual(WaitLimit.now, fixture.dispatch.until_ns);
    try testing.expect(!fixture.inbox.holds_messages(0));
}

test "a drain from a cursor stores now for a wake in a ring before the last one it visits" {
    var fixture: TestInbox = undefined;
    fixture.init();
    var idle: Idle = .{};
    try fixture.dispatch.add_poller(&idle.poller);
    // From cursor 3 the drain visits 3, 4, 1 and 2. The wake is in the first ring, and the one
    // message in the last, so the drain must sum what every visit took.
    try testing.expect(fixture.registry.mailbox(3, 0).push(Message.wake));
    try fixture.fill(2, 0, 1);
    fixture.inbox.sender_cursor = 3;
    var events: [4]Event = undefined;
    var senders: [4]u8 = undefined;
    try testing.expectEqual(@as(u32, 1), try fixture.drain(0, &events, &senders));
    try testing.expectEqual(@as(u8, '2'), senders[0]);
    try testing.expectEqual(WaitLimit.now, fixture.dispatch.until_ns);
}

test "holds_messages reads every ring to the receiver, and not the ring from itself" {
    var fixture: TestInbox = undefined;
    fixture.init();
    try testing.expect(!fixture.inbox.holds_messages(2));
    try fixture.fill(2, 2, 1);
    try testing.expect(!fixture.inbox.holds_messages(2));
    try fixture.fill(4, 2, 1);
    try testing.expect(fixture.inbox.holds_messages(2));
    try testing.expect(!fixture.inbox.holds_messages(3));
}

/// The drains within which a sender with messages is visited, with `loops` loops and a room of
/// `room` events (W3, section 3.6): `ceil((L - 2) / ceil(M / 32)) + 1`.
fn visit_bound(loops: u32, room: u32) u32 {
    const visits = std.math.divCeil(u32, room, constants.messages_per_drain) catch unreachable;
    return (std.math.divCeil(u32, loops - 2, visits) catch unreachable) + 1;
}

/// The most events a mailbox reserve holds: a quarter of a batch.
const reserve_events_max = constants.batch_max / constants.mailbox_share_divisor;

/// Drains `inbox` with a room of `room` events `visit_bound` times. It fails when it did not visit
/// a sender that `holds` marks.
fn expect_visits(inbox: *Inbox, receiver: LoopId, loops: u32, room: u32, holds: []const bool) !void {
    var events: [reserve_events_max]Event = undefined;
    var seen: [constants.loops_max]bool = @splat(false);
    var dispatch: Dispatch = .empty;
    for (0..visit_bound(loops, room)) |_| {
        const count = inbox.drain_mailboxes(receiver, events[0..room], &dispatch);
        for (events[0..count]) |message| seen[@intCast(message.result)] = true;
    }
    for (holds[0..loops], seen[0..loops]) |held, visited| try testing.expect(!held or visited);
}

/// The two rooms of the mailbox reserve the start test drains with: for `N = 10` and `N = 64`.
const start_rooms = [_]u32{
    @max(1, constants.fair_events_min / constants.mailbox_share_divisor),
    @max(1, 64 / constants.mailbox_share_divisor),
};

/// One case of the start test: `receiver` drains, from `start`, with a room of `room`.
fn expect_start(fixture: *TestInbox, receiver: LoopId, start: LoopId, room: u32) !void {
    fixture.init();
    var holds: [test_loops]bool = @splat(true);
    holds[receiver] = false;
    for (0..test_loops) |sender| {
        if (sender != receiver) try fixture.fill(@intCast(sender), receiver, 64);
    }
    fixture.inbox.sender_cursor = start;
    try expect_visits(&fixture.inbox, receiver, test_loops, room, &holds);
}

test "from every start, every sender is visited within the bound" {
    var fixture: TestInbox = undefined;
    for (0..test_loops * test_loops) |case| {
        const receiver: LoopId = @intCast(case / test_loops);
        const start: LoopId = @intCast(case % test_loops);
        if (start == receiver) continue;
        for (start_rooms) |room| try expect_start(&fixture, receiver, start, room);
    }
}

/// The property test's registry, sized for the most loops it draws.
const property_loops_max = 64;
const property_registry_bytes = Registry.memory_bytes(property_loops_max);
var property_memory: [property_registry_bytes]u8 align(layout.memory_alignment) = undefined;

/// The most events the property test draws for one tick.
const property_events_max = 512;

/// The seeds the property test runs.
const property_seeds = 256;

/// One seed: a registry of 2 to 64 loops, a receiver, a start, a tick of `N` events and which
/// senders hold messages. The drains visit each sender that holds one within the bound of W3.
fn property_run(seed: u64) !void {
    errdefer std.debug.print("inbox cursor property failed: seed {d}\n", .{seed});
    var random = Random.init(seed);
    const loops: u16 = @intCast(random.between(2, property_loops_max));
    var registry: Registry = undefined;
    registry.init(property_memory[0..Registry.memory_bytes(loops)], loops);
    var inbox = Inbox.init(&registry, &.{}, null);
    const receiver: LoopId = @intCast(random.below(loops));
    inbox.sender_cursor = @intCast(random.below(loops));
    const events_len = random.between(constants.fair_events_min, property_events_max);
    const room: u32 = @intCast(@max(1, events_len / constants.mailbox_share_divisor));
    var holds: [property_loops_max]bool = @splat(false);
    for (0..loops) |sender| {
        if (sender == receiver or !random.chance(1, 2)) continue;
        holds[sender] = true;
        const ring = registry.mailbox(@intCast(sender), receiver);
        const count = random.between(1, constants.mailbox_messages);
        for (0..count) |payload| {
            try testing.expect(ring.push(.{ .payload = payload, .tag = @intCast(sender) }));
        }
    }
    try expect_visits(&inbox, receiver, loops, room, &holds);
}

test "property: every sender with messages is visited within the bound, from any start" {
    for (0..property_seeds) |seed| try property_run(seed);
}
