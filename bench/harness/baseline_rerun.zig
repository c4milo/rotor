//! The second measurement of a configuration in which a row fell behind the baseline.
//!
//! One measurement cannot hold every row to `margin_thousandths`. On 2026-11-15 and 2026-11-17 the
//! nightly comparison ran commit `80f90d8` on an AMD EPYC 9V45, with the same runner image and
//! kernel. At 64 connections and 64 KiB it put libuv at 989 thousandths of rotor, and then at 1047.
//! The two runs differ by 58, which is more than the margin of 50.
//!
//! So when a row of a configuration falls behind, the runner measures the whole configuration once
//! more, on the same runner, and judges every row again. A row counts as a regression only when it
//! fell behind in both measurements. A row that fell behind only in the second measurement does
//! not count: the second measurement confirms a failure, and does not search for a new one.
//!
//! Each list holds one verdict per candidate, at the candidate's index in the runner's table. A
//! candidate that produced no row has `.unrecorded`.
const std = @import("std");
const assert = std.debug.assert;
const baseline = @import("baseline.zig");

const Verdict = baseline.Verdict;

/// Measures one configuration, and measures it once more when a row fell behind the baseline.
/// Returns the count of rows that fell behind in both measurements. `measurer` has a method
/// `measure(verdicts: *[candidate_count]Verdict, second: bool) !void`, which measures every
/// candidate and writes each verdict at the candidate's index. `second` is true for the second
/// measurement, so the measurer can say why it measures again.
pub fn count_behind(comptime candidate_count: usize, measurer: anytype) !u32 {
    comptime assert(candidate_count > 0);
    var first: [candidate_count]Verdict = @splat(.unrecorded);
    try measurer.measure(&first, false);
    if (!needs_second(&first)) return 0;
    var second: [candidate_count]Verdict = @splat(.unrecorded);
    try measurer.measure(&second, true);
    return held(&first, &second);
}

/// Whether the first measurement of a configuration asks for a second: true when a row fell
/// behind the baseline.
pub fn needs_second(first: []const Verdict) bool {
    assert(first.len > 0);
    for (first) |verdict| {
        if (verdict == .regressed) return true;
    }
    return false;
}

/// The count of rows that fell behind the baseline in both measurements. Call it only after a
/// second measurement, which only a first measurement with a row behind asks for.
pub fn held(first: []const Verdict, second: []const Verdict) u32 {
    assert(first.len == second.len);
    assert(needs_second(first));
    var count: u32 = 0;
    for (first, second) |verdict_first, verdict_second| {
        if (verdict_first == .regressed and verdict_second == .regressed) count += 1;
    }
    assert(count <= first.len);
    return count;
}

const testing = std.testing;

test "a first measurement with no row behind asks for no second" {
    const all_within = [_]Verdict{ .within, .within, .within };
    try testing.expect(!needs_second(&all_within));
    // Neither an undecided row nor an unrecorded one is behind.
    const no_decision = [_]Verdict{ .within, .undecided, .unrecorded };
    try testing.expect(!needs_second(&no_decision));
    // One row behind, at any index, asks for a second measurement.
    const last_behind = [_]Verdict{ .within, .within, .regressed };
    try testing.expect(needs_second(&last_behind));
    const first_behind = [_]Verdict{ .regressed, .within, .within };
    try testing.expect(needs_second(&first_behind));
}

test "a row counts only when it fell behind in both measurements" {
    // The nightly run of 2026-11-17 had two rows behind. Here the second measurement confirms one.
    const first = [_]Verdict{ .within, .regressed, .regressed, .within };
    const second_one = [_]Verdict{ .within, .regressed, .within, .within };
    try testing.expectEqual(@as(u32, 1), held(&first, &second_one));
    // Both rows behind again: both count.
    const second_both = [_]Verdict{ .within, .regressed, .regressed, .within };
    try testing.expectEqual(@as(u32, 2), held(&first, &second_both));
    // The second measurement clears both: nothing counts.
    const second_none = [_]Verdict{ .within, .within, .within, .within };
    try testing.expectEqual(@as(u32, 0), held(&first, &second_none));
}

test "a row behind only in the second measurement does not count" {
    const first = [_]Verdict{ .regressed, .within, .within };
    const second = [_]Verdict{ .within, .regressed, .regressed };
    try testing.expectEqual(@as(u32, 0), held(&first, &second));
}

/// A measurer that hands out fixed verdicts and records what it was asked.
const Scripted = struct {
    script: []const [3]Verdict,
    calls: u32 = 0,
    seconds: u32 = 0,

    fn measure(scripted: *Scripted, verdicts: *[3]Verdict, second: bool) !void {
        verdicts.* = scripted.script[scripted.calls];
        scripted.calls += 1;
        if (second) scripted.seconds += 1;
    }
};

test "a configuration with no row behind is measured once" {
    var scripted: Scripted = .{ .script = &.{.{ .within, .undecided, .unrecorded }} };
    try testing.expectEqual(@as(u32, 0), try count_behind(3, &scripted));
    try testing.expectEqual(@as(u32, 1), scripted.calls);
    try testing.expectEqual(@as(u32, 0), scripted.seconds);
}

test "a configuration with a row behind is measured twice, and counts what both found" {
    var cleared: Scripted = .{ .script = &.{
        .{ .within, .regressed, .within },
        .{ .within, .within, .within },
    } };
    try testing.expectEqual(@as(u32, 0), try count_behind(3, &cleared));
    try testing.expectEqual(@as(u32, 2), cleared.calls);
    try testing.expectEqual(@as(u32, 1), cleared.seconds);

    var confirmed: Scripted = .{ .script = &.{
        .{ .regressed, .regressed, .within },
        .{ .regressed, .within, .regressed },
    } };
    try testing.expectEqual(@as(u32, 1), try count_behind(3, &confirmed));
    try testing.expectEqual(@as(u32, 2), confirmed.calls);
    try testing.expectEqual(@as(u32, 1), confirmed.seconds);
}

test "a row that decides nothing in the second measurement does not count" {
    // Runs that disagree decide nothing in either measurement (`baseline.judge`).
    const first = [_]Verdict{ .regressed, .regressed };
    const second = [_]Verdict{ .undecided, .unrecorded };
    try testing.expectEqual(@as(u32, 0), held(&first, &second));
}
