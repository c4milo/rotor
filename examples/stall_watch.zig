//! A thread of the program's own that watches its loop for a stall (decision 28). rotor starts no
//! thread, so the program starts this one. It sleeps one period, checks the loop's heartbeat, and
//! reports a turn that stayed open for `checks_limit` checks or more, with the name of the callback
//! that holds the loop. A real program prints, exports a count, or aborts for a core file there.
//!
//! The program makes a reactor, and schedules a task that holds the loop until the watch reports it.
//! Then it reads the stall count, which the task's turn raised, from `statistics()`. `zig build
//! test` runs it, and the Linux gate runs it on io_uring and on epoll. It exits 0 only when the
//! watch and the stall count both named the task.
//!
//! Run:  zig build examples && ./zig-out/bin/stall_watch
const std = @import("std");
const rotor = @import("rotor");

/// How long the watch thread sleeps between two checks.
const period_ms = 10;
/// The checks in a row of one open turn that make a report: a turn of four periods or more.
const checks_limit = 3;
/// The most checks the watch makes before it gives up, and the most the task holds the loop.
const checks_max = 1000;
const hold_ms_max = 10_000;

/// A task that holds the loop until the watch reports it, as a task with too much work would.
const Slow = struct {
    task: rotor.Task = .init(Slow, "task", run),
    io: std.Io,
    reported: *std.atomic.Value(bool),

    fn run(slow: *Slow) void {
        const started = std.Io.Timestamp.now(slow.io, .awake);
        while (!slow.reported.load(.acquire)) {
            const held = started.durationTo(std.Io.Timestamp.now(slow.io, .awake));
            if (held.toMilliseconds() > hold_ms_max) return;
            std.atomic.spinLoopHint();
        }
    }
};

/// The program's watch thread, and what it saw.
const Watcher = struct {
    heartbeat: *rotor.Heartbeat,
    io: std.Io,
    reported: std.atomic.Value(bool) = .init(false),
    name: ?[*:0]const u8 = null,

    fn run(watcher: *Watcher) void {
        var watch = watcher.heartbeat.watch();
        // The loop's `deinit` halts while a watch reads its heartbeat.
        defer watch.end();
        for (0..checks_max) |_| {
            watcher.io.sleep(.fromMilliseconds(period_ms), .awake) catch return;
            const stuck = watch.check() orelse continue;
            if (stuck.checks < checks_limit) continue;
            watcher.name = stuck.name;
            std.debug.print("stall_watch: {s} has held the loop for {d} checks\n", .{
                stuck.name orelse "code outside a callback", stuck.checks,
            });
            watcher.reported.store(true, .release);
            return;
        }
    }
};

/// The program's reactor: a task is the reactor's, so the program makes one in place of a loop
/// (decision 33).
const Reactor = rotor.Reactor(rotor.Loop);

pub fn main(init: std.process.Init) !void {
    // A turn of 5 ms or more is a stall. The default is `constants.stall_turn_ns_default`.
    const options: Reactor.Options = .{ .loop = .{
        .operations = 4,
        .stall_turn_ns = 5 * rotor.constants.ns_per_ms,
    } };
    var memory: [Reactor.memory_bytes(&options)]u8 align(rotor.memory_alignment) = undefined;
    var reactor: Reactor = undefined;
    try reactor.init(&memory, &options);
    defer reactor.deinit();

    var watcher: Watcher = .{ .heartbeat = reactor.heartbeat(), .io = init.io };
    const thread = try std.Thread.spawn(.{}, Watcher.run, .{&watcher});
    var slow: Slow = .{ .io = init.io, .reported = &watcher.reported };
    // A library holds the view, and may schedule a task on it but not tick it.
    const shared = reactor.shared();
    try shared.schedule_in(.default, &slow.task);
    var events: [4]rotor.Event = undefined;
    // This tick runs the task, which holds the loop until the watch reports it.
    _ = try reactor.tick(&events, 0);
    thread.join();
    // The next tick's first clock stamp ends the task's turn, and counts it.
    _ = try reactor.tick(&events, 0);

    const statistics = reactor.statistics();
    const last = statistics.last_stall;
    std.debug.print("stall_watch: stalls {d}, the last of {d} ms in {s}\n", .{
        statistics.stalls, last.span_ns / rotor.constants.ns_per_ms, last.name orelse "no callback",
    });
    const expected = @typeName(Slow) ++ ".task";
    const watched = watcher.name orelse return error.NotReported;
    if (!std.mem.eql(u8, std.mem.span(watched), expected)) return error.WrongName;
    const counted = last.name orelse return error.NotCounted;
    if (!std.mem.eql(u8, std.mem.span(counted), expected)) return error.WrongName;
}
