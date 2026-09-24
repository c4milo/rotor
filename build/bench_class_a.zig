//! `zig build bench-echo-no-class-a`: `rotor_echo` with decision 8's class A assertions compiled out
//! and every other check kept, installed under its own name in `zig-out/no-class-a/`.
//! `echo_runner --candidates rotor --directory zig-out/no-class-a` then runs it in place of the
//! server rotor ships, and the difference between the two is what class A costs on the echo
//! workload (decision 8, The experiment). No other step builds it, so the comparison never meets
//! it.
const std = @import("std");
const modules = @import("modules.zig");

/// Where the step installs, under `zig-out/`.
const install_directory = "no-class-a";

/// Adds the step, and adds to `tests` the test of `bench/echo/rotor_echo_no_class_a.zig`, built
/// against the same graph, so the gate fails if that graph ever compiles class A.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, tests: *std.Build.Step) void {
    const step = b.step("bench-echo-no-class-a", "Build rotor_echo with class A compiled out");
    const graph = modules.add_with(b, target, .ReleaseSafe, .{ .class_a = false });
    const module = b.createModule(.{
        .root_source_file = b.path("bench/echo/rotor_echo.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const linux = target.result.os.tag == .linux;
    module.addImport("core", graph.core);
    module.addImport("backend", if (linux) graph.uring else graph.kqueue);
    module.addImport("harness", b.createModule(.{
        .root_source_file = b.path("bench/harness/harness.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    }));
    const install = b.addInstallArtifact(
        b.addExecutable(.{ .name = "rotor_echo", .root_module = module }),
        .{ .dest_dir = .{ .override = .{ .custom = install_directory } } },
    );
    step.dependOn(&install.step);

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
