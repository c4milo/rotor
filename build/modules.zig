//! The module graph: one module per directory of `src/`, wired in dependency order. A module can
//! `@import` only what this file gives it, so the dependency direction is enforced by the build
//! and not by review (CLAUDE.md, Layout).
//!
//! `core` imports nothing. `uring` imports `core`. `conformance` imports `core` and one backend,
//! which this file hands it as its `backend` import, so one suite tests every backend
//! (decision 10). `kqueue` imports `core`. docs/decisions/0001-interface.md names the module that
//! follows: `adapter`, after version one. `bench/` is outside `src/` and outside this graph;
//! build/bench.zig wires it.
const std = @import("std");

/// Each module's root is the file named after its directory (`src/core/core.zig`), which lists
/// the module's API as `pub const` declarations and runs every file's tests.
pub const Modules = struct {
    /// The types the caller sees, the slot table, the timer heap and the named limits.
    core: *std.Build.Module,
    /// The Linux backend, over io_uring. Its pure parts are tested on every host.
    uring: *std.Build.Module,
    /// The conformance suite with `uring` as the backend under test. It skips off Linux.
    conformance_uring: *std.Build.Module,
    /// The macOS backend, over kqueue. Its pure parts are tested on every host.
    kqueue: *std.Build.Module,
    /// The conformance suite with `kqueue` as the backend under test. It skips off macOS.
    conformance_kqueue: *std.Build.Module,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Modules {
    const core = create(b, "src/core/core.zig", target, optimize);
    const uring = create(b, "src/uring/uring.zig", target, optimize);
    uring.addImport("core", core);
    const conformance_uring = create(b, "src/conformance/conformance.zig", target, optimize);
    conformance_uring.addImport("core", core);
    conformance_uring.addImport("backend", uring);
    const kqueue = create(b, "src/kqueue/kqueue.zig", target, optimize);
    kqueue.addImport("core", core);
    const conformance_kqueue = create(b, "src/conformance/conformance.zig", target, optimize);
    conformance_kqueue.addImport("core", core);
    conformance_kqueue.addImport("backend", kqueue);
    return .{
        .core = core,
        .uring = uring,
        .conformance_uring = conformance_uring,
        .kqueue = kqueue,
        .conformance_kqueue = conformance_kqueue,
    };
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
