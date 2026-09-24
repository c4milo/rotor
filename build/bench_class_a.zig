//! `zig build bench-echo-no-class-a`: `rotor_echo` with decision 8's class A assertions compiled out
//! and every other check kept, installed under its own name in `zig-out/no-class-a/`.
//! `echo_runner --candidates rotor --directory zig-out/no-class-a` then runs it in place of the
//! server rotor ships, and the difference between the two is what class A costs on the echo
//! workload (decision 8, The experiment). No other step builds it, so the comparison never meets
//! it.
//!
//! On Linux, `zig build bench-echo-epoll-class-a` builds the same server on epoll twice, class A on
//! in `zig-out/epoll-class-a/` and off in `zig-out/epoll-no-class-a/`, so the runner compares the
//! two for the backend a process runs where the kernel refuses io_uring (decision 20). Both are
//! named `rotor_echo`, which is the program the runner's `rotor` candidate starts.
const std = @import("std");
const modules = @import("modules.zig");

/// Where the host backend's server with class A off is installed, under `zig-out/`.
const install_directory = "no-class-a";

/// Where the two epoll servers are installed, under `zig-out/`.
const epoll_on_directory = "epoll-class-a";
const epoll_off_directory = "epoll-no-class-a";

/// Adds the steps, and adds to `tests` the test of `bench/echo/rotor_echo_no_class_a.zig`, built
/// against the class-A-off graph, so the gate fails if that graph ever compiles class A.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, tests: *std.Build.Step) void {
    const step = b.step("bench-echo-no-class-a", "Build rotor_echo with class A compiled out");
    const graph = modules.add_with(b, target, .ReleaseSafe, .{ .class_a = false });
    const linux = target.result.os.tag == .linux;
    const host_backend = if (linux) graph.uring else graph.kqueue;
    step.dependOn(install_echo(b, target, graph.core, host_backend, install_directory));
    if (linux) {
        const epoll_step = b.step(
            "bench-echo-epoll-class-a",
            "Build rotor_echo on epoll twice, class A on and off",
        );
        const shipped = modules.add(b, target, .ReleaseSafe);
        const on = install_echo(b, target, shipped.core, shipped.epoll, epoll_on_directory);
        const off = install_echo(b, target, graph.core, graph.epoll, epoll_off_directory);
        epoll_step.dependOn(on);
        epoll_step.dependOn(off);
    }

    const check = b.addTest(.{
        .name = "bench-echo-no-class-a",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/echo/rotor_echo_no_class_a.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    check.root_module.addImport("core", graph.core);
    tests.dependOn(&b.addRunArtifact(check).step);
}

/// `rotor_echo` built against `core` and `backend`, installed as `rotor_echo` in
/// `zig-out/<directory>/`. Returns the install step.
fn install_echo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    core: *std.Build.Module,
    backend: *std.Build.Module,
    directory: []const u8,
) *std.Build.Step {
    const module = b.createModule(.{
        .root_source_file = b.path("bench/echo/rotor_echo.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    module.addImport("core", core);
    module.addImport("backend", backend);
    module.addImport("harness", b.createModule(.{
        .root_source_file = b.path("bench/harness/harness.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    }));
    const install = b.addInstallArtifact(
        b.addExecutable(.{ .name = "rotor_echo", .root_module = module }),
        .{ .dest_dir = .{ .override = .{ .custom = directory } } },
    );
    return &install.step;
}
