//! The programs under `examples/`. Each one imports the public module `rotor` the way a dependent
//! package does, so it can use nothing a consumer cannot. `zig build test` compiles them, so an
//! example the README shows cannot drift from the API. `zig build examples` also installs them.
const std = @import("std");
const modules = @import("modules.zig");

/// Every example program, by its name and its root file.
const programs = [_]struct { name: []const u8, root: []const u8 }{
    .{ .name = "echo", .root = "examples/echo.zig" },
};

/// Adds `zig build examples` and returns the step that compiles every example, for `zig build
/// test` to depend on.
pub fn add(
    b: *std.Build,
    graph: modules.Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const install = b.step("examples", "Build and install the example programs");
    const compile = b.step("examples-compile", "Compile the example programs");
    for (programs) |program| {
        const module = b.createModule(.{
            .root_source_file = b.path(program.root),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("rotor", graph.rotor);
        const executable = b.addExecutable(.{ .name = program.name, .root_module = module });
        compile.dependOn(&executable.step);
        install.dependOn(&b.addInstallArtifact(executable, .{}).step);
    }
    return compile;
}
