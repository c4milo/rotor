//! A post storm into a loop that runs callbacks (decisions 4, 26 and 27). Several threads post to
//! one target loop at once: a peer loop through `Loop.post` and through post operations, and
//! remotes through `Remote.post`. The target meanwhile runs pollers, timers that name a record,
//! and tasks that schedule themselves again. The race gate runs this file under ThreadSanitizer.
//! The threads that post are in `conformance_storm_senders.zig`.
//!
//! The oracle:
//!
//! - each message from one sender arrives exactly once, and in the order of its posts;
//! - for each sender, the messages received are the posts made less the `mailbox_full` refusals;
//! - once the pollers are removed, no task is queued and every sender finished, a tick with a
//!   wait of 2 s returns soon after a post.
//!
//! Thread timing is not seeded. Every choice a thread draws comes from `seed`, and a failure
//! prints it.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const storm_senders = @import("conformance_storm_senders.zig");

const ReactorHarness = conformance.ReactorHarness;
const Event = core.Event;
const Operation = core.Operation;
const Random = core.random.Random;
const LoopId = core.LoopId;
const Shared = storm_senders.Shared;
const Sender = storm_senders.Sender;
const Peer = storm_senders.Peer;

const ms = core.constants.ns_per_ms;

/// The seed of every choice in the scenario. A failure prints it.
const seed: u64 = 0x7374_6F72_6D5F_3237;

const target_id = storm_senders.target_id;
const peer_id = storm_senders.peer_id;
const first_remote_id = storm_senders.first_remote_id;
const remotes = storm_senders.remotes;
const ids = storm_senders.ids;
const messages_per_sender = storm_senders.messages_per_sender;
const senders = storm_senders.senders;
const messages_total = messages_per_sender * senders;
const tag_wake = storm_senders.tag_wake;

/// The libraries on the target loop. Each one adds a poller, keeps a timer with a record in
/// flight, and queues a task.
const libraries = 3;

/// The longest delay of a library's timer.
const timer_delay_max_ns = 2 * ms;
/// The most runs in which a library's task schedules itself again after one poll queues it.
const task_again_max = 8;
/// The wait of a storm tick that may block. A poller that answers true or a queued task cuts it.
const storm_wait_ns = ms;
/// Ticks the target makes with all senders finished and no message received, before it stops.
const idle_rounds_max = 200;
/// Ticks of the storm, at most: a bound for a sender that stops without a failure.
const storm_rounds_max = 1_000_000;
/// The wait of each tick of the quiet phase, which makes at most `conformance.collect_rounds_max`.
const quiet_wait_ns = 10 * ms;
/// The wait of the last tick: a tick that slept all of it fails the bound by far.
const long_wait_ns = 2 * core.constants.ns_per_s;

/// Room for the messages of every sender's ring in one tick.
const events_len = senders * core.constants.messages_per_drain;

var registry_memory: [backend.Registry.memory_bytes(ids)]u8 align(core.layout.memory_alignment) =
    undefined;

/// One library on the target loop. Its poller answers true at seeded ticks and queues the task at
/// others. The task schedules itself again a seeded count of times. Its timer names its record,
/// and the record submits the next timer from inside the tick.
const Library = struct {
    poller: core.Poller = .init(Library, "poller", polled),
    task: core.Task = .init(Library, "task", ran),
    completion: core.Completion = .init(Library, "completion", fired),
    reactor: *conformance.Reactor,
    random: Random,
    /// Runs left in which the task schedules itself again.
    again: u32 = 0,
    /// False once the storm is over: the task and the timer stop and the poller does nothing.
    running: bool = true,
    polls: u32 = 0,
    runs: u32 = 0,
    fires: u32 = 0,
    /// Set when a call inside the tick failed, which a callback cannot return.
    failed: bool = false,

    fn polled(library: *Library) core.WaitLimit {
        library.polls += 1;
        if (!library.running) return .none;
        if (!library.reactor.is_scheduled(&library.task) and library.random.chance(1, 4)) {
            library.again = @intCast(library.random.below(task_again_max + 1));
            library.reactor.schedule(&library.task) catch {
                library.failed = true;
            };
        }
        return if (library.random.chance(1, 3)) .now else .none;
    }

    fn ran(library: *Library) void {
        library.runs += 1;
        if (!library.running or library.again == 0) return;
        library.again -= 1;
        library.reactor.schedule(&library.task) catch {
            library.failed = true;
        };
    }

    fn fired(library: *Library, event: Event) void {
        library.fires += 1;
        if (!event.flags.dispatched) library.failed = true;
        if (library.running) library.start_timer();
    }

    fn start_timer(library: *Library) void {
        const delay_ns = library.random.below(timer_delay_max_ns + 1);
        const timer = Operation.timer(0, delay_ns, 0).completion(&library.completion);
        if (library.reactor.submit(&.{timer}, &.{}) != 1) library.failed = true;
    }
};

/// The target loop on the test's thread, its libraries, and what it received from each sender.
const Target = struct {
    harness: *ReactorHarness,
    libraries: [libraries]Library,
    random: Random,
    /// The payload of the next message from each sender id, which is also the count received.
    next: [ids]u64 = @splat(0),
    received: u32 = 0,
    pollers_added: bool = false,

    /// Checks one event of the storm: a message from a sender, in order.
    fn accept(target: *Target, event: Event) !void {
        try testing.expect(event.flags.message);
        try testing.expect(event.result >= peer_id and event.result < ids);
        const sender: usize = @intCast(event.result);
        try testing.expectEqual(target.next[sender], event.user_data);
        target.next[sender] += 1;
        target.received += 1;
    }

    fn start(target: *Target) !void {
        for (&target.libraries) |*library| {
            try target.harness.reactor.add_poller(&library.poller);
            library.start_timer();
        }
        target.pollers_added = true;
    }

    /// Ticks until every storm message arrived, or until every sender finished and the messages
    /// stopped coming.
    fn storm(target: *Target, shared: *Shared) !void {
        var events: [events_len]Event = undefined;
        var idle_rounds: u32 = 0;
        var round: u32 = 0;
        while (target.received < messages_total and round < storm_rounds_max) : (round += 1) {
            const wait_ns: u64 = if (target.random.chance(1, 2)) 0 else storm_wait_ns;
            const count = try target.harness.reactor.tick(&events, wait_ns);
            for (events[0..count]) |event| try target.accept(event);
            try target.expect_no_failure();
            const all_finished = shared.finished.load(.acquire) == senders;
            idle_rounds = if (count == 0 and all_finished) idle_rounds + 1 else 0;
            if (idle_rounds == idle_rounds_max) break;
        }
        try testing.expectEqual(@as(u32, messages_total), target.received);
    }

    /// Stops the libraries and removes the pollers, then ticks until nothing is queued or in
    /// flight. No message may arrive now: each storm message arrived once already.
    fn quiet(target: *Target) !void {
        const reactor = &target.harness.reactor;
        for (&target.libraries) |*library| library.running = false;
        target.remove_pollers();
        var events: [events_len]Event = undefined;
        var round: u32 = 0;
        const rounds_max = conformance.collect_rounds_max;
        while (reactor.in_flight() + reactor.tasks_queued() > 0 and round < rounds_max) : (round += 1) {
            try testing.expectEqual(@as(u32, 0), try reactor.tick(&events, quiet_wait_ns));
        }
        try testing.expectEqual(@as(u32, 0), reactor.in_flight());
        try testing.expectEqual(@as(u32, 0), reactor.tasks_queued());
        try target.expect_no_failure();
    }

    /// Waits until every sender finished, then takes a wake that is still set. A sender can wake
    /// the target after the target drained the message the wake announces. Such a wake stays set,
    /// and the next tick that waits ends at once with no event: the wasted wake of decision 12,
    /// point 6. A sender finishes after its last wake, so one tick that waits after that takes it.
    fn settle(target: *Target, shared: *Shared) !void {
        const reactor = &target.harness.reactor;
        var events: [events_len]Event = undefined;
        var round: u32 = 0;
        const rounds_max = conformance.collect_rounds_max;
        while (shared.finished.load(.acquire) < senders and round < rounds_max) : (round += 1) {
            try testing.expectEqual(@as(u32, 0), try reactor.tick(&events, quiet_wait_ns));
        }
        try testing.expectEqual(@as(u32, senders), shared.finished.load(.acquire));
        try testing.expectEqual(@as(u32, 0), try reactor.tick(&events, quiet_wait_ns));
    }

    /// One tick with a wait of 2 s, which the peer's post must end early. Returns its length.
    fn wake(target: *Target, shared: *Shared) !u64 {
        var events: [events_len]Event = undefined;
        shared.quiet.store(true, .release);
        const before = backend.testing.monotonic_ns();
        const count = try target.harness.reactor.tick(&events, long_wait_ns);
        const waited_ns = backend.testing.monotonic_ns() - before;
        try testing.expectEqual(@as(u32, 1), count);
        try testing.expect(events[0].flags.message);
        try testing.expectEqual(@as(i32, tag_wake), events[0].result);
        return waited_ns;
    }

    fn remove_pollers(target: *Target) void {
        if (!target.pollers_added) return;
        for (&target.libraries) |*library| target.harness.reactor.remove_poller(&library.poller);
        target.pollers_added = false;
    }

    /// Leaves the loop as `deinit` requires after a failure: no poller, no task, nothing in flight.
    fn abandon(target: *Target) void {
        for (&target.libraries) |*library| library.running = false;
        target.remove_pollers();
        _ = target.harness.reactor.discard_tasks();
        target.harness.reactor.cancel_all();
        var scratch: [events_len]Event = undefined;
        target.harness.reactor.drain(&scratch) catch {};
    }

    fn expect_no_failure(target: *const Target) !void {
        for (&target.libraries) |*library| try testing.expect(!library.failed);
    }
};

/// Every thread of the scenario, and the seed each one draws from.
const Storm = struct {
    shared: Shared,
    peer: Peer,
    senders: [remotes]Sender,
    threads: [senders]?std.Thread = @splat(null),

    fn init(storm: *Storm, registry: *backend.Registry, random: *Random) void {
        storm.* = .{
            .shared = .{ .registry = registry },
            .peer = undefined,
            .senders = undefined,
        };
        storm.peer = .{ .shared = &storm.shared, .random = .init(random.next()) };
        for (&storm.senders, 0..) |*sender, index| {
            const id: LoopId = @intCast(first_remote_id + index);
            sender.* = .{ .shared = &storm.shared, .id = id, .random = .init(random.next()) };
        }
    }

    fn spawn(storm: *Storm) !void {
        storm.threads[0] = try std.Thread.spawn(.{}, Peer.run, .{&storm.peer});
        for (&storm.senders, 1..) |*sender, index| {
            storm.threads[index] = try std.Thread.spawn(.{}, Sender.run, .{sender});
        }
    }

    /// Stops every sender that still runs, and waits for each thread.
    fn join(storm: *Storm) void {
        storm.shared.stop.store(true, .release);
        for (&storm.threads) |*thread| {
            if (thread.*) |started| started.join();
            thread.* = null;
        }
    }

    /// Per sender: no failure, and the messages received are the posts less the refusals.
    fn expect_accounts(storm: *const Storm, target: *const Target) !void {
        try testing.expectEqual(@as(?anyerror, null), storm.peer.failure);
        try testing.expectEqual(storm.peer.attempts - storm.peer.refusals, target.next[peer_id]);
        for (&storm.senders) |*sender| {
            try testing.expectEqual(@as(?anyerror, null), sender.failure);
            try testing.expectEqual(sender.attempts - sender.refusals, target.next[sender.id]);
        }
        for (target.next[peer_id..]) |received| {
            try testing.expectEqual(@as(u64, messages_per_sender), received);
        }
    }
};

/// The scenario's phases, on the target's thread. Returns the length of the last tick.
fn run_target(target: *Target, storm: *Storm) !u64 {
    errdefer target.abandon();
    try target.start();
    try target.storm(&storm.shared);
    try target.quiet();
    try target.settle(&storm.shared);
    return target.wake(&storm.shared);
}

fn scenario() !void {
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, ids);
    defer life.end();
    var harness: ReactorHarness = undefined;
    try harness.init(target_id, &registry);
    defer harness.deinit();

    var random: Random = .init(seed);
    var target: Target = .{
        .harness = &harness,
        .libraries = undefined,
        .random = .init(random.next()),
    };
    for (&target.libraries) |*library| {
        library.* = .{ .reactor = &harness.reactor, .random = .init(random.next()) };
    }
    var storm: Storm = undefined;
    storm.init(&registry, &random);
    defer storm.join();
    try storm.spawn();

    const waited_ns = try run_target(&target, &storm);
    storm.join();
    try storm.expect_accounts(&target);
    // The post ended the wait: the tick did not sleep its 2 s, and it returned after the post.
    try testing.expect(storm.peer.posted_at_ns > 0);
    try testing.expect(waited_ns < long_wait_ns / 2);
    // Each library's poller, record and task did run during the storm.
    for (&target.libraries) |*library| {
        try testing.expect(library.polls > 0 and library.fires > 0 and library.runs > 0);
    }
}

test "a storm of posts from loops and remotes reaches a loop of pollers, records and tasks" {
    if (conformance.unsupported()) return error.SkipZigTest;
    scenario() catch |err| {
        std.debug.print("the post storm failed: {t}; seed 0x{x}\n", .{ err, seed });
        return err;
    };
}
