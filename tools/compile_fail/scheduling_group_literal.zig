//! A library names a scheduling group by a literal id, which could be another library's group.
//! `zig build test-compile-fail` requires this file to fail to compile a call that names a group takes a `rotor.SchedulingGroup`, which only
//! `reserve_scheduling_group` and `NamedSchedulingGroup.scheduling_group` make (decision 30).
const rotor = @import("rotor");

fn library(shared: *rotor.SharedLoop, task: *rotor.Task) void {
    shared.schedule_in(3, task) catch {};
}

test "a library names a scheduling group by a literal" {
    _ = &library;
}
