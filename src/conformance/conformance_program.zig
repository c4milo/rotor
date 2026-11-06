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

const Harness = conformance.Harness;
const Event = core.Event;
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
const group_bytes = backend.buffers.group_bytes(actions.group_buffers, actions.buffer_bytes);
var group_memory: [group_bytes]u8 align(backend.buffers.group_alignment) = undefined;

pub const Program = struct {
    seed: u64,
    random: core.random.Random,
    main: *Harness,
    peer: *Harness,
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

    fn init(program: *Program, seed: u64, main: *Harness, peer: *Harness, stream: actions.Stream, datagrams: actions.Datagrams) void {
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
        const before_ns = program.main.loop.now_ns();
        program.in_tick = true;
        const count = program.main.loop.tick(program.events[0..room], wait_ns);
        program.in_tick = false;
        const handed = try count;
        // A queued task keeps the tick from blocking (decision 27).
        if (wait_ns == actions.long_wait_ns and program.main.loop.now_ns() - before_ns >= wait_ns / 2) {
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
        program.main.loop.cancel_all();
        for (&program.ledger.entries) |*entry| entry.cancel_requested = entry.in_flight;
        if (program.random.chance(1, 2)) try program.settle() else try program.drain();
        for (&program.libraries) |*library| {
            if (library.added) program.main.loop.remove_poller(&library.poller);
            library.added = false;
        }
        if (!program.main.loop.tables.dispatch.idle()) return error.DispatchNotIdleAtEnd;
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
        try program.main.loop.drain(&scratch);
        try ledger_module.check_after_tick(program);
    }

    fn drain(program: *Program) !void {
        var scratch: [actions.events_max]Event = undefined;
        program.draining = true;
        program.in_tick = true;
        defer program.draining = false;
        defer program.in_tick = false;
        try program.main.loop.drain(&scratch);
        try program.ledger.forget_drained();
        try ledger_module.check_after_tick(program);
    }

    /// Empties the loop after a failed check, so `deinit` does not halt before the seed prints.
    fn abandon(program: *Program) void {
        program.stopping = true;
        program.main.loop.cancel_all();
        var scratch: [actions.events_max]Event = undefined;
        program.main.loop.drain(&scratch) catch {};
        _ = program.main.loop.discard_tasks();
        for (&program.libraries) |*library| {
            if (library.added) program.main.loop.remove_poller(&library.poller);
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

    fn open(main: *Harness) !Sockets {
        const listener = try tcp.Listener.open();
        defer sync.close_now(listener.descriptor);
        const stream = try tcp.connected_pair(main, &listener);
        errdefer for (stream) |descriptor| sync.close_now(descriptor);
        const receiver = try sync.open_datagram(.ipv4, &loopback, .{ .coalesce = false });
        errdefer sync.close_now(receiver);
        const sender = try sync.open_datagram(.ipv4, &loopback, .{});
        return .{ .stream = stream, .receiver = receiver, .sender = sender };
    }

    fn close(sockets: *const Sockets) void {
        for (sockets.stream) |descriptor| sync.close_now(descriptor);
        sync.close_now(sockets.receiver);
        sync.close_now(sockets.sender);
    }

    fn datagrams(sockets: *const Sockets) !actions.Datagrams {
        return .{
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
    registry.init(&registry_memory, 2);
    var main: Harness = undefined;
    try main.init(0, &registry);
    defer main.deinit();
    var peer: Harness = undefined;
    try peer.init(actions.peer_id, &registry);
    defer peer.deinit();
    const memory = &group_memory;
    try main.loop.provide_datagram_buffers(actions.group_id, memory, actions.group_buffers, actions.buffer_bytes, .{});
    defer main.loop.release_buffers(actions.group_id);
    const sockets = try Sockets.open(&main);
    defer sockets.close();

    var program: Program = undefined;
    const stream: actions.Stream = .{ .client = sockets.stream[0], .server = sockets.stream[1] };
    program.init(seed, &main, &peer, stream, try sockets.datagrams());
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
