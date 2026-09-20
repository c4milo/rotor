//! `zig build bench-competitors`: fetch the pinned libuv and libxev, build each from its source,
//! and install one echo server and one size probe per competitor under zig-out/bin. build.zig
//! stays short (CLAUDE.md, Layout), so the wiring is in this file. bench/competitors/README.md
//! holds the pins.
//!
//! Both competitors are lazy packages in build.zig.zon, and Zig fetches a lazy package when the
//! build script calls `lazyDependency` for it. The build script runs the same way for every step,
//! and nothing tells it which step was asked for. So this file calls `lazyDependency` only under
//! the build option `-Dcompetitors`, and `zig build bench-competitors` without that option runs
//! `zig build bench-competitors -Dcompetitors` as a child process. The result: `zig build test`
//! never downloads or compiles a competitor, and a project that depends on rotor never reaches
//! this file at all. bench/competitors/README.md records the experiment, and what Zig does with a
//! package its global cache already holds.
//!
//! A competitor is built the way its own users ship it, optimized and with its assertions
//! compiled out, so that no result of the harness comes from a handicapped build.
const std = @import("std");

/// The mode every competitor is built in, which is the mode that favours them. libxev builds its
/// own benchmarks ReleaseFast (its build.zig, line 213). Under ReleaseFast Zig compiles C with
/// NDEBUG defined, which removes libuv's asserts. rotor itself ships ReleaseSafe.
const competitor_optimize: std.builtin.OptimizeMode = .ReleaseFast;

/// What `uv_cflags` and the C standard settings of libuv's CMakeLists.txt amount to for clang:
/// lines 20 to 23 select C11 with GNU extensions, line 168 adds `-fno-strict-aliasing`.
const libuv_flags = [_][]const u8{ "-std=gnu11", "-fno-strict-aliasing" };

/// The flags of rotor's own C programs under bench/competitors: libuv's, because `uv.h` names
/// POSIX types that glibc hides under a strict `-std=c11`, plus every warning as an error.
const libuv_program_flags = libuv_flags ++ [_][]const u8{ "-Wall", "-Wextra", "-Werror" };

/// libuv's sources for every target: `uv_sources`, CMakeLists.txt lines 175 to 187.
const libuv_common_sources = [_][]const u8{
    "src/fs-poll.c",
    "src/idna.c",
    "src/inet.c",
    "src/random.c",
    "src/strscpy.c",
    "src/strtok.c",
    "src/thread-common.c",
    "src/threadpool.c",
    "src/timer.c",
    "src/uv-common.c",
    "src/uv-data-getter-setters.c",
    "src/version.c",
};

/// libuv's sources for every Unix target: CMakeLists.txt lines 237 to 255.
const libuv_unix_sources = [_][]const u8{
    "src/unix/async.c",
    "src/unix/core.c",
    "src/unix/dl.c",
    "src/unix/fs.c",
    "src/unix/getaddrinfo.c",
    "src/unix/getnameinfo.c",
    "src/unix/loop-watcher.c",
    "src/unix/loop.c",
    "src/unix/pipe.c",
    "src/unix/poll.c",
    "src/unix/process.c",
    "src/unix/random-devurandom.c",
    "src/unix/signal.c",
    "src/unix/stream.c",
    "src/unix/tcp.c",
    "src/unix/thread.c",
    "src/unix/tty.c",
    "src/unix/udp.c",
};

/// What libuv adds on macOS: CMakeLists.txt lines 283 to 312.
const libuv_macos_sources = [_][]const u8{
    "src/unix/proctitle.c",
    "src/unix/bsd-ifaddrs.c",
    "src/unix/kqueue.c",
    "src/unix/random-getentropy.c",
    "src/unix/darwin-proctitle.c",
    "src/unix/darwin.c",
    "src/unix/fsevents.c",
};

/// What libuv adds on Linux: CMakeLists.txt lines 283, 284 and 327 to 334.
const libuv_linux_sources = [_][]const u8{
    "src/unix/proctitle.c",
    "src/unix/linux.c",
    "src/unix/procfs-exepath.c",
    "src/unix/random-getrandom.c",
    "src/unix/random-sysctl-linux.c",
};

/// One C preprocessor definition of libuv's `uv_defines`.
const Define = struct { name: []const u8, value: []const u8 };

/// Every Unix target: CMakeLists.txt line 230.
const libuv_unix_defines = [_]Define{
    .{ .name = "_FILE_OFFSET_BITS", .value = "64" },
    .{ .name = "_LARGEFILE_SOURCE", .value = "1" },
};

/// macOS: CMakeLists.txt line 308.
const libuv_macos_defines = [_]Define{
    .{ .name = "_DARWIN_UNLIMITED_SELECT", .value = "1" },
    .{ .name = "_DARWIN_USE_64_BIT_INODE", .value = "1" },
};

/// Linux: CMakeLists.txt line 328.
const libuv_linux_defines = [_]Define{
    .{ .name = "_GNU_SOURCE", .value = "1" },
    .{ .name = "_POSIX_C_SOURCE", .value = "200112" },
};

/// What libuv needs beyond its common and Unix parts on one operating system.
const LibuvPlatform = struct {
    sources: []const []const u8,
    defines: []const Define,
};

/// Declares `zig build bench-competitors`. Called only when rotor is the root build.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const requested = b.option(
        bool,
        "competitors",
        "Fetch and build the pinned competitors; `zig build bench-competitors` sets it itself",
    ) orelse false;
    const step = b.step(
        "bench-competitors",
        "Fetch the pinned libuv and libxev; install their echo servers, size probes and timers",
    );
    if (!requested) {
        step.dependOn(add_child_build(b, target));
        return;
    }
    // A null means the package is not fetched yet. Zig fetches what this script asked for when
    // the script returns, and runs it again, so returning early loses nothing. Both are asked
    // for before either null returns, so one pass fetches both.
    const maybe_libuv = b.lazyDependency("libuv", .{});
    const maybe_libxev = b.lazyDependency("libxev", .{});
    const libuv = maybe_libuv orelse return;
    const libxev = maybe_libxev orelse return;
    const programs: Programs = .{ .b = b, .target = target, .libuv = libuv, .libxev = libxev };
    // The size probe calls nothing in libuv, so it needs the headers and not the library.
    step.dependOn(programs.add_c("libuv_echo", add_libuv(b, target, libuv)));
    step.dependOn(programs.add_c("libuv_sizes", null));
    step.dependOn(programs.add_c("libuv_timers", add_libuv(b, target, libuv)));
    step.dependOn(programs.add_c("libuv_async", add_libuv(b, target, libuv)));
    step.dependOn(programs.add_zig("libxev_echo", false));
    step.dependOn(programs.add_zig("libxev_sizes", false));
    step.dependOn(programs.add_zig("libxev_async", true));
    step.dependOn(programs.add_zig("libxev_timers", true));
}

/// `zig build bench-competitors -Dcompetitors`, run from the build root for the same target.
fn add_child_build(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const child = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "bench-competitors",
        "-Dcompetitors",
        b.fmt("-Dtarget={s}", .{triple}),
    });
    child.setCwd(b.path(""));
    // The child installs files this step does not declare, so the cache cannot skip it.
    child.has_side_effects = true;
    return &child.step;
}

/// The libuv sources and definitions for `target`, or a panic naming the target: the harness
/// runs on Linux and macOS, the two systems rotor has a backend for (decision 2).
fn libuv_platform(target: std.Build.ResolvedTarget) LibuvPlatform {
    return switch (target.result.os.tag) {
        .macos => .{ .sources = &libuv_macos_sources, .defines = &libuv_macos_defines },
        .linux => .{ .sources = &libuv_linux_sources, .defines = &libuv_linux_defines },
        else => |tag| std.debug.panic("no libuv source list for {s}", .{@tagName(tag)}),
    };
}

/// libuv as a static library, compiled by Zig's C compiler from the pinned source.
fn add_libuv(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    libuv: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const platform = libuv_platform(target);
    const module = b.createModule(.{
        .target = target,
        .optimize = competitor_optimize,
        .link_libc = true,
    });
    module.addIncludePath(libuv.path("include"));
    module.addIncludePath(libuv.path("src"));
    for (libuv_unix_defines) |define| module.addCMacro(define.name, define.value);
    for (platform.defines) |define| module.addCMacro(define.name, define.value);
    const source_lists = [_][]const []const u8{
        &libuv_common_sources,
        &libuv_unix_sources,
        platform.sources,
    };
    const root = libuv.path("");
    for (source_lists) |sources| {
        module.addCSourceFiles(.{ .root = root, .files = sources, .flags = &libuv_flags });
    }
    return b.addLibrary(.{ .name = "uv", .linkage = .static, .root_module = module });
}

/// What every program of bench/competitors is built from. A program is one source file named
/// after it, and it is installed under that name.
const Programs = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    libuv: *std.Build.Dependency,
    libxev: *std.Build.Dependency,

    /// bench/competitors/`name`.c, compiled against the pinned libuv's headers and linked against
    /// `library` when the program calls into libuv.
    fn add_c(
        programs: Programs,
        name: []const u8,
        library: ?*std.Build.Step.Compile,
    ) *std.Build.Step {
        const b = programs.b;
        const module = b.createModule(.{
            .target = programs.target,
            .optimize = competitor_optimize,
            .link_libc = true,
        });
        module.addIncludePath(programs.libuv.path("include"));
        module.addCSourceFiles(.{
            .files = &.{b.fmt("bench/competitors/{s}.c", .{name})},
            .flags = &libuv_program_flags,
        });
        if (library) |linked| module.linkLibrary(linked);
        const program = b.addExecutable(.{ .name = name, .root_module = module });
        return &b.addInstallArtifact(program, .{}).step;
    }

    /// bench/competitors/`name`.zig, which imports the pinned libxev as `xev`.
    /// bench/competitors/`name`.zig, which imports the pinned libxev as `xev`. `wants_harness`
    /// adds the harness too, for a program that prints a result line: the line's format belongs
    /// to bench/harness/report.zig, and a candidate that hand-wrote it would be a second copy of
    /// a format only a round-trip test in that file pins.
    fn add_zig(programs: Programs, name: []const u8, wants_harness: bool) *std.Build.Step {
        const b = programs.b;
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("bench/competitors/{s}.zig", .{name})),
            .target = programs.target,
            .optimize = competitor_optimize,
        });
        module.addImport("xev", programs.libxev.module("xev"));
        if (wants_harness) module.addImport("harness", b.createModule(.{
            .root_source_file = b.path("bench/harness/harness.zig"),
            .target = programs.target,
            .optimize = competitor_optimize,
        }));
        const program = b.addExecutable(.{ .name = name, .root_module = module });
        return &b.addInstallArtifact(program, .{}).step;
    }
};
