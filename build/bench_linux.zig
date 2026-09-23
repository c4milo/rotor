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
        if (variant.optimize == .ReleaseSafe) {
            step.dependOn(add_post(b, target, graph));
            const harness = b.createModule(.{
                .root_source_file = b.path("bench/harness/harness.zig"),
                .target = target,
                .optimize = .ReleaseSafe,
            });
            for (programs) |program| {
                step.dependOn(add_program(b, target, graph, harness, program.name, program.root));
            }
        }
    }
}

/// The programs built for the container that take the io_uring backend as `backend`, beside the
/// harness.
const programs = [_]struct { name: []const u8, root: []const u8 }{
    // The datagram round-trip workload on io_uring: the path decision 15 added is the io_uring
    // one, and a macOS number says nothing about it.
    .{ .name = "rotor_datagram", .root = "bench/datagram/rotor_datagram.zig" },
    .{ .name = "rotor_reads", .root = "bench/files/rotor_reads.zig" },
    // The echo programs too, so the placement path that only Linux can take is run.
    .{ .name = "rotor_echo", .root = "bench/echo/rotor_echo.zig" },
    .{ .name = "echo_client", .root = "bench/echo/echo_client.zig" },
};

/// One bench program built for the container, given the backend as its `backend` import.
fn add_program(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    graph: modules.Modules,
    harness: *std.Build.Module,
    name: []const u8,
    root: []const u8,
) *std.Build.Step {
    const program = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    program.root_module.addImport("core", graph.core);
    program.root_module.addImport("backend", graph.uring);
    program.root_module.addImport("harness", harness);
    const install = b.addInstallArtifact(program, .{
        .dest_dir = .{ .override = .{ .custom = install_directory } },
    });
    return &install.step;
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
