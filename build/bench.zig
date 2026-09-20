//! `bench/`: the cost probes that fill docs/costs.md and the statistics the harness reports with.
//! Nothing here is linked into the library. build.zig stays short (CLAUDE.md, Layout), so the
//! wiring is in this file.
//!
//! A measurement is always built ReleaseSafe, the mode rotor ships in, whatever `-Drelease` says:
//! a Debug number describes nothing a consumer runs.
//!
//! The pinned competitors are wired by build/competitors.zig, under their own step.
const std = @import("std");
const competitors = @import("competitors.zig");
const modules = @import("modules.zig");

pub const Steps = struct {
    /// Compiles every bench executable, so `zig build test` fails when one stops building.
    compile: *std.Build.Step,
    /// The unit tests of bench/harness.
    harness_tests: *std.Build.Step,
};

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget) Steps {
    const compile_all = b.step("bench-compile", "Compile every bench executable");
    const costs = b.addExecutable(.{
        .name = "costs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/costs/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_costs = b.addRunArtifact(costs);
    if (b.args) |arguments| run_costs.addArgs(arguments);
    const costs_step = b.step("bench-costs", "Run the cost probes that fill docs/costs.md");
    costs_step.dependOn(&run_costs.step);
    compile_all.dependOn(&costs.step);

    const harness_tests = b.addTest(.{
        .name = "bench-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/harness/harness.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const run_harness_tests = &b.addRunArtifact(harness_tests).step;
    const harness_step = b.step("test-bench-harness", "Run the bench/harness tests alone");
    harness_step.dependOn(run_harness_tests);

    const echo = add_echo(b, target, modules.add(b, target, .ReleaseSafe));
    compile_all.dependOn(echo);

    competitors.add(b, target);

    return .{ .compile = compile_all, .harness_tests = run_harness_tests };
}

/// The echo servers and the client of the echo workload. Each is its own executable, as
/// bench/competitors' are, so the runner starts a server, drives it with one client and stops it.
/// The backend is the one this host can run, as the conformance suite's is.
fn add_echo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    graph: modules.Modules,
) *std.Build.Step {
    const backend = if (target.result.os.tag == .linux) graph.uring else graph.kqueue;
    const step = b.step("bench-echo", "Build the echo servers and the echo client");
    const harness_module = b.createModule(.{
        .root_source_file = b.path("bench/harness/harness.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const programs = [_][]const u8{ "rotor_echo", "echo_client" };
    for (programs) |name| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("bench/echo/{s}.zig", .{name})),
            .target = target,
            .optimize = .ReleaseSafe,
        });
        module.addImport("core", graph.core);
        module.addImport("backend", backend);
        module.addImport("harness", harness_module);
        const program = b.addExecutable(.{ .name = name, .root_module = module });
        step.dependOn(&b.addInstallArtifact(program, .{}).step);
    }
    return step;
}
