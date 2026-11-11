//! A seeded program of several libraries on one loop, on every real backend (decisions 26 and 27).
//! A generator drawn from `core.random` acts as three libraries and their program. It submits
//! timers, TCP and UDP operations over loopback and posts, with and without a record. It also
//! cancels, adds and removes pollers, queues tasks from the program, a record, a poller and a
//! task, discards the queue, and ticks with waits it draws. At the end it cancels everything and
//! empties the loop, by its own ticks or by `drain`. `conformance_program_ledger.zig` holds the
//! oracle, and `conformance_program_actions.zig` the actions.
//!
//! A failed seed prints its number. Two environment variables change the run:
//!
//! - `ROTOR_CONFORMANCE_SEED` runs that one seed first, to replay a failure.
//! - `ROTOR_CONFORMANCE_SOAK_SECONDS` runs seed after seed for that many seconds, and prints how
//!   many seeds, ticks, events and tasks it saw. Without it, the run takes `seeds_default` seeds.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const tcp = @import("conformance_tcp.zig");
const ledger_module = @import("conformance_program_ledger.zig");
const actions = @import("conformance_program_actions.zig");

const ReactorHarness = conformance.ReactorHarness;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

pub const soak_variable = "ROTOR_CONFORMANCE_SOAK_SECONDS";
pub const seed_variable = "ROTOR_CONFORMANCE_SEED";

/// The seeds of a run without a soak, and the steps of each seed.
const seeds_default = 32;
const steps_per_seed = 300;
/// The first seed of a run that names none.
const seed_first = 0x5EED_2026_1106;
/// The most seconds a soak may ask for: one day.
const soak_seconds_max = 24 * 60 * 60;

/// The libraries that share the loop. Each has a poller and a share of the tasks.
const libraries_count = 3;

const loopback = core.Address.ipv4(.{ 127, 0, 0, 1 }, 0);
/// The datagrams that check that the receiver takes only its sender's datagrams. A stranger's
/// datagram is not 8 bytes long, so a receive in the program that takes one fails with
/// `DatagramLengthWrong`.
const stranger_payload = "from a stranger";
const sender_payload = "from the sender";
/// The user data of the operations that prepare the datagram sockets, before the program.
const connect_user_data = 1;
const send_user_data = 2;
const receive_user_data = 3;
const group_bytes = backend.buffers.group_bytes(actions.group_buffers, actions.buffer_bytes);
var group_memory: [group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

pub const Program = struct {
    seed: u64,
    random: core.random.Random,
    main: *ReactorHarness,
    peer: *ReactorHarness,
    ledger: ledger_module.Ledger,
    jobs: ledger_module.Jobs,
    libraries: [libraries_count]actions.Library,
    stream: actions.Stream,
    datagrams: actions.Datagrams,
    posts: actions.Posts,
    /// The number of the tick in progress, or of the next tick between two ticks.
    tick_number: u64,
    /// True while the program is inside a tick of its loop, `drain` included.
    in_tick: bool,
    /// True once the program ends: no record, poller or task starts new work.
    stopping: bool,
    /// True inside `drain`, whose ticks the program does not number.
    draining: bool,
    /// The first check that failed inside a record, a poller or a task.
    failure: ?anyerror,
    events: [actions.events_max]Event,

    fn init(program: *Program, seed: u64, main: *ReactorHarness, peer: *ReactorHarness, stream: actions.Stream, datagrams: actions.Datagrams) void {
        program.* = .{
            .seed = seed,
            .random = .init(seed),
            .main = main,
            .peer = peer,
            .ledger = undefined,
            .jobs = undefined,
            .libraries = undefined,
            .stream = stream,
            .datagrams = datagrams,
            .posts = .{},
            .tick_number = 0,
            .in_tick = false,
            .stopping = false,
            .draining = false,
            .failure = null,
            .events = undefined,
        };
        program.ledger.init(program);
        program.jobs.init(program);
        for (&program.libraries) |*library| library.* = .{ .program = program };
    }

    /// Keeps the first error of a check inside a callback, which cannot return one.
    pub fn fail(program: *Program, err: anyerror) void {
        if (program.failure == null) program.failure = err;
    }

    /// One tick of the program's loop with a drawn wait and a drawn room for events, then the
    /// checks, then one tick of the peer loop.
    pub fn tick(program: *Program) !void {
        const wait_ns = actions.draw_wait(program);
        const room = actions.draw_room(program);
        var polls: [libraries_count]u32 = undefined;
        for (&program.libraries, &polls) |*library, *count| count.* = library.polls;
        const before_ns = program.main.reactor.now_ns();
        program.in_tick = true;
        const count = program.main.reactor.tick(program.events[0..room], wait_ns);
        program.in_tick = false;
        const handed = try count;
        // A queued task keeps the tick from blocking (decision 27).
        if (wait_ns == actions.long_wait_ns and program.main.reactor.now_ns() - before_ns >= wait_ns / 2) {
            return error.TickBlockedWithTaskQueued;
        }
        program.tick_number += 1;
        for (program.events[0..handed]) |event| try program.on_handed(event);
        for (&program.libraries, polls) |*library, before| {
            if (library.polls != before + @intFromBool(library.added)) return error.PollerNotOnceATick;
        }
        try ledger_module.check_after_tick(program);
        try actions.tick_peer(program);
    }

    fn on_handed(program: *Program, event: Event) !void {
        if (event.flags.message) return actions.on_message(program, event);
        try program.ledger.on_plain(event);
    }

    fn run(program: *Program, steps: u32) !void {
        for (0..steps) |_| {
            try actions.perform(program, actions.draw(&program.random));
            if (program.failure) |failure| return failure;
        }
        try program.finish();
    }

    /// Cancels every operation and empties the loop: by the program's own ticks, which see every
    /// final event, or by `drain`, which hands the plain ones to no one.
    fn finish(program: *Program) !void {
        program.stopping = true;
        program.main.reactor.cancel_all();
        for (&program.ledger.entries) |*entry| entry.cancel_requested = entry.in_flight;
        if (program.random.chance(1, 2)) try program.settle() else try program.drain();
        for (&program.libraries) |*library| {
            if (library.added) program.main.reactor.remove_poller(&library.poller);
            library.added = false;
        }
        if (!program.main.reactor.loop.tables.dispatch.idle()) return error.DispatchNotIdleAtEnd;
        try actions.check_end(program);
    }

    fn settle(program: *Program) !void {
        var round: u32 = 0;
        while (program.ledger.in_flight != 0 or program.jobs.queued != 0) : (round += 1) {
            if (round == core.constants.drain_rounds_max) return error.ProgramNeverSettled;
            try program.tick();
        }
        // Nothing is left, so `drain` returns at once.
        var scratch: [1]Event = undefined;
        try program.main.reactor.drain(&scratch);
        try ledger_module.check_after_tick(program);
    }

    fn drain(program: *Program) !void {
        var scratch: [actions.events_max]Event = undefined;
        program.draining = true;
        program.in_tick = true;
        defer program.draining = false;
        defer program.in_tick = false;
        try program.main.reactor.drain(&scratch);
        try program.ledger.forget_drained();
        try ledger_module.check_after_tick(program);
    }

    /// Empties the loop after a failed check, so `deinit` does not halt before the seed prints.
    fn abandon(program: *Program) void {
        program.stopping = true;
        program.main.reactor.cancel_all();
        var scratch: [actions.events_max]Event = undefined;
        program.main.reactor.drain(&scratch) catch {};
        _ = program.main.reactor.discard_tasks();
        for (&program.libraries) |*library| {
            if (library.added) program.main.reactor.remove_poller(&library.poller);
            library.added = false;
        }
    }
};

/// A number the environment names, or null when it names none. A value that is not a number halts
/// the run: a soak or a replay that quietly ran the default would prove nothing.
fn environment_number(comptime name: []const u8, maximum: u64) ?u64 {
    const text = testing.environ.getPosix(name) orelse return null;
    const value = std.fmt.parseInt(u64, text, 0) catch @panic(name ++ " is not a number");
    if (value > maximum) @panic(name ++ " is over the most");
    return value;
}

/// What a soak prints at its end.
const Totals = struct {
    seeds: u64 = 0,
    ticks: u64 = 0,
    finals: u64 = 0,
    mores: u64 = 0,
    tasks: u64 = 0,

    fn add(totals: *Totals, program: *const Program) void {
        totals.seeds += 1;
        totals.ticks += program.tick_number;
        totals.finals += program.ledger.finals;
        totals.mores += program.ledger.mores;
        totals.tasks += program.jobs.ran;
    }
};

/// The sockets of one seed: a TCP connection and a pair of datagram sockets over loopback.
const Sockets = struct {
    stream: [2]core.Descriptor,
    receiver: core.Descriptor,
    sender: core.Descriptor,

    fn open(main: *ReactorHarness) !Sockets {
        const listener = try tcp.Listener.open();
        defer sync.close_now(listener.descriptor);
        const stream = try tcp.connected_pair(main, &listener);
        errdefer for (stream) |descriptor| sync.close_now(descriptor);
        const receiver = try sync.open_datagram(.ipv4, &loopback, .{ .coalesce = false });
        errdefer sync.close_now(receiver);
        const sender = try sync.open_datagram(.ipv4, &loopback, .{});
        errdefer sync.close_now(sender);
        try hear_only(main, receiver, sender);
        return .{ .stream = stream, .receiver = receiver, .sender = sender };
    }

    /// Connects `receiver` to `sender`, so the kernel hands it no datagram from another socket.
    /// macOS can bind a dual-stack socket on `::` to the port of a socket on 127.0.0.1. The IPv4
    /// datagrams sent to that port then reach the 127.0.0.1 socket. A test in another process sent
    /// its datagram to this receiver that way. Then a third socket and the sender each send one
    /// datagram, and the receiver must take the sender's datagram first.
    fn hear_only(main: *ReactorHarness, receiver: core.Descriptor, sender: core.Descriptor) !void {
        const sender_address = try sync.local_address(sender);
        try main.submit(&.{Operation.connect(connect_user_data, receiver, &sender_address)}, &.{});
        var connected: [1]Event = undefined;
        try main.collect(&connected);
        try testing.expectEqual(@as(u32, 0), try connected[0].outcome());
        const stranger = try sync.open_datagram(.ipv4, &loopback, .{});
        defer sync.close_now(stranger);
        const out: core.datagram.Outbound = .{
            .peer = try sync.local_address(receiver),
            .local = undefined,
            .segment_bytes = 0,
            .ecn = .not_ect,
            .flags = .{ .peer = true },
        };
        // The stranger sends first, so a receiver that takes its datagram takes it first.
        try send_one(main, stranger, stranger_payload, &out);
        try send_one(main, sender, sender_payload, &out);
        var buffer: [2 * sender_payload.len]u8 = undefined;
        try main.submit(&.{Operation.receive(receive_user_data, receiver, &buffer)}, &.{});
        var received: [1]Event = undefined;
        try main.collect(&received);
        const bytes = try received[0].outcome();
        try testing.expectEqualStrings(sender_payload, buffer[0..bytes]);
    }

    fn send_one(main: *ReactorHarness, socket: core.Descriptor, bytes: []const u8, out: *const core.datagram.Outbound) !void {
        try main.submit(&.{Operation.send_to(send_user_data, socket, bytes, out)}, &.{});
        var sent: [1]Event = undefined;
        try main.collect(&sent);
        try testing.expectEqual(@as(u32, @intCast(bytes.len)), try sent[0].outcome());
    }

    fn close(sockets: *const Sockets) void {
        for (sockets.stream) |descriptor| sync.close_now(descriptor);
        sync.close_now(sockets.receiver);
        sync.close_now(sockets.sender);
    }

    fn datagrams(sockets: *const Sockets, group: core.BufferGroup) !actions.Datagrams {
        return .{
            .group = group,
            .receiver = sockets.receiver,
            .sender = sockets.sender,
            .out = .{
                .peer = try sync.local_address(sockets.receiver),
                .local = undefined,
                .segment_bytes = 0,
                .ecn = .not_ect,
                .flags = .{ .peer = true },
            },
        };
    }
};

fn run_seed(seed: u64, totals: *Totals) !void {
    var registry: backend.Registry = undefined;
    var registry_memory: [backend.Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, 2);
    defer life.end();
    var main: ReactorHarness = undefined;
    try main.init(0, &registry);
    defer main.deinit();
    var peer: ReactorHarness = undefined;
    try peer.init(actions.peer_id, &registry);
    defer peer.deinit();
    const memory = &group_memory;
    const group = try main.reactor.reserve_buffer_group();
    try main.reactor.provide_datagram_buffers(group, memory, actions.group_buffers, actions.buffer_bytes, .{});
    defer main.reactor.release_buffers(group);
    const sockets = try Sockets.open(&main);
    defer sockets.close();

    var program: Program = undefined;
    const stream: actions.Stream = .{ .client = sockets.stream[0], .server = sockets.stream[1] };
    program.init(seed, &main, &peer, stream, try sockets.datagrams(group));
    // Registered last, so it runs first: the seed prints before any cleanup can halt.
    errdefer {
        std.debug.print("conformance program: seed 0x{x} failed; replay with {s}=0x{x}\n", .{ seed, seed_variable, seed });
        program.abandon();
    }
    try program.run(steps_per_seed);
    totals.add(&program);
}

test "a seeded program of three libraries on one loop ends every operation and task once" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var totals: Totals = .{};
    const first = environment_number(seed_variable, std.math.maxInt(u64) - seeds_default) orelse seed_first;
    const soak_seconds = environment_number(soak_variable, soak_seconds_max) orelse 0;
    if (soak_seconds == 0) {
        for (0..seeds_default) |index| try run_seed(first + index, &totals);
        return;
    }
    const deadline_ns = backend.testing.monotonic_ns() + soak_seconds * core.constants.ns_per_s;
    var seed = first;
    while (backend.testing.monotonic_ns() < deadline_ns) : (seed +%= 1) try run_seed(seed, &totals);
    std.debug.print(
        "conformance program soak: {d} seeds, {d} ticks, {d} final events, {d} more events, {d} tasks\n",
        .{ totals.seeds, totals.ticks, totals.finals, totals.mores, totals.tasks },
    );
}
