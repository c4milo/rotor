//! A program queues a task on a plain loop. `zig build test-compile-fail` requires this file to fail
//! to compile: the tasks are the reactor's, and a plain `rotor.Loop` declares none of its calls
//! (decision 33). The compiler names the call.
const rotor = @import("rotor");

fn program(loop: *rotor.Loop, task: *rotor.Task) void {
    loop.schedule_in(.default, task) catch {};
}

test "a program queues a task on a plain loop" {
    _ = &program;
}
