//! The instruction gate of `bench/work/`: rotor's own work per operation, counted in instructions
//! and held to `bench/baseline/work.txt`.
//!
//! `work` runs one workload on loops that never sleep, and `work_gate` counts its instructions
//! with the counter the host has, `/usr/bin/time -l` on macOS and Valgrind's cachegrind on Linux,
//! and compares. The workload programs are built for the baseline processor of the host's
//! architecture, not the native one, so every machine of that architecture runs the same
//! instructions: GitHub's runners come from a pool of different processors, and a count built for
//! one would not hold for the next.
//!
//! `zig build test` runs the gate. A machine with no counter, such as GitHub's macOS runners,
//! which are virtual and report no instructions, or a Linux host without Valgrind, skips it and
//! says so. CI's Linux runners install Valgrind and run `zig build work-gate`.
const std = @import("std");
const modules = @import("modules.zig");

pub const Steps = struct {
    /// Builds and installs the workload programs and the gate: `bench-work`.
    install: *std.Build.Step,
    /// Runs the gate: `work-gate`, which `zig build test` depends on.
    gate: *std.Build.Step,
};

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget) Steps {
    const linux = target.result.os.tag == .linux;
    const work_target = b.resolveTargetQuery(.{
        .cpu_arch = target.result.cpu.arch,
        .os_tag = target.result.os.tag,
        .abi = target.result.abi,
        .cpu_model = .baseline,
    });
    const graph = modules.add(b, work_target, .ReleaseSafe);
    const install = b.step("bench-work", "Build the workload programs of the instruction gate");
    const gate = b.addExecutable(.{
        .name = "work_gate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/work/work_gate.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    install.dependOn(&b.addInstallArtifact(gate, .{}).step);

    const run = b.addRunArtifact(gate);
    run.addFileArg(b.path("bench/baseline/work.txt"));
    const host_backend = if (linux) "uring" else "kqueue";
    const host_program = work_program(b, graph, work_target, "work", if (linux) graph.uring else graph.kqueue);
    install.dependOn(&b.addInstallArtifact(host_program, .{}).step);
    run.addPrefixedArtifactArg(b.fmt("{s}=", .{host_backend}), host_program);
    if (linux) {
        const epoll_program = work_program(b, graph, work_target, "work_epoll", graph.epoll);
        install.dependOn(&b.addInstallArtifact(epoll_program, .{}).step);
        run.addPrefixedArtifactArg("epoll=", epoll_program);
    }
    const gate_step = b.step("work-gate", "Count rotor's own instructions per operation, held to the baseline");
    gate_step.dependOn(&run.step);
    // The gate's own tests run with the other bench programs' (`tested` in build/bench.zig).
    return .{ .install = install, .gate = gate_step };
}

/// One workload program, against `backend`, for the baseline processor.
fn work_program(
    b: *std.Build,
    graph: modules.Modules,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    backend: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("bench/work/work.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    module.addImport("core", graph.core);
    module.addImport("backend", backend);
    return b.addExecutable(.{ .name = name, .root_module = module });
}
