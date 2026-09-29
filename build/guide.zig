//! `zig build guide`: pepegrillo's `docs/performance.md`, the performance method every project on
//! pepegrillo follows, installed to `zig-out/docs/performance-method.md` from the commit
//! build.zig.zon pins. A reader finds the method the tree is held to at that commit, without a
//! clone of pepegrillo beside this one. build.zig stays short (CLAUDE.md, Layout), so the step is
//! in this file.
const std = @import("std");

/// The method's path inside the pepegrillo package.
const method_path = "docs/performance.md";

/// The installed copy's path under the install prefix.
const installed_path = "docs/performance-method.md";

/// Adds the `guide` step. It installs one file and builds nothing, so `zig build test` does not
/// depend on it.
pub fn add(b: *std.Build, pepegrillo: *std.Build.Dependency) void {
    const step = b.step(
        "guide",
        "Install pepegrillo's performance method to zig-out/" ++ installed_path,
    );
    step.dependOn(&b.addInstallFile(pepegrillo.path(method_path), installed_path).step);
}
