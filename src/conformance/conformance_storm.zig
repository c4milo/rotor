//! A post storm into a loop that runs callbacks (decisions 4, 26 and 27). Several threads post to
//! one target loop at once: a peer loop through `Loop.post` and through post operations, and
//! remotes through `Remote.post`. The target meanwhile runs pollers, timers that name a record,
//! and tasks that schedule themselves again. The race gate runs this file under ThreadSanitizer.
//!
//! The oracle:
//!
//! - each message from one sender arrives exactly once, and in the order of its posts;
//! - for each sender, the messages received are the posts made less the `mailbox_full` refusals;
//! - once the pollers are removed and no task is queued, a tick with a wait of 2 s returns soon
//!   after a post.
//!
//! Thread timing is not seeded. Every choice a thread draws comes from `seed`, and a failure
//! prints it.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Harness = conformance.Harness;
const Event = core.Event;
const Operation = core.Operation;
const Random = core.random.Random;
const LoopId = core.LoopId;

const ms = core.constants.ns_per_ms;

/// The seed of every choice in the scenario. A failure prints it.
const seed: u64 = 0x7374_6F72_6D5F_3237;

const target_id: LoopId = 0;
const peer_id: LoopId = 1;
const first_remote_id: LoopId = 2;
/// The threads with no loop that post to the target.
const remotes = 3;
const ids: u16 = first_remote_id + remotes;

/// The posts of each sender that the target accepts. A sender makes a refused post again, so it
/// posts more times than this when the target falls behind.
const messages_per_sender = 2000;
const senders = remotes + 1;
const messages_total = messages_per_sender * senders;

/// The tag of the peer's last message, which wakes the target once the storm is over. It is
/// above every sender id, so `accept` never takes it for a storm message.
const tag_wake = ids;

/// Posts one sender makes, refusals included, before it gives up on a target that never drains.
const attempts_max: u64 = 1 << 22;

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

/// Pauses of a millisecond the peer makes while it waits for the quiet phase and for the target
/// to sleep. Generous, because the race gate runs the suite under ThreadSanitizer.
const peer_pauses_max = 20_000;
const peer_pause_ns = ms;

/// Room for the messages of every sender's ring in one tick.
const events_len = senders * core.constants.messages_per_drain;

var registry_memory: [backend.Registry.memory_bytes(ids)]u8 align(core.layout.memory_alignment) =
    undefined;

/// What the threads share: stop on a failure of the target, and the phases of the scenario.
const Shared = struct {
    registry: *backend.Registry,
    /// Set before the target's thread joins the others, so that no sender waits for a loop that
    /// stopped.
    stop: std.atomic.Value(bool) = .init(false),
    /// Senders that finished their storm messages, with or without a failure.
    finished: std.atomic.Value(u32) = .init(0),
    /// Set by the target once its pollers are removed and nothing is queued or in flight.
    quiet: std.atomic.Value(bool) = .init(false),
};

/// A thread with no loop: posts `messages_per_sender` messages through a `Remote`.
const Sender = struct {
    shared: *Shared,
    id: LoopId,
    random: Random,
    attempts: u64 = 0,
    refusals: u64 = 0,
    failure: ?anyerror = null,

    fn run(sender: *Sender) void {
        sender.send() catch |err| {
            sender.failure = err;
        };
        _ = sender.shared.finished.fetchAdd(1, .release);
    }

    fn send(sender: *Sender) !void {
        var remote: backend.Remote = undefined;
        try remote.init(sender.shared.registry, sender.id);
        defer remote.deinit();
        for (0..messages_per_sender) |sequence| {
            try sender.deliver(&remote, .{ .payload = sequence, .tag = sender.id });
            if (sender.random.chance(1, 16)) std.Thread.yield() catch {};
        }
    }

    /// Posts `message` until the target accepts it, and counts each refusal.
    fn deliver(sender: *Sender, remote: *backend.Remote, message: core.Message) !void {
        while (sender.attempts < attempts_max) {
            if (sender.shared.stop.load(.acquire)) return error.Stopped;
            sender.attempts += 1;
            remote.post(target_id, message) catch |err| switch (err) {
                error.MailboxFull => {
                    sender.refusals += 1;
                    std.Thread.yield() catch {};
                    continue;
                },
                else => return err,
            };
            return;
        }
        return error.AttemptsExhausted;
    }
};

/// The peer loop's thread: posts its storm messages with `Loop.post` and with post operations, at
/// seeded choice, then waits for the quiet phase and posts the message that wakes the target.
const Peer = struct {
    shared: *Shared,
    random: Random,
    attempts: u64 = 0,
    refusals: u64 = 0,
    /// The clock when the peer posted `tag_wake`, or 0 when it did not.
    posted_at_ns: u64 = 0,
    counted: bool = false,
    failure: ?anyerror = null,

    fn run(peer: *Peer) void {
        peer.serve() catch |err| {
            peer.failure = err;
        };
        peer.finish();
    }

    fn finish(peer: *Peer) void {
        if (peer.counted) return;
        peer.counted = true;
        _ = peer.shared.finished.fetchAdd(1, .release);
    }

    fn serve(peer: *Peer) !void {
        var harness: Harness = undefined;
        try harness.init(peer_id, peer.shared.registry);
        defer harness.deinit();
        for (0..messages_per_sender) |sequence| {
            try peer.deliver(&harness, .{ .payload = sequence, .tag = peer_id });
        }
        peer.finish();
        try peer.wake(&harness);
    }

    fn deliver(peer: *Peer, harness: *Harness, message: core.Message) !void {
        while (peer.attempts < attempts_max) {
            if (peer.shared.stop.load(.acquire)) return error.Stopped;
            peer.attempts += 1;
            const refused = if (peer.random.chance(1, 4))
                try post_operation(harness, message)
            else
                try post_call(harness, message);
            if (!refused) return;
            peer.refusals += 1;
            std.Thread.yield() catch {};
        }
        return error.AttemptsExhausted;
    }

    /// Posts through `Loop.post`, and returns true when the target's ring was full.
    fn post_call(harness: *Harness, message: core.Message) !bool {
        harness.loop.post(target_id, message) catch |err| switch (err) {
            error.MailboxFull => return true,
            else => return err,
        };
        return false;
    }

    /// Posts through a post operation, waits for its event, and returns true on `mailbox_full`.
    fn post_operation(harness: *Harness, message: core.Message) !bool {
        try harness.submit(&.{Operation.post(0, target_id, message)}, &.{});
        var events: [1]Event = undefined;
        try harness.collect(&events);
        _ = events[0].outcome() catch |err| switch (err) {
            error.MailboxFull => return true,
            else => return err,
        };
        return false;
    }

    /// Waits for the quiet phase and for the target to sleep, then posts `tag_wake`.
    fn wake(peer: *Peer, harness: *Harness) !void {
        const shared = peer.shared;
        var pauses: u32 = 0;
        while (!shared.quiet.load(.acquire)) : (pauses += 1) {
            if (shared.stop.load(.acquire)) return error.Stopped;
            if (pauses == peer_pauses_max) return error.NeverQuiet;
            try harness.pause(peer_pause_ns);
        }
        pauses = 0;
        while (!shared.registry.must_wake(target_id) and pauses < peer_pauses_max) : (pauses += 1) {
            try harness.pause(peer_pause_ns);
        }
        // A pause after the target sleeps, so the post comes inside the wait and not before it.
        try harness.pause(peer_pause_ns);
        peer.posted_at_ns = backend.testing.monotonic_ns();
        try harness.loop.post(target_id, .{ .payload = 0, .tag = tag_wake });
        // On io_uring the wake of a `Loop.post` leaves with the poster's next tick.
        var events: [1]Event = undefined;
        _ = try harness.loop.tick(&events, 0);
    }
};

/// One library on the target loop. Its poller answers true at seeded ticks and queues the task at
/// others. The task schedules itself again a seeded count of times. Its timer names its record,
/// and the record submits the next timer from inside the tick.
const Library = struct {
    poller: core.Poller = .init(Library, "poller", polled),
    task: core.Task = .init(Library, "task", ran),
    completion: core.Completion = .init(Library, "completion", fired),
    loop: *conformance.Loop,
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

    fn polled(library: *Library) bool {
        library.polls += 1;
        if (!library.running) return false;
        if (!library.loop.is_scheduled(&library.task) and library.random.chance(1, 4)) {
            library.again = @intCast(library.random.below(task_again_max + 1));
            library.loop.schedule(&library.task) catch {
                library.failed = true;
            };
        }
        return library.random.chance(1, 3);
    }

    fn ran(library: *Library) void {
        library.runs += 1;
        if (!library.running or library.again == 0) return;
        library.again -= 1;
        library.loop.schedule(&library.task) catch {
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
        if (library.loop.submit(&.{timer}, &.{}) != 1) library.failed = true;
    }
};

/// The target loop on the test's thread, its libraries, and what it received from each sender.
const Target = struct {
    harness: *Harness,
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
            try target.harness.loop.add_poller(&library.poller);
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
            const count = try target.harness.loop.tick(&events, wait_ns);
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
        const loop = &target.harness.loop;
        for (&target.libraries) |*library| library.running = false;
        target.remove_pollers();
        var events: [events_len]Event = undefined;
        var round: u32 = 0;
        const rounds_max = conformance.collect_rounds_max;
        while (loop.in_flight() + loop.tasks_queued() > 0 and round < rounds_max) : (round += 1) {
            try testing.expectEqual(@as(u32, 0), try loop.tick(&events, quiet_wait_ns));
        }
        try testing.expectEqual(@as(u32, 0), loop.in_flight());
        try testing.expectEqual(@as(u32, 0), loop.tasks_queued());
        try target.expect_no_failure();
    }

    /// One tick with a wait of 2 s, which the peer's post must end early. Returns its length.
    fn wake(target: *Target, shared: *Shared) !u64 {
        var events: [events_len]Event = undefined;
        shared.quiet.store(true, .release);
        const before = backend.testing.monotonic_ns();
        const count = try target.harness.loop.tick(&events, long_wait_ns);
        const waited_ns = backend.testing.monotonic_ns() - before;
        try testing.expectEqual(@as(u32, 1), count);
        try testing.expect(events[0].flags.message);
        try testing.expectEqual(@as(i32, tag_wake), events[0].result);
        return waited_ns;
    }

    fn remove_pollers(target: *Target) void {
        if (!target.pollers_added) return;
        for (&target.libraries) |*library| target.harness.loop.remove_poller(&library.poller);
        target.pollers_added = false;
    }

    /// Leaves the loop as `deinit` requires after a failure: no poller, no task, nothing in flight.
    fn abandon(target: *Target) void {
        for (&target.libraries) |*library| library.running = false;
        target.remove_pollers();
        _ = target.harness.loop.discard_tasks();
        target.harness.loop.cancel_all();
        var scratch: [events_len]Event = undefined;
        target.harness.loop.drain(&scratch) catch {};
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
    return target.wake(&storm.shared);
}

fn scenario() !void {
    var registry: backend.Registry = undefined;
    const life = try conformance.RegistryLife.start(&registry, &registry_memory, ids);
    defer life.end();
    var harness: Harness = undefined;
    try harness.init(target_id, &registry);
    defer harness.deinit();

    var random: Random = .init(seed);
    var target: Target = .{
        .harness = &harness,
        .libraries = undefined,
        .random = .init(random.next()),
    };
    for (&target.libraries) |*library| {
        library.* = .{ .loop = &harness.loop, .random = .init(random.next()) };
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
