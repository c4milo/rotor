//! `zig build test-compile-fail`: proves that a library cannot tick, drain, end or cancel
//! everything on a loop it shares (decision 28), and cannot name a buffer group by a literal or
//! answer a poller with a `bool` (decision 29). It also proves that a caller cannot make a call of
//! decision 1's amendment of 2026-11-07 in its old shape, and that a library cannot schedule with
//! no group or set the groups, nor a program declare a named group that `Named` refuses
//! (decision 30), nor a cross-core call take the wrong types or a group of one loop (decision 32).
//! Each file of `tools/compile_fail/` makes
//! one such call, and its compile must fail with the message that states the rule or names the
//! type. A compile that succeeds, or that fails with another message, fails the step.
//! `zig build test` depends on it.
const std = @import("std");
const modules = @import("modules.zig");

/// One file that must not compile, and the end of the error line its compile must print. A
/// `program` is the root of its own executable, so the public module reads the file's
/// `rotor_scheduling_groups` (decision 30). The others are tests, whose root is Zig's test runner.
const Case = struct { file: []const u8, message: []const u8, program: bool = false };

/// One case for each name of `core.shared_loop.refused_calls`, with the message of its declaration
/// in `src/core/shared_loop.zig`, then the two types of decision 29, with the compiler's message.
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
    // Decision 29: the types of a group id and of a poller's answer.
    .{
        .file = "release_buffers",
        .message = "expected type 'buffer_group.BufferGroup', found 'comptime_int'",
    },
    .{
        .file = "poller",
        .message = "expected type 'fn (*poller.Library) dispatch.dispatch_callbacks.WaitLimit', " ++
            "found 'fn (*poller.Library) bool'",
    },
    // Decision 1, amendment of 2026-11-07: the public calls that changed their shape.
    .{ .file = "accept_flag", .message = "expected 2 argument(s), found 3" },
    .{
        .file = "heartbeat_writer",
        .message = "no field or member function named 'note_asleep' in 'stall_watch.HeartbeatView'",
    },
    .{
        .file = "next_generation",
        .message = "struct 'handle.Handle' has no member named 'next_generation'",
    },
    // Zig 0.16 prints both types as `T` in this message.
    .{ .file = "options_by_value", .message = "expected type '*const T', found 'T'" },
    // Decision 30: the refused calls of the groups, the type of a group id, the cost of a task,
    // and the program's declaration of its named groups.
    .{ .file = "schedule", .message = "a library names its group: schedule_in(group, task) (decision 30)" },
    .{
        .file = "reserve_scheduling_group",
        .message = "only the program sets the groups and their shares (decision 30)",
    },
    .{
        .file = "set_scheduling_group_shares",
        .message = "only the program sets the groups and their shares (decision 30)",
    },
    .{
        .file = "scheduling_group_literal",
        .message = "expected type 'scheduling.scheduling.SchedulingGroup', found 'comptime_int'",
    },
    .{ .file = "task_cost_zero", .message = "a task costs at least 1 unit" },
    .{ .file = "task_cost_above", .message = "a task costs at most task_charge_max units" },
    .{
        .file = "named_undeclared",
        .message = "enum 'meta.FieldEnum(named_undeclared.Declared)' has no member named 'dns'",
        .program = true,
    },
    .{
        .file = "named_default",
        .message = "the name 'default' is the group every loop has: name the group otherwise",
        .program = true,
    },
    .{
        .file = "named_shares_zero",
        .message = "the shares of the named group 'quic' are not in 1 to scheduling_shares_max",
        .program = true,
    },
    .{
        .file = "named_shares_above",
        .message = "the shares of the named group 'quic' are not in 1 to scheduling_shares_max",
        .program = true,
    },
    .{
        .file = "named_too_many",
        .message = "a program declares at most scheduling_groups_max - 1 named groups",
        .program = true,
    },
    // Decision 32: the types of a cross-core call. Zig 0.16 prints the generic types of a function
    // as `T` and `U` in these messages.
    .{
        .file = "call_handler_void",
        .message = "expected type 'fn (T, U) call.call.Answer(u64)', found 'fn (T, U) void'",
    },
    .{
        .file = "call_now_no_reply",
        .message = "coercion from enum '@typeInfo(call.call.Answer(u64)).@\"union\".tag_type.?' " ++
            "to union 'call.call.Answer(u64)' must initialize 'u64' field 'now'",
    },
    .{
        .file = "call_finish_type",
        .message = "expected type 'fn (T, call.call.CallResult(u64)) void', " ++
            "found 'fn (T, call.call.CallResult(u32)) void'",
    },
    .{
        .file = "call_from_remote",
        .message = "expected type '*shared_loop.SharedLoop(rotor_loop.Loop)', found '*rotor_loop.Remote'",
    },
    .{ .file = "call_no_group", .message = "missing struct field: group" },
    .{
        .file = "call_scheduling_group",
        .message = "expected type 'scheduling.scheduling.NamedSchedulingGroup', " ++
            "found 'scheduling.scheduling.SchedulingGroup'",
    },
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
        const compile = if (case.program)
            b.addExecutable(.{ .name = case.file, .root_module = module })
        else
            b.addTest(.{ .name = case.file, .root_module = module });
        compile.expect_errors = .{ .contains = b.fmt("error: {s}", .{case.message}) };
        step.dependOn(&compile.step);
    }
    return step;
}
