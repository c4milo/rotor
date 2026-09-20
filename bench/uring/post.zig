//! One cross-core message on its own: row C17 of docs/costs.md, and the unit of cost decision 4's
//! threading model pays in. Two loops on two threads pinned to two CPUs send one message back and
//! forth. A round trip is two posts, so half of it is one message, post to reap.
//!
//! It runs three times, and the third is the question the first two raise.
//!
//!   - `waiting`: each loop blocks in its tick until the message arrives, so the number includes
//!     the kernel waking the receiver, which is what an idle core pays.
//!   - `spinning`: each loop ticks without waiting, so the number is the message alone, which is
//!     what a busy core pays. It costs a core that does nothing else.
//!   - `spin then wait`: each loop ticks without waiting for `spin_ns`, and blocks only if
//!     nothing came. A loop whose peer answers inside that window never sleeps and never has to
//!     be woken; one whose peer is idle sleeps as before, having burnt `spin_ns` first.
//!
//! The gap between the first two is what a sleep costs. The third says how much of that a bounded
//! spin takes back, and it is measured here, in the benchmark, before anything is proposed for
//! the loop itself.
//!
//! A number from a virtual machine describes the virtual machine. It may guide work; it does not
//! go in docs/costs.md (rule 1 there).
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const core = @import("core");
const uring = @import("uring");

const Loop = uring.Loop;

const operations = 64;
const entries = 16;
/// Round trips timed per mode, after `warmup` that are not.
const samples = 20_000;
const warmup = 2_000;
const p99_per_mille = 990;
const per_mille = 1000;
const tag_ping = 1;
const tag_pong = 2;
const tag_stop = 3;
const cpu_first = 0;
const cpu_second = 1;

const options_first: Loop.Options = .{ .operations = operations, .entries = entries, .id = 0 };
const memory_bytes = Loop.memory_bytes(options_first);

var registry: uring.Registry = undefined;
const registry_bytes = uring.Registry.memory_bytes(2);
var registry_memory: [registry_bytes]u8 align(core.layout.memory_alignment) = undefined;
var round_trip_ns: [samples]u64 = undefined;

fn now_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * core.constants.ns_per_s + @as(u64, @intCast(now.nsec));
}

/// Pins the calling thread to one CPU. A failure is reported and not fatal: a machine with one
/// CPU still runs the benchmark, and says so.
fn pin(cpu: u6) void {
    var set: linux.cpu_set_t = @splat(0);
    set[0] = @as(usize, 1) << cpu;
    linux.sched_setaffinity(0, &set) catch {
        std.debug.print("post: could not pin to CPU {d}\n", .{cpu});
    };
}

/// One loop with its memory, and the two things both threads do with it.
const Side = struct {
    memory: [memory_bytes]u8 align(core.layout.memory_alignment) = undefined,
    loop: Loop = undefined,

    /// Posts one message and consumes the post's own completion when it arrives with the reply.
    fn post(side: *Side, target: core.LoopId, tag: u32) void {
        const taken = side.loop.submit(&.{.{ .user_data = 0, .kind = .{ .post = .{
            .target = target,
            .message = .{ .payload = 0, .tag = tag },
        } } }}, &.{});
        std.debug.assert(taken == 1);
    }

    /// Ticks until a message arrives and returns its tag. The post's own completion is an event
    /// too, and is skipped.
    fn receive(side: *Side, mode: Mode) !i32 {
        var events: [4]core.Event = undefined;
        // The spin, when there is one: tick without waiting until the budget is spent.
        const spin_until_ns = if (mode.spin_ns == 0) 0 else now_ns() + mode.spin_ns;
        while (true) {
            const spinning = now_ns() < spin_until_ns;
            const count = try side.loop.tick(&events, if (spinning) 0 else mode.wait_ns);
            for (events[0..count]) |event| {
                if (event.flags.message) return event.result;
            }
        }
    }
};

/// How a loop waits for its peer's message.
const Mode = struct {
    name: []const u8,
    /// What a blocking tick is given. 0 never blocks.
    wait_ns: u64,
    /// How long a tick polls before it blocks. 0 does not poll.
    spin_ns: u64 = 0,
};

/// The spin the third mode is given. Longer than a message takes to come back when the peer is
/// awake, and far shorter than the sleep it is trying to avoid.
const spin_budget_ns = 50 * 1000;

const Echo = struct {
    side: Side = .{},
    mode: Mode,
    failure: ?anyerror = null,

    fn run(echo: *Echo) void {
        echo.serve() catch |err| {
            echo.failure = err;
        };
    }

    fn serve(echo: *Echo) !void {
        pin(cpu_second);
        try echo.side.loop.init(&echo.side.memory, .{
            .operations = operations,
            .entries = entries,
            .id = 1,
            .registry = &registry,
        });
        defer echo.side.loop.deinit();
        while (try echo.side.receive(echo.mode) != tag_stop) echo.side.post(0, tag_pong);
        // Reap the completion of the last pong before the loop ends.
        var events: [4]core.Event = undefined;
        const wait_ns = echo.mode.wait_ns;
        while (echo.side.loop.in_flight() != 0) _ = try echo.side.loop.tick(&events, wait_ns);
    }
};

fn measure(mode: Mode) !void {
    registry.init(&registry_memory, 2);
    var first: Side = .{};
    var options = options_first;
    options.registry = &registry;
    try first.loop.init(&first.memory, options);
    defer first.loop.deinit();
    var echo: Echo = .{ .mode = mode };
    const thread = try std.Thread.spawn(.{}, Echo.run, .{&echo});

    // The other loop publishes its ring when its thread gets there.
    var events: [4]core.Event = undefined;
    while (registry.get(1) < 0) _ = try first.loop.tick(&events, core.constants.ns_per_ms);

    for (0..warmup + samples) |round| {
        const before = now_ns();
        first.post(1, tag_ping);
        const tag = try first.receive(mode);
        std.debug.assert(tag == tag_pong);
        if (round >= warmup) round_trip_ns[round - warmup] = now_ns() - before;
    }
    first.post(1, tag_stop);
    while (first.loop.in_flight() != 0) _ = try first.loop.tick(&events, core.constants.ns_per_ms);
    thread.join();
    if (echo.failure) |err| return err;

    std.mem.sort(u64, &round_trip_ns, {}, std.sort.asc(u64));
    const median = round_trip_ns[samples / 2];
    const p99 = round_trip_ns[samples * p99_per_mille / per_mille];
    std.debug.print("| {s} | {d} | {d} | {d} |\n", .{ mode.name, median, p99, median / 2 });
}

pub fn main() !void {
    if (builtin.os.tag != .linux) return error.NeedsLinux;
    pin(cpu_first);
    const mode = @tagName(builtin.mode);
    std.debug.print("uring post, {s}, {d} round trips per mode\n", .{ mode, samples });
    std.debug.print("| mode | round trip median ns | round trip p99 ns | one message ns |\n", .{});
    std.debug.print("|---|---|---|---|\n", .{});
    try measure(.{ .name = "waiting", .wait_ns = core.constants.ns_per_s });
    try measure(.{ .name = "spinning", .wait_ns = 0 });
    try measure(.{
        .name = "spin then wait",
        .wait_ns = core.constants.ns_per_s,
        .spin_ns = spin_budget_ns,
    });
}
