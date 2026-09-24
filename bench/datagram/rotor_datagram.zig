//! rotor_datagram: the datagram round-trip workload, which is the shape a QUIC transport has.
//!
//! Run:  rotor_datagram [--in-flight N] [--bytes B] [--seconds S]
//!
//! One loop, one thread, two sockets (decision 4). A client socket sends a datagram to a server
//! socket bound on the loopback; the server answers it from the address it was written to, with
//! `Outbound.reply_to`, and the client's receive of that answer closes one round trip. `in_flight`
//! round trips are kept outstanding, so the loop always has work and the measurement is of the
//! path and not of the program waiting.
//!
//! It exercises every part of the datagram surface decision 15 added, and no other program does:
//! a multishot `receive_from` from a provided-buffer group, the accessor that finds a datagram
//! inside its buffer, `send_to` with a peer, and the reply path that answers from the local
//! address the kernel reported. A run that is wrong in any of them does not complete.
//!
//! Three numbers come out, and the second is the one that matters:
//!
//!   - **Throughput**: round trips per second.
//!   - **Latency**: how long each round trip took, at the median, the 99th and the 999th. A
//!     transport is judged on the tail, and a loop that batches more of them later is not
//!     obviously better.
//!   - **Lost**: round trips still outstanding when the run gave up on them. UDP drops a datagram
//!     that finds the receiving socket's buffer full, and a burst larger than that buffer does. A
//!     run waits `lost_wait_ns` past its deadline for the last answers, and no longer.
//!   - **Ticks**: how many ticks the run took. Each tick of a readiness backend makes one call into
//!     the kernel for readiness, so ticks per round trip shows how many datagrams one of those calls
//!     served. It is a count, so a busy machine does not change it the way it changes a time.
//!
//! It prints one line, every field one token with no spaces, as `rotor_timers` does:
//!
//!     datagram-echo <candidate> <version> <in_flight> <bytes> <round_trips> <span_ns> <p50> <p99>
//!         <p999> <ticks> <lost>
//!
//! **No number from this program is a claim.** `docs/costs.md` names no Linux machine yet, so a
//! run here guides work and nothing else (CLAUDE.md, performance discipline).
const std = @import("std");
const core = @import("core");
const backend = @import("backend");
const harness = @import("harness");
const now_ns = harness.clock.now_ns;
const percentile = harness.percentile;

const Loop = backend.Loop;
const Event = core.Event;
const Operation = core.Operation;
const Address = core.Address;
const Outbound = core.datagram.Outbound;
const sync = backend.sync;

/// Round trips outstanding at once, at most. Each holds one sample slot and one send. It is a
/// group's buffers: a socket holds at most one datagram per round trip, so a tick that takes every
/// datagram waiting on a socket still finds a free buffer for each. More would let a group run out,
/// which ends its multishot receive and stops the run.
const in_flight_max = group_buffers;

/// Slots: two multishot receives, plus one send per round trip in flight, with room to spare.
const operations = 2 * in_flight_max + 64;
const entries = 4096;
const events_max = 1024;

/// The two buffer groups: one per socket, because a group serves one socket's receives and both
/// sockets receive here. `provide_datagram_buffers` fixes one reserve for the loop, which both
/// groups then share.
const server_group = 0;
const client_group = 1;

/// Buffers per group, and the bytes of each: the prefix plus the largest payload offered.
const group_buffers = 512;
const bytes_max = 1400;
const buffer_bytes = core.datagram.prefix_bytes(.{}) + bytes_max;

/// Lateness samples kept, as `rotor_timers` keeps them: the first this many.
const samples_max = 1 << 17;

/// The datagrams a run sends, at most, so every loop here is bounded.
const round_trips_max = 1 << 26;

/// How long a run waits past its deadline for the round trips still outstanding. One whose datagram
/// was dropped never completes, and before this bound a run that lost one ticked until
/// `round_trips_max`, which at a millisecond a tick is most of a day.
const lost_wait_ns = 100 * core.constants.ns_per_ms;

const user_data_server_receive = 1;
const user_data_client_receive = 2;
const user_data_send = 3;

var loop_memory: [
    Loop.memory_bytes(.{ .operations = operations, .entries = entries })
]u8 align(core.layout.memory_alignment) = undefined;

const group_alignment = backend.buffers.group_alignment;
const group_bytes = backend.buffers.group_bytes(group_buffers, buffer_bytes);
var server_memory: [group_bytes]u8 align(group_alignment) = undefined;
var client_memory: [group_bytes]u8 align(group_alignment) = undefined;

/// The bytes every datagram carries, written once.
var payload: [bytes_max]u8 = undefined;

/// When each outstanding round trip started, by its slot in the window.
var started_ns: [in_flight_max]u64 = undefined;
var latency_ns: [samples_max]u64 = undefined;

/// Where the client sends, and where the server answers. Both live for the whole run, which is
/// what decision 5's rule 3 asks of an `Outbound` an operation names.
var to_server: Outbound align(@alignOf(Outbound)) = undefined;
var to_client: [in_flight_max]Outbound align(@alignOf(Outbound)) = undefined;

const Options = struct {
    in_flight: u32 = 64,
    bytes: u32 = 1200,
    seconds: u64 = 3,
};

const Run = struct {
    loop: *Loop,
    options: Options,
    deadline_ns: u64,
    round_trips: u64 = 0,
    ticks: u64 = 0,
    taken: u32 = 0,
    /// The next window slot a send will use, and how many are outstanding.
    next: u32 = 0,
    outstanding: u32 = 0,
    stopping: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    payload = @splat('q');

    var loop: Loop = undefined;
    try loop.init(&loop_memory, .{ .operations = operations, .entries = entries });
    defer loop.deinit();

    const any_port = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const server = try sync.open_datagram(.ipv4, &any_port, .{});
    defer sync.close_now(server);
    const client = try sync.open_datagram(.ipv4, &any_port, .{});
    defer sync.close_now(client);
    to_server = .{
        .peer = try sync.local_address(server),
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };

    try provide(&loop);
    var state: Run = .{ .loop = &loop, .options = options, .deadline_ns = 0 };
    const span_ns = try run(&state, server, client);
    try report(init, &state, span_ns);
}

fn provide(loop: *Loop) !void {
    try loop.provide_datagram_buffers(server_group, &server_memory, group_buffers, buffer_bytes, .{});
    try loop.provide_datagram_buffers(client_group, &client_memory, group_buffers, buffer_bytes, .{});
}

/// Arms both receives, fills the window, and keeps it full until the deadline. Returns the span.
fn run(state: *Run, server: core.Descriptor, client: core.Descriptor) !u64 {
    const loop = state.loop;
    try arm_receives(loop, server, client);

    const started = now_ns();
    state.deadline_ns = started + state.options.seconds * core.constants.ns_per_s;
    while (state.outstanding < state.options.in_flight) send_one(state, client);

    var events: [events_max]Event = undefined;
    var rounds: u64 = 0;
    const give_up_ns = state.deadline_ns + lost_wait_ns;
    while (state.outstanding != 0 and rounds < round_trips_max) : (rounds += 1) {
        if (now_ns() >= give_up_ns) break;
        const count = try loop.tick(&events, core.constants.ns_per_ms);
        for (events[0..count]) |event| handle(state, event, server, client);
    }
    const span = now_ns() - started;
    state.ticks = rounds;
    loop.cancel_all();
    try loop.drain(&events);
    return span;
}

fn arm_receives(loop: *Loop, server: core.Descriptor, client: core.Descriptor) !void {
    const armed = loop.submit(&.{
        receive_from(user_data_server_receive, server, server_group),
        receive_from(user_data_client_receive, client, client_group),
    }, &.{});
    if (armed != 2) return error.SubmitRefused;
}

fn receive_from(user_data: u64, socket: core.Descriptor, group: u16) Operation {
    return .{ .user_data = user_data, .kind = .{ .receive_from = .{
        .socket = socket,
        .group = group,
    } } };
}

fn handle(state: *Run, event: Event, server: core.Descriptor, client: core.Descriptor) void {
    switch (event.user_data) {
        user_data_server_receive => serve(state, event, server),
        user_data_client_receive => complete_round_trip(state, event, client),
        // A send's completion frees nothing: its buffer is this program's own.
        else => _ = event.outcome() catch {},
    }
}

/// The server side: answer the datagram from the address it was sent to, which is the one call a
/// QUIC server makes per packet.
fn serve(state: *Run, event: Event, server: core.Descriptor) void {
    const received = event.outcome() catch return;
    const delivery = state.loop.datagram(server_group, event);
    // The window slot rides in the first bytes, so the client knows which round trip returned.
    const slot = slot_of(delivery.bytes);
    to_client[slot] = Outbound.reply_to(&delivery.from);
    _ = state.loop.submit(&.{.{ .user_data = user_data_send, .kind = .{ .send_to = .{
        .socket = server,
        .buffer = .{ .bytes = delivery.bytes[0..received] },
        .to = &to_client[slot],
    } } }}, &.{});
    state.loop.give_back_buffer(server_group, event.flags.buffer_id);
}

/// The client side: one round trip closed, its latency recorded, and another sent unless the
/// deadline has passed.
fn complete_round_trip(state: *Run, event: Event, client: core.Descriptor) void {
    defer state.loop.give_back_buffer(client_group, event.flags.buffer_id);
    _ = event.outcome() catch return;
    const delivery = state.loop.datagram(client_group, event);
    const slot = slot_of(delivery.bytes);
    const at_ns = now_ns();
    state.round_trips += 1;
    state.outstanding -= 1;
    record(state, at_ns - started_ns[slot]);
    if (at_ns >= state.deadline_ns) {
        state.stopping = true;
        return;
    }
    send_one(state, client);
}

fn send_one(state: *Run, client: core.Descriptor) void {
    if (state.stopping) return;
    const slot = state.next;
    state.next = (state.next + 1) % state.options.in_flight;
    started_ns[slot] = now_ns();
    write_slot(payload[0..state.options.bytes], slot);
    const taken = state.loop.submit(&.{.{ .user_data = user_data_send, .kind = .{ .send_to = .{
        .socket = client,
        .buffer = .{ .bytes = payload[0..state.options.bytes] },
        .to = &to_server,
    } } }}, &.{});
    if (taken == 1) state.outstanding += 1;
}

/// The window slot a datagram carries, in its first four bytes.
const slot_bytes = 4;

fn write_slot(bytes: []u8, slot: u32) void {
    std.mem.writeInt(u32, bytes[0..slot_bytes], slot, .little);
}

fn slot_of(bytes: []const u8) u32 {
    if (bytes.len < slot_bytes) return 0;
    return std.mem.readInt(u32, bytes[0..slot_bytes], .little) % in_flight_max;
}

fn record(state: *Run, elapsed_ns: u64) void {
    if (state.taken == samples_max) return;
    latency_ns[state.taken] = elapsed_ns;
    state.taken += 1;
}

fn report(init: std.process.Init, state: *const Run, span_ns: u64) !void {
    const samples = latency_ns[0..state.taken];
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    try out.interface.print(
        "datagram-echo rotor this-tree {d} {d} {d} {d} {d} {d} {d} {d} {d}\n",
        .{
            state.options.in_flight,
            state.options.bytes,
            state.round_trips,
            span_ns,
            percentile.nearest_rank(samples, percentile.p50),
            percentile.nearest_rank(samples, percentile.p99),
            percentile.nearest_rank(samples, percentile.p999),
            state.ticks,
            state.outstanding,
        },
    );
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
    if (options.in_flight == 0 or options.in_flight > in_flight_max) return error.TooManyInFlight;
    if (options.bytes < slot_bytes or options.bytes > bytes_max) return error.BytesOutOfRange;
    if (options.seconds == 0) return error.EmptyConfiguration;
    return options;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--in-flight")) {
        options.in_flight = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--bytes")) {
        options.bytes = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else {
        return error.UnknownArgument;
    }
}
