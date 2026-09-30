//! undefined-fill: a function's local array is not set to `undefined` in the library. In Debug and
//! ReleaseSafe, the only modes rotor ships, Zig writes a pattern over every `undefined` value, so
//! `var messages: [32]Message = undefined;` stores 512 bytes each time the function runs, whether
//! it uses one element or none. Two such arrays in the drains of a kqueue tick took about a
//! quarter of its own cycles until 2026-09-29 (decision 12, point 6, its amendment of that day).
//!
//! What it reads under `src/`, with the library's tests and test helpers set aside:
//!
//! - It reads each `var` inside a function body, and not one inside a `test` block or one that is
//!   a member of a container. It stops at a file's `const testing = std.testing;`, where rotor's
//!   files begin their tests, so a fixture or a helper only tests call is not read.
//! - It passes an array whose length is a number of at most 8, or whose declaration shows it is
//!   under 64 bytes, and one `allowed` names below, on a cold path.
//!
//! The rule is pepegrillo's `undefined_fill`, which rotor wrote first as a rule of its own on
//! 2026-09-30, the same day pepegrillo took it as a generic rule. pepegrillo's version also passes
//! an array under 64 bytes, which rotor's did not; rotor had no finding that this changes. This
//! file holds rotor's configuration of it and the fixtures that pin that configuration.
const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const undefined_fill = lint.rules.undefined_fill;

pub const config: undefined_fill.Config = .{
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"src"},
        .exclude_directories = &.{"src/conformance"},
        // Helpers only tests call, named for it.
        .exclude_paths = &.{ "src/kqueue/kqueue_testing.zig", "src/linux_shared/linux_shared_testing.zig" },
        .exclude_stem_segment = "_test",
    },
    .stop_at_testing_import = true,
    .allowed = &.{
        // A changelist full before the tick's own call: the rare tick that registers more than
        // `changes_max` descriptors pays for it.
        .{ .path = "src/kqueue/kqueue_submit.zig", .variable = "receipts" },
        // Registration of buffers, once per loop, before any tick.
        .{ .path = "src/uring/uring_buffers.zig", .variable = "vectors" },
        // A group's wakes, made once when the group is created.
        .{ .path = "src/rotor/rotor_loop_registry.zig", .variable = "wakes" },
        // A group's pipe ends, made once when the group is created.
        .{ .path = "src/kqueue/kqueue_group.zig", .variable = "ends" },
        // The 64 bytes a group's wake is read into, beside the `read` that drains it.
        .{ .path = "src/kqueue/kqueue_group.zig", .variable = "bytes" },
        // A datagram's control block, 128 bytes, beside the `sendmsg` or `recvmsg` it goes with.
        // What the fill costs against that call is not measured.
        .{ .path = "src/kqueue/kqueue_datagram.zig", .variable = "control" },
        .{ .path = "src/epoll/epoll_datagram.zig", .variable = "control" },
    },
};

const Rule = undefined_fill.Rule(config);
pub const name = Rule.name;
pub const check = Rule.check;

// Tests. Each fixture pins one shape of the configuration; pepegrillo tests the rule itself.

const testing = std.testing;
const harness = lint.harness;

const drain_source =
    \\const count = 32;
    \\fn drain() void {
    \\    var messages: [count]Message = undefined;
    \\    _ = &messages;
    \\}
;

test "undefined-fill reports a local array whose length is a name, in the library" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try harness.expect_messages(try harness.run(arena, Rule, "src/core/inbox.zig", drain_source), &.{
        "var messages is an array set to undefined, which Debug and ReleaseSafe fill on every call: " ++
            "write into the caller's memory, or declare it only where it is used",
    });
}

test "undefined-fill reads the library under src/, and not its tests, the suite or test helpers" {
    try testing.expect(config.scope.applies("src/core/inbox.zig"));
    try testing.expect(config.scope.applies("src/kqueue/kqueue_tick.zig"));
    try testing.expect(!config.scope.applies("src/conformance/conformance_tcp.zig"));
    try testing.expect(!config.scope.applies("src/kqueue/kqueue_mailbox_test.zig"));
    try testing.expect(!config.scope.applies("src/kqueue/kqueue_testing.zig"));
    try testing.expect(!config.scope.applies("bench/work/work.zig"));
}

test "undefined-fill stops where a rotor file begins its tests" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try harness.expect_messages(try harness.run(arena, Rule, "src/core/inbox.zig",
        \\const std = @import("std");
        \\const testing = std.testing;
        \\const count = 32;
        \\fn fixture() void {
        \\    var slots: [count]Message = undefined;
        \\    _ = &slots;
        \\}
    ), &.{});
}

test "undefined-fill passes a cold path the configuration names, in its own file only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\const changes_max = 256;
        \\fn apply_early() void {
        \\    var receipts: [changes_max]Kevent = undefined;
        \\    _ = &receipts;
        \\}
    ;
    try harness.expect_messages(try harness.run(arena, Rule, "src/kqueue/kqueue_submit.zig", source), &.{});
    const elsewhere = try harness.run(arena, Rule, "src/kqueue/kqueue_reap.zig", source);
    try testing.expectEqual(@as(usize, 1), elsewhere.len);
}
