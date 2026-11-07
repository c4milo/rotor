//! A loop that stops while another thread posts to it (decision 4, amendment of 2026-11-06).
//!
//! A sender reads the descriptor that wakes a loop from the registry, pushes its message, and then
//! wakes the loop through that descriptor. Until 2026-11-06 a loop closed that descriptor at
//! `deinit`. When the loop ended between the read and the wake, the next open could get the number,
//! and the wake reached it: 8 bytes written into a file or a socket on epoll, a completion in some
//! other ring on io_uring, a user event fired in some other kqueue. Now the registry keeps the
//! descriptor of each id until the application closes it, after every loop and remote ended.
//!
//! Here the target loop starts and stops many times while a thread with a `Remote` posts to it
//! without a pause. Right after each `deinit` this thread opens a trap: descriptors of the kind a
//! wake could reach, which take the lowest numbers free, the ones the loop freed among them. No
//! trap may take the number the registry gave senders for the loop, and no trap may receive
//! anything. The race is real, so the scenario also runs under the race gate. Its window is
//! narrow, and a wake that lands in a trap is rare even when the number is reused. So the check
//! of the number is what fails at once, and each backend's own test makes such a wake by hand
//! (`epoll_wake.zig`, `kqueue_wake.zig`, `uring_wake.zig`).
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Trap = backend.wake_module.Trap;

const target_id: core.LoopId = 0;
const poster_id: core.LoopId = 1;
const ids: u16 = 2;

/// Times the target loop starts and stops while the other thread posts. Each round leaves its trap
/// open until the end, so a wake that comes late still finds it.
const rounds = 32;
/// How long each life of the target sleeps in one tick, at most. A post wakes it sooner.
const sleep_ns = 2 * core.constants.ns_per_ms;
/// Posts the other thread tries before it gives up, should this thread never tell it to stop.
const post_attempts_max: u32 = 1 << 24;

var registry_memory: [backend.Registry.memory_bytes(ids)]u8 align(core.layout.memory_alignment) =
    undefined;
var traps: [rounds]Trap align(@alignOf(Trap)) = undefined;
var harness: Harness align(@alignOf(Harness)) = undefined;

/// The other thread: a `Remote` that posts to the target until it is told to stop. It ignores
/// `LoopNotFound` and `MailboxFull`, which are what a stopped or a slow target answers.
const Poster = struct {
    registry: *backend.Registry,
    stop: std.atomic.Value(bool) = .init(false),
    posted: u32 = 0,
    failure: ?anyerror = null,

    fn run(poster: *Poster) void {
        poster.post_until_stopped() catch |err| {
            poster.failure = err;
        };
    }

    fn post_until_stopped(poster: *Poster) !void {
        var remote: backend.Remote = undefined;
        try remote.init(poster.registry, poster_id);
        defer remote.deinit();
        var attempt: u32 = 0;
        while (!poster.stop.load(.acquire) and attempt < post_attempts_max) : (attempt += 1) {
            remote.post(target_id, .{ .payload = attempt, .tag = 1 }) catch |err| switch (err) {
                error.LoopNotFound, error.MailboxFull => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => return err,
            };
            poster.posted += 1;
        }
    }
};

/// Starts and stops the target `rounds` times, and opens a trap after each stop. Returns how many
/// traps it opened, which the caller closes.
fn start_and_stop(registry: *backend.Registry) !u32 {
    var opened: u32 = 0;
    errdefer for (traps[0..opened]) |*trap| trap.close();
    var events: [conformance.operations]Event = undefined;
    while (opened < rounds) {
        try harness.init(target_id, registry);
        // What a sender may hold when the loop ends.
        const number = registry.get(target_id);
        _ = harness.tick(&events, sleep_ns) catch |err| {
            harness.deinit();
            return err;
        };
        harness.deinit();
        try traps[opened].open();
        opened += 1;
        if (traps[opened - 1].holds(number)) return error.NumberReused;
    }
    return opened;
}

test "a loop that stops while another thread posts to it wakes no descriptor opened after it" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, ids);
    defer life.end();
    var poster: Poster = .{ .registry = &registry };
    const thread = try std.Thread.spawn(.{}, Poster.run, .{&poster});
    const started = start_and_stop(&registry);
    poster.stop.store(true, .release);
    thread.join();
    const opened = try started;
    defer for (traps[0..opened]) |*trap| trap.close();

    try testing.expectEqual(@as(?anyerror, null), poster.failure);
    try testing.expect(poster.posted > 0);
    for (traps[0..opened]) |*trap| try testing.expect(!trap.received());
}
