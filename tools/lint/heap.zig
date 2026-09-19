//! heap: rotor allocates nothing (CLAUDE.md non-negotiable 1). The caller hands every loop the
//! memory it runs in at init, as slices, and rotor exposes the sizes as comptime constants, so
//! nothing under `src/` names an allocator: no operation can allocate when no code path holds one.
//!
//! Over every `.zig` file under `src/`, the rule makes two checks:
//!   1. a chain that starts with one of `forbidden_prefixes` at a dot boundary: `std.heap`, and
//!      the allocators of `std.testing`. A test that needs scratch memory declares a fixed array;
//!   2. a parameter whose type names `Allocator`, on any function, `init` included.
//!
//! What the rule cannot see: an allocator passed as `anytype`. The memory a backend maps for the
//! kernel's rings comes from `mmap`, which is a syscall and not an allocator, and is mapped once
//! at init.
//!
//! The rule is pepegrillo's `forbidden_references`. This file holds rotor's configuration of it
//! and the fixtures that pin that configuration.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const forbidden_references = lint.rules.forbidden_references;

/// Every chain that names an allocator a file did not receive. `std.testing` is listed member by
/// member, because the rest of it is what every test uses.
const forbidden_prefixes = [_][]const u8{
    "std.heap",
    "std.testing.allocator",
    "std.testing.allocator_instance",
    "std.testing.failing_allocator",
    "std.testing.FailingAllocator",
};

const reason = "rotor allocates nothing; the caller hands in memory at init";

/// The configuration. It reads `src/` alone: `tools/` and `bench/` are never linked into the
/// library.
pub const config: forbidden_references.Config = .{
    .name = "heap",
    .scope = .{ .extensions = &.{lint.paths.zig_extension}, .include_directories = &.{"src"} },
    .prefixes = &forbidden_prefixes,
    .parameter_check = .{ .type_segment = "Allocator", .description = "an allocator parameter" },
    .reason = reason,
};

const Rule = forbidden_references.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests. Each fixture pins one shape from the header.

const testing = std.testing;
const harness = lint.harness;

const failing_fixture: [:0]const u8 =
    \\const std = @import("std");
    \\const arena_type = std.heap.ArenaAllocator;
    \\pub fn init(allocator: std.mem.Allocator, entries: u32) !void {
    \\    _ = allocator;
    \\    _ = entries;
    \\}
;

test "heap passes a loop that takes its memory as a slice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/core/loop.zig",
        \\pub fn init(loop: *Loop, memory: []align(page_bytes) u8) void {
        \\    loop.memory = memory;
        \\}
    );
    try harness.expect_messages(findings, &.{});
}

test "heap flags std.heap and an allocator parameter, init included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const findings = try harness.run(arena, Rule, "src/core/loop.zig", failing_fixture);
    try harness.expect_messages(findings, &.{
        "reference to std.heap.ArenaAllocator: " ++ reason,
        "init takes an allocator parameter: " ++ reason,
    });
}

test "heap reads src/ alone" {
    try testing.expect(config.scope.applies("src/uring/uring.zig"));
    try testing.expect(!config.scope.applies("tools/lint/main.zig"));
    try testing.expect(!config.scope.applies("bench/echo.zig"));
    try testing.expect(!config.scope.applies("build/modules.zig"));
}
