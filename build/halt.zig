//! `zig build halt-check`: proves that assertions halt (decision 8). Each scenario executable
//! under tools/halt/ violates assertions on purpose, and tools/halt_check.zig runs every scenario
//! in a child process that must die by a signal. `zig build test` depends on it.
//!
//! The canary proves the check itself: its scenarios do not halt, and the check must say so.
const std = @import("std");
const modules = @import("modules.zig");

/// The scenarios of the canary: one that violates nothing and one that dies during its set-up.
const canary_failures = "2";

pub fn add(
    b: *std.Build,
    graph: modules.Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const check = b.addExecutable(.{
        .name = "halt_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/halt_check.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const step = b.step("halt-check", "Require every halt scenario to die by a signal");

    const core_scenarios = scenarios(b, "core_scenarios", target, optimize);
    core_scenarios.root_module.addImport("core", graph.core);
    const core_run = b.addRunArtifact(check);
    core_run.addArtifactArg(core_scenarios);
    step.dependOn(&core_run.step);

    const uring_scenarios = scenarios(b, "uring_scenarios", target, optimize);
    uring_scenarios.root_module.addImport("core", graph.core);
    uring_scenarios.root_module.addImport("uring", graph.uring);
    const uring_run = b.addRunArtifact(check);
    uring_run.addArtifactArg(uring_scenarios);
    step.dependOn(&uring_run.step);

    const canary = scenarios(b, "canary_scenarios", target, optimize);
    const canary_run = b.addRunArtifact(check);
    canary_run.addArtifactArg(canary);
    canary_run.addArgs(&.{ "--expect-failures", canary_failures });
    step.dependOn(&canary_run.step);
    return step;
}

/// A scenario executable, built for the target and in the mode the modules it imports are built
/// for: an assertion must halt in Debug and in ReleaseSafe alike.
fn scenarios(
    b: *std.Build,
    comptime name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/halt/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
}
