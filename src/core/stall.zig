//! The stall count and the heartbeat of decision 28. A turn is the span from one clock stamp of a
//! tick to the next tick's first stamp. It holds the callbacks of the last tick, the program's own
//! code between ticks, and the pollers of the next tick. A kernel wait is never in a turn, because
//! the stamp after a wait starts a new turn.
//!
//! The loop counts each turn at or above its threshold as a stall, in `Statistics` (decision 9,
//! rule 7). A callback that never returns never ends its turn, so the loop also writes a heartbeat
//! on a cache line of its own. A thread that the program starts reads it through a `Watch`, and
//! names the callback that holds the loop.
//!
//! Nothing here reads a clock: the backend hands each stamp in (non-negotiable 2). The loop writes
//! the count and the heartbeat, and never reads them for a choice of what runs.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const statistics_module = @import("statistics.zig");

const Poller = @import("dispatch/dispatch.zig").Poller;
const Statistics = statistics_module.Statistics;
const Stall = statistics_module.Stall;

/// What `beat_ns` holds while the loop is in a kernel wait, and before its first tick. A span
/// from it saturates at 0, so a wait is never a stall and needs no branch of its own.
pub const asleep: u64 = std.math.maxInt(u64);

/// The name of the callback at `field` of `Parent`, for example `colibri.client.Client.receive`.
/// `Completion.init`, `Poller.init` and `Task.init` name their static `Call` with it, so a stall
/// and a watch can say which callback held the loop, with no new parameter at a call site.
pub fn name_of(comptime Parent: type, comptime field: []const u8) [:0]const u8 {
    return @typeName(Parent) ++ "." ++ field;
}

/// A callback's name, as its static `Call` holds it. The heartbeat holds the address of the name in
/// the `Call`, which the loop already has in a register: one store for each callback, and no load.
pub const Name = [:0]const u8;

/// A threshold that no span reaches: what `stall_turn_ns = null` stores.
const never: u64 = std.math.maxInt(u64);

/// What the loop's thread writes so that another thread can see that it is stuck (decision 28).
/// Another thread reads `beat_ns`, `running` and `watchers`. The loop's own fields share the line.
/// Each loop carves one from its caller's memory (`Layout.take`), and `Tables` holds a pointer to
/// it, so `Tables` and the loop keep their own alignment. Size 128 B, alignment 128.
pub const Heartbeat = struct {
    /// The stamp that started the open turn, or `asleep`. The loop stores it with release order.
    beat_ns: std.atomic.Value(u64) align(constants.heartbeat_alignment),
    /// A turn at or above this is a stall, or `never`. Only the loop's thread reads it. It follows
    /// `beat_ns`, so the turn check loads both with one instruction on arm64 (`ldp`).
    turn_ns: u64,
    /// The name of the callback that runs now, in its static `Call`, or null. The loop stores it
    /// with release order.
    running: std.atomic.Value(?*const Name),
    /// The watches that read this line. The loop's `deinit` halts while it is above 0.
    watchers: std.atomic.Value(u32),
    /// The callbacks that the loop called in the open turn. Only the loop's thread reads it.
    turn: Turn,
    /// The name of the last record or task of the open turn. Only the loop's thread reads it. A
    /// stall of one poller takes the poller's name from the table of pollers instead, so `begin`
    /// stores no name.
    turn_name: ?*const Name,

    /// The callbacks of the open turn, in two counts that one instruction zeroes at each first
    /// stamp of a tick (`stp` on arm64). A turn holds the records and the tasks of one tick's
    /// `end`, then the pollers of the next tick's `begin`. Each count has one writer in each turn,
    /// so each writer stores its count and adds nothing: `end` writes `ended` after the stamp that
    /// zeroed it, and `begin` writes `polled` before the stamp that reads it. Each count is a word,
    /// so `end` stores the count it computes in a word with no conversion. Size 16 B, alignment 8.
    pub const Turn = extern struct {
        /// The records and the tasks of the last `end`.
        ended: u64,
        /// The pollers of the last `begin`.
        polled: u64,

        pub const zero: Turn = .{ .ended = 0, .polled = 0 };

        /// The callbacks of the turn. A turn holds one `end` and one `begin`, so it fits a `u32`.
        pub fn callbacks(turn: Turn) u32 {
            return @intCast(turn.ended + turn.polled);
        }
    };

    /// A heartbeat that counts a turn of `stall_turn_ns` or more, or none when it is null.
    pub fn init(stall_turn_ns: ?u64) Heartbeat {
        if (stall_turn_ns) |turn_ns| assert(turn_ns >= 1);
        return .{
            .beat_ns = .init(asleep),
            .running = .init(null),
            .watchers = .init(0),
            .turn = .zero,
            .turn_ns = stall_turn_ns orelse never,
            .turn_name = null,
        };
    }

    /// The first stamp of a tick (R1). It ends the open turn, counts it when it is a stall, and
    /// starts the next one. Each tick pays one subtraction and one compare for the turn check
    /// (decision 28, "What it costs"). The subtraction wraps, so it needs no branch for `asleep`
    /// or for a null threshold: `check_turn` handles both, and only a span at or above the
    /// threshold reaches it. A watch needs the stamp with or without a threshold, so the stores
    /// stay here. Only the loop's thread writes `beat_ns`, so it reads its own stamp with a plain
    /// load. The compiler then loads the stamp and `turn_ns` with one instruction. `pollers` is
    /// the loop's table of pollers, which only a stall of one poller reads.
    pub fn note_clock(
        heartbeat: *Heartbeat,
        statistics: *Statistics,
        pollers: *const [constants.pollers_max]*Poller,
        now_ns: u64,
    ) void {
        if (now_ns -% heartbeat.beat_ns.raw >= heartbeat.turn_ns) {
            heartbeat.check_turn(statistics, pollers, now_ns);
        }
        heartbeat.beat_ns.store(now_ns, .release);
        heartbeat.turn = .zero;
    }

    /// The turn check: counts the open turn when it is a stall. A null threshold counts no turn
    /// (decision 28, ruling B). A turn after a wait, or before the first tick, spans 0 ns, because
    /// `beat_ns` holds `asleep` and this subtraction saturates. The loop reaches it only for a
    /// stall, for its first tick, for a stamp before the last one, and for a span of
    /// `maxInt(u64)` under a null threshold.
    fn check_turn(
        heartbeat: *const Heartbeat,
        statistics: *Statistics,
        pollers: *const [constants.pollers_max]*Poller,
        now_ns: u64,
    ) void {
        if (heartbeat.turn_ns == never) return;
        const span_ns = now_ns -| heartbeat.beat_ns.load(.monotonic);
        if (span_ns < heartbeat.turn_ns) return;
        heartbeat.note_stall(statistics, heartbeat.name_of_one(pollers), now_ns, span_ns);
    }

    /// The name of the one callback of the open turn, or null when it called none or several. A
    /// turn of one poller called the first poller of the table: `begin` called the pollers of the
    /// table, and nothing adds or removes one between `begin` and the stamp that reads this.
    fn name_of_one(
        heartbeat: *const Heartbeat,
        pollers: *const [constants.pollers_max]*Poller,
    ) ?*const Name {
        if (heartbeat.turn.callbacks() != 1) return null;
        if (heartbeat.turn.polled == 1) return &pollers[0].call.name;
        return heartbeat.turn_name;
    }

    /// The loop is about to block in a kernel wait. No turn is open until `note_woken`.
    pub fn note_asleep(heartbeat: *Heartbeat) void {
        heartbeat.beat_ns.store(asleep, .release);
    }

    /// The stamp after a wait that blocked (R2): it starts a turn, and counts none. The counts of
    /// the turn are 0 already: the tick's first stamp zeroed them, and no callback runs between
    /// that stamp and this one.
    pub fn note_woken(heartbeat: *Heartbeat, now_ns: u64) void {
        assert(now_ns != asleep);
        heartbeat.beat_ns.store(now_ns, .release);
    }

    /// The loop calls the callback `name` next. `name` is static data: the name in a `Call`.
    pub fn enter(heartbeat: *Heartbeat, name: *const Name) void {
        heartbeat.running.store(name, .release);
    }

    /// `end` called `called` records, at least one, and runs none now. The turn keeps the count
    /// and the last name, so a stall of one callback can name it. The records come first in an
    /// `end`, after the stamp that zeroed the count, so this stores the count. A batch that called
    /// no record does not call it: the count is 0 since the stamp, and `running` is null already.
    pub fn leave(heartbeat: *Heartbeat, called: u64) void {
        assert(called != 0);
        heartbeat.turn.ended = called;
        heartbeat.forget_running();
    }

    /// `end` ran `ran` tasks, at least one, after its records, and runs none now. As `leave`, but
    /// it adds to the count, because the records of the same `end` may have counted first.
    pub fn leave_tasks(heartbeat: *Heartbeat, ran: u64) void {
        assert(ran != 0);
        heartbeat.turn.ended += ran;
        heartbeat.forget_running();
    }

    /// `begin` called `polled` pollers, at least one, and runs none now. It keeps the count for the
    /// turn, and stores null in `running` with release order. It keeps no name: `name_of_one`
    /// finds a poller's name in the table of pollers.
    pub fn leave_polling(heartbeat: *Heartbeat, polled: u32) void {
        assert(polled != 0);
        heartbeat.turn.polled = polled;
        heartbeat.running.store(null, .release);
    }

    /// Keeps the last name of a record or a task for the turn, and stores null in `running` with
    /// release order.
    fn forget_running(heartbeat: *Heartbeat) void {
        heartbeat.turn_name = heartbeat.running.load(.monotonic);
        heartbeat.running.store(null, .release);
    }

    /// Writes the stall that ended at `now_ns` to `statistics`. Only a stall reaches it.
    fn note_stall(
        heartbeat: *const Heartbeat,
        statistics: *Statistics,
        name: ?*const Name,
        now_ns: u64,
        span_ns: u64,
    ) void {
        statistics.stalls += 1;
        statistics.stall_ns_max = @max(statistics.stall_ns_max, span_ns);
        statistics.last_stall = .{
            .end_ns = now_ns,
            .span_ns = span_ns,
            .callbacks = heartbeat.turn.callbacks(),
            .name = text_of(name),
        };
    }

    /// A watch of this heartbeat. Any thread may call it. Call `Watch.end` before the loop's
    /// `deinit`.
    pub fn watch(heartbeat: *Heartbeat) Watch {
        const before = heartbeat.watchers.fetchAdd(1, .acq_rel);
        assert(before < std.math.maxInt(u32));
        return .{ .heartbeat = heartbeat, .beat_ns = asleep, .checks = 0 };
    }

    /// Halts while a watch reads this heartbeat: what the loop's `deinit` checks, because a watch
    /// would read memory that the program frees once the loop has ended (decision 8, class C).
    pub fn assert_unwatched(heartbeat: *const Heartbeat) void {
        assert(heartbeat.watchers.load(.acquire) == 0);
    }

    /// What another thread holds to read one loop's heartbeat. It reads no clock: the program calls
    /// `check` once in each period that it chooses.
    pub const Watch = struct {
        heartbeat: *Heartbeat,
        /// The stamp that the last check saw, or `asleep`.
        beat_ns: u64,
        /// The checks in a row that saw that stamp, after the first one.
        checks: u32,

        /// Reads the heartbeat once. Returns the open turn when the last check saw the same turn
        /// open, and null when the loop moved, sleeps, or this is the first check of a turn.
        ///
        /// The order of the loads: `beat_ns` with acquire order, `running` with acquire order, and
        /// `beat_ns` again. The loop stores each with release order. So when the two loads of
        /// `beat_ns` are equal, the name belongs to that turn (`spec/tla/heartbeat/`).
        pub fn check(watcher: *Watch) ?Stuck {
            const heartbeat = watcher.heartbeat;
            const first_ns = heartbeat.beat_ns.load(.acquire);
            const name = heartbeat.running.load(.acquire);
            const second_ns = heartbeat.beat_ns.load(.monotonic);
            if (first_ns != second_ns or first_ns == asleep) return null;
            if (first_ns != watcher.beat_ns) {
                watcher.beat_ns = first_ns;
                watcher.checks = 0;
                return null;
            }
            watcher.checks +|= 1;
            return .{ .name = text_of(name), .since_ns = first_ns, .checks = watcher.checks };
        }

        /// Subtracts 1 from the heartbeat's watchers. Call it before the loop's `deinit`.
        pub fn end(watcher: *Watch) void {
            const before = watcher.heartbeat.watchers.fetchSub(1, .acq_rel);
            assert(before >= 1);
        }
    };

    /// A turn that stayed open for at least one period of the watch.
    pub const Stuck = struct {
        /// The callback that runs now, or null for code outside a callback: the program's own code
        /// between ticks, or the loop's work before a wait. Static data, as `Stall.name` is.
        name: ?[*:0]const u8,
        /// The stamp that started the open turn.
        since_ns: u64,
        /// The checks in a row, after the first one, that saw this turn open. A turn of `n` periods
        /// or more is reported with `checks` of `n - 1` or more.
        checks: u32,
    };
};

/// The text of a name the heartbeat holds, or null. A name is static data, so this reads no memory
/// that a library may free.
fn text_of(name: ?*const Name) ?[*:0]const u8 {
    const held = name orelse return null;
    return held.*.ptr;
}

comptime {
    // The most callbacks one turn holds: one `end` and one `begin` (`Heartbeat.Turn`).
    const turn_callbacks_max = constants.pollers_max + constants.batch_max +
        constants.tasks_per_tick_max;
    assert(turn_callbacks_max < std.math.maxInt(u32));
    assert(@sizeOf(Heartbeat) == constants.heartbeat_alignment);
    assert(@alignOf(Heartbeat) == constants.heartbeat_alignment);
    // The turn check loads the stamp and the threshold together.
    assert(@offsetOf(Heartbeat, "turn_ns") == @offsetOf(Heartbeat, "beat_ns") + 8);
    // One store zeroes both counts of a turn.
    assert(@sizeOf(Heartbeat.Turn) == 16);
    assert(@alignOf(Heartbeat.Turn) == 8);
}

const testing = std.testing;

/// Names of callbacks in the tests, static as a `Call`'s are.
const receive_name: Name = "library.Client.receive";
const run_name: Name = "library.Task.run";

/// A library's poller, for the tests of a stall of one poller.
const Server = struct {
    poller: Poller = .init(Server, "poller", polled),

    fn polled(server: *Server) bool {
        _ = server;
        return false;
    }
};

/// A `Statistics` with one slot of starts, and the loop's table of pollers, for the tests of the
/// turn check. The table holds one poller.
const Counted = struct {
    starts: [1]u64 = .{0},
    statistics: Statistics = undefined,
    server: Server = .{},
    pollers: [constants.pollers_max]*Poller = undefined,

    fn init(counted: *Counted) void {
        counted.statistics.init(.{}, &counted.starts);
        counted.pollers[0] = &counted.server.poller;
    }
};

test "a turn at the threshold is a stall, a turn below it is not, and a wait is never one" {
    var counted: Counted = .{};
    counted.init();
    var heartbeat: Heartbeat = .init(100);
    // Before the first tick no turn is open, so the first stamp counts nothing.
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 1_000);
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 1_099);
    try testing.expectEqual(@as(u64, 0), counted.statistics.stalls);
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 1_199);
    try testing.expectEqual(@as(u64, 1), counted.statistics.stalls);
    try testing.expectEqual(@as(u64, 100), counted.statistics.stall_ns_max);
    try testing.expectEqual(@as(u64, 1_199), counted.statistics.last_stall.end_ns);
    // A wait of any length between two stamps is no turn. The stamp after a wait starts one.
    heartbeat.note_asleep();
    heartbeat.note_woken(5_000);
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 5_150);
    try testing.expectEqual(@as(u64, 2), counted.statistics.stalls);
    try testing.expectEqual(@as(u64, 150), counted.statistics.last_stall.span_ns);
    heartbeat.note_asleep();
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 90_000);
    try testing.expectEqual(@as(u64, 2), counted.statistics.stalls);
    // The longest stall stays when a shorter one follows.
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 90_500);
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 90_600);
    try testing.expectEqual(@as(u64, 4), counted.statistics.stalls);
    try testing.expectEqual(@as(u64, 500), counted.statistics.stall_ns_max);
    try testing.expectEqual(@as(u64, 100), counted.statistics.last_stall.span_ns);
}

test "a null threshold counts no stall" {
    var counted: Counted = .{};
    counted.init();
    var heartbeat: Heartbeat = .init(null);
    // The longest span a turn can have: it reaches the threshold that `null` stores, so only a
    // turn check that a null threshold skips leaves it uncounted.
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 0);
    heartbeat.note_clock(&counted.statistics, &counted.pollers, std.math.maxInt(u64));
    try testing.expectEqual(@as(u64, 0), counted.statistics.stalls);
    // The stamp is stored all the same, because a watch reads it with or without a threshold.
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 5);
    try testing.expectEqual(@as(u64, 5), heartbeat.beat_ns.load(.monotonic));
}

test "a stall names its callback only when the turn called one" {
    var counted: Counted = .{};
    counted.init();
    var heartbeat: Heartbeat = .init(10);
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 100);
    // One record in a tick's `end`. The next tick's `begin` has no poller, so it calls nothing.
    heartbeat.enter(&receive_name);
    heartbeat.leave(1);
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 200);
    const one = counted.statistics.last_stall;
    try testing.expectEqual(@as(u32, 1), one.callbacks);
    try testing.expectEqualStrings("library.Client.receive", std.mem.span(one.name.?));

    // One poller in the next tick's `begin`, and no record before it: the first of the table.
    const poller_name = &counted.server.poller.call.name;
    heartbeat.enter(poller_name);
    heartbeat.leave_polling(1);
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 300);
    const polled = counted.statistics.last_stall;
    try testing.expectEqual(@as(u32, 1), polled.callbacks);
    try testing.expectEqualStrings(@typeName(Server) ++ ".poller", std.mem.span(polled.name.?));

    // A record in one `end` and a poller in the next `begin`: the stall names neither.
    heartbeat.enter(&receive_name);
    heartbeat.leave(1);
    heartbeat.enter(poller_name);
    heartbeat.leave_polling(1);
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 400);
    try testing.expectEqual(@as(u32, 2), counted.statistics.last_stall.callbacks);
    try testing.expectEqual(@as(?[*:0]const u8, null), counted.statistics.last_stall.name);

    // No callback: the program's own code held the loop. The stamp at 400 zeroed both counts.
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 500);
    try testing.expectEqual(@as(u32, 0), counted.statistics.last_stall.callbacks);
    try testing.expectEqual(@as(?[*:0]const u8, null), counted.statistics.last_stall.name);
    try testing.expectEqual(@as(u64, 4), counted.statistics.stalls);
}

test "a watch reports a turn that stays open, with the callback that runs, and counts the checks" {
    var heartbeat: Heartbeat = .init(null);
    var watch = heartbeat.watch();
    defer watch.end();
    // Before the first tick the loop is asleep for a watch.
    try testing.expectEqual(@as(?Heartbeat.Stuck, null), watch.check());

    var counted: Counted = .{};
    counted.init();
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 700);
    heartbeat.enter(&run_name);
    // The first check of a turn keeps its stamp and reports nothing.
    try testing.expectEqual(@as(?Heartbeat.Stuck, null), watch.check());
    const stuck = watch.check().?;
    try testing.expectEqualStrings("library.Task.run", std.mem.span(stuck.name.?));
    try testing.expectEqual(@as(u64, 700), stuck.since_ns);
    try testing.expectEqual(@as(u32, 1), stuck.checks);
    try testing.expectEqual(@as(u32, 2), watch.check().?.checks);

    // The callback returned, and the program's own code holds the turn: no name.
    heartbeat.leave(1);
    try testing.expectEqual(@as(?[*:0]const u8, null), watch.check().?.name);

    // A loop that moved starts the count again.
    heartbeat.note_clock(&counted.statistics, &counted.pollers, 800);
    try testing.expectEqual(@as(?Heartbeat.Stuck, null), watch.check());
    try testing.expectEqual(@as(u32, 1), watch.check().?.checks);

    // A loop asleep in a kernel wait is never stuck.
    heartbeat.note_asleep();
    try testing.expectEqual(@as(?Heartbeat.Stuck, null), watch.check());
    try testing.expectEqual(@as(?Heartbeat.Stuck, null), watch.check());
}

test "the watchers count the watches, so a loop can halt while one reads it" {
    var heartbeat: Heartbeat = .init(null);
    heartbeat.assert_unwatched();
    var first = heartbeat.watch();
    var second = heartbeat.watch();
    try testing.expectEqual(@as(u32, 2), heartbeat.watchers.load(.acquire));
    first.end();
    second.end();
    heartbeat.assert_unwatched();
}
