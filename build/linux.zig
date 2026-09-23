//! `zig build test-linux`: builds every test executable that runs under Linux, the io_uring probe,
//! and the halt check with its Linux-only scenarios, for the container target, and installs them
//! under zig-out/linux/. It runs none of them: tools/linux_test.sh runs them in Docker. build.zig
//! stays short (CLAUDE.md, Layout), so the wiring is in this file.
//!
//! rotor has no simulator. Its uring backend is tested against a real Linux kernel
//! (docs/decisions/0010-no-simulator.md), and the development machine is a Mac, so the tests are
//! built here and run in a container.
//!
//! The container target is Linux on the build host's CPU architecture, so the executables run
//! without emulation in Docker on an Apple silicon Mac and on an x86-64 Linux host alike. The ABI
//! is musl and nothing links libc, so every executable is static and takes nothing from the
//! container's image. The CPU model is the architecture's baseline, so an executable built on one
//! machine runs on any other machine of that architecture.
//!
//! The step writes three files beside the executables, and tools/linux_test.sh reads all three:
//!   - `manifest_name` lists the test executables this build installed, one per line, in the
//!     order they run. The script runs what the manifest lists, so an executable that an earlier
//!     build left behind is never run, and a listed executable that is missing fails the run.
//!   - `halt_manifest_name` does the same for the halt check's scenario executables. Each line
//!     names one, followed by the arguments the check takes after it.
//!   - `stamp_name` is touched last, after every install. The script compares every source
//!     against it and refuses an install older than the tree it is meant to test. The stamp
//!     depends on every install, so it is newer than all of them and older than any source edited
//!     afterwards. One of the executables cannot stand in for it: an install that did not change
//!     keeps its old time, so a fresh build would look stale.
const std = @import("std");
const halt = @import("halt.zig");
const modules = @import("modules.zig");

/// The directory the step fills and tools/linux_test.sh reads, under the install prefix.
const install_directory = "linux";

/// The file the step touches last, which says when this install finished.
const stamp_name = ".test-linux-stamp";

/// The file that lists the installed test executables, one name per line, in run order.
const manifest_name = "tests.manifest";

/// The file that lists the installed halt scenario executables, one per line, in run order, each
/// name followed by the arguments the halt check takes after it. The check itself is not listed:
/// tools/linux_test.sh names it, as it names the probe.
const halt_manifest_name = "halt.manifest";

/// The io_uring probe, which tools/linux_test.sh runs before any test. It is not in the manifest:
/// the script names it, so a build that stops installing it fails the run.
const probe_name = "uring_probe";

/// The probe's entry point, which imports the other uring_probe_*.zig files. tools/linux_test.sh
/// compares every Zig source under tools/ to the stamp, so an edit to the probe counts as stale.
const probe_source = "tools/uring_probe.zig";

/// Adds the `test-linux` step. `optimize` is the mode the unit tests compile in, as it is for
/// `zig build test`, so `-Drelease` checks the ReleaseSafe build under Linux too.
pub fn add(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const target = container_target(b);
    const graph = modules.add(b, target, optimize);

    // One line per module whose tests run under Linux: `uring` joins here when it exists. `kqueue`
    // never does, because its tests need the kernel of a Mac.
    const unit_tests = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "core", .module = graph.core },
        // What both Linux backends share. It needs no io_uring, so it runs confined.
        .{ .name = "linux-shared", .module = graph.linux_shared },
        .{ .name = "uring", .module = graph.uring },
        .{ .name = "conformance-uring", .module = graph.conformance_uring },
        // The second Linux backend (decision 20), and the one suite against it. Both enter the
        // kernel, so they mean nothing until they run against one; `tools/linux_test.sh` runs them
        // **without** `seccomp=unconfined`, because a backend that needed that flag would be
        // pointless.
        .{ .name = "epoll", .module = graph.epoll },
        .{ .name = "conformance-epoll", .module = graph.conformance_epoll },
        // The public module picks `uring` on this target, and its tests drive a loop through it.
        .{ .name = "rotor", .module = graph.rotor },
        // The harness is outside the module graph, and nothing built it for Linux until
        // 2026-09-22: two of its files did not compile there and no gate said so, because every
        // caller of them was a program this gate does not build. Its tests run here now.
        .{ .name = "bench-harness", .module = b.createModule(.{
            .root_source_file = b.path("bench/harness/harness.zig"),
            .target = target,
            .optimize = optimize,
        }) },
    };

    const stamp = b.addSystemCommand(&.{"touch"});
    stamp.addArg(b.pathJoin(&.{ b.install_path, install_directory, stamp_name }));
    // The stamp says when this install finished, so every run rewrites it.
    stamp.has_side_effects = true;

    var manifest: []const u8 = "";
    for (unit_tests) |entry| {
        const tests = b.addTest(.{ .name = entry.name, .root_module = entry.module });
        stamp.step.dependOn(&install(b, tests).step);
        manifest = b.fmt("{s}{s}\n", .{ manifest, entry.name });
    }
    std.debug.assert(manifest.len > 0);

    // The probe is a tool, and a tool never ships, so it compiles in Debug as the other tools do.
    const probe_module = b.createModule(.{
        .root_source_file = b.path(probe_source),
        .target = target,
        .optimize = .Debug,
    });
    // The probe imports the backend so it checks what `Loop.init` demands and not a copy of it.
    // A tool may import the library; the rule is that the library never imports a tool.
    probe_module.addImport("uring", graph.uring);
    const probe = b.addExecutable(.{ .name = probe_name, .root_module = probe_module });
    stamp.step.dependOn(&install(b, probe).step);

    stamp.step.dependOn(install_manifest(b, manifest_name, manifest));
    add_halt(b, graph, target, optimize, stamp);

    const step = b.step(
        "test-linux",
        "Build the Linux test executables, the io_uring probe and the halt check for " ++
            "tools/linux_test.sh",
    );
    step.dependOn(&stamp.step);
}

/// Installs the halt check, the scenario executables it runs, and the manifest that lists them. The
/// scenarios build in `optimize`, as `zig build halt-check` builds them: an assertion must halt in
/// Debug and in ReleaseSafe alike.
fn add_halt(
    b: *std.Build,
    graph: modules.Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    stamp: *std.Build.Step.Run,
) void {
    const built = halt.linux(b, graph, target, optimize);
    stamp.step.dependOn(&install(b, built.check).step);
    var manifest: []const u8 = "";
    for (built.scenarios) |entry| {
        stamp.step.dependOn(&install(b, entry.executable).step);
        var line: []const u8 = entry.executable.name;
        for (entry.arguments) |argument| line = b.fmt("{s} {s}", .{ line, argument });
        manifest = b.fmt("{s}{s}\n", .{ manifest, line });
    }
    stamp.step.dependOn(install_manifest(b, halt_manifest_name, manifest));
}

/// Writes `contents` to `name` in the install directory.
fn install_manifest(b: *std.Build, name: []const u8, contents: []const u8) *std.Build.Step {
    std.debug.assert(contents.len > 0);
    const file = b.addWriteFiles().add(name, contents);
    const installed = b.addInstallFileWithDir(file, .{ .custom = install_directory }, name);
    return &installed.step;
}

/// Linux on the build host's CPU architecture, musl ABI, baseline CPU model.
pub fn container_target(b: *std.Build) std.Build.ResolvedTarget {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = b.graph.host.result.cpu.arch,
        .os_tag = .linux,
        .abi = .musl,
    });
    std.debug.assert(target.result.os.tag == .linux);
    std.debug.assert(target.result.cpu.arch == b.graph.host.result.cpu.arch);
    return target;
}

fn install(b: *std.Build, compile: *std.Build.Step.Compile) *std.Build.Step.InstallArtifact {
    return b.addInstallArtifact(compile, .{
        .dest_dir = .{ .override = .{ .custom = install_directory } },
    });
}
