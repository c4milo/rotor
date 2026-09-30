//! `zig build guide`: pepegrillo's `docs/performance/`, the performance method every project on
//! pepegrillo follows, installed to `zig-out/docs/performance/` from the commit build.zig.zon pins.
//! `performance.md` there is the entry point. A reader finds the method the tree is held to at that
//! commit, without a clone of pepegrillo beside this one. build.zig stays short (CLAUDE.md,
//! Layout), so the step is in this file.
const std = @import("std");

/// The method's folder inside the pepegrillo package.
const method_directory = "docs/performance";

/// The installed folder's path under the install prefix.
const installed_directory = "docs/performance";

/// Adds the `guide` step. It installs one folder and builds nothing, so `zig build test` does not
/// depend on it.
pub fn add(b: *std.Build, pepegrillo: *std.Build.Dependency) void {
    const step = b.step(
        "guide",
        "Install pepegrillo's performance method to zig-out/" ++ installed_directory,
    );
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = pepegrillo.path(method_directory),
        .install_dir = .prefix,
        .install_subdir = installed_directory,
    }).step);
}
