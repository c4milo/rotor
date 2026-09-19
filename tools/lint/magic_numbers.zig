//! magic-numbers: every limit is named in a constant and never written inline (CLAUDE.md
//! non-negotiable 1).
//!
//! Over every `.zig` file under `src/`, the rule reports an integer literal greater than 1
//! unless it is the whole value of a `const` declaration or a container field, which names it.
//! `test` and `comptime` blocks are not read: a test states the numbers it checks, and a layout
//! assert checks a number rather than using one as a limit. `constants.zig` is not read, because
//! that is where the names live.
//!
//! The rule is pepegrillo's `magic_numbers`. This file holds rotor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const magic_numbers = lint.rules.magic_numbers;

pub const config: magic_numbers.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"src"},
        .exclude_basenames = &.{"constants.zig"},
    },
};

const Rule = magic_numbers.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

const failing_fixture: [:0]const u8 =
    \\pub fn reap(ring: *Ring) void {
    \\    var cqes: [256]Cqe = undefined;
    \\    _ = ring.copy(&cqes);
    \\}
;

fn expect_findings(path: []const u8, source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, path, source);
    try harness.expect_messages(findings, expected);
}

test "magic-numbers passes a named limit and a comptime layout assert" {
    try expect_findings("src/uring/uring_reap.zig",
        \\const completions_per_reap = 256;
        \\pub fn reap(ring: *Ring) void {
        \\    var cqes: [completions_per_reap]Cqe = undefined;
        \\    comptime std.debug.assert(@sizeOf(Cqe) == 16);
        \\    _ = ring.copy(&cqes);
        \\}
    , &.{});
}

test "magic-numbers flags an inline array length under src and skips constants.zig" {
    try expect_findings("src/uring/uring_reap.zig", failing_fixture, &.{"integer literal 256"});
    try expect_findings("src/uring/constants.zig", failing_fixture, &.{});
    try expect_findings("bench/echo.zig", failing_fixture, &.{});
}
