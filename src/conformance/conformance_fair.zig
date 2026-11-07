//! The fair tick order (W3, ruled 2026-11-07): a long finished list does not keep the due timers,
//! the kernel's answer or the messages of other loops out of a tick. Each check is the bound of
//! W3, section 3.6, computed from `core.tick_share` and the limits of `constants.zig`, so the
//! scenario holds no count of its own.
//!
//! The loop under test keeps `fair_posts` posts in flight to a loop that never ticks. That loop's
//! ring fills, and every later post ends at the flush with `mailbox_full`. So the finished list of
//! the loop under test holds about `fair_posts` entries at every tick, on every backend.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const constants = @import("constants.zig");
const tcp = @import("conformance_tcp.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const Remote = backend.Remote;
const builtin = @import("builtin");
const linux = std.os.linux;

/// The ids of the main scenario's registry: the loop under test, the loop that never ticks, and
/// the first of the remotes that post to the loop under test.
const tested_id: core.LoopId = 0;
const idle_id: core.LoopId = 1;
const remote_id_first: core.LoopId = 2;
const remotes = constants.fair_loops - remote_id_first;

/// The user data of the operations of the loop under test.
const post_user_data = 1;
const receive_user_data = 2;
const timer_user_data = 3;

/// The tag of the one message the last remote posts in each round. The other remotes tag theirs
/// with their own ids, which are below it.
const probe_tag = constants.fair_loops;

/// The loop under test, with room for `fair_operations` operations.
pub const FairLoop = struct {
    memory: [memory_bytes]u8 align(core.layout.memory_alignment),
    loop: backend.Loop,

    const memory_bytes = backend.Loop.memory_bytes(.{
        .operations = constants.fair_operations,
        .entries = conformance.entries,
    });

    pub fn init(fair: *FairLoop, registry: ?*backend.Registry) !void {
        try fair.loop.init(&fair.memory, .{
            .operations = constants.fair_operations,
            .entries = conformance.entries,
            .id = tested_id,
            .registry = registry,
            .spin_budget_ns = conformance.spin_budget_ns(),
        });
    }

    /// Submits `count` copies of `operation`, all or none.
    pub fn submit_copies(fair: *FairLoop, operation: Operation, count: u32) !void {
        var batch: [constants.fair_events]Operation = undefined;
        var left = count;
        while (left != 0) {
            const now = @min(left, batch.len);
            @memset(batch[0..now], operation);
            if (fair.loop.submit(batch[0..now], &.{}) != now) return error.TableFull;
            left -= now;
        }
    }

    /// Ends every operation in flight, for the loop's `deinit`.
    pub fn end(fair: *FairLoop) !void {
        fair.loop.cancel_all();
        var scratch: [constants.fair_events]Event = undefined;
        try fair.loop.drain(&scratch);
    }
};

/// The bounds of W3, section 3.6, in ticks, at `fair_events` events and `fair_loops` loops.
const Bounds = struct {
    /// A due timer: its event comes from the fired list in the first tick.
    timer: u32,
    /// A completion the kernel holds: `ceil(1 / (K - own)) + 1`. The `+ 1` is for a kernel that
    /// posts the completion after the tick's own call.
    receive: u32,
    /// A sender with messages: `ceil((L - 2) / ceil(M / 32)) + 1`.
    message: u32,

    fn of() Bounds {
        const own = backend.constants.own_entries_max;
        const room_max = backend.constants.kernel_room_max;
        const share = core.tick_share.split(constants.fair_events, true, true, own, room_max);
        const places = share.kernel_min - own;
        const mailbox = constants.fair_events - share.lists_max - share.kernel_min;
        const visits = std.math.divCeil(u32, mailbox, core.constants.messages_per_drain) catch unreachable;
        const turns = std.math.divCeil(u32, constants.fair_loops - 2, visits) catch unreachable;
        return .{ .timer = 1, .receive = (std.math.divCeil(u32, 1, places) catch unreachable) + 1, .message = turns + 1 };
    }
};

/// The longest a scenario waits for the kernel to deliver a byte or a connection over loopback, in
/// milliseconds. Delivery takes microseconds; the margin is for a loaded machine.
const readable_wait_ms = 1000;

/// Waits until `descriptor` is readable, so the kernel holds the byte or the connection before a
/// tick asks for it. On macOS a write over loopback can reach the other end after the write
/// returns: this scenario saw the receive come up to 4 ticks late without the wait (2026-11-07).
pub fn wait_readable(descriptor: core.Descriptor) !void {
    if (builtin.os.tag == .linux) {
        var watched = [1]linux.pollfd{.{ .fd = descriptor, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&watched, 1, readable_wait_ms);
        if (linux.errno(rc) != .SUCCESS or rc != 1) return error.NotReadable;
        return;
    }
    var watched = [1]std.c.pollfd{.{ .fd = descriptor, .events = std.c.POLL.IN, .revents = 0 }};
    if (std.c.poll(&watched, 1, readable_wait_ms) != 1) return error.NotReadable;
}

/// The tick, from 1, in which each probe's event came, or null while it has not come.
const Seen = struct {
    timer: ?u32 = null,
    receive: ?u32 = null,
    message: ?u32 = null,

    fn all(seen: Seen) bool {
        return seen.timer != null and seen.receive != null and seen.message != null;
    }
};

/// Fails, and names `probe`, when its event did not come, or came after `bound` ticks.
fn expect_within(comptime probe: []const u8, seen: ?u32, bound: u32) !void {
    const prefix = "the " ++ probe ++ " probe's event ";
    const tick = seen orelse {
        std.debug.print(prefix ++ "did not come; its bound is {d} ticks\n", .{bound});
        return error.TestUnexpectedResult;
    };
    if (tick <= bound) return;
    std.debug.print(prefix ++ "came in tick {d}, past its bound of {d}\n", .{ tick, bound });
    return error.TestUnexpectedResult;
}

/// The main scenario: the loop under test, the loop that never ticks, the remotes, and a socket
/// pair whose one end the loop under test receives on.
const Scenario = struct {
    fair: FairLoop,
    idle: Harness,
    /// A loop of no registry that connects the pair and writes each round's byte.
    side: Harness,
    remotes: [remotes]Remote,
    listener: tcp.Listener,
    pair: [2]core.Descriptor,
    received: [1]u8,
    sent: [1]u8,

    fn init(scenario: *Scenario, registry: *backend.Registry) !void {
        try scenario.fair.init(registry);
        try scenario.idle.init(idle_id, registry);
        try scenario.side.init(0, null);
        for (&scenario.remotes, 0..) |*remote, offset| {
            try remote.init(registry, @intCast(remote_id_first + offset));
        }
        scenario.listener = try tcp.Listener.open();
        scenario.pair = try tcp.connected_pair(&scenario.side, &scenario.listener);
        scenario.sent = .{1};
    }

    fn deinit(scenario: *Scenario) void {
        for (scenario.pair) |descriptor| backend.sync.close_now(descriptor);
        backend.sync.close_now(scenario.listener.descriptor);
        for (&scenario.remotes) |*remote| remote.deinit();
        scenario.side.deinit();
        scenario.idle.deinit();
        scenario.fair.loop.deinit();
    }

    /// The receive that waits on the pair, submitted before any byte of its round arrives.
    fn submit_receive(scenario: *Scenario) !void {
        const receive = Operation.receive(receive_user_data, scenario.pair[1], &scenario.received);
        try scenario.fair.submit_copies(receive, 1);
    }

    /// Fills the rings of every remote but the last to the loop under test.
    fn fill_rings(scenario: *Scenario) !void {
        for (scenario.remotes[0 .. remotes - 1], 0..) |*remote, offset| {
            const tag: u32 = remote_id_first + @as(u32, @intCast(offset));
            for (0..core.constants.mailbox_messages) |payload| {
                remote.post(tested_id, .{ .payload = payload, .tag = tag }) catch |err| switch (err) {
                    error.MailboxFull => break,
                    else => return err,
                };
            }
        }
    }

    /// Writes one byte to the pair, submits a timer of 0 ns, and posts one message from the last
    /// remote.
    fn probe(scenario: *Scenario) !void {
        try scenario.side.submit(&.{Operation.send(1, scenario.pair[0], &scenario.sent)}, &.{});
        var sent: [1]Event = undefined;
        try scenario.side.collect(&sent);
        try testing.expectEqual(@as(u32, 1), try sent[0].outcome());
        try wait_readable(scenario.pair[1]);
        try scenario.fair.submit_copies(Operation.timer(timer_user_data, 0, 0), 1);
        try scenario.remotes[remotes - 1].post(tested_id, .{ .payload = 0, .tag = probe_tag });
    }

    /// One tick of the loop under test under the load. Every tick hands over `fair_events`
    /// events, and each post that ends is posted again.
    fn tick(scenario: *Scenario, seen: *Seen, number: u32) !void {
        var events: [constants.fair_events]Event = undefined;
        const count = try scenario.fair.loop.tick(&events, 0);
        try testing.expectEqual(constants.fair_events, count);
        var posts: u32 = 0;
        for (events[0..count]) |event| {
            if (event.flags.message) {
                if (event.result == probe_tag) seen.message = seen.message orelse number;
                continue;
            }
            switch (event.user_data) {
                post_user_data => posts += 1,
                receive_user_data => seen.receive = seen.receive orelse number,
                timer_user_data => seen.timer = seen.timer orelse number,
                else => return error.UnexpectedEvent,
            }
        }
        const message: core.Message = .{ .payload = 0, .tag = 0 };
        try scenario.fair.submit_copies(Operation.post(post_user_data, idle_id, message), posts);
    }

    /// One round: `extra` ticks under the load, then the probes, then ticks until each probe's
    /// event came. Each must come within its bound.
    fn round(scenario: *Scenario, extra: u32, bounds: Bounds) !void {
        try scenario.fill_rings();
        var ignored: Seen = .{};
        for (0..extra) |_| try scenario.tick(&ignored, 0);
        try scenario.probe();
        var seen: Seen = .{};
        const ticks_max = @max(bounds.timer, bounds.receive, bounds.message);
        var number: u32 = 1;
        while (!seen.all() and number <= ticks_max) : (number += 1) try scenario.tick(&seen, number);
        try expect_within("timer", seen.timer, bounds.timer);
        try expect_within("receive", seen.receive, bounds.receive);
        try expect_within("message", seen.message, bounds.message);
        try scenario.submit_receive();
    }
};

test "a long finished list keeps neither a due timer, the kernel nor a sender out of a tick" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    var registry_memory: [backend.Registry.memory_bytes(constants.fair_loops)]u8 align(core.layout.memory_alignment) = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, constants.fair_loops);
    defer life.end();
    var scenario: Scenario = undefined;
    try scenario.init(&registry);
    defer scenario.deinit();
    try scenario.submit_receive();
    const message: core.Message = .{ .payload = 0, .tag = 0 };
    try scenario.fair.submit_copies(Operation.post(post_user_data, idle_id, message), constants.fair_posts);
    const bounds = Bounds.of();
    // The test cannot set the cursor through the public surface. So round `r` ticks `r` more
    // times under the load before its probes, and the cursor starts from each sender in turn.
    for (0..constants.fair_loops - 1) |extra| try scenario.round(@intCast(extra), bounds);
    try scenario.fair.end();
}

test "a tick gives the places its reserves did not use back to the lists" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    var registry_memory: [backend.Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, 2);
    defer life.end();
    var harness: Harness = undefined;
    try harness.init(tested_id, &registry);
    defer harness.deinit();
    var idle: Harness = undefined;
    try idle.init(idle_id, &registry);
    defer idle.deinit();
    // Posts to a loop that never ticks end at the flush. Nothing waits for readiness, and every
    // ring to the loop is empty, so the reserves that the tick keeps find nothing.
    var posts: [constants.fair_give_back_events]Operation = undefined;
    @memset(&posts, Operation.post(post_user_data, idle_id, .{ .payload = 0, .tag = 0 }));
    try harness.submit(&posts, &.{});
    var events: [constants.fair_give_back_events]Event = undefined;
    try testing.expectEqual(constants.fair_give_back_events, try harness.tick(&events, 0));
    try testing.expectEqual(@as(u32, 0), harness.loop.in_flight());
}
