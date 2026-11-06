//! The shuffled conformance suites (decision 10, amendment of 2026-11-06). Each one is the
//! conformance suite of one backend, built from a graph whose `core` permutes each reaped batch
//! from a seed (`src/core/shuffle.zig`). A scenario that assumes an order between two operations
//! of one batch then fails, because the kernel promises no such order.
//!
//! `zig build test` runs the suite once more with the seed `-Dshuffle-seed=N` names, or with
//! `seed_default`. It runs only the suites of the backends this host can run: kqueue on macOS,
//! io_uring and epoll on Linux. The Linux gate runs the two Linux suites (build/linux.zig). It also
//! runs the `uring` module's own tests from the same graph on every host, because the reap tests
//! there hand it completions a test built, and need no kernel. The name of each run holds its
//! seed, so the line that reports a failure names the seed that replays it. build.zig stays short
//! (CLAUDE.md, Layout), so the wiring is in this file.
const std = @import("std");
const modules = @import("modules.zig");

/// The seed `zig build test` and `zig build test-linux` shuffle with when `-Dshuffle-seed` names
/// none.
pub const seed_default: u64 = 1;

/// The seed of this build: `-Dshuffle-seed=N`, or `seed_default`.
pub fn seed(b: *std.Build) u64 {
    return b.option(
        u64,
        "shuffle-seed",
        "The seed of the shuffled conformance suites (decision 10, amendment of 2026-11-06)",
    ) orelse seed_default;
}

/// The name of the shuffled suite of `backend`. It holds the seed, so a failure names it.
pub fn name(b: *std.Build, backend: []const u8, shuffle_seed: u64) []const u8 {
    return b.fmt("conformance-{s}-shuffle-seed-{d}", .{ backend, shuffle_seed });
}

/// Adds the shuffled suite of each backend this host runs, and the shuffled tests of the `uring`
/// module, to `test_step`. Each gets a narrow step `zig build test-<name>-shuffled`, which a
/// mutation is measured against.
pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shuffle_seed: u64,
    test_step: *std.Build.Step,
) void {
    const graph = modules.add_with(b, target, optimize, .{ .shuffle_seed = shuffle_seed });
    const os = target.result.os.tag;
    const suites = [_]struct { name: []const u8, module: *std.Build.Module, runs: bool }{
        .{
            .name = "conformance-kqueue",
            .module = graph.conformance_kqueue,
            .runs = os.isDarwin(),
        },
        .{ .name = "conformance-uring", .module = graph.conformance_uring, .runs = os == .linux },
        .{ .name = "conformance-epoll", .module = graph.conformance_epoll, .runs = os == .linux },
        .{ .name = "uring", .module = graph.uring, .runs = true },
    };
    for (suites) |suite| {
        if (!suite.runs) continue;
        const tests = b.addTest(.{
            .name = b.fmt("{s}-shuffle-seed-{d}", .{ suite.name, shuffle_seed }),
            .root_module = suite.module,
        });
        const run = &b.addRunArtifact(tests).step;
        test_step.dependOn(run);
        const narrow = b.step(
            b.fmt("test-{s}-shuffled", .{suite.name}),
            b.fmt("Run the {s} tests alone, with each reaped batch shuffled", .{suite.name}),
        );
        narrow.dependOn(run);
    }
}
