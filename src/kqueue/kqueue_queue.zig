//! `Queue`: one loop's kqueue: its setup, and the one `kevent` call a tick makes, which carries
//! the tick's registrations in and the descriptors that became ready out. Everything here enters
//! the kernel, so it is tested under macOS alone.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const core = @import("core");
const constants = @import("constants.zig");

pub const Kevent = std.c.Kevent;

pub const InitError = error{ Unsupported, SystemResources, Unexpected };

/// `SystemResources`: a signal interrupted the call more than `interrupt_retries_max` times.
pub const ExchangeError = error{ SystemResources, Unexpected };

const supported = builtin.os.tag.isDarwin();

pub const Queue = struct {
    descriptor: core.Descriptor,

    /// Opens the kqueue and adds the one user event other loops trigger to wake this one.
    /// `EV_CLEAR` resets it as it is delivered, so one trigger wakes one `kevent` call.
    pub fn init() InitError!Queue {
        if (comptime !supported) return error.Unsupported;
        const descriptor = std.c.kqueue();
        if (descriptor < 0) return error.SystemResources;
        var queue: Queue = .{ .descriptor = descriptor };
        const added: [1]Kevent = .{user_event(std.c.EV.ADD | std.c.EV.CLEAR, 0)};
        var none: [0]Kevent = .{};
        _ = queue.exchange(&added, &none, null) catch {
            queue.deinit();
            return error.Unexpected;
        };
        assert(queue.descriptor >= 0);
        return queue;
    }

    pub fn deinit(queue: *Queue) void {
        assert(queue.descriptor >= 0);
        _ = std.c.close(queue.descriptor);
        queue.descriptor = -1;
    }

    /// The tick's one `kevent` call: `changes` in, readiness out, and returns how many of
    /// `readiness` it filled. With `wait_ns`, blocks until a descriptor is ready, the loop is
    /// woken, or the wait passes. Without it, returns at once.
    pub fn exchange(
        queue: *Queue,
        changes: []const Kevent,
        readiness: []Kevent,
        wait_ns: ?u64,
    ) ExchangeError!u32 {
        assert(queue.descriptor >= 0);
        assert(changes.len <= constants.changes_max);
        assert(readiness.len <= constants.readiness_max);
        const nanoseconds = wait_ns orelse 0;
        assert(nanoseconds <= core.constants.wait_ns_max);
        const timeout: std.c.timespec = .{
            .sec = @intCast(nanoseconds / core.constants.ns_per_s),
            .nsec = @intCast(nanoseconds % core.constants.ns_per_s),
        };
        return queue.call(changes, readiness, &timeout);
    }

    /// The tick's one `kevent` call when it blocks with no timeout: `changes` in, readiness out.
    /// It returns only when an event is ready, so the caller must have armed the loop's wait timer
    /// before the call, or in `changes` (decision 12, point 7). On macOS a call with a timeout costs
    /// about 1,000 more instructions in the kernel than one without, whatever the timeout.
    pub fn wait(queue: *Queue, changes: []const Kevent, readiness: []Kevent) ExchangeError!u32 {
        assert(queue.descriptor >= 0);
        assert(changes.len <= constants.changes_max);
        assert(readiness.len >= 1 and readiness.len <= constants.readiness_max);
        return queue.call(changes, readiness, null);
    }

    fn call(
        queue: *Queue,
        changes: []const Kevent,
        readiness: []Kevent,
        timeout: ?*const std.c.timespec,
    ) ExchangeError!u32 {
        var retry: u32 = 0;
        while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
            const rc = std.c.kevent(
                queue.descriptor,
                changes.ptr,
                @intCast(changes.len),
                readiness.ptr,
                @intCast(readiness.len),
                timeout,
            );
            if (rc >= 0) return @intCast(rc);
            if (std.posix.errno(rc) != .INTR) return error.Unexpected;
        }
        return error.SystemResources;
    }

    /// Wakes the loop whose kqueue is `target` out of its `kevent` call. Any thread may call it:
    /// it is one system call on a descriptor, and it touches no memory of the target loop.
    pub fn wake(target: core.Descriptor) void {
        assert(target >= 0);
        const trigger: [1]Kevent = .{user_event(0, std.c.NOTE.TRIGGER)};
        var none: [0]Kevent = .{};
        const zero: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.kevent(target, &trigger, trigger.len, &none, 0, &zero);
    }
};

/// The change a polling tick adds to its own changelist: a trigger of this loop's wake event, so
/// the `kevent` call that follows finds one event ready and returns at once
/// (`kqueue_tick.zig`, `arm_poll`).
pub fn poll_trigger() Kevent {
    return user_event(0, std.c.NOTE.TRIGGER);
}

/// The change that arms the loop's wait timer to fire once, `bound_ns` from now (decision 12,
/// point 7). Adding it again moves the one timer, so a loop holds at most one.
///
/// `NOTE_CRITICAL` asks the kernel to fire the timer when it is due. Without it macOS may fire it
/// late to coalesce it with other timers, by more the lower the process's priority tier: run as a
/// background process (`taskpolicy -b`), a tick's wait of 5 ms came back more than 7.5 ms late, and
/// the conformance suite's test of a repeating timer that must not drift failed on GitHub's macOS
/// runners from 2026-09-27. The `kevent` timeout this timer replaced was not delayed that way.
pub fn wait_timer(bound_ns: u64) Kevent {
    assert(bound_ns >= 1);
    assert(bound_ns <= core.constants.wait_ns_max);
    return .{
        .ident = constants.wait_timer_identifier,
        .filter = std.c.EVFILT.TIMER,
        .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
        .fflags = std.c.NOTE.NSECONDS | std.c.NOTE.CRITICAL,
        .data = @intCast(bound_ns),
        .udata = 0,
    };
}

fn user_event(flags: u16, fflags: u32) Kevent {
    return .{
        .ident = constants.wake_identifier,
        .filter = std.c.EVFILT.USER,
        .flags = flags,
        .fflags = fflags,
        .data = 0,
        .udata = 0,
    };
}

/// The change that registers, or removes, the filter of one descriptor.
pub fn descriptor_event(descriptor: core.Descriptor, filter: i16, flags: u16) Kevent {
    assert(descriptor >= 0);
    return .{
        .ident = @intCast(descriptor),
        .filter = filter,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
}

const testing = std.testing;

test "init refuses on a host without kqueue" {
    if (supported) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, Queue.init());
}

test "a poll of an idle kqueue returns nothing, and a wake ends a wait long before it is over" {
    if (!supported) return error.SkipZigTest;
    var queue = try Queue.init();
    defer queue.deinit();
    var readiness: [4]Kevent = undefined;
    try testing.expectEqual(@as(u32, 0), try queue.exchange(&.{}, &readiness, null));
    Queue.wake(queue.descriptor);
    const ready = try queue.exchange(&.{}, &readiness, core.constants.wait_ns_max);
    try testing.expectEqual(@as(u32, 1), ready);
    try testing.expectEqual(@as(i16, std.c.EVFILT.USER), readiness[0].filter);
    // The event cleared itself as it was delivered.
    try testing.expectEqual(@as(u32, 0), try queue.exchange(&.{}, &readiness, null));
}
