//! rotor_post: one cross-core message on its own, the rotor side of the cross-core comparison.
//!
//! Run:  rotor_post [--mode waiting|spinning|spin-then-wait|spin-budget] [--samples N] [--warmup N]
//!                  [--cpu N] [--peer-cpu N] [--burst N] [--gap-us N] [--peer thread|process]
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
//! The other modes stay reachable because the gap between them is large and belongs to rotor
//! alone: `spinning` never blocks, and `spin-then-wait` polls for a budget before it blocks.
//! `spin-budget` does what `spin-then-wait` does through the loop's own `spin_budget_ns`, which
//! decision 13 built, where `spin-then-wait` spins in this program. `bench/uring/post.zig`
//! measures the first three with rotor on both ends. No extra mode is a comparison; each is rotor
//! against itself, and a row from one says so in its candidate name.
//!
//! `--burst N` sends N pings in one submit, so one tick's flush posts all of them, and the peer
//! answers the N with one pong. It measures what a burst of posts to a loop that sleeps costs, which
//! decision 12, point 6 says should be one wake. It is rotor against itself, as the two extra modes
//! are, and its row says so. The default of 1 is the ping-pong above.
//!
//! `--gap-us N` makes the measuring side wait N microseconds before each ping, so the peer has had
//! nothing to do for that long when the ping arrives. That is decision 13's idle case: a peer in
//! `spin-then-wait` whose next message comes after its spin budget spends the budget and sleeps
//! anyway. The program prints the CPU time the peer's thread used per round trip on a line of its
//! own, before the result, because that is the cost the idle case is about and a latency does not
//! show it. A run with a gap is rotor against itself, and its row says so.
//!
//! `--peer process` runs the peer loop in a process of its own, made by `fork`, and the two loops
//! share a group's registry in a shared mapping (decision 21): the message crosses a process
//! boundary, and a wake is the group's wake. It is rotor against itself too.
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
const thread_cpu_ns = harness.clock.thread_cpu_ns;
const command_line = @import("rotor_post_options.zig");
const Mode = command_line.Mode;
const Options = command_line.Options;
const wait_ns = command_line.wait_ns;
const burst_max = command_line.burst_max;

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

/// Events one tick may hand over. A side has one message in flight and its own post's completion.
const events_max = 4;

const options_template: Loop.Options = .{
    .operations = operations,
    .entries = entries,
    .id = id_first,
};
const memory_bytes = Loop.memory_bytes(options_template);

/// The options of the loop with `id`, in `mode`: both loops share the registry, and a loop in
/// `spin-budget` is given the budget in its options.
fn loop_options(mode: Mode, id: core.LoopId) Loop.Options {
    var options = options_template;
    options.id = id;
    options.registry = &registry;
    options.spin_budget_ns = mode.loop_budget();
    return options;
}

comptime {
    std.debug.assert(burst_max < operations);
}

var registry: backend.Registry align(@alignOf(backend.Registry)) = undefined;
const registry_bytes = backend.Registry.memory_bytes(loops);
var registry_memory: [registry_bytes]u8 align(core.layout.memory_alignment) = undefined;

var latencies: Histogram align(harness.histogram.alignment_bytes) = .empty;

/// What the peer thread reports back about itself: it cannot return a value, so it writes one.
var peer_placement: placement.Placement align(@alignOf(placement.Placement)) = .scheduler_default;

/// The CPU time the peer's thread used over the measured round trips, which it writes for the same
/// reason. A spin shows here and a sleep does not, so this is what a mode costs a core.
var peer_cpu_ns: u64 = 0;

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
    warmup: u32,
    samples: u32,
    failure: ?anyerror = null,

    fn run(peer: *Peer) void {
        peer.serve() catch |err| {
            peer.failure = err;
        };
    }

    fn serve(peer: *Peer) !void {
        peer_placement = placement.place(peer.cpu);
        try peer.side.loop.init(&peer.side.memory, loop_options(peer.mode, id_second));
        defer peer.side.loop.deinit();
        std.debug.assert(peer.side.loop.in_flight() == 0);

        // The CPU clock starts where the measuring side's samples start, and stops at the last
        // pong of the last one, so the stop and the drain are not counted.
        const last_round = peer.warmup + peer.samples - 1;
        var cpu_start_ns: u64 = 0;
        var round: u32 = 0;
        while (true) : (round += 1) {
            if (round == peer.warmup) cpu_start_ns = thread_cpu_ns();
            if (try peer.side.receive(peer.mode, peer.burst) == tag_stop) break;
            peer.side.post(id_first, tag_pong, 1);
            if (round == last_round) peer_cpu_ns = thread_cpu_ns() - cpu_start_ns;
        }
        std.debug.assert(round == last_round + 1);
        try peer.side.drain(peer.mode);
    }
};

var first: Side align(@alignOf(Side)) = .{};

/// Runs the ping-pong and fills `latencies`, returning the measured span.
fn ping_pong(options: Options) !u64 {
    var round: u32 = 0;
    var span_ns: u64 = 0;
    while (round < options.warmup + options.samples) : (round += 1) {
        wait_gap(options.gap_us);
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

/// Waits `gap_us` without leaving the core, so the gap is the one asked for. A sleep would come back
/// late by the kernel's timer slack: `/proc/self/timerslack_ns` read 50,000 in the Linux gate's
/// container on 2026-09-24, as long as the gaps being measured.
fn wait_gap(gap_us: u32) void {
    if (gap_us == 0) return;
    const until_ns = now_ns() + @as(u64, gap_us) * std.time.ns_per_us;
    while (now_ns() < until_ns) {}
}

/// Starts the peer, measures, stops it, and returns the run as a `Result`.
fn measure(options: Options) !Result {
    std.debug.assert(options.samples >= 1);
    if (options.peer_process) return measure_across(options);
    registry.init(&registry_memory, loops);
    const own = placement.place(options.cpu);

    try first.loop.init(&first.memory, loop_options(options.mode, id_first));
    defer first.loop.deinit();

    var peer: Peer = .{
        .mode = options.mode,
        .cpu = options.peer_cpu,
        .burst = options.burst,
        .warmup = options.warmup,
        .samples = options.samples,
    };
    const thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});

    // The peer publishes its ring when its thread reaches `init`, and not before.
    var events: [events_max]Event = undefined;
    while (registry.get(id_second) < 0) _ = try first.loop.tick(&events, wait_ns);

    const span_ns = try ping_pong(options);

    first.post(id_second, tag_stop, 1);
    try first.drain(options.mode);
    thread.join();
    if (peer.failure) |err| return err;

    return result_of(options, span_ns, own);
}

/// The row of a run that measured `span_ns` over `options.samples` round trips, with this thread
/// placed as `own` says and the peer as it reported.
fn result_of(options: Options, span_ns: u64, own: placement.Placement) Result {
    const pinned = own.names_a_core() and peer_placement.names_a_core();
    return .init(.{
        .workload = "cross-core",
        .candidate = command_line.candidate_of(options),
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

/// What the peer reports when it runs in a process of its own, where a thread writes the globals
/// above. It sits in the shared mapping after the registry.
const Report = extern struct {
    cpu_ns: u64 = 0,
    placement: u8 = 0,
    failed: bool = false,
};

/// The shared mapping of a run whose peer is a process: the registry, then the report.
const across_bytes = std.mem.alignForward(usize, registry_bytes, @alignOf(Report)) + @sizeOf(Report);

/// Ticks the measuring loop waits, of `wait_ns` each, for a peer process to claim its id.
const peer_start_ticks_max = 1000;

/// What the peer process is handed: the options, and the mapping it attaches to.
const Across = struct {
    peer: Peer,
    memory: []align(std.heap.page_size_min) u8,
};

fn measure_across(options: Options) !Result {
    const memory = try harness.process.shared(across_bytes);
    defer harness.process.release(memory);
    var wakes: [loops]core.mailbox.Wake = undefined;
    try backend.group_module.make(&wakes);
    defer backend.group_module.close(&wakes);
    registry.init_group(memory[0..registry_bytes], loops, &wakes);
    const report = report_in(memory);
    report.* = .{};
    const child = try harness.process.start(Across, .{ .peer = .{
        .mode = options.mode,
        .cpu = options.peer_cpu,
        .burst = options.burst,
        .warmup = options.warmup,
        .samples = options.samples,
    }, .memory = memory }, serve_across);
    const own = placement.place(options.cpu);
    try first.loop.init(&first.memory, loop_options(options.mode, id_first));
    defer first.loop.deinit();
    try wait_for_peer(report);

    const span_ns = try ping_pong(options);
    first.post(id_second, tag_stop, 1);
    try first.drain(options.mode);
    if (try harness.process.wait(child) != harness.process.status_passed) return error.PeerFailed;
    if (report.failed) return error.PeerFailed;
    peer_cpu_ns = report.cpu_ns;
    peer_placement = @enumFromInt(report.placement);
    return result_of(options, span_ns, own);
}

fn report_in(memory: []align(std.heap.page_size_min) u8) *Report {
    const offset = std.mem.alignForward(usize, registry_bytes, @alignOf(Report));
    return @ptrCast(@alignCast(memory[offset..][0..@sizeOf(Report)]));
}

/// Ticks until the peer process claimed its id, or says it failed, or the ticks run out.
fn wait_for_peer(report: *const Report) !void {
    var events: [events_max]Event = undefined;
    for (0..peer_start_ticks_max) |_| {
        if (registry.get(id_second) >= 0) return;
        if (report.failed) return error.PeerFailed;
        _ = try first.loop.tick(&events, wait_ns);
    }
    return error.PeerFailed;
}

/// The peer process: it attaches to the group's registry, serves as the peer thread does, and
/// writes what the thread would have written into the report.
fn serve_across(across: Across) u8 {
    const report = report_in(across.memory);
    registry.attach(across.memory[0..registry_bytes]) catch {
        report.failed = true;
        return harness.process.status_failed;
    };
    var peer = across.peer;
    peer.run();
    report.cpu_ns = peer_cpu_ns;
    report.placement = @intFromEnum(peer_placement);
    report.failed = peer.failure != null;
    return if (peer.failure == null) harness.process.status_passed else harness.process.status_failed;
}

const output_buffer_bytes = 4096;

pub fn main(init: std.process.Init) !void {
    const options = try command_line.parse(init);
    const result = try measure(options);

    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;
    const peer_cpu_per_round_trip_ns = peer_cpu_ns / options.samples;
    try writer.print("rotor_post: mode {s}, gap {d} us, peer CPU per round trip {d} ns\n", .{
        @tagName(options.mode),
        options.gap_us,
        peer_cpu_per_round_trip_ns,
    });
    try writer.writeAll(harness.report.markdown_header);
    try result.render_markdown_row(writer);
    try writer.writeByte('\n');
    // Last, because the runner reads the last line of what a candidate printed.
    try result.render_json_line(writer);
    try writer.flush();
}

test {
    _ = command_line;
}

test "a loop is given the spin budget in the spin-budget mode and in no other" {
    try std.testing.expect(loop_options(.spin_budget, id_second).spin_budget_ns > 0);
    for ([_]Mode{ .waiting, .spinning, .spin_then_wait }) |mode| {
        try std.testing.expectEqual(@as(u64, 0), loop_options(mode, id_first).spin_budget_ns);
    }
    try std.testing.expectEqual(id_second, loop_options(.waiting, id_second).id);
}
