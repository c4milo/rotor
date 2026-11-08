//! A library declares a task with a cost above `task_charge_max`. `zig build test-compile-fail` requires this
//! file to fail to compile with the message of `Task.init_cost` (decision 30).
const rotor = @import("rotor");

const Library = struct {
    task: rotor.Task = .init_cost(Library, "task", run, rotor.constants.task_charge_max + 1),

    fn run(_: *Library) void {}
};

test "a task above the most cost" {
    const library: Library = .{};
    _ = &library;
}
