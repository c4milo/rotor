//! The unit tests of `push` and of the port's `push_reserved` (decision 33, amendment of
//! 2026-11-10): a call and a return into a ring, with no kernel. Loops 0 and 1 of the registry run,
//! and id 2 runs no loop.
const std = @import("std");
const testing = std.testing;
const constants = @import("../constants.zig");
const layout = @import("../layout.zig");
const mailbox = @import("../mailbox.zig");
const operation = @import("../operation.zig");
const call_loop = @import("call_loop.zig");

const Descriptor = operation.Descriptor;
const LoopId = operation.LoopId;
const Message = operation.Message;
const Registry = mailbox.Registry;

const origin: LoopId = 0;
const target: LoopId = 1;
const absent: LoopId = 2;
const loops: u16 = 3;
const origin_wake: Descriptor = 100;
const target_wake: Descriptor = 101;
/// The calls out that a test writes in a ring before a return, which the return must not change.
const calls_before: u32 = 3;

const call_message: Message = .{ .payload = 7, .tag = constants.message_tag_call, .reserved = 1 };
const return_message: Message = .{ .payload = 7, .tag = constants.message_tag_return, .reserved = 1 };
const post_message: Message = .{ .payload = 9, .tag = 0 };

/// A registry on which loops 0 and 1 run.
const Fixture = struct {
    memory: [Registry.memory_bytes(loops)]u8 align(layout.memory_alignment),
    registry: Registry,

    fn init(fixture: *Fixture) void {
        fixture.registry.init(&fixture.memory, loops);
        fixture.registry.set(origin, origin_wake);
        fixture.registry.set(target, target_wake);
    }

    /// The ring from `origin` to `target`.
    fn ring(fixture: *Fixture) *mailbox.Mailbox {
        return fixture.registry.mailbox(origin, target);
    }

    /// The messages in the ring from `origin` to `target`.
    fn held(fixture: *Fixture) u32 {
        const ring_of = fixture.ring();
        return ring_of.tail.load(.unordered) -% ring_of.head.load(.unordered);
    }

    /// Fills the slots that a post sees.
    fn fill_posts(fixture: *Fixture) !void {
        for (0..constants.mailbox_posts_max) |_| try testing.expect(fixture.ring().push_post(post_message));
    }
};

test "a call goes into the ring, changes no count, and wakes no loop that is awake" {
    var fixture: Fixture = undefined;
    fixture.init();
    const pushed = try call_loop.push(&fixture.registry, origin, target, call_message);
    try testing.expectEqual(&fixture.ring().calls_out, pushed.calls_out);
    try testing.expectEqual(@as(u32, 0), pushed.calls_out.*);
    try testing.expectEqual(@as(?Descriptor, null), pushed.wake);
    try testing.expectEqual(@as(u32, 1), fixture.held());
}

test "a call to a loop that sleeps returns the descriptor that wakes it" {
    var fixture: Fixture = undefined;
    fixture.init();
    fixture.registry.begin_sleep(target);
    const pushed = try call_loop.push(&fixture.registry, origin, target, call_message);
    try testing.expectEqual(@as(?Descriptor, target_wake), pushed.wake);
    try testing.expectEqual(@as(u32, 1), fixture.held());
}

test "a call to an id that runs no loop is refused, and pushes nothing" {
    var fixture: Fixture = undefined;
    fixture.init();
    try testing.expectError(error.LoopNotFound, call_loop.push(null, origin, target, call_message));
    try testing.expectError(error.LoopNotFound, call_loop.push(&fixture.registry, origin, absent, call_message));
    try testing.expectError(error.LoopNotFound, call_loop.push(&fixture.registry, origin, loops, call_message));
    try testing.expect(fixture.registry.mailbox(origin, absent).is_empty());
    try testing.expectEqual(@as(u32, 0), fixture.held());
}

test "a pair with every call out refuses a call, and so does a ring that the posts filled" {
    var fixture: Fixture = undefined;
    fixture.init();
    fixture.ring().calls_out = constants.calls_per_pair_max;
    try testing.expectError(error.CallsFull, call_loop.push(&fixture.registry, origin, target, call_message));
    try testing.expectEqual(@as(u32, 0), fixture.held());
    fixture.ring().calls_out = 0;
    try fixture.fill_posts();
    try testing.expectError(error.MailboxFull, call_loop.push(&fixture.registry, origin, target, call_message));
    try testing.expectEqual(constants.mailbox_posts_max, fixture.held());
}

test "a return goes into a slot that the posts leave, and changes no count" {
    var fixture: Fixture = undefined;
    fixture.init();
    try fixture.fill_posts();
    fixture.ring().calls_out = calls_before;
    const pushed = try call_loop.push(&fixture.registry, origin, target, return_message);
    try testing.expectEqual(&fixture.ring().calls_out, pushed.calls_out);
    try testing.expectEqual(calls_before, pushed.calls_out.*);
    try testing.expectEqual(@as(?Descriptor, null), pushed.wake);
    try testing.expectEqual(constants.mailbox_posts_max + 1, fixture.held());
}

test "a return wakes a loop that sleeps, and not an id whose loop left" {
    var fixture: Fixture = undefined;
    fixture.init();
    fixture.registry.begin_sleep(target);
    const pushed = try call_loop.push(&fixture.registry, origin, target, return_message);
    try testing.expectEqual(@as(?Descriptor, target_wake), pushed.wake);
    fixture.registry.clear(target);
    const left = try call_loop.push(&fixture.registry, origin, target, return_message);
    try testing.expectEqual(@as(?Descriptor, null), left.wake);
    try testing.expectEqual(@as(u32, 2), fixture.held());
}

/// A loop with the three things `push_reserved` reads, and a wake that counts.
const CountingLoop = struct {
    tables: struct { id: LoopId },
    inbox: struct { registry: ?*Registry },
    woken: u32 = 0,
    last_woken: LoopId = 0,

    pub fn wake_target(loop: *CountingLoop, woken: LoopId, descriptor: Descriptor) void {
        call_loop.assert_wake(loop.tables.id, woken, descriptor);
        loop.woken += 1;
        loop.last_woken = woken;
    }
};

const counting_calls = call_loop.Calls(CountingLoop);

test "push_reserved wakes the target through the loop's own wake, only when it sleeps" {
    var fixture: Fixture = undefined;
    fixture.init();
    var loop: CountingLoop = .{ .tables = .{ .id = origin }, .inbox = .{ .registry = &fixture.registry } };
    const count = try counting_calls.push_reserved(&loop, target, call_message);
    try testing.expectEqual(&fixture.ring().calls_out, count);
    try testing.expectEqual(@as(u32, 0), loop.woken);
    fixture.registry.begin_sleep(target);
    _ = try counting_calls.push_reserved(&loop, target, call_message);
    _ = try counting_calls.push_reserved(&loop, target, return_message);
    try testing.expectEqual(@as(u32, 2), loop.woken);
    try testing.expectEqual(target, loop.last_woken);
    // A refused call wakes no loop.
    try testing.expectError(error.LoopNotFound, counting_calls.push_reserved(&loop, absent, call_message));
    try testing.expectEqual(@as(u32, 2), loop.woken);
    try testing.expectEqual(@as(u32, 3), fixture.held());
}
