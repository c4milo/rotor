//! One library on two adapters, in the shape of colibri's (decision 33, ruling item 4, and step 5
//! of its build order). The library takes an interface in its own terms: three functions, `turn`,
//! `complete` and `deadline`. It names no type of rotor, does no I/O and reads no clock. At each of
//! its deadlines it sends a message on one end of a loopback connection, and it receives each
//! message on the other end.
//!
//! The program runs the library twice, once on each adapter:
//!
//! - On a plain `rotor.Loop` that the program owns and ticks. The adapter puts its tag in each
//!   `user_data`, and the program hands it each event with that tag. Before each tick the program
//!   writes the least of the library's deadline and its own with `wait_until`.
//! - On a `rotor.Reactor(rotor.Loop)`, through the view `*rotor.SharedLoop`. A record of each
//!   operation hands the library its result. A poller bounds the wait at the library's deadline,
//!   and a task in the library's scheduling group calls `turn`.
//!
//! The program has a deadline of its own on both runs: `beats_max` beats. The first comes
//! `beat_gap_ns` after the start, long after the library's last message, and the others follow
//! `beat_ns` apart. So for a time each deadline is the only near one. A library deadline that
//! bounds no wait is met at the first beat, about 400 ms late. A beat that bounds no wait is met
//! after the tick's whole wait of 10 s. On the reactor, a poller of the program bounds the wait at
//! the next beat.
//!
//! The program prints one line for each run, and exits 0 only when both runs ended. `zig build
//! test` runs `tools/two_adapters_check.zig`, which starts the program and holds the two lines to
//! the same numbers. The Linux gate does the same on io_uring and on epoll.
//!
//! Run:  zig build examples && ./zig-out/bin/two_adapters
const std = @import("std");
const rotor = @import("rotor");
const assert = std.debug.assert;

/// What the library sends: one message at each of its deadlines, `message_bytes` each.
const messages = "round 1\nround 2\nround 3\nround 4\n";
const message_bytes = 8;
/// The time from one message of the library to the next.
const period_ns = 2 * rotor.constants.ns_per_ms;

/// The program's own deadline: `beats_max` beats, the first `beat_gap_ns` after the start and the
/// others `beat_ns` apart. The checker bounds the lateness of a deadline far under the gap.
const beat_gap_ns = 400 * rotor.constants.ns_per_ms;
const beat_ns = 3 * rotor.constants.ns_per_ms;
const beats_max = 8;

/// The operations that one loop holds at most: the library's two, or the accept and the connect.
const loop_operations = 4;
/// The ticks that one run may take before the program calls it stuck.
const ticks_max = 1000;
/// The shares of the library's scheduling group: the default, one unit at each visit (decision 30).
const library_shares = 100;
/// The longest line of the report.
const line_bytes_max = 160;

comptime {
    assert(messages.len % message_bytes == 0);
    // The first beat comes long after the library's last message: ten times as long at least.
    assert(beat_gap_ns > 10 * (messages.len / message_bytes * period_ns));
}

/// The library. A host does each operation that `turn` writes, and gives back its result with
/// `complete`. The host calls `turn` again by the instant that `deadline` names. The library sends
/// on one end of a connection and receives on the other. The host maps each end to a socket.
const Pacer = struct {
    period_ns: u64,
    /// When the library wants its next `turn`, or null while only a completion can give it work.
    wake_ns: ?u64,
    /// When the next message is due. Each one is due `period_ns` after the one before.
    send_due_ns: u64,
    sent_bytes: u32 = 0,
    received_bytes: u32 = 0,
    /// One flag for each `Id`: true while that operation is out.
    out: [operations_max]bool = @splat(false),
    failed: bool = false,
    /// The latest turn for a message, after the deadline of that message.
    late_ns_max: u64 = 0,
    inbox: [messages.len]u8 = undefined,

    /// The library's name for each operation. At most one of each is out at once.
    pub const Id = enum(u8) { send, receive };
    pub const operations_max = @typeInfo(Id).@"enum".fields.len;

    /// What the library asks a host to do.
    pub const Operation = union(Id) {
        /// Send these bytes on the sending end.
        send: []const u8,
        /// Receive into these bytes on the receiving end.
        receive: []u8,
    };

    /// What a host gives back for each operation: the bytes that moved, or null when it failed.
    pub const Completion = struct { id: Id, bytes: ?u32 };

    /// A library that wants its first turn at `now_ns`, and sends its first message one period
    /// later. Each time is on the host's clock.
    pub fn init(now_ns: u64, period: u64) Pacer {
        return .{ .period_ns = period, .wake_ns = now_ns, .send_due_ns = now_ns + period };
    }

    /// Writes into `operations` what the library needs done now, and returns how many.
    pub fn turn(pacer: *Pacer, now_ns: u64, operations: *[operations_max]Operation) u32 {
        pacer.wake_ns = null;
        if (pacer.failed) return 0;
        var count: u32 = 0;
        if (pacer.next_receive()) |operation| {
            operations[count] = operation;
            count += 1;
        }
        if (pacer.next_send(now_ns)) |operation| {
            operations[count] = operation;
            count += 1;
        }
        return count;
    }

    /// Takes the result of an operation that `turn` wrote. The library then wants a turn at once.
    pub fn complete(pacer: *Pacer, completion: Completion, now_ns: u64) void {
        const index = @intFromEnum(completion.id);
        assert(pacer.out[index]);
        pacer.out[index] = false;
        pacer.wake_ns = now_ns;
        const bytes = completion.bytes orelse {
            pacer.failed = true;
            return;
        };
        switch (completion.id) {
            .send => pacer.sent_bytes += bytes,
            .receive => pacer.take(bytes),
        }
    }

    /// When the library wants its next `turn`, on the host's clock. Null while only a completion
    /// can give it work, and after it ended or failed.
    pub fn deadline(pacer: *const Pacer) ?u64 {
        if (pacer.failed or pacer.ended()) return null;
        return pacer.wake_ns;
    }

    /// True when each message went out and came back whole. No operation is then out.
    pub fn ended(pacer: *const Pacer) bool {
        return pacer.sent_bytes == messages.len and pacer.received_bytes == messages.len;
    }

    fn next_receive(pacer: *Pacer) ?Operation {
        const index = @intFromEnum(Id.receive);
        if (pacer.out[index] or pacer.received_bytes == messages.len) return null;
        pacer.out[index] = true;
        return .{ .receive = pacer.inbox[pacer.received_bytes..] };
    }

    /// The rest of the message that a short send left, or the next message once it is due.
    fn next_send(pacer: *Pacer, now_ns: u64) ?Operation {
        const index = @intFromEnum(Id.send);
        if (pacer.out[index] or pacer.sent_bytes == messages.len) return null;
        if (pacer.sent_bytes % message_bytes == 0) {
            if (now_ns < pacer.send_due_ns) {
                pacer.wake_ns = pacer.send_due_ns;
                return null;
            }
            pacer.late_ns_max = @max(pacer.late_ns_max, now_ns - pacer.send_due_ns);
            pacer.send_due_ns += pacer.period_ns;
        }
        const end = (pacer.sent_bytes / message_bytes + 1) * message_bytes;
        pacer.out[index] = true;
        return .{ .send = messages[pacer.sent_bytes..end] };
    }

    /// Checks the bytes that a receive wrote. The end of the stream before the last message fails.
    fn take(pacer: *Pacer, bytes: u32) void {
        const start = pacer.received_bytes;
        pacer.received_bytes += bytes;
        const got = pacer.inbox[start..pacer.received_bytes];
        if (bytes == 0 or !std.mem.eql(u8, got, messages[start..pacer.received_bytes])) pacer.failed = true;
    }
};

/// The two ends of a loopback connection: the library sends on `client` and receives on `server`.
const Pair = struct {
    client: rotor.Descriptor,
    server: rotor.Descriptor,

    fn close(pair: Pair) void {
        rotor.sync.close_now(pair.client);
        rotor.sync.close_now(pair.server);
    }
};

/// The rotor operation that does the library's `operation`, with `user_data`. Both adapters use it.
fn rotor_operation(operation: Pacer.Operation, user_data: u64, pair: Pair) rotor.Operation {
    return switch (operation) {
        .send => |bytes| rotor.Operation.send(user_data, pair.client, bytes),
        .receive => |into| rotor.Operation.receive(user_data, pair.server, into),
    };
}

/// The library's completion of its operation `id`, from the final event of the rotor operation.
fn library_completion(id: Pacer.Id, event: rotor.Event) Pacer.Completion {
    assert(event.is_final());
    const bytes = event.outcome() catch return .{ .id = id, .bytes = null };
    return .{ .id = id, .bytes = bytes };
}

/// Who owns an operation on the plain loop, in the high 32 bits of its `user_data`. The low 32 bits
/// are the owner's: the library's `Id`, or a step of the program.
const Owner = enum(u32) { program = 1, library = 2 };

fn user_data_of(owner: Owner, low: u32) u64 {
    return @as(u64, @intFromEnum(owner)) << 32 | low;
}

/// The adapter over a plain loop that the program owns and ticks. The program calls each function
/// between two ticks.
const PlainAdapter = struct {
    loop: *rotor.Loop,
    pacer: *Pacer,
    pair: Pair,

    /// Calls `turn` when the library's deadline is due, and submits what it writes.
    fn turn_when_due(adapter: *PlainAdapter) !void {
        const now_ns = adapter.loop.now_ns();
        if (adapter.deadline_ns() > now_ns) return;
        var asked: [Pacer.operations_max]Pacer.Operation = undefined;
        const count = adapter.pacer.turn(now_ns, &asked);
        for (asked[0..count]) |operation| {
            const user_data = user_data_of(.library, @intFromEnum(operation));
            const submitted = rotor_operation(operation, user_data, adapter.pair);
            if (adapter.loop.submit(&.{submitted}, &.{}) != 1) return error.NotTaken;
        }
    }

    /// The library's deadline, or `maxInt(u64)` when it has none, which `WaitLimit.at` reads as
    /// `.none`.
    fn deadline_ns(adapter: *const PlainAdapter) u64 {
        return adapter.pacer.deadline() orelse std.math.maxInt(u64);
    }

    /// The library's deadline as a wait limit.
    fn limit(adapter: *const PlainAdapter) rotor.WaitLimit {
        return .at(adapter.deadline_ns());
    }

    /// Hands the library the result of one of its operations. The program has no operation out
    /// during the run, so an event of another owner is a mistake.
    fn complete(adapter: *PlainAdapter, event: rotor.Event) !void {
        if (event.user_data >> 32 != @intFromEnum(Owner.library)) return error.UnknownOwner;
        const id: Pacer.Id = @enumFromInt(@as(u32, @truncate(event.user_data)));
        adapter.pacer.complete(library_completion(id, event), adapter.loop.now_ns());
    }
};

/// The program's reactor.
const Reactor = rotor.Reactor(rotor.Loop);

/// The adapter over the view of a reactor. A record of each operation hands the library its result.
/// A poller bounds the wait at the library's deadline. A task in the library's scheduling group
/// calls `turn` and submits what it writes. The poller schedules the task when the deadline is due,
/// and a record schedules it after a result, because the library then wants a turn at once.
const ReactorAdapter = struct {
    shared: *rotor.SharedLoop,
    group: rotor.SchedulingGroup,
    pacer: *Pacer,
    pair: Pair,
    /// One record for each `Id`. `start` writes them.
    records: [Pacer.operations_max]Record = undefined,
    poller: rotor.Poller = .init(ReactorAdapter, "poller", on_poll),
    turn_task: rotor.Task = .init(ReactorAdapter, "turn_task", on_turn),

    /// The record of one operation of the library. A record takes the whole `user_data` of its
    /// operation, so each operation that can be out at once needs a record of its own. A record
    /// finds its parent through the name of its field, so each record is a struct of its own,
    /// which knows its adapter and its id.
    const Record = struct {
        completion: rotor.Completion = .init(Record, "completion", on_event),
        adapter: *ReactorAdapter,
        id: Pacer.Id,

        fn on_event(record: *Record, event: rotor.Event) void {
            const adapter = record.adapter;
            adapter.pacer.complete(library_completion(record.id, event), adapter.shared.now_ns());
            adapter.schedule_turn();
        }
    };

    /// Writes the records and adds the poller. The adapter stays at its address until `stop`.
    fn start(adapter: *ReactorAdapter) !void {
        for (&adapter.records, 0..) |*record, index| {
            record.* = .{ .adapter = adapter, .id = @enumFromInt(index) };
        }
        try adapter.shared.add_poller(&adapter.poller);
    }

    fn stop(adapter: *ReactorAdapter) void {
        adapter.shared.remove_poller(&adapter.poller);
    }

    fn on_poll(adapter: *ReactorAdapter) rotor.WaitLimit {
        const due_ns = adapter.pacer.deadline() orelse return .none;
        if (due_ns > adapter.shared.now_ns()) return .at(due_ns);
        // A queued task keeps the tick from a wait.
        adapter.schedule_turn();
        return .none;
    }

    /// Queues the task that calls `turn`, unless it is queued. It runs in this tick, after the
    /// records.
    fn schedule_turn(adapter: *ReactorAdapter) void {
        if (adapter.shared.is_scheduled(&adapter.turn_task)) return;
        // The library's group holds no other task, so it has room.
        adapter.shared.schedule_in(adapter.group, &adapter.turn_task) catch unreachable;
    }

    fn on_turn(adapter: *ReactorAdapter) void {
        var asked: [Pacer.operations_max]Pacer.Operation = undefined;
        const count = adapter.pacer.turn(adapter.shared.now_ns(), &asked);
        for (asked[0..count]) |operation| {
            const record = &adapter.records[@intFromEnum(operation)];
            const marked = rotor.Completion.mark(&record.completion, rotor_operation(operation, 0, adapter.pair));
            // The library has one operation of each id out at most, and the loop has room for both.
            const taken = adapter.shared.submit(&.{marked}, &.{});
            assert(taken == 1);
        }
    }
};

/// The program's own deadline: `beats_max` beats, the first `beat_gap_ns` after the start. A real
/// program sends a report or flushes a log there. A beat that comes due late still runs, and the
/// program keeps how late it was. On both runs the program runs the beats after a tick, in its own
/// code.
const Beats = struct {
    next_ns: u64,
    count: u32 = 0,
    late_ns_max: u64 = 0,
    /// The reactor run adds it. The plain run writes the beats' deadline with `wait_until`.
    poller: rotor.Poller = .init(Beats, "poller", on_poll),

    fn init(now_ns: u64) Beats {
        return .{ .next_ns = now_ns + beat_gap_ns };
    }

    fn ended(beats: *const Beats) bool {
        return beats.count == beats_max;
    }

    /// The next beat's deadline, or `maxInt(u64)` after the last beat.
    fn deadline_ns(beats: *const Beats) u64 {
        return if (beats.ended()) std.math.maxInt(u64) else beats.next_ns;
    }

    /// Runs each beat that is due at `now_ns`.
    fn run(beats: *Beats, now_ns: u64) void {
        while (!beats.ended() and beats.next_ns <= now_ns) {
            beats.late_ns_max = @max(beats.late_ns_max, now_ns - beats.next_ns);
            beats.count += 1;
            beats.next_ns += beat_ns;
        }
    }

    /// The program's poller on the reactor. It only bounds the wait, and runs no beat. A poller runs
    /// before the tick waits, so a tick after the last beat would wait its whole `wait_ns` before
    /// the program could see that the run ended.
    fn on_poll(beats: *Beats) rotor.WaitLimit {
        return beats.limit();
    }

    /// The next beat's deadline as a wait limit: `.none` after the last beat.
    fn limit(beats: *const Beats) rotor.WaitLimit {
        return .at(beats.deadline_ns());
    }
};

/// What one run reached: the messages sent and received, the beats, the latest deadline, and how
/// long the run took on the loop's clock.
const Report = struct { sent: u32, received: u32, beats: u32, late_ns_max: u64, run_ns: u64 };

fn report_of(pacer: *const Pacer, beats: *const Beats, run_ns: u64) Report {
    return .{
        .sent = pacer.sent_bytes / message_bytes,
        .received = pacer.received_bytes / message_bytes,
        .beats = beats.count,
        .late_ns_max = @max(pacer.late_ns_max, beats.late_ns_max),
        .run_ns = run_ns,
    };
}

pub fn main(init: std.process.Init) !void {
    try print_report(init.io, "plain", try run_plain());
    try print_report(init.io, "reactor", try run_reactor());
}

/// The library on a plain loop. The loop has one stored limit, and only the program writes it.
fn run_plain() !Report {
    const options: rotor.Loop.Options = .{ .operations = loop_operations };
    var memory: [rotor.Loop.memory_bytes(&options)]u8 align(rotor.memory_alignment) = undefined;
    var loop: rotor.Loop = undefined;
    try loop.init(&memory, &options);
    defer loop.deinit();
    var address: rotor.Address = undefined;
    const pair = try connected_pair(rotor.Loop, &loop, &address);
    defer pair.close();

    const start_ns = loop.now_ns();
    var pacer: Pacer = .init(start_ns, period_ns);
    var adapter: PlainAdapter = .{ .loop = &loop, .pacer = &pacer, .pair = pair };
    var beats: Beats = .init(start_ns);
    var events: [loop_operations]rotor.Event = undefined;
    for (0..ticks_max) |_| {
        try adapter.turn_when_due();
        if (pacer.failed) return error.LibraryFailed;
        if (pacer.ended() and beats.ended()) return report_of(&pacer, &beats, loop.now_ns() - start_ns);
        loop.wait_until(adapter.limit().least(beats.limit()));
        const count = try loop.tick(&events, rotor.constants.wait_ns_max);
        for (events[0..count]) |event| try adapter.complete(event);
        beats.run(loop.now_ns());
    }
    return error.Stuck;
}

/// The library on a reactor, through the view. Only the reactor writes the stored limit, for its
/// pollers. So the program bounds the wait for its own deadline with a poller too.
fn run_reactor() !Report {
    const options: Reactor.Options = .{ .loop = .{ .operations = loop_operations } };
    var memory: [Reactor.memory_bytes(&options)]u8 align(rotor.memory_alignment) = undefined;
    var reactor: Reactor = undefined;
    try reactor.init(&memory, &options);
    defer reactor.deinit();
    var address: rotor.Address = undefined;
    const pair = try connected_pair(Reactor, &reactor, &address);
    defer pair.close();

    const group = try reactor.reserve_scheduling_group(library_shares);
    const start_ns = reactor.now_ns();
    var pacer: Pacer = .init(start_ns, period_ns);
    var adapter: ReactorAdapter = .{ .shared = reactor.shared(), .group = group, .pacer = &pacer, .pair = pair };
    try adapter.start();
    defer adapter.stop();
    var beats: Beats = .init(start_ns);
    try reactor.add_poller(&beats.poller);
    defer reactor.remove_poller(&beats.poller);
    var events: [loop_operations]rotor.Event = undefined;
    for (0..ticks_max) |_| {
        if (pacer.failed) return error.LibraryFailed;
        const ended = pacer.ended() and beats.ended() and reactor.tasks_queued() == 0;
        if (ended) return report_of(&pacer, &beats, reactor.now_ns() - start_ns);
        // The reactor calls the records, the pollers and the task, so no event comes back here.
        if (try reactor.tick(&events, rotor.constants.wait_ns_max) != 0) return error.EventNotTaken;
        beats.run(reactor.now_ns());
    }
    return error.Stuck;
}

/// A connection on 127.0.0.1 through `host`, a plain loop or a reactor: a listener on a free port,
/// then a connect to it and the accept, as two operations of `host`. Neither names a record, so a
/// reactor also hands both events to the program. `address` outlives the connect, which reads it.
fn connected_pair(comptime Host: type, host: *Host, address: *rotor.Address) !Pair {
    const any = rotor.Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const listener = try rotor.sync.listen(&any, .{ .backlog = 1, .reuse_port = false });
    defer rotor.sync.close_now(listener);
    address.* = try rotor.sync.local_address(listener);
    const client = try rotor.sync.open_socket(.ipv4);
    // The messages are small. With Nagle's algorithm, a message can wait for the acknowledgment of
    // the message before it.
    try rotor.sync.set_no_delay(client, true);
    const accept = rotor.Operation.accept(user_data_of(.program, 0), listener);
    const connect = rotor.Operation.connect(user_data_of(.program, 1), client, address);
    if (host.submit(&.{ accept, connect }, &.{}) != 2) return error.NotTaken;
    var server: ?rotor.Descriptor = null;
    var connected = false;
    var events: [loop_operations]rotor.Event = undefined;
    for (0..ticks_max) |_| {
        if (server != null and connected) return .{ .client = client, .server = server.? };
        const count = try host.tick(&events, rotor.constants.ns_per_s);
        for (events[0..count]) |event| {
            const result = try event.outcome();
            if (event.user_data == accept.user_data) server = @intCast(result) else connected = true;
        }
    }
    return error.Stuck;
}

/// Writes the line of one run to stdout, where the checker reads it.
fn print_report(io: std.Io, adapter: []const u8, report: Report) !void {
    var line: [line_bytes_max]u8 = undefined;
    const format = "two_adapters {s} backend={t} sent={d} received={d} beats={d} late_us={d} run_us={d}\n";
    const text = try std.fmt.bufPrint(&line, format, .{
        adapter,
        rotor.backend(),
        report.sent,
        report.received,
        report.beats,
        report.late_ns_max / rotor.constants.ns_per_us,
        report.run_ns / rotor.constants.ns_per_us,
    });
    try std.Io.File.stdout().writeStreamingAll(io, text);
}
