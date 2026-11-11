//! A twin of decision 10 that lacks three names of the port of decision 33, passed to
//! `rotor.Reactor`. `zig build test-compile-fail` requires this file to fail to compile with the
//! message of the reactor's check, and requires the message to name each of the three.
const rotor = @import("rotor");

/// A line with each call that the reactor makes on it.
const Line = struct {
    pub fn enter() void {}
    pub fn leave() void {}
    pub fn leave_polling() void {}
    pub fn leave_tasks() void {}
    pub fn leave_group_tasks() void {}
    pub fn name_poller() void {}
};

/// Each name of the core's surface, and five names of the port: it lacks `tick_backend`,
/// `stored_limit` and `push_reserved`.
const Twin = struct {
    pub const Options = struct {};
    pub fn memory_bytes() void {}
    pub fn init() void {}
    pub fn deinit() void {}
    pub fn dropped_wakes() void {}
    pub fn submit() void {}
    pub fn cancel() void {}
    pub fn post() void {}
    pub fn tick() void {}
    pub fn heartbeat() void {}
    pub fn in_flight() void {}
    pub fn now_ns() void {}
    pub fn wait_descriptor() void {}
    pub fn statistics() void {}
    pub fn cancel_all() void {}
    pub fn drain() void {}
    pub fn assert_empty() void {}
    pub fn register_buffers() void {}
    pub fn register_descriptors() void {}
    pub fn provide_buffers() void {}
    pub fn provide_datagram_buffers() void {}
    pub fn datagram() void {}
    pub fn give_back_buffer() void {}
    pub fn release_buffers() void {}
    pub fn provided_buffer() void {}
    pub fn reserve_buffer_group() void {}
    pub fn wait_limit() void {}
    pub fn wait_until() void {}

    pub fn take_kept_error() void {}
    pub fn outstanding() void {}
    pub fn heartbeat_line() *Line {
        unreachable;
    }
    pub fn attach_reserved() void {}
    pub fn assert_owner() void {}
};

test "a twin that lacks three names of the port makes no reactor" {
    _ = rotor.Reactor(Twin);
}
