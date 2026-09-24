//! What the loop's own work costs, bounded, on both backends (decision 10: one suite, and the
//! build hands it the backend under test). Every other scenario here checks behaviour; these check
//! that a path did not become slow, which nothing else in `zig build test` would notice.
//!
//! The tree found out why it needs this on 2026-09-22. A polling `kevent` on macOS parked the
//! thread for 12 µs where the call itself costs 444 ns, so an empty tick cost 12,495 ns instead of
//! 358. Every conformance scenario passed throughout, the echo rows moved inside their spread, and
//! the loss only showed as a cross-core row four times libuv's. A bound on the tick would have
//! failed the moment it landed.
//!
//! **A timing test is only honest if it cannot flake.** Three things make these ones safe:
//!
//!   - **The best of `attempts` is what is checked.** Other work on the machine makes a run slower
//!     and never faster, so the fastest attempt is the closest reading of the path's own cost, and
//!     a loaded machine costs attempts rather than a false failure. A regression raises the best
//!     attempt with all the others.
//!   - **Every bound is an order of magnitude above what was measured**, so the gate answers "did
//!     this become slow" and never "is this machine busy". The comment on each says what it was
//!     measured at, on which machine and when; a bound moved down because a path got faster is a
//!     change to make deliberately, with the number beside it.
//!   - **A failure prints what it measured**, so a reader can tell a real regression from a
//!     machine that cannot be measured on at all.
//!
//! **The bounds are for Debug**, which is what `zig build test` compiles a test in, and they are
//! eight to ten times the Debug reading and not the ReleaseSafe one. The first version of this
//! file took its numbers from a ReleaseSafe program and left the submit bound 1.3 times what the
//! path costs; a hosted runner read 110 ns against a bound of 100 and the first CI run went red.
//! Under a sanitizer these skip: the race gate's job is races, and TSan's cost is not this loop's.
//!
//! What these do not do is measure. `docs/costs.md` and `bench/` are where a number that supports
//! a claim comes from; a bound here is a tripwire and never a result.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Event = core.Event;
const Loop = backend.Loop;

/// Times each cost is measured, of which the fastest is checked. Twenty is enough that one of them
/// lands between two scheduler interruptions on a machine with work on it, and costs milliseconds.
const attempts = 20;

/// Operations one attempt of each cost runs, so one reading covers many and the clock's own step
/// (about 40 ns on Apple silicon) is a rounding error rather than the measurement.
const polls_per_attempt = 500;
const fires_per_attempt = 2000;
const submits_per_attempt = 256;

/// Timers armed for the fire cost, and how often each is due. The period is short and the timers
/// are many, so the loop is always behind and every tick returns a full batch: what is measured is
/// the cost of delivering a fire and not the wait for one.
const fire_timers = 256;
const fire_period_ns = 10 * core.constants.ns_per_us;

/// This file's own loop, because the shared harness holds 64 operations and the fire cost arms
/// `fire_timers`. Nothing here needs a registry, an offload or a socket.
const operations = 1024;
const events_max = 512;
const options: Loop.Options = .{ .operations = operations };
var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
// Each static restates its type's alignment. Zig 0.16's own x86-64 backend, which builds Debug on
// x86-64, places a static without the alignment its type takes from an aligned field, unless the
// static declares it. `conformance_offload.zig` met it on 2026-09-23.
var loop: Loop align(@alignOf(Loop)) = undefined;

/// A poll with nothing in flight: `tick` with no wait, which returns at once.
///
/// Measured on `mac` (M1 Pro, macOS 26.6.2) on 2026-09-22: 750 ns in Debug, 406 in ReleaseSafe.
/// Before `kqueue_tick.zig` gave a polling tick its own wake trigger the same path cost 12,495 ns,
/// and that cost is a scheduler park rather than code, so it is the same on any machine. The bound
/// is eight times the Debug reading and half the regression it exists to catch.
const poll_bound_ns = 6000;

/// One fire of a repeating timer, delivered in a batch: the heap's pop, the finished list and the
/// event. Measured on `mac` on 2026-09-22 over `fire_timers`, on a period short enough that every
/// tick returns a full batch: 374 ns in Debug and 57 in ReleaseSafe. The same fire at 4,096 timers
/// on a 1 ms period costs 247 ns in ReleaseSafe, and a timer the caller re-arms costs 404.
const fire_bound_ns = 4000;

/// One operation of a batch `submit` takes: the slot claimed, the operation checked and the timer
/// armed. Measured on `mac` on 2026-09-22: 78 ns in Debug and 7 in ReleaseSafe. A GitHub-hosted
/// x86-64 runner read 110 ns in Debug and 119 under ThreadSanitizer, which is what a bound of 100
/// tripped on and why this one is ten times the Debug reading.
const submit_bound_ns = 800;

const now_ns = backend.testing.monotonic_ns;

/// True where a cost cannot be read: a sanitizer's own work is most of what a timing loop would
/// measure there, and the race gate runs this suite under ThreadSanitizer to find races.
fn unmeasurable() bool {
    return builtin.sanitize_thread;
}

/// Fails with what it measured, because a bound that trips says nothing by itself.
fn expect_under(measured_ns: u64, bound_ns: u64, what: []const u8) !void {
    if (measured_ns < bound_ns) return;
    std.debug.print(
        "cost: {s} took {d} ns, over the bound of {d} ns. The best of {d} attempts is checked, so" ++
            " a busy machine is not this. Re-run on a quiet one; a failure that stays is a" ++
            " regression (src/conformance/conformance_cost.zig).\n",
        .{ what, measured_ns, bound_ns, attempts },
    );
    return error.CostOverBound;
}

test "a poll with nothing to do stays under its bound" {
    if (conformance.unsupported() or unmeasurable()) return error.SkipZigTest;
    try loop.init(&memory, options);
    defer loop.deinit();
    var events: [events_max]Event = undefined;

    var best_ns: u64 = std.math.maxInt(u64);
    for (0..attempts) |_| {
        const started_ns = now_ns();
        for (0..polls_per_attempt) |_| {
            try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 0));
        }
        best_ns = @min(best_ns, (now_ns() - started_ns) / polls_per_attempt);
    }
    try expect_under(best_ns, poll_bound_ns, "a poll with nothing in flight");
}

test "one fire of a repeating timer stays under its bound" {
    if (conformance.unsupported() or unmeasurable()) return error.SkipZigTest;
    try loop.init(&memory, options);
    defer loop.deinit();
    var events: [events_max]Event = undefined;

    var batch: [fire_timers]core.Operation = undefined;
    for (&batch, 0..) |*operation, index| {
        operation.* = core.Operation.timer(index, fire_period_ns, fire_period_ns);
    }
    try testing.expectEqual(@as(u32, fire_timers), loop.submit(&batch, &.{}));
    defer {
        loop.cancel_all();
        loop.drain(&events) catch @panic("the timers did not end");
    }

    var best_ns: u64 = std.math.maxInt(u64);
    for (0..attempts) |_| {
        var fired: u32 = 0;
        const started_ns = now_ns();
        while (fired < fires_per_attempt) {
            const count = try loop.tick(&events, core.constants.ns_per_ms);
            for (events[0..count]) |event| try testing.expect(event.flags.more);
            fired += count;
        }
        best_ns = @min(best_ns, (now_ns() - started_ns) / fired);
    }
    try expect_under(best_ns, fire_bound_ns, "one fire of a repeating timer");
}

test "one operation of a batch submit stays under its bound" {
    if (conformance.unsupported() or unmeasurable()) return error.SkipZigTest;
    try loop.init(&memory, options);
    defer loop.deinit();
    var events: [events_max]Event = undefined;

    // A deadline no attempt reaches, so every submit claims a slot and arms a timer and nothing
    // fires while the cost is being read.
    var batch: [submits_per_attempt]core.Operation = undefined;
    for (&batch, 0..) |*operation, index| {
        operation.* = core.Operation.timer(index, core.constants.ns_per_s, 0);
    }

    var best_ns: u64 = std.math.maxInt(u64);
    for (0..attempts) |_| {
        const started_ns = now_ns();
        const taken = loop.submit(&batch, &.{});
        const elapsed_ns = now_ns() - started_ns;
        try testing.expectEqual(@as(u32, submits_per_attempt), taken);
        best_ns = @min(best_ns, elapsed_ns / submits_per_attempt);
        // The next attempt needs the slots back, and a cancelled timer ends inside one tick.
        loop.cancel_all();
        try loop.drain(&events);
    }
    try expect_under(best_ns, submit_bound_ns, "one operation of a batch submit");
}
