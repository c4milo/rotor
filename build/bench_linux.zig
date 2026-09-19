//! `zig build bench-linux`: the benchmarks that need io_uring, built for the container target of
//! build/linux.zig and installed under zig-out/linux-bench/. It runs none of them: they run on a
//! Linux machine, or in Docker when a first indication is enough (a virtual machine's numbers
//! never go in docs/costs.md).
//!
//! Each benchmark is built twice. `_safe` is ReleaseSafe, the mode rotor ships in. `_fast` is
//! ReleaseFast, which no other part of the build offers: it removes every assertion and every
//! bounds and overflow check, so the difference between the two is an upper bound on what the
//! hot path's assertions cost (decision 8, The experiment).
const std = @import("std");
const linux = @import("linux.zig");
const modules = @import("modules.zig");

const install_directory = "linux-bench";

pub fn add(b: *std.Build) void {
    const step = b.step("bench-linux", "Build the io_uring benchmarks for Linux; run none");
    const target = linux.container_target(b);
    const variants = [_]struct { suffix: []const u8, optimize: std.builtin.OptimizeMode }{
        .{ .suffix = "safe", .optimize = .ReleaseSafe },
        .{ .suffix = "fast", .optimize = .ReleaseFast },
    };
    for (variants) |variant| {
        const graph = modules.add(b, target, variant.optimize);
        const nop = b.addExecutable(.{
            .name = b.fmt("uring_nop_{s}", .{variant.suffix}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/uring/nop.zig"),
                .target = target,
                .optimize = variant.optimize,
            }),
        });
        nop.root_module.addImport("core", graph.core);
        nop.root_module.addImport("uring", graph.uring);
        const install = b.addInstallArtifact(nop, .{
            .dest_dir = .{ .override = .{ .custom = install_directory } },
        });
        step.dependOn(&install.step);
        if (variant.optimize == .ReleaseSafe) step.dependOn(add_post(b, target, graph));
    }
}

/// One cross-core message on its own (row C17), in the mode rotor ships in.
fn add_post(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    graph: modules.Modules,
) *std.Build.Step {
    const post = b.addExecutable(.{
        .name = "uring_post",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/uring/post.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    post.root_module.addImport("core", graph.core);
    post.root_module.addImport("uring", graph.uring);
    const install = b.addInstallArtifact(post, .{
        .dest_dir = .{ .override = .{ .custom = install_directory } },
    });
    return &install.step;
}
