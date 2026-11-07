//! A watch thread calls a writer call of the heartbeat it was handed.
//! `zig build test-compile-fail` requires this file to fail to compile: `Loop.heartbeat` returns a
//! view that declares only `watch` (decision 1, amendment of 2026-11-07).
const rotor = @import("rotor");

fn watcher(heartbeat: *rotor.Heartbeat) void {
    heartbeat.note_asleep();
}

test "a watch thread writes the heartbeat it was handed" {
    _ = &watcher;
}
