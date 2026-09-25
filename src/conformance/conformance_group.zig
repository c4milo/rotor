//! Scenarios for loops in several processes (decision 21): a registry in memory two processes share,
//! the wakes its creator made, and a second process started by `fork` after both exist. The parent
//! runs loop 0 and a child runs loop 1.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const process = @import("conformance_process.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const Registry = backend.Registry;
const Wake = core.mailbox.Wake;
const Memory = []align(core.layout.memory_alignment) u8;

const loops = 2;
const tag_ping = 1;
const tag_pong = 2;
const payload_ping = 41;
const payload_left = 43;

/// The longest a loop sleeps in a scenario that expects a post to wake it: far longer than a wake
/// takes, so a loop nobody woke shows as one that slept it out.
const sleep_ns = 2 * core.constants.ns_per_s;
/// How long one side waits for the other's loop to say it sleeps, in ticks of `round_ns`.
const sleep_rounds_max = 2000;
const round_ns = core.constants.ns_per_ms;

/// What a child exits with, each naming what went wrong in it.
const status_attach_failed: u8 = 1;
const status_loop_failed: u8 = 2;
const status_never_slept: u8 = 3;
const status_post_refused: u8 = 4;
const status_wrong_message: u8 = 5;
const status_slept_through: u8 = 6;

/// A registry two processes share, and the wakes its creator made. The creator keeps its copies of
/// the wakes until `deinit`.
const Group = struct {
    memory: Memory,
    wakes: [loops]Wake,
    registry: Registry,

    fn init(group: *Group) !void {
        group.memory = try process.shared_memory(Registry.memory_bytes(loops));
        errdefer process.release_memory(group.memory);
        try backend.group_module.make(&group.wakes);
        group.registry.init_group(group.memory, loops, &group.wakes);
    }

    fn deinit(group: *Group) void {
        backend.group_module.close(&group.wakes);
        process.release_memory(group.memory);
    }
};

/// Ticks `harness` until loop `id` of `registry` says it sleeps, or the rounds run out.
fn wait_until_asleep(harness: *Harness, registry: *Registry, id: core.LoopId) bool {
    var events: [1]Event = undefined;
    for (0..sleep_rounds_max) |_| {
        if (registry.must_wake(id)) return true;
        _ = harness.loop.tick(&events, round_ns) catch return false;
    }
    return false;
}

/// Posts `message` to `target` and waits for the post's own event.
fn post_once(harness: *Harness, target: core.LoopId, message: core.Message) u8 {
    harness.submit(&.{Operation.post(9, target, message)}, &.{}) catch return status_loop_failed;
    var events: [1]Event = undefined;
    harness.collect(&events) catch return status_loop_failed;
    const result = events[0].outcome() catch return status_post_refused;
    return if (result == 0) process.status_passed else status_post_refused;
}

/// The child: attaches, runs loop 1, waits until loop 0 says it sleeps, and posts to it once.
fn post_to_a_sleeping_loop(memory: Memory) u8 {
    var member: Registry = undefined;
    member.attach(memory) catch return status_attach_failed;
    var harness: Harness = undefined;
    harness.init(1, &member) catch return status_loop_failed;
    defer harness.deinit();
    if (!wait_until_asleep(&harness, &member, 0)) return status_never_slept;
    return post_once(&harness, 0, .{ .payload = payload_ping, .tag = tag_ping });
}

/// How long a tick waits after a wake, to show the wake was emptied: a loop that left it would find
/// its wake ready again and return at once.
const settle_ns = 20 * core.constants.ns_per_ms;

// Each scenario starts its child before the parent's loop, so the child holds none of the parent
// loop's own descriptors: a wake reaches the parent only through what the group's creator made.

test "a post from another process wakes a loop that sleeps, and the loop sleeps again after" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var group: Group = undefined;
    try group.init();
    defer group.deinit();
    const child = try process.start(Memory, group.memory, post_to_a_sleeping_loop);
    var harness: Harness = undefined;
    try harness.init(0, &group.registry);
    defer harness.deinit();

    var events: [1]Event = undefined;
    const before = backend.testing.monotonic_ns();
    const produced = try harness.loop.tick(&events, sleep_ns);
    const slept = backend.testing.monotonic_ns() - before;
    try testing.expectEqual(process.status_passed, try process.wait(child));
    try testing.expectEqual(@as(u32, 1), produced);
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(@as(u64, payload_ping), events[0].user_data);
    // A loop nobody woke would have slept the whole wait before it read the message.
    try testing.expect(slept < sleep_ns / 2);

    const settled = backend.testing.monotonic_ns();
    try testing.expectEqual(@as(u32, 0), try harness.loop.tick(&events, settle_ns));
    try testing.expect(backend.testing.monotonic_ns() - settled >= settle_ns / 2);
}

/// The child: runs loop 1, sleeps until a ping comes, and answers it with a pong.
fn answer_a_ping(memory: Memory) u8 {
    var member: Registry = undefined;
    member.attach(memory) catch return status_attach_failed;
    var harness: Harness = undefined;
    harness.init(1, &member) catch return status_loop_failed;
    defer harness.deinit();
    var events: [1]Event = undefined;
    const before = backend.testing.monotonic_ns();
    const produced = harness.loop.tick(&events, sleep_ns) catch return status_loop_failed;
    if (backend.testing.monotonic_ns() - before >= sleep_ns / 2) return status_slept_through;
    if (produced != 1 or !events[0].flags.message) return status_wrong_message;
    if (events[0].result != tag_ping) return status_wrong_message;
    return post_once(&harness, 0, .{ .payload = events[0].user_data + 1, .tag = tag_pong });
}

test "a message crosses to a loop that sleeps in another process, and its answer comes back" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var group: Group = undefined;
    try group.init();
    defer group.deinit();
    const child = try process.start(Memory, group.memory, answer_a_ping);
    var harness: Harness = undefined;
    try harness.init(0, &group.registry);
    defer harness.deinit();

    try testing.expect(wait_until_asleep(&harness, &group.registry, 1));
    const ping: core.Message = .{ .payload = payload_ping, .tag = tag_ping };
    try testing.expectEqual(process.status_passed, post_once(&harness, 1, ping));
    var events: [1]Event = undefined;
    try harness.collect(&events);
    try testing.expectEqual(process.status_passed, try process.wait(child));
    try testing.expect(events[0].flags.message);
    try testing.expectEqual(@as(i32, tag_pong), events[0].result);
    try testing.expectEqual(@as(u64, payload_ping + 1), events[0].user_data);
}

/// The child: attaches and runs loop 1, then exits without withdrawing it, as a process that died
/// would.
fn die_holding_a_loop(memory: Memory) u8 {
    var member: Registry = undefined;
    member.attach(memory) catch return status_attach_failed;
    var harness: Harness = undefined;
    harness.init(1, &member) catch return status_loop_failed;
    return process.status_passed;
}

/// The second child: claims loop 1 again, and reads what was posted to the dead one.
fn take_a_loop_over(memory: Memory) u8 {
    var member: Registry = undefined;
    member.attach(memory) catch return status_attach_failed;
    var harness: Harness = undefined;
    harness.init(1, &member) catch return status_loop_failed;
    defer harness.deinit();
    var events: [1]Event = undefined;
    harness.collect(&events) catch return status_wrong_message;
    if (!events[0].flags.message or events[0].user_data != payload_left) return status_wrong_message;
    return process.status_passed;
}

test "a loop whose process died is released, and a new process takes its rings over" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var group: Group = undefined;
    try group.init();
    defer group.deinit();
    var harness: Harness = undefined;
    try harness.init(0, &group.registry);
    defer harness.deinit();
    const dead = try process.start(Memory, group.memory, die_holding_a_loop);
    try testing.expectEqual(process.status_passed, try process.wait(dead));

    // The dead loop still publishes its wake, so a post to it is taken into its ring.
    try testing.expect(group.registry.get(1) >= 0);
    const left: core.Message = .{ .payload = payload_left, .tag = tag_ping };
    try testing.expectEqual(process.status_passed, post_once(&harness, 1, left));

    // Once released, the id runs no loop, until a new process claims it.
    group.registry.release(1);
    try harness.submit(&.{Operation.post(9, 1, left)}, &.{});
    var events: [1]Event = undefined;
    try harness.collect(&events);
    try testing.expectError(error.LoopNotFound, events[0].outcome());
    const heir = try process.start(Memory, group.memory, take_a_loop_over);
    try testing.expectEqual(process.status_passed, try process.wait(heir));
}

/// The child: attaches, claims id 1 as a `Remote`, which runs no loop, waits until loop 0 says it
/// sleeps, and posts to it once.
fn post_from_a_remote(memory: Memory) u8 {
    var member: Registry = undefined;
    member.attach(memory) catch return status_attach_failed;
    var remote: backend.Remote = undefined;
    remote.init(&member, 1) catch return status_loop_failed;
    defer remote.deinit();
    const deadline = backend.testing.monotonic_ns() + sleep_ns;
    while (!member.must_wake(0)) {
        if (backend.testing.monotonic_ns() > deadline) return status_never_slept;
        std.atomic.spinLoopHint();
    }
    remote.post(0, .{ .payload = payload_ping, .tag = tag_ping }) catch return status_post_refused;
    return process.status_passed;
}

test "a post from a Remote in another process wakes a loop that sleeps" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var group: Group = undefined;
    try group.init();
    defer group.deinit();
    const child = try process.start(Memory, group.memory, post_from_a_remote);
    var harness: Harness = undefined;
    try harness.init(0, &group.registry);
    defer harness.deinit();

    var events: [1]Event = undefined;
    const before = backend.testing.monotonic_ns();
    const produced = try harness.loop.tick(&events, sleep_ns);
    const slept = backend.testing.monotonic_ns() - before;
    try testing.expectEqual(process.status_passed, try process.wait(child));
    try testing.expectEqual(@as(u32, 1), produced);
    try testing.expectEqual(@as(u64, payload_ping), events[0].user_data);
    try testing.expect(slept < sleep_ns / 2);
}
