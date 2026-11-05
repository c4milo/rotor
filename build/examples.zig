//! The programs under `examples/`, and what shows they work. Each program imports the public module
//! `rotor` the way a dependent package does, so it can use nothing a consumer cannot. `zig build
//! test` depends on `zig build examples-check`, which:
//!
//!   - builds each program and runs it: against its checker when it has one, which talks to it as a
//!     client, and on its own otherwise, which must exit 0;
//!   - builds `examples/consumer`, a project of its own whose `build.zig` holds the README's two
//!     lines, with a nested `zig build`, and runs the echo checker on what it built;
//!   - requires every Zig block of the README and the guide to be an excerpt of a file here
//!     (`tools/readme_examples.zig`).
//!
//! So a page cannot show code that stopped compiling, stopped working, or no longer matches the
//! program that runs. The Linux gate runs the same programs on io_uring and on epoll
//! (`build/linux.zig`). `zig build examples` installs them.
const std = @import("std");
const modules = @import("modules.zig");

/// One example program: its name, its root file, and the program that checks it works, or null for
/// a program that checks itself and exits 0 only when every step did what it should.
pub const Program = struct { name: []const u8, root: []const u8, checker: ?[]const u8 };

pub const programs = [_]Program{
    .{ .name = "echo", .root = "examples/echo.zig", .checker = "tools/echo_check.zig" },
    .{ .name = "guide", .root = "examples/guide.zig", .checker = null },
};

/// The Zig sources under `examples/`, which the lint and the format check read. They are named file by
/// file and the directory is not walked: a build of `examples/consumer` leaves the packages it
/// fetched in `examples/consumer/zig-pkg/`, and those are not rotor's to lint.
pub const sources = [_][]const u8{
    "examples/echo.zig",
    "examples/guide.zig",
    "examples/consumer/build.zig",
};

/// Every file `tools/readme_examples.zig` reads: the pages and the programs they excerpt.
const excerpted_files = [_][]const u8{
    "README.md",
    "docs/using.md",
    "examples/echo.zig",
    "examples/guide.zig",
    "examples/consumer/build.zig",
};

/// Adds `zig build examples` and `zig build examples-check`, and returns the second for `zig build
/// test` to depend on.
pub fn add(
    b: *std.Build,
    graph: modules.Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const install = b.step("examples", "Build and install the example programs");
    const check = b.step("examples-check", "Build each example and check that it works");
    for (programs) |program| {
        const executable = example(b, graph, target, optimize, program.name, program.root);
        install.dependOn(&b.addInstallArtifact(executable, .{}).step);
        const run = if (program.checker) |root| with_checker: {
            const run = b.addRunArtifact(checker(b, target, program.name, root));
            run.addArtifactArg(executable);
            break :with_checker run;
        } else b.addRunArtifact(executable);
        // It opens sockets, and a cached result would say nothing about the program as it is now.
        run.has_side_effects = true;
        check.dependOn(&run.step);
    }
    check.dependOn(add_consumer(b, target));
    check.dependOn(add_excerpts(b));
    return check;
}

/// The README's quick start, followed as a person would: `examples/consumer` depends on this tree
/// and builds `examples/echo.zig`, and the echo checker runs on what it built. The nested build
/// reads the tree through its dependency, which this build does not track, so it runs every time.
fn add_consumer(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const build = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--build-file" });
    build.addFileArg(b.path("examples/consumer/build.zig"));
    build.addArg("--cache-dir");
    _ = build.addOutputDirectoryArg("consumer-cache");
    build.addArg("--prefix");
    const prefix = build.addOutputDirectoryArg("consumer");
    build.addPrefixedFileArg("-Dprogram=", b.path("examples/echo.zig"));
    build.has_side_effects = true;
    const run = b.addRunArtifact(checker(b, target, "consumer_echo", "tools/echo_check.zig"));
    run.addFileArg(prefix.path(b, "bin/echo"));
    run.has_side_effects = true;
    return &run.step;
}

/// The test that holds the README's and the guide's code to the programs here.
fn add_excerpts(b: *std.Build) *std.Build.Step {
    const tests = b.addTest(.{
        .name = "readme_examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/readme_examples.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    for (excerpted_files) |path| {
        tests.root_module.addAnonymousImport(path, .{ .root_source_file = b.path(path) });
    }
    return &b.addRunArtifact(tests).step;
}

/// The program that checks the example `name` works. A tool never ships, so it compiles in Debug.
pub fn checker(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    root: []const u8,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = b.fmt("{s}_check", .{name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = .Debug,
        }),
    });
}

/// One example, compiled against the public module.
pub fn example(
    b: *std.Build,
    graph: modules.Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("rotor", graph.rotor);
    return b.addExecutable(.{ .name = name, .root_module = module });
}
