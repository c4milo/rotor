//! Decision 13: a loop may poll for a bounded time before it blocks. These are that record's rules,
//! as functions of what the caller asked for and of the clock the tick read, and never of a
//! statistic (its point 4). Each backend's `tick` runs the spin itself, because a round of it is
//! that backend's own tick without a wait, and a call that takes a `*Loop` stays in the backend
//! (CLAUDE.md, Layout).
//!
//! The budget is off unless the caller sets it (`spin_budget_ns` in the loop's options, 0 by
//! default), which is what the owner accepted on 2026-09-24: a loop spends a core it was not given
//! only when its caller asks.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

/// True when a tick given `wait_ns` polls before it blocks: the loop has a budget, and the caller's
/// wait is longer than it. A tick the caller asked not to block in never spins, and nor does one
/// whose whole wait fits in the budget: that one blocks for its wait, as every tick did before.
///
/// It leaves the wait unchecked: `Loop.tick` asks this before the tick's own `begin_tick`, which is
/// the one place a wait longer than `wait_ns_max` halts, so a check here would hide that one.
pub fn applies(budget_ns: u64, wait_ns: u64) bool {
    assert(budget_ns <= constants.spin_budget_ns_max);
    return budget_ns != 0 and wait_ns > budget_ns;
}

/// One tick's spin: when it stops polling, and how many polls it has made.
pub const Spin = struct {
    end_ns: u64,
    rounds: u32,

    /// The spin of a tick that read `now_ns` and found nothing to hand over, or null when a timer
    /// comes due inside the budget. That tick blocks until the timer instead, so a spin never holds
    /// a loop busy for a deadline it could sleep until (decision 13, point 2).
    pub fn begin(budget_ns: u64, now_ns: u64, earliest_ns: ?u64) ?Spin {
        assert(budget_ns >= 1);
        assert(budget_ns <= constants.spin_budget_ns_max);
        const end_ns = now_ns + budget_ns;
        if (earliest_ns) |deadline_ns| {
            if (deadline_ns <= end_ns) return null;
        }
        return .{ .end_ns = end_ns, .rounds = 0 };
    }

    /// True while the budget lasts. `now_ns` is the clock the last poll read: each poll is a whole
    /// tick, and each tick reads the clock afresh.
    pub fn more(spin: *Spin, now_ns: u64) bool {
        if (spin.rounds >= constants.spin_rounds_max) return false;
        spin.rounds += 1;
        return now_ns < spin.end_ns;
    }
};

/// What is left of the caller's wait of `wait_ns`, which began when the clock read `start_ns`.
pub fn remaining_ns(wait_ns: u64, start_ns: u64, now_ns: u64) u64 {
    assert(now_ns >= start_ns);
    assert(wait_ns <= constants.wait_ns_max);
    return wait_ns -| (now_ns - start_ns);
}

const testing = std.testing;
/// The budget decision 13 measured, in microseconds.
const test_budget_us = 50;
const test_budget_ns = test_budget_us * constants.ns_per_us;

test "a tick spins only with a budget, and only for a wait longer than it" {
    try testing.expect(!applies(0, constants.ns_per_s));
    try testing.expect(!applies(test_budget_ns, 0));
    try testing.expect(!applies(test_budget_ns, test_budget_ns));
    try testing.expect(applies(test_budget_ns, test_budget_ns + 1));
    try testing.expect(applies(constants.spin_budget_ns_max, constants.wait_ns_max));
}

test "a timer due inside the budget stops the spin before it starts" {
    const now_ns = 7 * constants.ns_per_ms;
    try testing.expectEqual(@as(?Spin, null), Spin.begin(test_budget_ns, now_ns, now_ns + test_budget_ns));
    try testing.expectEqual(@as(?Spin, null), Spin.begin(test_budget_ns, now_ns, now_ns));
    const later = Spin.begin(test_budget_ns, now_ns, now_ns + test_budget_ns + 1).?;
    try testing.expectEqual(now_ns + test_budget_ns, later.end_ns);
    const no_timer = Spin.begin(test_budget_ns, now_ns, null).?;
    try testing.expectEqual(now_ns + test_budget_ns, no_timer.end_ns);
}

test "a spin lasts until the clock passes its budget, and no more than its rounds" {
    const now_ns = 3 * constants.ns_per_ms;
    var spin = Spin.begin(test_budget_ns, now_ns, null).?;
    try testing.expect(spin.more(now_ns));
    try testing.expect(spin.more(now_ns + test_budget_ns - 1));
    try testing.expect(!spin.more(now_ns + test_budget_ns));

    // A clock that stood still would keep the budget from ever passing; the rounds end it.
    var stuck = Spin.begin(test_budget_ns, now_ns, null).?;
    var polls: u32 = 0;
    while (stuck.more(now_ns)) polls += 1;
    try testing.expectEqual(constants.spin_rounds_max, polls);
}

test "what is left of a wait is what the spin did not spend, and never less than nothing" {
    const start_ns = 5 * constants.ns_per_ms;
    try testing.expectEqual(10 * constants.ns_per_ms, remaining_ns(10 * constants.ns_per_ms, start_ns, start_ns));
    try testing.expectEqual(
        10 * constants.ns_per_ms - test_budget_ns,
        remaining_ns(10 * constants.ns_per_ms, start_ns, start_ns + test_budget_ns),
    );
    try testing.expectEqual(@as(u64, 0), remaining_ns(test_budget_ns, start_ns, start_ns + 2 * test_budget_ns));
}
