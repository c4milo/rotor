//! `zig build halt-check`: proves that assertions halt (decision 8). Each scenario executable
//! under tools/halt/ violates assertions on purpose, and tools/halt_check.zig runs every scenario
//! in a child process that must die by a signal. `zig build test` depends on it.
//!
//! The canary proves the check itself: its scenarios do not halt, and the check must say so.
//!
//! `linux` builds the check, the canary and the Linux-only scenarios for the Linux gate. A scenario
//! is Linux-only when its path, with its assertion deleted, makes a Linux system call: on a Mac
//! that call runs some other system call, so the check there cannot prove the assertion.
//! build/linux.zig installs them and tools/linux_test.sh runs them in Docker.
const std = @import("std");
const assert = std.debug.assert;
const modules = @import("modules.zig");

/// The scenarios of the canary: one that violates nothing and one that dies during its set-up.
const canary_failures = "2";

/// What the check takes after the canary's executable.
const canary_arguments = [_][]const u8{ "--expect-failures", canary_failures };

/// A scenario executable the Linux gate runs the check on, and what the check takes after it.
pub const LinuxScenarios = struct {
    executable: *std.Build.Step.Compile,
    arguments: []const []const u8,
};

/// The scenario executables `linux` builds: the Linux-only scenarios of uring and of epoll, and the
/// canary.
pub const linux_scenarios_count = 3;

/// What `linux` builds: the check, and the scenario executables it runs.
pub const Linux = struct {
    check: *std.Build.Step.Compile,
    scenarios: [linux_scenarios_count]LinuxScenarios,
};

pub fn add(
    b: *std.Build,
    graph: modules.Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const check = check_executable(b, b.graph.host);
    const step = b.step("halt-check", "Require every halt scenario to die by a signal");

    // Each scenario file and the backend it proves, beside `core`, which all of them import.
    const files = [_]struct { name: []const u8, backend: ?[]const u8 }{
        .{ .name = "core_scenarios", .backend = null },
        .{ .name = "uring_scenarios", .backend = "uring" },
        .{ .name = "kqueue_scenarios", .backend = "kqueue" },
        .{ .name = "epoll_scenarios", .backend = "epoll" },
    };
    inline for (files) |file| {
        const executable = scenarios(b, file.name, target, optimize);
        executable.root_module.addImport("core", graph.core);
        if (file.backend) |name| executable.root_module.addImport(name, module_named(graph, name));
        step.dependOn(&run_check(b, check, executable, &.{}).step);
    }

    const canary = scenarios(b, "canary_scenarios", target, optimize);
    step.dependOn(&run_check(b, check, canary, &canary_arguments).step);
    return step;
}

/// One run of the check over `executable`. It must exit 0, which makes the run a check of its own
/// and not a step with side effects: Zig then caches it on the content of both executables and
/// the arguments, and runs it beside the others. A failure prints what the check wrote to stderr,
/// the name of each scenario that did not halt.
fn run_check(
    b: *std.Build,
    check: *std.Build.Step.Compile,
    executable: *std.Build.Step.Compile,
    arguments: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(check);
    run.addArtifactArg(executable);
    run.addArgs(arguments);
    run.expectExitCode(0);
    return run;
}

fn module_named(graph: modules.Modules, name: []const u8) *std.Build.Module {
    if (std.mem.eql(u8, name, "uring")) return graph.uring;
    if (std.mem.eql(u8, name, "kqueue")) return graph.kqueue;
    std.debug.assert(std.mem.eql(u8, name, "epoll"));
    return graph.epoll;
}

/// The check and the scenarios of the Linux gate, built for `target`, which must be Linux.
pub fn linux(
    b: *std.Build,
    graph: modules.Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Linux {
    assert(target.result.os.tag == .linux);
    const uring_scenarios = scenarios(b, "uring_linux_scenarios", target, optimize);
    uring_scenarios.root_module.addImport("core", graph.core);
    uring_scenarios.root_module.addImport("uring", graph.uring);
    const epoll_scenarios = scenarios(b, "epoll_linux_scenarios", target, optimize);
    epoll_scenarios.root_module.addImport("core", graph.core);
    epoll_scenarios.root_module.addImport("epoll", graph.epoll);
    const canary = scenarios(b, "canary_scenarios", target, optimize);
    return .{
        .check = check_executable(b, target),
        .scenarios = .{
            .{ .executable = uring_scenarios, .arguments = &.{} },
            .{ .executable = epoll_scenarios, .arguments = &.{} },
            .{ .executable = canary, .arguments = &canary_arguments },
        },
    };
}

/// The check is a tool, and a tool never ships, so it compiles in Debug.
fn check_executable(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "halt_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/halt_check.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
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
