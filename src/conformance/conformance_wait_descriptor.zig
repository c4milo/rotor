//! The wait descriptor (decision 23): what a host that owns the wait sleeps on. Such a host cannot
//! block inside `tick`, because other things must wake it too. It waits in a call of its own, with
//! the loop's descriptor among what it waits on, and ticks the loop with a wait of 0 when the
//! descriptor is readable.
//!
//! The scenarios here are that host. A `Watcher` is the host's own queue, which holds the loop's
//! descriptor for read readiness: a second kqueue on macOS and a second epoll instance on Linux,
//! which is what a host's wait is built on there. It makes the kernel's calls itself, because it is
//! the host's side and the surface has nothing for it. On Linux they are the kernel's calls, since
//! the test executables there link no C library, and on macOS the C library's, as in
//! `conformance_process.zig`.
//!
//! The loop a scenario watches is never given a wait. A tick that blocks arms the loop's wait
//! timer, which makes the descriptor readable later for no operation.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");
const tcp = @import("conformance_tcp.zig");

const Harness = conformance.Harness;
const Loop = conformance.Loop;
const Event = core.Event;
const Operation = core.Operation;
const sync = backend.sync;

const on_linux = builtin.os.tag == .linux;

/// True when the backend under test reports readiness, which is exactly when its file operations
/// block (decision 18): kqueue and epoll. Such a loop waits on one kernel object, which a host can
/// wait on too. io_uring's loop has none.
const reports_readiness = backend.files_block;

/// How long a scenario waits for the watcher to report the descriptor readable. The wait ends as
/// soon as it is, so only a descriptor that never turns readable takes this long.
const wake_wait_ms = 2000;

/// How long a scenario watches a descriptor that must stay quiet. Readiness left behind shows at
/// once. The wait is there so that a descriptor that turns readable a moment later is seen too.
const quiet_wait_ms = 20;

/// The most ticks a host's turn takes before the scenario calls the loop stuck.
const turn_ticks_max = 16;

/// The host's own queue, holding one descriptor for read readiness.
const Watcher = struct {
    descriptor: core.Descriptor,

    fn open(watched: core.Descriptor) !Watcher {
        const watcher: Watcher = .{ .descriptor = try open_queue() };
        errdefer watcher.close();
        try watcher.add(watched);
        return watcher;
    }

    fn open_queue() !core.Descriptor {
        if (comptime on_linux) {
            const opened = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            if (linux.errno(opened) != .SUCCESS) return error.WatcherFailed;
            return @intCast(opened);
        }
        const opened = std.c.kqueue();
        if (opened < 0) return error.WatcherFailed;
        return opened;
    }

    /// Level triggered on both systems, so the watcher reports the descriptor for as long as it
    /// is readable, and a scenario can ask twice.
    fn add(watcher: *const Watcher, watched: core.Descriptor) !void {
        if (comptime on_linux) {
            var interest: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = 0 } };
            const added = linux.epoll_ctl(watcher.descriptor, linux.EPOLL.CTL_ADD, watched, &interest);
            if (linux.errno(added) != .SUCCESS) return error.WatcherFailed;
            return;
        }
        const change = [1]std.c.Kevent{.{
            .ident = @intCast(watched),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.ADD,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        var none: [0]std.c.Kevent = .{};
        if (std.c.kevent(watcher.descriptor, &change, change.len, &none, 0, null) != 0) {
            return error.WatcherFailed;
        }
    }

    fn close(watcher: *const Watcher) void {
        sync.close_now(watcher.descriptor);
    }

    /// True when the watched descriptor is readable, waiting up to `wait_ms` for it: the host's
    /// sleep.
    fn readable(watcher: *const Watcher, wait_ms: u31) !bool {
        // A signal that interrupts the wait starts it again, a bounded number of times.
        for (0..core.constants.interrupt_retries_max + 1) |_| {
            return watcher.wait_once(wait_ms) catch |err| switch (err) {
                error.Interrupted => continue,
                else => return err,
            };
        }
        return error.WatcherFailed;
    }

    fn wait_once(watcher: *const Watcher, wait_ms: u31) !bool {
        if (comptime on_linux) {
            var ready: [1]linux.epoll_event = undefined;
            const rc = linux.epoll_wait(watcher.descriptor, &ready, ready.len, wait_ms);
            return switch (linux.errno(rc)) {
                .SUCCESS => rc == 1,
                .INTR => error.Interrupted,
                else => error.WatcherFailed,
            };
        }
        const wait_ns = @as(u64, wait_ms) * core.constants.ns_per_ms;
        const timeout: std.c.timespec = .{
            .sec = @intCast(wait_ns / core.constants.ns_per_s),
            .nsec = @intCast(wait_ns % core.constants.ns_per_s),
        };
        var ready: [1]std.c.Kevent = undefined;
        var none: [0]std.c.Kevent = .{};
        const rc = std.c.kevent(watcher.descriptor, &none, 0, &ready, ready.len, &timeout);
        if (rc >= 0) return rc == 1;
        return if (std.posix.errno(rc) == .INTR) error.Interrupted else error.WatcherFailed;
    }
};

/// A host's turn: ticks with a wait of 0 until a tick delivers nothing, and returns how many
/// events the ticks wrote. `events` has room for one more than can come, so the last tick has
/// somewhere to write.
fn turn(loop: *Loop, events: []Event) !usize {
    var filled: usize = 0;
    for (0..turn_ticks_max) |_| {
        if (filled == events.len) return error.NoRoomForTheLastTick;
        const delivered = try loop.tick(events[filled..], 0);
        if (delivered == 0) return filled;
        filled += delivered;
    }
    return error.TurnDidNotEnd;
}

/// Ends whatever a scenario that failed left in flight. `deinit` halts on a loop that is not
/// empty, and that halt would hide which check failed. The ticks of the drain block, which is
/// fine here: nothing watches the descriptor any more.
fn end_in_flight(loop: *Loop) void {
    var scratch: [4]Event = undefined;
    loop.cancel_all();
    loop.drain(&scratch) catch {};
}

test "a loop names a descriptor a host can wait on exactly when its backend reports readiness" {
    if (conformance.unsupported()) return error.SkipZigTest;
    var harness: Harness = undefined;
    try harness.init(0, null);
    defer harness.deinit();
    // io_uring has none: the kernel posts a completion only when the loop's own thread enters the
    // ring, so a host that sleeps elsewhere would never be woken for one (decision 23).
    try testing.expectEqual(reports_readiness, harness.loop.wait_descriptor() != null);
    // The same answer each time: the descriptor is the loop's own, from `init` to `deinit`.
    try testing.expectEqual(harness.loop.wait_descriptor(), harness.loop.wait_descriptor());
}

test "a host that sleeps on the wait descriptor is woken for a receive, and not after a tick that delivers nothing" {
    if (conformance.unsupported() or !reports_readiness) return error.SkipZigTest;
    // The peer's loop makes the connection and sends. It blocks in its ticks, as a loop that
    // nobody watches may.
    var peer: Harness = undefined;
    try peer.init(0, null);
    defer peer.deinit();
    const listener = try tcp.Listener.open();
    defer sync.close_now(listener.descriptor);
    const pair = try tcp.connected_pair(&peer, &listener);
    defer for (pair) |descriptor| sync.close_now(descriptor);

    // The host's loop is never given a wait.
    var host: Harness = undefined;
    try host.init(0, null);
    defer host.deinit();
    defer end_in_flight(&host.loop);
    const watched = host.loop.wait_descriptor() orelse return error.NoWaitDescriptor;
    const watcher = try Watcher.open(watched);
    defer watcher.close();

    // A receive that has nothing to read waits. The turn that registers it delivers nothing, and
    // leaves the descriptor quiet: the host may sleep on it.
    var buffer: [16]u8 = undefined;
    var events: [4]Event = undefined;
    try host.submit(&.{Operation.receive(1, pair[1], &buffer)}, &.{});
    try testing.expectEqual(@as(usize, 0), try turn(&host.loop, &events));
    try testing.expect(!try watcher.readable(quiet_wait_ms));

    // The peer sends, and the host's loop is not ticked between the send and the wake. Loopback
    // takes its time to deliver, which is why a host waits on the watcher and does not tick
    // straight after the send.
    try peer.submit(&.{Operation.send(2, pair[0], "wake")}, &.{});
    var sent: [1]Event = undefined;
    try peer.collect(&sent);
    try testing.expectEqual(@as(u32, 4), try sent[0].outcome());
    try testing.expect(try watcher.readable(wake_wait_ms));

    // The host's turn hands the receive over, and the descriptor is quiet again.
    try testing.expectEqual(@as(usize, 1), try turn(&host.loop, &events));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u32, 4), try events[0].outcome());
    try testing.expectEqualStrings("wake", buffer[0..4]);
    try testing.expect(!try watcher.readable(quiet_wait_ms));
}
