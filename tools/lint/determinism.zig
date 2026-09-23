//! determinism: a loop's behaviour is a function of what the caller submits and what the kernel
//! answers (CLAUDE.md non-negotiable 2). Nothing in `core` reads the host clock, the PRNG, or the
//! entropy source: a property test draws from `core.random`, and a sampling decision is a
//! function of the operation sequence (docs/decisions/0009-sampling-and-replay.md).
//!
//! Over every `.zig` file under `src/` but not under a kernel backend, the rule flags a chain that
//! starts with one of `forbidden_prefixes` at a dot boundary, and a chain that starts with one of
//! `forbidden_raw_prefixes` with no boundary. `std.time` is flagged whole, its unit constants
//! included: a duration rotor uses is a named limit in a `constants.zig`.
//!
//! **The list is the whole of the guard, so a name that stops naming anything is a hole.** Three
//! clocks reachable from `core` were missing on 2026-09-22, found by auditing the list against
//! Zig 0.16 rather than by any failure: `std.Io.Clock`, `std.c.clock_gettime` and
//! `std.os.linux.clock_gettime`. The tree used all three, in the backends alone, so nothing was
//! violated and nothing would have been reported had `core` reached for them.
//!
//! `std.crypto.random` went the other way. It was listed and Zig 0.16 has no such declaration, so
//! that entry had been guarding an impossible mistake since the upgrade. The `comptime` check below
//! is why it is gone: a listed name that resolves to nothing now fails the build instead of going
//! quiet. It cannot catch the first kind, a name that exists and is missing from the list, which is
//! why that list is read by a person against the standard library when Zig moves.
//!
//! `std.posix.clock_` stays, and now matches only `clock_t` and `clockid_t`: `std.posix` lost its
//! clock function in Zig 0.16. It is kept as a raw prefix because those types are a step towards
//! reading a clock, and because Zig may put the function back.
//!
//! The kernel backends, `src/uring/` and `src/kqueue/`, are exempt: reading the monotonic clock
//! for a timer is their job. `bench/` is outside `src/` and is not read.
//!
//! What the rule cannot see: a clock reached through a parameter. That is the shape rotor wants.
//!
//! The rule is pepegrillo's `forbidden_references`. This file holds rotor's configuration of it
//! and the fixtures that pin that configuration.

const std = @import("std");
const pepegrillo = @import("pepegrillo");
const lint = pepegrillo.lint;
const forbidden_references = lint.rules.forbidden_references;

const forbidden_prefixes = [_][]const u8{
    "std.time",
    "std.Random",
    "std.Io.Clock",
    "std.c.clock_gettime",
    "std.os.linux.clock_gettime",
};
const forbidden_raw_prefixes = [_][]const u8{"std.posix.clock_"};

comptime {
    // Every whole name above must still name something in the standard library, and every partial
    // name must still match something. A Zig upgrade that removes one fails this build rather than
    // leaving a rule that reports nothing.
    lint.names.assert_all_resolve(std, "std", &forbidden_prefixes);
    lint.names.assert_all_match(std, "std", &forbidden_raw_prefixes);
}

/// The modules that talk to a kernel and so may read its clock.
const kernel_backend_directories = [_][]const u8{ "src/uring", "src/kqueue", "src/epoll" };

const reason = "core reads no clock and draws from core.random alone";

pub const config: forbidden_references.Config = .{
    .name = "determinism",
    .scope = .{
        .extensions = &.{lint.paths.zig_extension},
        .include_directories = &.{"src"},
        .exclude_directories = &kernel_backend_directories,
    },
    .prefixes = &forbidden_prefixes,
    .raw_prefixes = &forbidden_raw_prefixes,
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
    \\pub fn sample(self: *Counters) bool {
    \\    self.now_ns = std.time.nanoTimestamp();
    \\    var generator = std.Random.DefaultPrng.init(0);
    \\    _ = std.posix.clock_gettime(.MONOTONIC);
    \\    _ = std.c.clock_gettime(.MONOTONIC, &now);
    \\    _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
    \\    _ = std.Io.Clock.Timestamp.fromNow(io, .{});
    \\    return generator.random().int(u8) == 0;
    \\}
;

test "determinism passes a sampling decision drawn from the op clock" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try harness.run(arena_state.allocator(), Rule, "src/core/sample.zig",
        \\pub fn sample(op: u64) bool {
        \\    return op & constants.sample_mask == 0;
        \\}
    );
    try harness.expect_messages(findings, &.{});
}

test "determinism flags every clock it names, and the PRNG" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const findings = try harness.run(arena, Rule, "src/core/sample.zig", failing_fixture);
    try harness.expect_messages(findings, &.{
        "reference to std.time.nanoTimestamp: " ++ reason,
        "reference to std.Random.DefaultPrng.init: " ++ reason,
        "reference to std.posix.clock_gettime: " ++ reason,
        "reference to std.c.clock_gettime: " ++ reason,
        "reference to std.os.linux.clock_gettime: " ++ reason,
        "reference to std.Io.Clock.Timestamp.fromNow: " ++ reason,
    });
}

test "determinism reads core and not the kernel backends" {
    try testing.expect(config.scope.applies("src/core/completion.zig"));
    try testing.expect(config.scope.applies("src/core/random.zig"));
    try testing.expect(!config.scope.applies("src/uring/uring.zig"));
    try testing.expect(!config.scope.applies("src/kqueue/kqueue.zig"));
    try testing.expect(!config.scope.applies("src/epoll/epoll_tick.zig"));
    // The public module is in scope: it chooses a backend and reads no clock of its own.
    try testing.expect(config.scope.applies("src/rotor/rotor_loop.zig"));
    try testing.expect(!config.scope.applies("bench/echo.zig"));
}
