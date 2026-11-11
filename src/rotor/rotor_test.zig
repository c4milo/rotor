//! The public module's tests of what it names beside the loop: that every public function
//! compiles, the calls of `sync`, and the choice of backend (decisions 20 and 23). Split from
//! `rotor.zig` for the 500-line limit.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
const reactor = @import("reactor");
const uring = @import("uring");
const kqueue = @import("kqueue");
const rotor = @import("rotor.zig");

const Address = rotor.Address;
const Backend = rotor.Backend;
const Descriptor = rotor.Descriptor;
const Heartbeat = rotor.Heartbeat;
const Loop = rotor.Loop;
/// The host's reactor (decision 33).
const HostReactor = rotor.Reactor(Loop);
const Offload = rotor.Offload;
const Registry = rotor.Registry;
const Remote = rotor.Remote;
const RequireError = rotor.RequireError;
const SharedLoop = rotor.SharedLoop;
const backend = rotor.backend;
const require_backend = rotor.require_backend;
const supported = rotor.supported;
const sync = rotor.sync;

const linux = builtin.os.tag == .linux;

const testing = std.testing;

/// Names each function that `declarations` lists of `T`, so the compiler analyses it, and skips each
/// name that `refused` holds: a declaration that fails to compile when named.
fn name_each_function(
    comptime T: type,
    comptime declarations: []const std.builtin.Type.Declaration,
    comptime refused: fn (comptime name: []const u8) bool,
) void {
    inline for (declarations) |declaration| {
        if (comptime refused(declaration.name)) continue;
        const value = @field(T, declaration.name);
        if (@typeInfo(@TypeOf(value)) == .@"fn") _ = &value;
    }
}

/// No declaration is refused.
fn none_refused(comptime _: []const u8) bool {
    return false;
}

/// A reactor's `wait_until` fails to compile when named (decision 33), as the view's refused calls
/// do.
fn reactor_refused(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "wait_until");
}

test "every public function compiles for this host, not only the ones something calls" {
    // Zig analyses a function only when something names it. `register_descriptors` and
    // `register_buffers` did not compile for Linux until 2026-09-22, and no gate said so, because
    // nothing on Linux called them. Naming every function of every public type here closes that.
    @setEvalBranchQuota(10_000);
    inline for (.{ Loop, Registry, Remote, sync, Heartbeat.Watch }) |T| {
        name_each_function(T, @typeInfo(T).@"struct".decls, none_refused);
    }
    name_each_function(HostReactor, @typeInfo(HostReactor).@"struct".decls, reactor_refused);
    // The view's refused calls are declarations that fail to compile when named, so the walk skips
    // them; `zig build test-compile-fail` names each one.
    inline for (.{ SharedLoop, HostReactor.SharedLoop }) |View| {
        name_each_function(View, @typeInfo(View).@"opaque".decls, reactor.shared.is_refused);
    }
    _ = &Heartbeat.watch;
    _ = &backend;
    _ = &require_backend;
    _ = &Offload.memory_bytes;
}

test "the public sync carries the backend's twenty-four names, and nothing else" {
    const Host = if (linux) uring.sync else kqueue.sync;
    const own = @typeInfo(sync).@"struct".decls;
    // Its private declarations aside, the public sync names what the backend's names.
    var public: usize = 0;
    inline for (own) |declaration| {
        try testing.expect(@hasDecl(Host, declaration.name));
        public += 1;
    }
    try testing.expectEqual(@typeInfo(Host).@"struct".decls.len, public);
}

test "the process runs io_uring where the kernel takes a ring, and epoll where it refuses one" {
    if (!linux) {
        try testing.expectEqual(Backend.kqueue, backend());
        return;
    }
    // Asked here directly, with one raw `io_uring_setup`, rather than through the backend's own
    // probe: a probe that always answered one way would pass a test that asked it.
    const os = std.os.linux;
    var params = std.mem.zeroes(os.io_uring_params);
    const rc = os.io_uring_setup(1, &params);
    const refused = switch (os.errno(rc)) {
        .SUCCESS => blk: {
            _ = os.close(@intCast(rc));
            break :blk false;
        },
        .PERM, .NOSYS => true,
        else => return error.SkipZigTest,
    };
    try testing.expectEqual(if (refused) Backend.epoll else Backend.uring, backend());
    // The choice holds: a second ask is answered the same, from what the first kept.
    try testing.expectEqual(backend(), backend());
}

test "the public module requires a backend: the one that runs is granted, another is refused" {
    // `rotor_loop_backend.zig` holds the tests of each outcome. This one holds the public call to
    // them: a call that granted everything, or refused everything, fails here.
    try require_backend(backend());
    const others = [_]Backend{ .uring, .epoll, .kqueue };
    for (others) |other| {
        if (other == backend()) continue;
        const refusal = require_backend(other);
        const expected: RequireError = if (linux and other != .kqueue)
            error.OtherBackendChosen
        else
            error.Unsupported;
        try testing.expectError(expected, refusal);
    }
}

test "a socket from sync suits the backend: it does not block exactly when epoll runs" {
    if (!supported or !linux) return error.SkipZigTest;
    const os = std.os.linux;
    const socket = try sync.open_socket(.ipv4);
    defer sync.close_now(socket);
    const listener = try sync.listen(&Address.ipv4(.{ 127, 0, 0, 1 }, 0), .{
        .backlog = 1,
        .reuse_port = false,
    });
    defer sync.close_now(listener);
    const datagram_socket = try sync.open_datagram(.ipv4, null, .{});
    defer sync.close_now(datagram_socket);
    for ([_]Descriptor{ socket, listener, datagram_socket }) |descriptor| {
        const flags = os.fcntl(descriptor, os.F.GETFL, 0);
        try testing.expectEqual(os.E.SUCCESS, os.errno(flags));
        const status: os.O = @bitCast(@as(u32, @intCast(flags)));
        try testing.expectEqual(backend() == .epoll, status.NONBLOCK);
    }
}
