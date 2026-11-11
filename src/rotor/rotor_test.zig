//! The public module's tests of what it names beside the loop: that every public function
//! compiles, the calls of `sync`, and the choice of backend (decisions 20 and 23). Split from
//! `rotor.zig` for the 500-line limit.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
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

test "every public function compiles for this host, not only the ones something calls" {
    // Zig analyses a function only when something names it. `register_descriptors` and
    // `register_buffers` did not compile for Linux until 2026-09-22, and no gate said so, because
    // nothing on Linux called them. Naming every function of every public type here closes that.
    @setEvalBranchQuota(10_000);
    inline for (.{ Loop, HostReactor, Registry, Remote, sync, Heartbeat.Watch }) |T| {
        inline for (@typeInfo(T).@"struct".decls) |declaration| {
            const value = @field(T, declaration.name);
            if (@typeInfo(@TypeOf(value)) == .@"fn") _ = &value;
        }
    }
    // The view's refused calls are declarations that fail to compile when named, so the walk skips
    // them; `zig build test-compile-fail` names each one.
    inline for (.{ SharedLoop, HostReactor.SharedLoop }) |View| {
        inline for (@typeInfo(View).@"opaque".decls) |declaration| {
            if (comptime core.shared_loop.is_refused(declaration.name)) continue;
            const value = @field(View, declaration.name);
            if (@typeInfo(@TypeOf(value)) == .@"fn") _ = &value;
        }
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

/// What the test of the host's reactor counts: one record, one poller and one task.
const Counts = struct {
    completion: rotor.Completion = .init(Counts, "completion", completed),
    poller: rotor.Poller = .init(Counts, "poller", polled),
    task: rotor.Task = .init(Counts, "task", ran),
    completions: u32 = 0,
    polls: u32 = 0,
    runs: u32 = 0,

    fn completed(counts: *Counts, _: rotor.Event) void {
        counts.completions += 1;
    }

    fn polled(counts: *Counts) rotor.WaitLimit {
        counts.polls += 1;
        return .none;
    }

    fn ran(counts: *Counts) void {
        counts.runs += 1;
    }
};

const reactor_options: HostReactor.Options = .{ .loop = .{ .operations = 4 } };

test "a reactor built through the public module runs a record, a poller and a task, and drains" {
    if (!supported) return error.SkipZigTest;
    var memory: [HostReactor.memory_bytes(&reactor_options)]u8 align(rotor.memory_alignment) = undefined;
    var reactor: HostReactor = undefined;
    try reactor.init(&memory, &reactor_options);
    defer reactor.deinit();
    var counts: Counts = .{};
    var events: [4]rotor.Event = undefined;
    // A library holds the reactor's view, whose address is the reactor's.
    const shared = reactor.shared();
    try testing.expectEqual(@intFromPtr(&reactor), @intFromPtr(shared));
    try shared.add_poller(&counts.poller);
    try shared.schedule_in(.default, &counts.task);
    try testing.expectEqual(1, reactor.tasks_queued());
    try testing.expectEqual(0, reactor.in_flight());
    const timer = rotor.Operation.timer(0, rotor.constants.ns_per_ms, 0).completion(&counts.completion);
    try testing.expectEqual(1, shared.submit(&.{timer}, &.{}));
    try testing.expectEqual(1, reactor.in_flight());
    var round: u32 = 0;
    while (counts.completions == 0 and round < 100) : (round += 1) {
        try testing.expectEqual(0, try reactor.tick(&events, 10 * rotor.constants.ns_per_ms));
    }
    try testing.expectEqual(1, counts.completions);
    try testing.expectEqual(1, counts.runs);
    try testing.expect(counts.polls >= 1);
    shared.remove_poller(&counts.poller);
    try reactor.drain(&events);
    reactor.assert_empty();
    try testing.expectEqual(0, reactor.in_flight());
    try testing.expectEqual(backend() == .uring, reactor.wait_descriptor() == null);
    try testing.expect(reactor.statistics().sample_mask >= 1);
    _ = reactor.heartbeat();
}
