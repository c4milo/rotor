//! A library declares a task with a cost of 0 units. `zig build test-compile-fail` requires this
//! file to fail to compile with the message of `Task.init_cost` (decision 30).
const rotor = @import("rotor");

const Library = struct {
    task: rotor.Task = .init_cost(Library, "task", run, 0),

    fn run(_: *Library) void {}
};

test "a task of cost 0" {
    const library: Library = .{};
    _ = &library;
}
