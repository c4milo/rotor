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
    /// The unit tests inside the bench programs themselves. A bench program is an executable, so
    /// nothing ran its `test` blocks until this step existed: a test in bench/crosscore/
    /// rotor_post.zig passed `zig build test` while deliberately broken.
    program_tests: *std.Build.Step,
    /// Milestone 4's gate: the echo workload run end to end against rotor's own server, which
    /// is the one candidate that needs no pinned competitor. It proves the whole path, from
    /// starting a server to a row with its spread, and not only that the programs compile.
    echo_smoke: *std.Build.Step,
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

    const graph = modules.add(b, target, .ReleaseSafe);
    const echo = add_echo(b, target, graph);
    compile_all.dependOn(echo);

    competitors.add(b, target);

    return .{
        .compile = compile_all,
        .harness_tests = run_harness_tests,
        .program_tests = add_program_tests(b, target, graph),
        .echo_smoke = add_echo_smoke(b, echo),
    };
}

/// One bench program whose `test` blocks the gate runs. `root` is the program's source file and
/// `needs_loop` says whether it drives a rotor loop, which decides the imports it is given.
const Tested = struct {
    name: []const u8,
    root: []const u8,
    needs_loop: bool,
};

/// Every bench program that holds tests. A program missing from this list keeps its tests and
/// never runs them, which is the failure this list exists to stop, so a new one is added here
/// with its first test.
const tested = [_]Tested{
    .{ .name = "bench-costs-tests", .root = "bench/costs/main.zig", .needs_loop = false },
    .{ .name = "bench-post-tests", .root = "bench/crosscore/rotor_post.zig", .needs_loop = true },
    .{
        .name = "bench-crosscore-runner-tests",
        .root = "bench/crosscore/crosscore_runner.zig",
        .needs_loop = false,
    },
    .{
        .name = "bench-timers-runner-tests",
        .root = "bench/timers/timers_runner.zig",
        .needs_loop = false,
    },
    .{
        .name = "bench-reads-runner-tests",
        .root = "bench/files/reads_runner.zig",
        .needs_loop = false,
    },
};

/// Runs the `test` blocks inside the bench programs. They are executables, so `zig build test`
/// compiled them and ran none of their tests; every one of them was decoration until this step.
fn add_program_tests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    graph: modules.Modules,
) *std.Build.Step {
    const backend = if (target.result.os.tag == .linux) graph.uring else graph.kqueue;
    const step = b.step("test-bench-programs", "Run the tests inside the bench programs");
    for (tested) |program| {
        const module = b.createModule(.{
            .root_source_file = b.path(program.root),
            .target = target,
            .optimize = .Debug,
        });
        module.addImport("harness", b.createModule(.{
            .root_source_file = b.path("bench/harness/harness.zig"),
            .target = target,
            .optimize = .Debug,
        }));
        if (program.needs_loop) {
            module.addImport("core", graph.core);
            module.addImport("backend", backend);
        }
        const tests = b.addTest(.{ .name = program.name, .root_module = module });
        step.dependOn(&b.addRunArtifact(tests).step);
    }
    return step;
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
    // `std_io_echo` is a competitor, and it needs no pinned package: `std.Io` is the compiler's
    // own. So it is built here and not by build/competitors.zig.
    const std_io = b.addExecutable(.{
        .name = "std_io_echo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/competitors/std_io_echo.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    step.dependOn(&b.addInstallArtifact(std_io, .{}).step);

    // The timer churn workload: one program per candidate, each measuring itself, because a
    // timer has no client to measure it from.
    const timers = b.createModule(.{
        .root_source_file = b.path("bench/timers/rotor_timers.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    timers.addImport("core", graph.core);
    timers.addImport("backend", backend);
    timers.addImport("harness", harness_module);
    const timers_program = b.addExecutable(.{ .name = "rotor_timers", .root_module = timers });
    step.dependOn(&b.addInstallArtifact(timers_program, .{}).step);

    // The runner of that workload. It needs the harness alone: it starts programs and reads the
    // result lines they print.
    const timers_runner = b.createModule(.{
        .root_source_file = b.path("bench/timers/timers_runner.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    timers_runner.addImport("harness", harness_module);
    const timers_runner_program = b.addExecutable(.{
        .name = "timers_runner",
        .root_module = timers_runner,
    });
    step.dependOn(&b.addInstallArtifact(timers_runner_program, .{}).step);

    // The datagram round-trip workload, which measures itself as the timer one does: its client
    // and its server are two sockets on one loop, so no second program has to be started.
    const datagram = b.createModule(.{
        .root_source_file = b.path("bench/datagram/rotor_datagram.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    datagram.addImport("core", graph.core);
    datagram.addImport("backend", backend);
    const datagram_program = b.addExecutable(.{
        .name = "rotor_datagram",
        .root_module = datagram,
    });
    step.dependOn(&b.addInstallArtifact(datagram_program, .{}).step);

    // The O_DIRECT read workload, which is the only program that registers a buffer.
    const reads = b.createModule(.{
        .root_source_file = b.path("bench/files/rotor_reads.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    reads.addImport("core", graph.core);
    reads.addImport("backend", backend);
    reads.addImport("harness", harness_module);
    const reads_program = b.addExecutable(.{ .name = "rotor_reads", .root_module = reads });
    step.dependOn(&b.addInstallArtifact(reads_program, .{}).step);

    // The runner of that workload, which compares four candidates across two programs: rotor
    // with registered buffers and without, and libuv on its pool and on its ring.
    const reads_runner = b.createModule(.{
        .root_source_file = b.path("bench/files/reads_runner.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    reads_runner.addImport("harness", harness_module);
    const reads_runner_program = b.addExecutable(.{
        .name = "reads_runner",
        .root_module = reads_runner,
    });
    step.dependOn(&b.addInstallArtifact(reads_runner_program, .{}).step);

    // The cross-core workload: decision 4's main claim, one message at a time. Each candidate
    // measures itself and prints a result line, because a message between two threads of one
    // process has no client outside it. It has its own step, because the runner drives the
    // pinned competitors too and a caller may want only this one.
    const crosscore = b.step("bench-crosscore", "Build the cross-core message programs");
    const post = b.createModule(.{
        .root_source_file = b.path("bench/crosscore/rotor_post.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    post.addImport("core", graph.core);
    post.addImport("backend", backend);
    post.addImport("harness", harness_module);
    const post_program = b.addExecutable(.{ .name = "rotor_post", .root_module = post });
    crosscore.dependOn(&b.addInstallArtifact(post_program, .{}).step);

    // The runner needs the harness alone: it starts programs and reads the lines they print.
    const crosscore_runner = b.createModule(.{
        .root_source_file = b.path("bench/crosscore/crosscore_runner.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    crosscore_runner.addImport("harness", harness_module);
    const crosscore_program = b.addExecutable(.{
        .name = "crosscore_runner",
        .root_module = crosscore_runner,
    });
    crosscore.dependOn(&b.addInstallArtifact(crosscore_program, .{}).step);
    step.dependOn(crosscore);

    const programs = [_][]const u8{ "rotor_echo", "echo_client", "echo_runner" };
    // Every echo program gets the harness, because placement lives there now.
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

/// Milestone 4's gate. One short run of the echo workload against rotor's server: three rounds of
/// a second each, four connections, a small payload. It names rotor alone with `--candidates`, so
/// it never needs `zig build bench-competitors`, and it fails when a server cannot be started,
/// when a candidate stalls, or when too few runs come back to make a row.
///
/// It is short, and it is not a measurement: `zig build test` runs on a machine doing other
/// things, and docs/costs.md says what a number needs.
fn add_echo_smoke(b: *std.Build, echo: *std.Build.Step) *std.Build.Step {
    const run = b.addSystemCommand(&.{
        b.pathJoin(&.{ b.install_path, "bin", "echo_runner" }),
        "--rounds",
        "3",
        "--seconds",
        "1",
        "--warmup",
        "0",
        "--connections",
        "4",
        "--payloads",
        "1024",
        "--candidates",
        "rotor",
        "--port-base",
        "30000",
        "--directory",
        b.pathJoin(&.{ b.install_path, "bin" }),
    });
    run.step.dependOn(echo);
    // It starts a server and binds a port, so a cached result would say nothing.
    run.has_side_effects = true;
    const step = b.step("test-bench-echo", "Run the echo workload against rotor, briefly");
    step.dependOn(&run.step);
    return step;
}
