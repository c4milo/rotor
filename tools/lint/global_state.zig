//! global-state: a container-level `var` under `src/` is `threadlocal` (CLAUDE.md non-negotiable 4:
//! a loop belongs to one thread and shares nothing with another). A `var` every thread shares is
//! one copy for the whole process, which two loops race on, so the rule refuses it: hand the state
//! in at init, as a loop's memory is handed in, or make it the thread's own.
//!
//! What it does not read:
//!
//! - `src/conformance/` and every file whose stem ends in `_test`. Their `var`s are test fixtures,
//!   such as a loop's memory or a buffer group aligned to 64 KiB, too large for a stack and too
//!   aligned for a thread's local storage. No library code imports them.
//! - `src/rotor/rotor_choice.zig`, which holds the one value a process shares by design: the
//!   backend it chose on Linux, asked of the kernel once so that no two loops of one process run
//!   different backends (decision 20, open question 5). Its one `var` is an atomic, written once,
//!   and that file says why a `threadlocal` would be wrong.
//!
//! The rule is pepegrillo's `global_state`. This file holds rotor's configuration of it and the
//! fixtures that pin that configuration.
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const global_state = lint.rules.global_state;

pub const config: global_state.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"src"},
        .exclude_directories = &.{"src/conformance"},
        .exclude_paths = &.{"src/rotor/rotor_choice.zig"},
        .exclude_stem_segment = "_test",
    },
};

const Rule = global_state.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests. Each fixture pins one shape of the configuration.

const testing = std.testing;
const harness = lint.harness;

test "global-state flags a var every thread shares, and passes a thread's own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try harness.expect_messages(try harness.run(arena, Rule, "src/core/tables.zig", "var shared: u32 = 0;"), &.{
        "var shared is state every thread shares: make it threadlocal, or hand it in",
    });
    try harness.expect_messages(
        try harness.run(arena, Rule, "src/core/tables.zig", "threadlocal var mine: u32 = 0;"),
        &.{},
    );
}

test "global-state reads the library under src/, and not its tests or the process's backend choice" {
    try testing.expect(config.scope.applies("src/core/core.zig"));
    try testing.expect(config.scope.applies("src/rotor/rotor_loop.zig"));
    try testing.expect(config.scope.applies("src/kqueue/kqueue.zig"));
    try testing.expect(!config.scope.applies("src/rotor/rotor_choice.zig"));
    try testing.expect(!config.scope.applies("src/conformance/conformance_tcp.zig"));
    try testing.expect(!config.scope.applies("src/core/tables_test.zig"));
    try testing.expect(!config.scope.applies("src/kqueue/kqueue_offload_test.zig"));
    try testing.expect(!config.scope.applies("bench/crosscore/rotor_post.zig"));
    try testing.expect(!config.scope.applies("examples/echo.zig"));
    try testing.expect(!config.scope.applies("tools/echo_check.zig"));
}
