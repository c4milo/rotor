//! unbounded-loop: every loop is bounded by a named limit (CLAUDE.md non-negotiable 1).
//!
//! Over every `.zig` file under `src/`, the rule reports two shapes:
//!   1. `while (true)` with no `break`, or with a `break` but no named limit anywhere in the loop;
//!   2. a condition that compares a length read against an integer literal with no named limit
//!      anywhere in the loop: `while (queue.count() > 0)`. A length read is a call or a field
//!      whose last name is one of `length_reader_names`.
//!
//! A named limit is a chain holding the segment `constants` or ending in `_max`.
//!
//! What the rule cannot do: it reads the shape of the source, not its arithmetic, so a loop it
//! passes is not proved bounded. It catches the two shapes that are unbounded on their face; the
//! runtime assertion on the trip count is what proves the bound.
//!
//! The rule is pepegrillo's `unbounded_loop`. This file holds rotor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const unbounded_loop = lint.rules.unbounded_loop;

const length_reader_names = [_][]const u8{
    "remaining", "len", "size", "count", "ready", "pending",
};

pub const config: unbounded_loop.Config = .{
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .forever = .unless_bounded_break,
    .length_read = true,
    .bound = .{ .segments = &.{"constants"}, .last_segment_suffixes = &.{"_max"} },
    .length_reader_names = &length_reader_names,
    .messages = .{
        .forever_without_break = "while (true) has no break; nothing ends the loop",
        .forever_without_bound = "while (true) breaks on no named limit;" ++
            " bound it with a constants.zig value",
        .length_read = "the condition reads {[read]s} against a literal" ++
            " and the loop names no limit",
    },
};

const Rule = unbounded_loop.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

test "unbounded-loop passes a reap that a named limit bounds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/uring/uring_reap.zig",
        \\pub fn reap(ring: *Ring) void {
        \\    var round: u32 = 0;
        \\    while (ring.ready() > 0) : (round += 1) {
        \\        if (round == constants.reap_rounds_max) break;
        \\        ring.dispatch();
        \\    }
        \\}
    );
    try harness.expect_messages(findings, &.{});
}

test "unbounded-loop flags a drain with no limit and a while (true) with no break" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/uring/uring_reap.zig",
        \\pub fn reap(ring: *Ring) void {
        \\    while (ring.ready() > 0) ring.dispatch();
        \\    while (true) ring.dispatch();
        \\}
    );
    try harness.expect_messages(findings, &.{
        "the condition reads ring.ready against a literal and the loop names no limit",
        "while (true) has no break; nothing ends the loop",
    });
}

test "unbounded-loop reads src/ alone" {
    try testing.expect(config.scope.applies("src/sim/sim.zig"));
    try testing.expect(!config.scope.applies("bench/echo.zig"));
    try testing.expect(!config.scope.applies("tools/lint/main.zig"));
}
