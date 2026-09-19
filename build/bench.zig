//! `bench/`: the cost probes that fill docs/costs.md and the statistics the harness reports with.
//! Nothing here is linked into the library. build.zig stays short (CLAUDE.md, Layout), so the
//! wiring is in this file.
//!
//! A measurement is always built ReleaseSafe, the mode rotor ships in, whatever `-Drelease` says:
//! a Debug number describes nothing a consumer runs.
const std = @import("std");

pub const Steps = struct {
    /// Compiles every bench executable, so `zig build test` fails when one stops building.
    compile: *std.Build.Step,
    /// The unit tests of bench/harness.
    harness_tests: *std.Build.Step,
};

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget) Steps {
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

    return .{ .compile = &costs.step, .harness_tests = run_harness_tests };
}
