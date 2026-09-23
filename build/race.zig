//! `zig build test-race`: builds the test executables of the modules that run two threads, with
//! ThreadSanitizer, for Linux, and installs them under zig-out/race/. It runs none of them:
//! tools/race_test.sh runs them in Docker.
//!
//! Why a step of its own, beside `test-linux`. rotor's loops are shared-nothing (decision 4), so
//! the only memory two threads touch is the mailbox rings and the sleep flag of decision 12,
//! point 6, and the registry both backends share. Those are a handful of atomics, and an
//! argument about their ordering is the kind of argument a test cannot settle by passing.
//! ThreadSanitizer settles part of it: it reports a race the run actually performed.
//!
//! What it does not settle: it sees the interleavings that happened, not every interleaving that
//! could. A lost wakeup that needs a rare order is not ruled out by a clean run. That is what the
//! handshake's own test is for, and it is why this step is evidence and not a proof.
//!
//! The target differs from `test-linux`'s. ThreadSanitizer needs a dynamic glibc, so these
//! executables are `-gnu` and not static musl, and they run in a glibc image. It cannot be built
//! on macOS at all: the sanitizer's runtime needs a libcxx that does not compile against this
//! SDK, which is why the step targets Linux even when the module under test is the macOS backend.
//! The kqueue module compiles for Linux and its kernel-free tests, the mailbox's among them, run
//! there; the rest skip.
const std = @import("std");
const modules = @import("modules.zig");

/// The directory the step fills and tools/race_test.sh reads, under the install prefix.
const install_directory = "race";

/// The file that lists the installed executables, one name per line, in run order.
const manifest_name = "tests.manifest";

/// The file the step touches last, which says when this install finished.
const stamp_name = ".test-race-stamp";

/// The steps this file adds. `compile` checks that the sanitized suites compile for Linux, and
/// emits no binary, so `zig build test` can require it without writing to zig-out, needing Docker,
/// or paying for code generation, the link and the sanitizer's runtime.
pub const Steps = struct { compile: *std.Build.Step };

pub fn add(b: *std.Build) Steps {
    const target = race_target(b);
    const graph = modules.add(b, target, .Debug);

    // One line per module whose tests start a thread. `core` starts none. `kqueue` holds the
    // threaded tests of the mailbox rings; each conformance suite runs two loops on two threads over
    // the registry, and the offload's workers beside a loop. `conformance-epoll` is the only one of
    // those whose loops use the rings: io_uring carries a post in the kernel.
    const suites = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "kqueue", .module = graph.kqueue },
        .{ .name = "conformance-uring", .module = graph.conformance_uring },
        .{ .name = "conformance-epoll", .module = graph.conformance_epoll },
    };

    const stamp = b.addSystemCommand(&.{"touch"});
    stamp.addArg(b.pathJoin(&.{ b.install_path, install_directory, stamp_name }));
    stamp.has_side_effects = true;

    const compile_all = b.step(
        "test-race-compile",
        "Check that the ThreadSanitizer suites compile for Linux, and emit no binary",
    );

    var manifest: []const u8 = "";
    for (suites) |suite| {
        suite.module.sanitize_thread = true;
        // The sanitizer's runtime is C, and it needs libc linked.
        suite.module.link_libc = true;
        const tests = b.addTest(.{ .name = suite.name, .root_module = suite.module });
        // A second compile of the same module whose binary nothing reads, so it emits none. It is
        // enough to catch a symbol that exists on Darwin alone, which is why the compile is here.
        compile_all.dependOn(&b.addTest(.{ .name = suite.name, .root_module = suite.module }).step);
        const installed = b.addInstallArtifact(tests, .{
            .dest_dir = .{ .override = .{ .custom = install_directory } },
        });
        stamp.step.dependOn(&installed.step);
        manifest = b.fmt("{s}{s}\n", .{ manifest, suite.name });
    }
    std.debug.assert(manifest.len > 0);

    const manifest_file = b.addWriteFiles().add(manifest_name, manifest);
    const install_manifest = b.addInstallFileWithDir(
        manifest_file,
        .{ .custom = install_directory },
        manifest_name,
    );
    stamp.step.dependOn(&install_manifest.step);

    const step = b.step(
        "test-race",
        "Build the ThreadSanitizer executables for tools/race_test.sh",
    );
    step.dependOn(&stamp.step);
    return .{ .compile = compile_all };
}

/// Linux on the build host's CPU architecture, glibc ABI: ThreadSanitizer's runtime needs it.
fn race_target(b: *std.Build) std.Build.ResolvedTarget {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = b.graph.host.result.cpu.arch,
        .os_tag = .linux,
        .abi = .gnu,
    });
    std.debug.assert(target.result.os.tag == .linux);
    std.debug.assert(target.result.abi == .gnu);
    return target;
}
