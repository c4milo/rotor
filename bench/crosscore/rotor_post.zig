//! rotor_post: one cross-core message on its own, the rotor side of the cross-core comparison.
//!
//! Run:  rotor_post [--mode waiting|spinning|spin-then-wait] [--samples N] [--warmup N]
//!                  [--cpu N] [--peer-cpu N] [--burst N]
//!
//! Decision 4 calls the threading model rotor's main claim and names its unit of cost as one
//! cross-core message; rows C17 to C19 of `docs/costs.md` are that unit measured against the
//! kernel. This program measures it against what libuv and libxev charge for the same thing.
//!
//! **The comparison runs in `waiting`, and that is the default.** Two loops on two threads send a
//! message back and forth, each blocking in its tick until the peer's message arrives, so every
//! number includes the kernel waking a receiver that was asleep. `uv_async_send` and libxev's
//! `Async` both wake a sleeping loop and have no other mode, so a run that let rotor spin while
//! they slept would measure the spin and not the message. That is the one way this workload could
//! be rigged, and it is the reason the default is the slow mode.
//!
//! The other two modes stay reachable because the gap between them is large and belongs to rotor
//! alone: `spinning` never blocks, and `spin-then-wait` polls for a budget before it blocks.
//! `bench/uring/post.zig` measures the same three with rotor on both ends. Neither extra mode is
//! a comparison; both are rotor against itself, and a row from one says so in its candidate name.
//!
//! `--burst N` sends N pings in one submit, so one tick's flush posts all of them, and the peer
//! answers the N with one pong. It measures what a burst of posts to a loop that sleeps costs, which
//! decision 12, point 6 says should be one wake. It is rotor against itself, as the two extra modes
//! are, and its row says so. The default of 1 is the ping-pong above.
//!
//! **A round trip is two messages, so one message is half of it.** The two directions run the
//! same mechanism over the same pair of loops, so halving is a fair split and not an average over
//! two different things. The histogram holds halves, so every percentile is one message.
const std = @import("std");
const core = @import("core");
const backend = @import("backend");
const harness = @import("harness");

const Loop = backend.Loop;
const Event = core.Event;
const Histogram = harness.Histogram;
const Result = harness.Result;
const placement = harness.placement;
const now_ns = harness.clock.now_ns;

/// Slots per loop. A message in flight costs one, and nothing else is ever submitted here.
const operations = 64;

/// Submission entries per tick, which the kqueue backend takes and does not size by.
const entries = 16;

/// Loops in the registry: the two this program runs.
const loops = 2;

/// The measuring loop's id, and its peer's.
const id_first: core.LoopId = 0;
const id_second: core.LoopId = 1;

/// The tags the two sides answer each other with, and the one that ends the run.
const tag_ping: u32 = 1;
const tag_pong: u32 = 2;
const tag_stop: u32 = 3;

/// Round trips measured, and the ones before them that are not.
const samples_default: u32 = 20_000;
const warmup_default: u32 = 2_000;

/// The most round trips a run may ask for. It bounds nothing that is allocated, because the
/// histogram is a fixed size whatever the count, but a run is a bounded loop (CLAUDE.md).
const samples_max: u32 = 1_000_000;

/// What a blocking tick is given. Long enough that a tick blocks rather than spins, short enough
/// that a peer that died ends the run instead of hanging it.
const wait_ns: u64 = std.time.ns_per_ms;

/// How long `spin-then-wait` polls before it blocks. Longer than a message takes when the peer is
/// awake, and far shorter than the sleep it is trying to avoid.
const spin_budget_ns: u64 = 50 * std.time.ns_per_us;

/// Events one tick may hand over. A side has one message in flight and its own post's completion.
const events_max = 4;

/// The most pings one burst may carry. Each holds a slot until its own completion, and a slot is
/// left for the answer.
const burst_max: u32 = 32;

const options_template: Loop.Options = .{
    .operations = operations,
    .entries = entries,
    .id = id_first,
};
const memory_bytes = Loop.memory_bytes(options_template);

/// How a loop waits for its peer's message.
const Mode = enum {
    /// Blocks until the message comes, so the number includes waking a sleeping receiver. The
    /// only mode an alternative can be compared against.
    waiting,
    /// Never blocks, so the number is the message alone. It costs a core that does nothing else.
    spinning,
    /// Polls for `spin_budget_ns`, then blocks. A peer that answers inside the budget is never
    /// slept on.
    spin_then_wait,

    /// What a tick of this mode is given when it is not polling.
    fn wait(mode: Mode) u64 {
        return if (mode == .spinning) 0 else wait_ns;
    }

    /// How long a tick of this mode polls before it blocks.
    fn spin(mode: Mode) u64 {
        return if (mode == .spin_then_wait) spin_budget_ns else 0;
    }

    /// The candidate name a row of this mode carries. Only `waiting` is rotor against another
    /// library; the other two are rotor against itself, and a table must not read as though a
    /// alternative had been offered the same choice.
    fn candidate(mode: Mode) []const u8 {
        return switch (mode) {
            .waiting => "rotor",
            .spinning => "rotor (spinning, not a comparison)",
            .spin_then_wait => "rotor (spin then wait, not a comparison)",
        };
    }
};

const Options = struct {
    mode: Mode = .waiting,
    samples: u32 = samples_default,
    warmup: u32 = warmup_default,
    /// The core the measuring loop takes, and the one its peer takes. Null places neither, which
    /// is what a host that cannot pin reports.
    cpu: ?usize = placement.first_cpu,
    peer_cpu: ?usize = placement.second_cpu,
    /// Pings per round trip, all in one submit. A round trip carries them and one pong.
    burst: u32 = 1,

    fn messages_per_round_trip(options: Options) u32 {
        return options.burst + 1;
    }
};

comptime {
    std.debug.assert(burst_max < operations);
}

var registry: backend.Registry align(@alignOf(backend.Registry)) = undefined;
const registry_bytes = backend.Registry.memory_bytes(loops);
var registry_memory: [registry_bytes]u8 align(core.layout.memory_alignment) = undefined;

var latencies: Histogram align(harness.histogram.alignment_bytes) = .empty;

/// What the peer thread reports back about itself: it cannot return a value, so it writes one.
var peer_placement: placement.Placement align(@alignOf(placement.Placement)) = .scheduler_default;

/// One loop with its memory, and the two things both threads do with it.
const Side = struct {
    memory: [memory_bytes]u8 align(core.layout.memory_alignment) = undefined,
    loop: Loop = undefined,

    /// Posts `count` messages to `target` in one submit, so one flush posts them all. Each one's
    /// own completion arrives as an event too, and `receive` skips it: an event is the peer's
    /// message only when `flags.message` says so.
    fn post(side: *Side, target: core.LoopId, tag: u32, count: u32) void {
        std.debug.assert(count >= 1 and count <= burst_max);
        std.debug.assert(tag == tag_ping or tag == tag_pong or tag == tag_stop);
        var batch: [burst_max]core.Operation = undefined;
        const message: core.Message = .{ .payload = 0, .tag = tag };
        for (batch[0..count]) |*operation| operation.* = core.Operation.post(0, target, message);
        const taken = side.loop.submit(batch[0..count], &.{});
        std.debug.assert(taken == count);
    }

    /// Ticks until `wanted` of the peer's messages have arrived, or a stop has, and returns the
    /// tag of the last.
    fn receive(side: *Side, mode: Mode, wanted: u32) !i32 {
        var events: [events_max]Event = undefined;
        const spin_ns = mode.spin();
        const spin_until_ns = if (spin_ns == 0) 0 else now_ns() + spin_ns;
        var received: u32 = 0;
        while (true) {
            // No clock read when there is no spin: libuv and libxev read none inside the round
            // trip, and one here would be timed as part of rotor's message.
            const polling = spin_until_ns != 0 and now_ns() < spin_until_ns;
            const count = try side.loop.tick(&events, if (polling) 0 else mode.wait());
            std.debug.assert(count <= events_max);
            if (count_messages(events[0..count], &received, wanted)) |tag| return tag;
        }
    }

    /// Counts the peer's messages among `events` into `received`, and answers the tag that ends the
    /// wait: a stop, or the message that makes `wanted`. Null while the wait goes on.
    fn count_messages(events: []const Event, received: *u32, wanted: u32) ?i32 {
        for (events) |event| {
            if (!event.flags.message) continue;
            received.* += 1;
            if (event.result == tag_stop or received.* == wanted) return event.result;
        }
        return null;
    }

    /// Ticks until nothing this side submitted is still in flight.
    fn drain(side: *Side, mode: Mode) !void {
        var events: [events_max]Event = undefined;
        while (side.loop.in_flight() != 0) _ = try side.loop.tick(&events, mode.wait());
        std.debug.assert(side.loop.in_flight() == 0);
    }
};

/// The peer: it answers every ping with a pong until it is told to stop.
const Peer = struct {
    side: Side = .{},
    mode: Mode,
    cpu: ?usize,
    burst: u32,
    failure: ?anyerror = null,

    fn run(peer: *Peer) void {
        peer.serve() catch |err| {
            peer.failure = err;
        };
    }

    fn serve(peer: *Peer) !void {
        peer_placement = placement.place(peer.cpu);
        var options = options_template;
        options.id = id_second;
        options.registry = &registry;
        try peer.side.loop.init(&peer.side.memory, options);
        defer peer.side.loop.deinit();
        std.debug.assert(peer.side.loop.in_flight() == 0);

        while (try peer.side.receive(peer.mode, peer.burst) != tag_stop) {
            peer.side.post(id_first, tag_pong, 1);
        }
        try peer.side.drain(peer.mode);
    }
};

var first: Side align(@alignOf(Side)) = .{};

/// Runs the ping-pong and fills `latencies`, returning the measured span.
fn ping_pong(options: Options) !u64 {
    var round: u32 = 0;
    var span_ns: u64 = 0;
    while (round < options.warmup + options.samples) : (round += 1) {
        const before = now_ns();
        first.post(id_second, tag_ping, options.burst);
        const tag = try first.receive(options.mode, 1);
        std.debug.assert(tag == tag_pong);
        const elapsed = now_ns() - before;
        if (round >= options.warmup) {
            latencies.record(elapsed / options.messages_per_round_trip());
            span_ns += elapsed;
        }
    }
    std.debug.assert(round == options.warmup + options.samples);
    return span_ns;
}

/// Starts the peer, measures, stops it, and returns the run as a `Result`.
fn measure(options: Options) !Result {
    std.debug.assert(options.samples >= 1);
    registry.init(&registry_memory, loops);
    const own = placement.place(options.cpu);

    var loop_options = options_template;
    loop_options.registry = &registry;
    try first.loop.init(&first.memory, loop_options);
    defer first.loop.deinit();

    var peer: Peer = .{ .mode = options.mode, .cpu = options.peer_cpu, .burst = options.burst };
    const thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});

    // The peer publishes its ring when its thread reaches `init`, and not before.
    var events: [events_max]Event = undefined;
    while (registry.get(id_second) < 0) _ = try first.loop.tick(&events, wait_ns);

    const span_ns = try ping_pong(options);

    first.post(id_second, tag_stop, 1);
    try first.drain(options.mode);
    thread.join();
    if (peer.failure) |err| return err;

    const pinned = own.names_a_core() and peer_placement.names_a_core();
    return .init(.{
        .workload = "cross-core",
        .candidate = if (options.burst == 1) options.mode.candidate() else burst_candidate,
        .candidate_version = "this tree",
        .configuration = .{
            // Two cores only when both threads were actually pinned to one each. A host that
            // cannot pin reports 0, because the two ends may have shared a core and a row that
            // claimed two would be measuring something else (see bench/harness/placement.zig).
            .cores = if (pinned) loops else 0,
            .connections = 1,
            // A message carries a tag and a payload word, not a buffer of bytes.
            .payload_bytes = 0,
            .load = .even,
        },
        .duration_ns = @max(span_ns, 1),
        .operations = @as(u64, options.samples) * options.messages_per_round_trip(),
    }, &latencies);
}

const output_buffer_bytes = 4096;

/// The candidate name of a run with bursts: rotor against itself, as the two extra modes are.
const burst_candidate = "rotor (burst of posts, not a comparison)";

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    const result = try measure(options);

    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll(harness.report.markdown_header);
    try result.render_markdown_row(writer);
    try writer.writeByte('\n');
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
    try validate(options);
    return options;
}

/// Refuses a run that measures nothing or that asks for more than the slots hold.
fn validate(options: Options) !void {
    if (options.samples == 0 or options.samples > samples_max) return error.SampleCount;
    if (options.burst == 0 or options.burst > burst_max) return error.BurstSize;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--mode")) {
        options.mode = mode_of(value) orelse return error.UnknownMode;
    } else if (std.mem.eql(u8, name, "--samples")) {
        options.samples = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--warmup")) {
        options.warmup = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--cpu")) {
        options.cpu = try parse_cpu(value);
    } else if (std.mem.eql(u8, name, "--peer-cpu")) {
        options.peer_cpu = try parse_cpu(value);
    } else if (std.mem.eql(u8, name, "--burst")) {
        options.burst = try std.fmt.parseInt(u32, value, 10);
    } else {
        return error.UnknownArgument;
    }
}

/// A core, or `none` for a run that places nothing and reports that it did not.
fn parse_cpu(value: []const u8) !?usize {
    if (std.mem.eql(u8, value, "none")) return null;
    return try std.fmt.parseInt(usize, value, 10);
}

/// The mode named on the command line. `spin-then-wait` is spelled with dashes there and with
/// underscores in the enum, so the two are mapped here rather than by `stringToEnum`.
fn mode_of(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "waiting")) return .waiting;
    if (std.mem.eql(u8, value, "spinning")) return .spinning;
    if (std.mem.eql(u8, value, "spin-then-wait")) return .spin_then_wait;
    return null;
}

const testing = std.testing;

test "every mode the command line names maps to one, and nothing else does" {
    try testing.expectEqual(Mode.waiting, mode_of("waiting").?);
    try testing.expectEqual(Mode.spinning, mode_of("spinning").?);
    try testing.expectEqual(Mode.spin_then_wait, mode_of("spin-then-wait").?);
    try testing.expectEqual(@as(?Mode, null), mode_of("spin_then_wait"));
    try testing.expectEqual(@as(?Mode, null), mode_of(""));
    try testing.expectEqual(@as(?Mode, null), mode_of("waiting "));
}

test "only the waiting mode is named as a comparison" {
    try testing.expectEqualStrings("rotor", Mode.waiting.candidate());
    for ([_]Mode{ .spinning, .spin_then_wait }) |mode| {
        try testing.expect(std.mem.indexOf(u8, mode.candidate(), "not a comparison") != null);
    }
}

test "waiting blocks, spinning never does, and spin-then-wait does both" {
    try testing.expect(Mode.waiting.wait() > 0);
    try testing.expectEqual(@as(u64, 0), Mode.waiting.spin());

    try testing.expectEqual(@as(u64, 0), Mode.spinning.wait());
    try testing.expectEqual(@as(u64, 0), Mode.spinning.spin());

    try testing.expect(Mode.spin_then_wait.wait() > 0);
    try testing.expect(Mode.spin_then_wait.spin() > 0);
}

test "a core is a number or the word none, and nothing else" {
    try testing.expectEqual(@as(usize, 3), (try parse_cpu("3")).?);
    try testing.expectEqual(@as(?usize, null), try parse_cpu("none"));
    try testing.expectError(error.InvalidCharacter, parse_cpu("first"));
    // A negative core is refused as an overflow and not as a bad character: `usize` has no sign,
    // so the parser reads the digit and finds it does not fit.
    try testing.expectError(error.Overflow, parse_cpu("-1"));
}

test "a round trip is its pings and one pong, so a ping-pong is two messages" {
    // The count is what `measure` multiplies by and what `ping_pong` divides by. A change to one
    // without the other would make the throughput and the percentiles disagree.
    const ping_pong_options: Options = .{};
    try testing.expectEqual(@as(u32, 2), ping_pong_options.messages_per_round_trip());
    const burst_options: Options = .{ .burst = 16 };
    try testing.expectEqual(@as(u32, 17), burst_options.messages_per_round_trip());
}

test "a burst is at least one ping and at most what the slots hold" {
    var options: Options = .{};
    try apply(&options, "--burst", "16");
    try testing.expectEqual(@as(u32, 16), options.burst);
    try testing.expectError(error.InvalidCharacter, apply(&options, "--burst", "many"));
    try validate(options);
    try validate(.{ .burst = burst_max });
    try testing.expectError(error.BurstSize, validate(.{ .burst = 0 }));
    try testing.expectError(error.BurstSize, validate(.{ .burst = burst_max + 1 }));
}
