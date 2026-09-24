//! static-alignment: a container-level `var` states its own alignment (CLAUDE.md, Conventions).
//!
//! Zig 0.16's own x86_64 backend, which builds Debug on x86_64, places a static without the
//! alignment its type gets from an aligned field unless the variable declares it. On 2026-09-23 a
//! new static moved a conformance fixture 32 bytes off its 64-byte boundary, and `Layout.take`
//! halted in CI. So over every `.zig` file the lint reads, the rule reports a container-level `var`
//! of a named type that declares no `align(...)`, and asks for `align(@alignOf(T))`. The build
//! runner, the bench programs and the halt scenarios are built for x86_64 as the library is, so no
//! directory is exempt.
//!
//! The rule is pepegrillo's `static_alignment`. This file holds rotor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const static_alignment = lint.rules.static_alignment;

pub const config: static_alignment.Config = .{
    .scope = .{ .extensions = &.{lint.paths.zig_extension} },
};

const Rule = static_alignment.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

fn expect_findings(path: []const u8, source: [:0]const u8, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, path, source);
    try harness.expect_messages(findings, expected);
}

const failing_fixture: [:0]const u8 = "var loop: Loop = undefined;";
const failing_message = "var loop declares no alignment: write align(@alignOf(Loop))";

test "static-alignment asks a loop's static for its alignment in every directory" {
    try expect_findings("src/conformance/conformance_cost.zig", failing_fixture, &.{failing_message});
    try expect_findings("tools/halt/epoll_scenarios.zig", failing_fixture, &.{failing_message});
    try expect_findings("bench/uring/nop.zig", failing_fixture, &.{failing_message});
    try expect_findings("build/lint.zig", failing_fixture, &.{failing_message});
}

test "static-alignment passes a static that states its alignment, and a buffer of bytes" {
    try expect_findings("src/conformance/conformance_cost.zig",
        \\var loop: Loop align(@alignOf(Loop)) = undefined;
        \\var memory: [4096]u8 align(64) = undefined;
        \\var bytes: [16]u8 = undefined;
    , &.{});
}
