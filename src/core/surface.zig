//! The surface every backend carries (decision 1): `uring`, `kqueue` and `epoll` each export a
//! `Loop` with the declarations named here, so a consumer's build swaps one for another, or for a
//! deterministic twin of its own (decision 10), without a changed line. `check` runs at comptime in
//! each backend's root, so a backend that drops or misspells a declaration fails to compile on
//! every host, whichever kernel it needs. The names of the reactor are the module `reactor`'s, and
//! a loop declares none of them (decision 33).
//!
//! The list holds names and not signatures. A signature that differs fails where a consumer
//! calls it, and the conformance suite calls every one. `check_port` checks the port of decision
//! 33 in the same way, and the conformance suite holds the type of each name of the port.
const std = @import("std");

/// Every public declaration of a backend's `Loop`. Grows with the milestones; a name, once here,
/// stays.
pub const loop_declarations = [_][]const u8{
    "Options",
    "memory_bytes",
    "init",
    "deinit",
    "dropped_wakes",
    "submit",
    "cancel",
    "post",
    "tick",
    "heartbeat",
    "in_flight",
    "now_ns",
    "wait_descriptor",
    "statistics",
    "cancel_all",
    "drain",
    "assert_empty",
    "register_buffers",
    "register_descriptors",
    "provide_buffers",
    "provide_datagram_buffers",
    "datagram",
    "give_back_buffer",
    "release_buffers",
    "provided_buffer",
    "reserve_buffer_group",
    "wait_limit",
    "wait_until",
};

/// Every public declaration of a backend's `Remote`: what a thread that owns no loop holds to
/// post with (decision 4). It is the whole of the surface, because a `Remote` does one thing.
pub const remote_declarations = [_][]const u8{
    "init",
    "deinit",
    "post",
    "dropped_wakes",
};

/// The port of decision 33: what the reactor needs from a backend's `Loop`, and a plain caller must
/// not call. Each backend declares these names, and the public `rotor.Loop` does not. The public
/// module does not export this list. A name joined the list at the step that built its state
/// (decision 33, amendment of 2026-11-10): `attach_reserved` joined it at step 3, with the hook.
pub const port_declarations = [_][]const u8{
    "tick_backend",
    "take_kept_error",
    "outstanding",
    "stored_limit",
    "heartbeat_line",
    "attach_reserved",
    "push_reserved",
    "assert_owner",
};

/// Fails the compile, naming the first declaration `Loop` lacks.
pub fn check(comptime Loop: type) void {
    inline for (loop_declarations) |name| {
        if (!@hasDecl(Loop, name)) {
            @compileError("backend Loop lacks the declaration '" ++ name ++ "' (core/surface.zig)");
        }
    }
}

/// Fails the compile, naming the first name of the port that `Loop` lacks. Each backend calls it
/// on its own `Loop`, beside `check`.
pub fn check_port(comptime Loop: type) void {
    inline for (port_declarations) |name| {
        if (!@hasDecl(Loop, name)) {
            @compileError("backend Loop lacks the port's declaration '" ++ name ++ "' (core/surface.zig)");
        }
    }
}

/// Fails the compile, naming the first declaration `Remote` lacks. Each backend calls it on its
/// own `Remote`, as it calls `check` on its `Loop`.
pub fn check_remote(comptime Remote: type) void {
    inline for (remote_declarations) |name| {
        if (!@hasDecl(Remote, name)) {
            @compileError("backend Remote lacks the declaration '" ++ name ++ "' (core/surface.zig)");
        }
    }
}

const testing = std.testing;

const Complete = struct {
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
};

test "a loop with every declaration passes the check" {
    comptime check(Complete);
    try testing.expectEqual(loop_declarations.len, @typeInfo(Complete).@"struct".decls.len);
    // The 43 names of v0.10.0, less the 16 of the reactor, and `wait_until` (decision 33).
    try testing.expectEqual(28, loop_declarations.len);
}

const CompletePort = struct {
    pub fn tick_backend() void {}
    pub fn take_kept_error() void {}
    pub fn outstanding() void {}
    pub fn stored_limit() void {}
    pub fn heartbeat_line() void {}
    pub fn attach_reserved() void {}
    pub fn push_reserved() void {}
    pub fn assert_owner() void {}
};

test "a loop with every name of the port passes the check, and the list is exactly those eight" {
    comptime check_port(CompletePort);
    try testing.expectEqual(port_declarations.len, @typeInfo(CompletePort).@"struct".decls.len);
    try testing.expectEqual(8, port_declarations.len);
}

const CompleteRemote = struct {
    pub fn init() void {}
    pub fn deinit() void {}
    pub fn post() void {}
    pub fn dropped_wakes() void {}
};

test "a remote with every declaration passes the check, and the list is exactly those four" {
    comptime check_remote(CompleteRemote);
    try testing.expectEqual(remote_declarations.len, @typeInfo(CompleteRemote).@"struct".decls.len);
}
