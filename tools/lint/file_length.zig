//! file-length: a hand-written source file stays at or under 500 lines, its tests included
//! (CLAUDE.md, Conventions). Split the file rather than raise the limit, and name every piece
//! after the file it came from, keeping the original name as the entry point. The hot-path files
//! docs/decisions/0007-hot-path-ugliness.md names are not exempt.
//!
//! Over every `.zig` and `.sh` file under `src/`, `tools/`, `build/` and `bench/`, the rule
//! counts lines the way an editor numbers them and reports a file over the limit once, at the
//! first line past it. Markdown is exempt: a document's audited unit is the section.
//!
//! The rule is pepegrillo's `file_length`. This file holds rotor's configuration of it.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const file_length = lint.rules.file_length;

/// The most lines a hand-written file may hold.
pub const max_lines: u32 = 500;

pub const config: file_length.Config = .{
    .scope = .{
        .extensions = &.{ ".zig", ".sh" },
        .include_directories = &.{ "src", "tools", "build", "bench" },
    },
    .max_lines = max_lines,
    .message_suffix = "; split the file",
};

const Rule = file_length.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests.

const testing = std.testing;
const harness = lint.harness;

const fixture_line = "//\n";

test "file-length passes a file at the limit and flags one line over it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const at_limit = try harness.run(arena, Rule, "src/uring/uring.zig", fixture_line ** max_lines);
    try harness.expect_messages(at_limit, &.{});
    const over_limit = fixture_line ** (max_lines + 1);
    const over = try harness.run(arena, Rule, "src/uring/uring.zig", over_limit);
    try harness.expect_messages(over, &.{"501 lines, over the 500-line limit; split the file"});
    try testing.expectEqual(max_lines + 1, over[0].line);
}

test "file-length reads .zig and .sh under src, tools, build and bench" {
    try testing.expect(config.scope.applies("src/core/core.zig"));
    try testing.expect(config.scope.applies("bench/run.sh"));
    try testing.expect(config.scope.applies("build/modules.zig"));
    try testing.expect(!config.scope.applies("docs/costs.md"));
    try testing.expect(!config.scope.applies("build.zig"));
}
