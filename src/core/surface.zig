//! The surface every backend carries (decision 1): `uring` and `kqueue` each export a `Loop` with
//! the declarations named here, so a consumer's build swaps one for the other, or for a
//! deterministic twin of its own (decision 10), without a changed line. `check` runs at comptime
//! in each backend's root, so a backend that drops or misspells a declaration fails to compile on
//! every host, whichever kernel it needs.
//!
//! The list holds names and not signatures. A signature that differs fails where a consumer
//! calls it, and the conformance suite calls every one.
const std = @import("std");

/// Every public declaration of a backend's `Loop`. Grows with the milestones; a name, once here,
/// stays.
pub const loop_declarations = [_][]const u8{
    "Options",
    "memory_bytes",
    "init",
    "deinit",
    "submit",
    "cancel",
    "tick",
    "in_flight",
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
    "provided_buffer",
};

/// Every public declaration of a backend's `Remote`: what a thread that owns no loop holds to
/// post with (decision 4). It is the whole of the surface, because a `Remote` does one thing.
pub const remote_declarations = [_][]const u8{
    "init",
    "deinit",
    "post",
};

/// Fails the compile, naming the first declaration `Loop` lacks.
pub fn check(comptime Loop: type) void {
    inline for (loop_declarations) |name| {
        if (!@hasDecl(Loop, name)) {
            @compileError("backend Loop lacks the declaration '" ++ name ++ "' (core/surface.zig)");
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
    pub fn submit() void {}
    pub fn cancel() void {}
    pub fn tick() void {}
    pub fn in_flight() void {}
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
    pub fn provided_buffer() void {}
};

test "a loop with every declaration passes the check" {
    comptime check(Complete);
    try testing.expectEqual(loop_declarations.len, @typeInfo(Complete).@"struct".decls.len);
}

const CompleteRemote = struct {
    pub fn init() void {}
    pub fn deinit() void {}
    pub fn post() void {}
};

test "a remote with every declaration passes the check, and the list is exactly those three" {
    comptime check_remote(CompleteRemote);
    try testing.expectEqual(remote_declarations.len, @typeInfo(CompleteRemote).@"struct".decls.len);
}
