//! A project of its own that depends on rotor the way the README says, with this tree as the
//! dependency. `zig build test` builds it with a nested `zig build` and runs `tools/echo_check.zig`
//! on the program it built, so the README's two `build.zig` lines are shown to work, and not only
//! to parse. By hand:
//!
//!     cd examples/consumer && zig build && ./zig-out/bin/echo
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const program = b.option([]const u8, "program", "The program to build") orelse "../echo.zig";
    const exe = b.addExecutable(.{
        .name = "echo",
        .root_module = b.createModule(.{
            .root_source_file = .{ .cwd_relative = program },
            .target = target,
            .optimize = optimize,
        }),
    });
    const rotor = b.dependency("rotor", .{ .target = target, .release = optimize != .Debug });
    exe.root_module.addImport("rotor", rotor.module("rotor"));
    b.installArtifact(exe);
}
