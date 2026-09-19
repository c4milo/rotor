//! The module graph: one module per directory of `src/`, wired in dependency order. A module can
//! `@import` only what this file gives it, so the dependency direction is enforced by the build
//! and not by review (CLAUDE.md, Layout).
//!
//! The skeleton holds `core` alone, which imports nothing. docs/decisions/0001-interface.md names
//! the modules that follow once the decision records are accepted: `sim`, `uring`, `kqueue` and
//! `bench` in version one, and `adapter` after it. None of them exists yet, because no loop code
//! is written before that review.
const std = @import("std");

/// Each module's root is the file named after its directory (`src/core/core.zig`), which lists
/// the module's API as `pub const` declarations and runs every file's tests.
pub const Modules = struct {
    /// The named limits and the types every other module will share. Imports nothing.
    core: *std.Build.Module,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Modules {
    return .{ .core = create(b, "src/core/core.zig", target, optimize) };
}

fn create(
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
}
