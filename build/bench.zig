//! `bench/`: the cost probes that fill docs/costs.md and the statistics the harness reports with.
//! Nothing here is linked into the library. build.zig stays short (CLAUDE.md, Layout), so the
//! wiring is in this file.
//!
//! A measurement is always built ReleaseSafe, the mode rotor ships in, whatever `-Drelease` says:
//! a Debug number describes nothing a consumer runs.
//!
//! The pinned alternatives are wired by build/alternatives.zig, under their own step.
const std = @import("std");
const alternatives = @import("alternatives.zig");
const modules = @import("modules.zig");
const bench_class_a = @import("bench_class_a.zig");

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
    /// is the one candidate that needs no pinned alternative. It proves the whole path, from
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
    costs.root_module.addImport("harness", b.createModule(.{
        .root_source_file = b.path("bench/harness/harness.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    }));
    const run_costs = b.addRunArtifact(costs);
    if (b.args) |arguments| run_costs.addArgs(arguments);
    const costs_step = b.step("bench-costs", "Run the cost probes that fill docs/costs.md");
    costs_step.dependOn(&run_costs.step);
    // A compile of the probes whose binary nothing reads, so it emits none: the run above builds
    // the binary when `bench-costs` asks for it.
    const costs_check = b.addExecutable(.{ .name = "costs", .root_module = costs.root_module });
    compile_all.dependOn(&costs_check.step);

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
    const echo_smoke = add_echo_smoke(b);
    add_echo(b, target, graph, compile_all, echo_smoke.run);
    const program_tests = add_program_tests(b, target, graph);
    bench_class_a.add(b, target, program_tests);

    alternatives.add(b, target);

    return .{
        .compile = compile_all,
        .harness_tests = run_harness_tests,
        .program_tests = program_tests,
        .echo_smoke = echo_smoke.step,
    };
}

/// One bench program whose `test` blocks the gate runs. `root` is the program's source file and
/// `needs_loop` says whether it drives a rotor loop, which decides the imports it is given.
const Tested = struct {
    name: []const u8,
    root: []const u8,
    needs_loop: bool,
    /// True when its tests read the committed echo baseline, which they get as `echo_baseline`.
    reads_baseline: bool = false,
};

/// Every bench program that holds tests. A program missing from this list keeps its tests and
/// never runs them, which is the failure this list exists to stop, so a new one is added here
/// with its first test.
const tested = [_]Tested{
    .{
        .name = "bench-costs-tests",
        .root = "bench/costs/main.zig",
        .needs_loop = false,
    },
    .{
        .name = "bench-post-tests",
        .root = "bench/crosscore/rotor_post.zig",
        .needs_loop = true,
    },
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
        .name = "bench-std-io-timers-tests",
        .root = "bench/alternatives/std_io_timers.zig",
        .needs_loop = false,
    },
    .{
        .name = "bench-reads-runner-tests",
        .root = "bench/files/reads_runner.zig",
        .needs_loop = false,
    },
    .{
        .name = "bench-reads-pool-tests",
        .root = "bench/files/reads_pool.zig",
        .needs_loop = true,
    },
    .{
        .name = "bench-storm-tests",
        .root = "bench/echo/storm.zig",
        .needs_loop = true,
    },
    // `rotor_echo.zig` is at its 500 lines, so its tests live beside it. The file imports the
    // server, which imports `rotor_echo_pieces.zig`, so this runs that file's tests too.
    .{
        .name = "bench-rotor-echo-tests",
        .root = "bench/echo/rotor_echo_test.zig",
        .needs_loop = true,
    },
    .{
        .name = "bench-rotor-reads-tests",
        .root = "bench/files/rotor_reads.zig",
        .needs_loop = true,
    },
    .{
        .name = "bench-rotor-timers-tests",
        .root = "bench/timers/rotor_timers.zig",
        .needs_loop = true,
    },
    // No `main` of its own: it is the client inside `echo_runner`, and its tests run because it
    // is named here. The guard below requires a program with a `main`; naming one without is how
    // a file like this is covered.
    .{
        .name = "bench-echo-client-tests",
        .root = "bench/echo/client.zig",
        .needs_loop = true,
    },
    .{
        .name = "bench-calls-gate-tests",
        .root = "bench/calls/calls_gate.zig",
        .needs_loop = false,
    },
    .{
        .name = "bench-echo-runner-tests",
        .root = "bench/echo/echo_runner_setup.zig",
        .needs_loop = true,
        .reads_baseline = true,
    },
};

/// The most bytes of one bench program `require_every_test_runs` reads. The longest is under
/// 40,000; this is room to spare.
const program_bytes_max = 1 << 18;

/// Refuses a bench program that holds a `test` block and is missing from `tested`, whose tests
/// would then never run. The list above cannot notice its own gap, and no test in the tree can:
/// a program taken off it simply stops being tested, which happened to
/// `bench/timers/rotor_timers.zig` and was found by hand on 2026-09-22. This runs at configure
/// time, so the build fails rather than a later reading of a passing summary.
///
/// A program is a file under `bench/` with a `main`. A file without one belongs to a module whose
/// own step runs its tests (`bench/harness`, the cost probes), and a program whose tests live in a
/// `_test.zig` beside it is listed here all the same.
fn require_every_test_runs(b: *std.Build) void {
    const io = b.graph.io;
    const root = b.build_root.handle;
    var directory = root.openDir(io, "bench", .{ .iterate = true }) catch return;
    defer directory.close(io);
    var walker = directory.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch return) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = b.fmt("bench/{s}", .{entry.path});
        const source = root.readFileAlloc(io, path, b.allocator, .limited(program_bytes_max)) catch
            continue;
        if (untested_program(path, source)) {
            std.debug.panic("build/bench.zig: {s} holds tests and is not in `tested`", .{path});
        }
    }
}

/// True for a program with a `main` and a `test` block that `tested` does not name.
fn untested_program(path: []const u8, source: []const u8) bool {
    if (std.mem.indexOf(u8, source, "\npub fn main(") == null) return false;
    if (std.mem.indexOf(u8, source, "\ntest \"") == null) return false;
    for (tested) |entry| {
        if (std.mem.eql(u8, entry.root, path)) return false;
    }
    return true;
}

/// Runs the `test` blocks inside the bench programs. They are executables, so `zig build test`
/// compiled them and ran none of their tests; every one of them was decoration until this step.
fn add_program_tests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    graph: modules.Modules,
) *std.Build.Step {
    const backend = if (target.result.os.tag == .linux) graph.uring else graph.kqueue;
    require_every_test_runs(b);
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
        if (program.reads_baseline) module.addAnonymousImport("echo_baseline", .{
            .root_source_file = b.path("bench/baseline/echo.txt"),
        });
        const tests = b.addTest(.{ .name = program.name, .root_module = module });
        step.dependOn(&b.addRunArtifact(tests).step);
    }
    return step;
}

/// One bench program: the name it installs as, its source, and what it imports beside `std`.
const Program = struct {
    name: []const u8,
    root: []const u8,
    /// `core` and the host's backend, for a program that drives a rotor loop.
    needs_loop: bool,
    /// The harness, for placement, the clock and the result line a self-timed candidate prints.
    needs_harness: bool,
    /// Installed by `bench-crosscore` as well as by `bench-echo`.
    crosscore: bool = false,
    /// Built against the epoll backend in place of the host's, and only on a Linux host.
    epoll: bool = false,
};

/// Every program `bench-echo` installs. Each is its own executable, as bench/alternatives' are, so
/// a runner starts a candidate, measures it and stops it.
const programs = [_]Program{
    // `std_io_echo` and `std_io_timers` are alternatives that need no pinned package, because
    // `std.Io` is the compiler's own, so they are built here and not by build/alternatives.zig.
    .{
        .name = "std_io_echo",
        .root = "bench/alternatives/std_io_echo.zig",
        .needs_loop = false,
        .needs_harness = false,
    },
    .{
        .name = "std_io_timers",
        .root = "bench/alternatives/std_io_timers.zig",
        .needs_loop = false,
        .needs_harness = true,
    },
    // Timer churn: each candidate measures itself, because a timer has no client to measure it
    // from, and the runner starts the programs and reads the result lines they print.
    .{
        .name = "rotor_timers",
        .root = "bench/timers/rotor_timers.zig",
        .needs_loop = true,
        .needs_harness = true,
    },
    .{
        .name = "timers_runner",
        .root = "bench/timers/timers_runner.zig",
        .needs_loop = false,
        .needs_harness = true,
    },
    // The datagram round trip measures itself too: its client and server are two sockets on one
    // loop.
    .{
        .name = "rotor_datagram",
        .root = "bench/datagram/rotor_datagram.zig",
        .needs_loop = true,
        .needs_harness = true,
    },
    // The O_DIRECT reads, the only program that registers a buffer, and their runner.
    .{
        .name = "rotor_reads",
        .root = "bench/files/rotor_reads.zig",
        .needs_loop = true,
        .needs_harness = true,
    },
    .{
        .name = "reads_runner",
        .root = "bench/files/reads_runner.zig",
        .needs_loop = false,
        .needs_harness = true,
    },
    // Decision 4's main claim, one cross-core message at a time, with a step of its own because
    // its runner drives the pinned alternatives too and a caller may want only this one.
    .{
        .name = "rotor_post",
        .root = "bench/crosscore/rotor_post.zig",
        .needs_loop = true,
        .needs_harness = true,
        .crosscore = true,
    },
    .{
        .name = "crosscore_runner",
        .root = "bench/crosscore/crosscore_runner.zig",
        .needs_loop = false,
        .needs_harness = true,
        .crosscore = true,
    },
    // The echo workload. Every echo program gets the harness, because placement lives there.
    .{
        .name = "rotor_echo",
        .root = "bench/echo/rotor_echo.zig",
        .needs_loop = true,
        .needs_harness = true,
    },
    .{
        .name = "echo_client",
        .root = "bench/echo/echo_client.zig",
        .needs_loop = true,
        .needs_harness = true,
    },
    .{
        .name = "echo_runner",
        .root = "bench/echo/echo_runner.zig",
        .needs_loop = true,
        .needs_harness = true,
    },
    // The echo server on epoll, which `bench/calls/count_calls.sh` counts as `rotor_epoll`, and
    // the gate CI holds rotor's counts per echo to `bench/baseline/calls.txt` with.
    .{
        .name = "rotor_epoll",
        .root = "bench/echo/rotor_echo.zig",
        .needs_loop = true,
        .needs_harness = true,
        .epoll = true,
    },
    .{
        .name = "calls_gate",
        .root = "bench/calls/calls_gate.zig",
        .needs_loop = false,
        .needs_harness = false,
    },
};

/// The programs the echo smoke runs: the runner, which holds the client, and rotor's server.
const smoke_programs = [_][]const u8{ "echo_runner", "rotor_echo" };

/// The programs of `programs`, built against the backend this host can run, as the conformance
/// suite's are, installed by the `bench-echo` step. Each program is two compile steps over one
/// module. The installed one is a full ReleaseSafe build. The one `check` depends on is a compile
/// whose binary nothing reads, so Zig analyses every function and emits no binary: that proves the
/// program compiles at a fraction of the cost, which is all `zig build test` asks of most of them.
/// `smoke` depends on the installs of the programs the echo smoke runs.
fn add_echo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    graph: modules.Modules,
    check: *std.Build.Step,
    smoke: *std.Build.Step,
) void {
    const echo = b.step("bench-echo", "Build the echo servers and the echo client");
    const crosscore = b.step("bench-crosscore", "Build the cross-core message programs");
    echo.dependOn(crosscore);
    const harness_module = b.createModule(.{
        .root_source_file = b.path("bench/harness/harness.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    for (programs) |program| {
        const module = program_module(b, target, graph, harness_module, program) orelse continue;
        const install = &b.addInstallArtifact(
            b.addExecutable(.{ .name = program.name, .root_module = module }),
            .{},
        ).step;
        (if (program.crosscore) crosscore else echo).dependOn(install);
        if (is_smoke_program(program.name)) smoke.dependOn(install);
        check.dependOn(&b.addExecutable(.{ .name = program.name, .root_module = module }).step);
    }
}

/// The module of one program of `programs`, or null for one this host does not build: an epoll
/// program off Linux.
fn program_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    graph: modules.Modules,
    harness_module: *std.Build.Module,
    program: Program,
) ?*std.Build.Module {
    const linux = target.result.os.tag == .linux;
    if (program.epoll and !linux) return null;
    const module = b.createModule(.{
        .root_source_file = b.path(program.root),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    if (program.needs_loop) {
        const host_backend = if (linux) graph.uring else graph.kqueue;
        module.addImport("core", graph.core);
        module.addImport("backend", if (program.epoll) graph.epoll else host_backend);
    }
    if (program.needs_harness) module.addImport("harness", harness_module);
    return module;
}

fn is_smoke_program(name: []const u8) bool {
    for (smoke_programs) |smoke| {
        if (std.mem.eql(u8, smoke, name)) return true;
    }
    return false;
}

/// Milestone 4's gate. One short run of the echo workload against rotor's server: three rounds of
/// a second each, four connections, a small payload. It names rotor alone with `--candidates`, so
/// it never needs `zig build bench-alternatives`, and it fails when a server cannot be started,
/// when a candidate stalls, or when too few runs come back to make a row.
///
/// It is short, and it is not a measurement: `zig build test` runs on a machine doing other
/// things, and docs/costs.md says what a number needs.
fn add_echo_smoke(b: *std.Build) struct { run: *std.Build.Step, step: *std.Build.Step } {
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
    // It starts a server and binds a port, so a cached result would say nothing.
    run.has_side_effects = true;
    const step = b.step("test-bench-echo", "Run the echo workload against rotor, briefly");
    step.dependOn(&run.step);
    return .{ .run = &run.step, .step = step };
}
