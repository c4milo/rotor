//! libxev_async: one cross-core message on its own, the libxev side of the cross-core comparison.
//!
//! Run:  libxev_async [--samples N] [--warmup N] [--cpu N] [--peer-cpu N]
//!
//! It is written the way that is fastest for libxev, as `bench/alternatives/libxev_echo.zig` is,
//! so that no result of the harness comes from a candidate written carelessly. `xev.Async` is the
//! one thing libxev offers for waking another loop, and this uses it the way libxev's own test
//! does: one `wait` armed with `.rearm`, so a notification never has to arm another.
//!
//! Both loops block in `run(.once)` between messages. That is the mode rotor's `rotor_post` is
//! compared in, and it is the only one `xev.Async` has: there is no libxev call that polls for a
//! notification without sleeping, so a comparison against a spinning rotor would not be one.
//!
//! A round trip is two messages, so one message is half of it, which is what the histogram holds.
const std = @import("std");
const xev = @import("xev");
const harness = @import("harness");

const Histogram = harness.Histogram;
const Result = harness.Result;
const placement = harness.placement;
const now_ns = harness.clock.now_ns;

/// The pinned commit of libxev, which `bench/alternatives/README.md` records.
const version = "9ce8e8e";

const samples_default: u32 = 20_000;
const warmup_default: u32 = 2_000;
const samples_max: u32 = 1_000_000;

/// The messages one round trip carries: the ping and the pong.
const messages_per_round_trip = 2;

/// Loops this program runs: the measuring one and its peer.
const loops = 2;

const Options = struct {
    samples: u32 = samples_default,
    warmup: u32 = warmup_default,
    cpu: ?usize = placement.first_cpu,
    peer_cpu: ?usize = placement.second_cpu,
};

/// One loop and the notifier it waits on. The peer notifies this side's `notifier`; this side
/// notifies the peer's.
const Side = struct {
    loop: xev.Loop,
    notifier: xev.Async,
    completion: xev.Completion = .{},
    woken: bool = false,

    fn init(side: *Side) !void {
        side.loop = try xev.Loop.init(.{});
        side.notifier = try xev.Async.init();
        // Armed once for the whole run. The callback re-arms, so no notification costs an arm.
        side.notifier.wait(&side.loop, &side.completion, Side, side, on_wake);
    }

    fn deinit(side: *Side) void {
        side.notifier.deinit();
        side.loop.deinit();
    }

    fn on_wake(
        userdata: ?*Side,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        result catch unreachable;
        userdata.?.woken = true;
        return .rearm;
    }

    /// Runs the loop until the peer's notification arrives.
    fn receive(side: *Side) !void {
        side.woken = false;
        while (!side.woken) try side.loop.run(.once);
        std.debug.assert(side.woken);
    }
};

var first: Side align(@alignOf(Side)) = undefined;
var second: Side align(@alignOf(Side)) = undefined;
var latencies: Histogram align(harness.histogram.alignment_bytes) = .empty;

/// Set when the measuring side has taken its last sample, so the peer stops after one more wake.
var stopping: std.atomic.Value(bool) align(@alignOf(std.atomic.Value(bool))) = .init(false);
/// Set once the peer's loop and notifier exist, because the measuring side may not notify before.
var peer_ready: std.atomic.Value(bool) align(@alignOf(std.atomic.Value(bool))) = .init(false);
var peer_placement: placement.Placement align(@alignOf(placement.Placement)) = .scheduler_default;
var peer_failure: ?anyerror = null;

/// The peer: it answers every notification with one of its own until it is told to stop.
fn serve(cpu: ?usize) void {
    peer_placement = placement.place(cpu);
    second.init() catch |err| {
        peer_failure = err;
        peer_ready.store(true, .release);
        return;
    };
    defer second.deinit();
    peer_ready.store(true, .release);

    while (true) {
        second.receive() catch |err| {
            peer_failure = err;
            return;
        };
        if (stopping.load(.acquire)) return;
        first.notifier.notify() catch |err| {
            peer_failure = err;
            return;
        };
    }
}

/// The ping-pong, which fills `latencies` and returns the measured span.
fn ping_pong(options: Options) !u64 {
    var span_ns: u64 = 0;
    var round: u32 = 0;
    while (round < options.warmup + options.samples) : (round += 1) {
        const before = now_ns();
        try second.notifier.notify();
        try first.receive();
        const elapsed = now_ns() - before;
        if (round >= options.warmup) {
            latencies.record(elapsed / messages_per_round_trip);
            span_ns += elapsed;
        }
    }
    std.debug.assert(round >= options.samples);
    return span_ns;
}

fn measure(options: Options) !Result {
    std.debug.assert(options.samples >= 1);
    const own = placement.place(options.cpu);
    try first.init();
    defer first.deinit();

    const thread = try std.Thread.spawn(.{}, serve, .{options.peer_cpu});
    while (!peer_ready.load(.acquire)) std.atomic.spinLoopHint();
    if (peer_failure) |err| {
        thread.join();
        return err;
    }

    const span_ns = try ping_pong(options);

    // One last notification, which the peer answers by leaving rather than by notifying back.
    stopping.store(true, .release);
    try second.notifier.notify();
    thread.join();
    if (peer_failure) |err| return err;

    const pinned = own.names_a_core() and peer_placement.names_a_core();
    return .init(.{
        .workload = "cross-core",
        .candidate = "libxev",
        .candidate_version = version,
        .configuration = .{
            .cores = if (pinned) loops else 0,
            .connections = 1,
            .payload_bytes = 0,
            .load = .even,
        },
        .duration_ns = @max(span_ns, 1),
        .operations = @as(u64, options.samples) * messages_per_round_trip,
    }, &latencies);
}

const output_buffer_bytes = 4096;

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    const result = try measure(options);

    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;
    // Last, because the runner reads the last line of what a candidate printed.
    try result.render_json_line(writer);
    try writer.flush();
}

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    if (options.samples == 0 or options.samples > samples_max) return error.SampleCount;
    return options;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--samples")) {
        options.samples = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--warmup")) {
        options.warmup = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--cpu")) {
        options.cpu = try parse_cpu(value);
    } else if (std.mem.eql(u8, name, "--peer-cpu")) {
        options.peer_cpu = try parse_cpu(value);
    } else {
        return error.UnknownArgument;
    }
}

fn parse_cpu(value: []const u8) !?usize {
    if (std.mem.eql(u8, value, "none")) return null;
    return try std.fmt.parseInt(usize, value, 10);
}
