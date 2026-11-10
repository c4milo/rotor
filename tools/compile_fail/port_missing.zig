//! A backend's `Loop` that lacks a name of the port of decision 33.
//! `zig build test-compile-fail` requires this file to fail to compile with the message of
//! `core.surface.check_port`, which names the first name that the type lacks.
const core = @import("core");

/// A loop with the first name of the port and none of the others.
const Loop = struct {
    pub fn tick_backend() void {}
};

test "a backend's loop lacks a name of the port" {
    comptime core.surface.check_port(Loop);
}
