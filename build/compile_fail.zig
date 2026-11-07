//! `zig build test-compile-fail`: proves that a library cannot tick, drain, end or cancel
//! everything on a loop it shares (decision 28). Each file of `tools/compile_fail/` calls one
//! refused call of `rotor.SharedLoop`, and its compile must fail with the message that states the
//! rule. A compile that succeeds, or that fails with another message, fails the step. `zig build
//! test` depends on it.
const std = @import("std");
const modules = @import("modules.zig");

/// One file that must not compile, and the end of the error line its compile must print.
const Case = struct { file: []const u8, message: []const u8 };

/// One case for each name of `core.shared_loop.refused_calls`, with the message of its declaration
/// in `src/core/shared_loop.zig`.
pub const cases = [_]Case{
    .{
        .file = "tick",
        .message = "a library never ticks a shared loop: finish the work in a record, a poller " ++
            "or a task (decision 27, ruling 1)",
    },
    .{ .file = "drain", .message = "only the program drains a shared loop" },
    .{ .file = "deinit", .message = "only the program ends a shared loop" },
    .{ .file = "cancel_all", .message = "cancel_all cancels every library's operations" },
    .{ .file = "discard_tasks", .message = "only the program discards the task queue" },
};

/// Adds `zig build test-compile-fail` and returns it for `zig build test` to depend on.
pub fn add(
    b: *std.Build,
    graph: modules.Modules,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const step = b.step(
        "test-compile-fail",
        "Require each refused call of SharedLoop to fail to compile with its message",
    );
    for (cases) |case| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/compile_fail/{s}.zig", .{case.file})),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("rotor", graph.rotor);
        const compile = b.addTest(.{ .name = case.file, .root_module = module });
        compile.expect_errors = .{ .contains = b.fmt("error: {s}", .{case.message}) };
        step.dependOn(&compile.step);
    }
    return step;
}
