//! The heartbeat as the program hands it to its watch thread (decision 28). `Loop.heartbeat`
//! returns a `*HeartbeatView`, which declares only `watch`, as `SharedLoop` declares only the calls
//! of a library. The calls that write the heartbeat stay with the loop, so a watch thread cannot
//! make them (decision 1, amendment of 2026-11-07).
//!
//! It is an opaque type. Its address is the heartbeat's, and `watch` casts the address back. A
//! `Watch` holds the view, and casts it back in `check` and `end`.
const std = @import("std");
const assert = std.debug.assert;
const stall = @import("stall.zig");

const Heartbeat = stall.Heartbeat;
const asleep = stall.asleep;

/// The view of one loop's heartbeat that the program hands to a thread it starts.
pub const HeartbeatView = opaque {
    /// A watch of this heartbeat. Any thread may call it. Call `Watch.end` before the loop's
    /// `deinit`, which halts while a watch reads the heartbeat.
    pub fn watch(view: *HeartbeatView) Watch {
        const before = heartbeat_of(view).watchers.fetchAdd(1, .acq_rel);
        assert(before < std.math.maxInt(u32));
        return .{ .view = view, .beat_ns = asleep, .checks = 0 };
    }

    /// What another thread holds to read one loop's heartbeat. It reads no clock: the program
    /// calls `check` once in each period that it chooses.
    pub const Watch = struct {
        view: *HeartbeatView,
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
            const heartbeat = heartbeat_of(watcher.view);
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
            return .{ .name = stall.text_of(name), .since_ns = first_ns, .checks = watcher.checks };
        }

        /// Subtracts 1 from the heartbeat's watchers. Call it before the loop's `deinit`.
        pub fn end(watcher: *Watch) void {
            const before = heartbeat_of(watcher.view).watchers.fetchSub(1, .acq_rel);
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

/// The view of `heartbeat`, which the loop hands out. Only the loop's own code calls it.
pub fn view_of(heartbeat: *Heartbeat) *HeartbeatView {
    return @ptrCast(heartbeat);
}

fn heartbeat_of(view: *HeartbeatView) *Heartbeat {
    return @ptrCast(@alignCast(view));
}

const testing = std.testing;
const constants = @import("constants.zig");
const statistics_module = @import("statistics.zig");
const Poller = @import("dispatch/dispatch.zig").Poller;

const run_name: stall.Name = "library.Task.run";

test "the view declares watch and the types of a watch, and no call that writes the heartbeat" {
    const declarations = @typeInfo(HeartbeatView).@"opaque".decls;
    try testing.expectEqual(@as(usize, 3), declarations.len);
    inline for (.{ "watch", "Watch", "Stuck" }) |name| try testing.expect(@hasDecl(HeartbeatView, name));
}

test "a watch reports a turn that stays open, with the callback that runs, and counts the checks" {
    var heartbeat: Heartbeat = .init(null);
    var watch = view_of(&heartbeat).watch();
    defer watch.end();
    const Stuck = HeartbeatView.Stuck;
    // Before the first tick the loop is asleep for a watch.
    try testing.expectEqual(@as(?Stuck, null), watch.check());

    // A null threshold counts no stall, so the turn check reads neither of these.
    var starts: [1]u64 = .{0};
    var statistics: statistics_module.Statistics = undefined;
    statistics.init(.{}, &starts);
    var pollers: [constants.pollers_max]*Poller = undefined;
    heartbeat.note_clock(&statistics, &pollers, 700);
    heartbeat.enter(&run_name);
    // The first check of a turn keeps its stamp and reports nothing.
    try testing.expectEqual(@as(?Stuck, null), watch.check());
    const stuck = watch.check().?;
    try testing.expectEqualStrings("library.Task.run", std.mem.span(stuck.name.?));
    try testing.expectEqual(@as(u64, 700), stuck.since_ns);
    try testing.expectEqual(@as(u32, 1), stuck.checks);
    try testing.expectEqual(@as(u32, 2), watch.check().?.checks);

    // The callback returned, and the program's own code holds the turn: no name.
    heartbeat.leave(1);
    try testing.expectEqual(@as(?[*:0]const u8, null), watch.check().?.name);

    // A loop that moved starts the count again.
    heartbeat.note_clock(&statistics, &pollers, 800);
    try testing.expectEqual(@as(?Stuck, null), watch.check());
    try testing.expectEqual(@as(u32, 1), watch.check().?.checks);

    // A loop asleep in a kernel wait is never stuck.
    heartbeat.note_asleep();
    try testing.expectEqual(@as(?Stuck, null), watch.check());
    try testing.expectEqual(@as(?Stuck, null), watch.check());
}

test "the watchers count the watches, so a loop can halt while one reads it" {
    var heartbeat: Heartbeat = .init(null);
    heartbeat.assert_unwatched();
    var first = view_of(&heartbeat).watch();
    var second = view_of(&heartbeat).watch();
    try testing.expectEqual(@as(u32, 2), heartbeat.watchers.load(.acquire));
    first.end();
    second.end();
    heartbeat.assert_unwatched();
}
