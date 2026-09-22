//! defer-order: a `defer` registered under a statement that can fail (CLAUDE.md, non-negotiable 1:
//! every resource a loop is given has an owner, and the owner releases it on every path).
//!
//! The rule exists because of one bug. `bench/echo/client.zig` opened one socket per connection
//! inside `connect_all`, which returns on the first connect it cannot make, and registered
//! `defer close_all()` under that call. A server that never started made every connect fail, the
//! sockets already opened were never closed, and a run of the comparison died out of descriptors
//! on 2026-09-22. The same block also left the connects still in flight, which `deinit` halts on.
//! A linter cannot see the second; it sees the first exactly.
//!
//! The scope is `src` and `bench`: the library and the harness. `tools/` is developer tooling that
//! runs once and exits, so a leak there costs a process that is ending anyway.
//!
//! The rule is pepegrillo's `defer_order`. This file holds rotor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const defer_order = lint.rules.defer_order;

pub const config: defer_order.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{ "src", "bench" },
    },
};

const Rule = defer_order.Rule(config);
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

test "defer-order passes a cleanup that names what the fallible statement produced" {
    try expect_findings("src/store/page.zig",
        \\pub fn open(path: []const u8) !void {
        \\    const file = try openFile(path);
        \\    defer file.close();
        \\    var loop: Loop = undefined;
        \\    try loop.init(&memory);
        \\    defer loop.deinit();
        \\}
    , &.{});
}

/// The finding the rule reports, which the harness matches whole.
const message = "a defer after a statement that can fail; anything acquired above it leaks when" ++
    " that statement returns";

test "defer-order reports a cleanup for something the fallible statement does not name" {
    try expect_findings("src/store/page.zig",
        \\pub fn run(options: Options) !void {
        \\    try connect_all(&client);
        \\    defer close_all();
        \\}
    , &.{message});
}

test "defer-order reads src and bench, and leaves tools alone" {
    const leaking: [:0]const u8 =
        \\pub fn run() !void {
        \\    try connect_all(&client);
        \\    defer close_all();
        \\}
    ;
    try expect_findings("src/store/page.zig", leaking, &.{message});
    try expect_findings("bench/echo/client.zig", leaking, &.{message});
    try expect_findings("tools/lint/main.zig", leaking, &.{});
}
