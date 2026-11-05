//! The burst mode of `rotor_datagram`: datagrams one peer sends in bursts, received into buffers
//! large enough for UDP_GRO, which is where coalescing can pay (decision 15, amendment of
//! 2026-11-05).
//!
//! One loop, one thread, two sockets on the loopback. A client keeps `in_flight` segmented sends
//! outstanding, each of `burst` datagrams of `bytes` bytes, and sends again as each completes. A
//! server receives with one multishot `receive_from` from a group of 64 KiB buffers, takes each
//! datagram the loop hands over, and gives its buffer back. With coalescing on, the kernel joins
//! the datagrams of a burst in one receive and the loop splits them again. With it off, each
//! datagram is a receive of its own.
//!
//! It prints one line, every field one token with no spaces:
//!
//!     datagram-burst <candidate> <version> <coalesce> <in_flight> <burst> <bytes> <datagrams>
//!         <receives> <span_ns> <ticks>
//!
//! `datagrams` counts the datagrams received, and `receives` the kernel receives they came in:
//! the events whose segment index is 0. Datagrams the kernel dropped for a full socket buffer are
//! not counted, so the rate is what the receiver took.
//!
//! **No number from this program is a claim.** `docs/costs.md` names no Linux machine yet.
const std = @import("std");
const core = @import("core");
const backend = @import("backend");
const harness = @import("harness");
const now_ns = harness.clock.now_ns;

const Loop = backend.Loop;
const Event = core.Event;
const Outbound = core.datagram.Outbound;
const Address = core.Address;
const sync = backend.sync;

/// A buffer holds the prefix and the largest coalesced datagram, rounded up to a cache line: the
/// loop reads the head in front of each datagram through a typed pointer, so every buffer must start
/// aligned, and 65,535 is odd.
const buffer_bytes = std.mem.alignForward(u32, core.datagram.prefix_bytes(.{}) + core.constants.coalesced_bytes_max, 64);
const group_buffers = 64;
const group_id = 0;

/// Sends outstanding at once, at most.
const in_flight_max = 64;
const bytes_max = 1400;
const operations = in_flight_max + 16;
const entries = 1024;
const events_max = 1024;

/// The ticks a run makes, at most, so every loop here is bounded.
const ticks_max = 1 << 26;

const user_data_receive = 1;
const user_data_send = 2;

var loop_memory: [
    Loop.memory_bytes(.{ .operations = operations, .entries = entries })
]u8 align(core.layout.memory_alignment) = undefined;
var group_memory: [backend.buffers.group_bytes(group_buffers, buffer_bytes)]u8 align(backend.buffers.group_alignment) = undefined;

/// What one send carries: `burst` datagrams of `bytes`, back to back.
var payload: [core.constants.segments_max * bytes_max]u8 = undefined;
var to_server: Outbound align(@alignOf(Outbound)) = undefined;

const Options = struct {
    burst: u32 = 16,
    coalesce: bool = true,
    in_flight: u32 = 4,
    bytes: u32 = 1200,
    seconds: u64 = 3,
};

const Run = struct {
    loop: *Loop,
    options: Options,
    client: core.Descriptor,
    server: core.Descriptor,
    deadline_ns: u64 = 0,
    datagrams: u64 = 0,
    receives: u64 = 0,
    ticks: u64 = 0,
    outstanding: u32 = 0,
};

/// True when the command line asks for the burst mode.
pub fn wanted(init: std.process.Init) !bool {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "--burst")) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    payload = @splat('b');
    var loop: Loop = undefined;
    try loop.init(&loop_memory, .{ .operations = operations, .entries = entries });
    defer loop.deinit();
    try loop.provide_datagram_buffers(group_id, &group_memory, group_buffers, buffer_bytes, .{});

    const any_port = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const server = try sync.open_datagram(.ipv4, &any_port, .{ .coalesce = options.coalesce });
    defer sync.close_now(server);
    const client = try sync.open_datagram(.ipv4, &any_port, .{});
    defer sync.close_now(client);
    to_server = .{
        .peer = try sync.local_address(server),
        .local = undefined,
        .segment_bytes = @intCast(options.bytes),
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    var state: Run = .{ .loop = &loop, .options = options, .client = client, .server = server };
    const span_ns = try run(&state);
    try report(init, &state, span_ns);
}

fn run(state: *Run) !u64 {
    const loop = state.loop;
    arm(state);
    const started = now_ns();
    state.deadline_ns = started + state.options.seconds * core.constants.ns_per_s;
    while (state.outstanding < state.options.in_flight) send(state);
    var events: [events_max]Event = undefined;
    while (now_ns() < state.deadline_ns and state.ticks < ticks_max) : (state.ticks += 1) {
        const count = try loop.tick(&events, core.constants.ns_per_ms);
        for (events[0..count]) |event| handle(state, event);
    }
    const span = now_ns() - started;
    loop.cancel_all();
    try loop.drain(&events);
    return span;
}

fn arm(state: *Run) void {
    _ = state.loop.submit(&.{.{ .user_data = user_data_receive, .kind = .{ .receive_from = .{
        .socket = state.server,
        .group = group_id,
    } } }}, &.{});
}

fn send(state: *Run) void {
    const bytes = payload[0 .. state.options.burst * state.options.bytes];
    const taken = state.loop.submit(&.{.{ .user_data = user_data_send, .kind = .{ .send_to = .{
        .socket = state.client,
        .buffer = .{ .bytes = bytes },
        .to = &to_server,
    } } }}, &.{});
    if (taken == 1) state.outstanding += 1;
}

fn handle(state: *Run, event: Event) void {
    if (event.user_data == user_data_send) {
        state.outstanding -= 1;
        if (now_ns() < state.deadline_ns) send(state);
        return;
    }
    if (event.flags.buffer) {
        state.datagrams += 1;
        if (event.flags.segment == 0) state.receives += 1;
        state.loop.give_back_buffer(group_id, event.flags.buffer_id);
    }
    // A multishot receive can end with a success, or when the group ran dry: start it again.
    if (!event.flags.more and now_ns() < state.deadline_ns) arm(state);
}

fn report(init: std.process.Init, state: *const Run, span_ns: u64) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    try out.interface.print("datagram-burst rotor this-tree {s} {d} {d} {d} {d} {d} {d} {d}\n", .{
        if (state.options.coalesce) "on" else "off",
        state.options.in_flight,
        state.options.burst,
        state.options.bytes,
        state.datagrams,
        state.receives,
        span_ns,
        state.ticks,
    });
    try out.interface.flush();
}

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    if (options.burst == 0 or options.burst > core.constants.segments_max) return error.BurstOutOfRange;
    if (options.in_flight == 0 or options.in_flight > in_flight_max) return error.TooManyInFlight;
    if (options.bytes == 0 or options.bytes > bytes_max) return error.BytesOutOfRange;
    return options;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--burst")) {
        options.burst = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--coalesce")) {
        options.coalesce = std.mem.eql(u8, value, "on");
    } else if (std.mem.eql(u8, name, "--in-flight")) {
        options.in_flight = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--bytes")) {
        options.bytes = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else {
        return error.UnknownArgument;
    }
}
