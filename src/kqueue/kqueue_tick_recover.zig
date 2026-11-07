//! What the tick's `kevent` call did to the changelist (decision 12, point 10, amended on
//! 2026-11-06). A call that succeeded applied the whole list. A call that failed applied all of it,
//! part of it or none of it, and `recover` keeps every registration it may not have applied. Split
//! from `kqueue_tick.zig` for the 500-line limit.
//!
//! On macOS 26.6.2 on 2026-11-06 a probe showed what a failed call applied:
//!
//! - A call on a descriptor that is not a kqueue fails with EBADF and applies no change.
//! - A change the kernel refuses, with no room left in the readiness for its answer, fails the call
//!   with that change's errno. The changes before it are applied, and the changes after it are not.
//! - kevent(2) ties EINTR to the timeout, and says the kernel applies every change before it reads
//!   events. So a call that ends in EINTR applied its whole list. The probe did not show this.
//! - With EV_RECEIPT on every change and room for every answer, the kernel answers each change and
//!   does not fail the call. An EV_ADD of a filter that is there answers 0, and an EV_DELETE of a
//!   filter that is not there answers ENOENT.
const std = @import("std");
const assert = std.debug.assert;
const queue_module = @import("kqueue_queue.zig");
const submit_module = @import("kqueue_submit.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const ExchangeError = queue_module.ExchangeError;

/// Empties the changelist after a call that succeeded, and calls `recover` after one that failed.
/// `registrations` is how many changes the list held before the tick added its own trigger and
/// timer.
pub fn settle_changes(loop: *Loop, registrations: u32, called: ExchangeError!u32) ExchangeError!u32 {
    const count = called catch |failure| return recover(loop, registrations, failure);
    loop.changes_used = 0;
    return count;
}

/// Keeps the registrations of a call that failed, so no operation that waits for readiness loses
/// its filter. The tick's own trigger and timer are dropped, and the next tick adds its own.
///
/// The registrations go in again in one more call, with a receipt on each, which applies the ones
/// the failed call did not apply. One that it did apply is applied again: an EV_ADD changes
/// nothing, and an EV_DELETE comes back refused and stays on the list. Its refusal reaches the reap
/// in the next tick, which tries the first waiter of that filter once.
///
/// When that call fails too, the kqueue failed, and the list stays for the next tick. When it
/// succeeds, the kqueue works, so the failed call stopped at a change the kernel refused with no
/// room for its answer. That change is back on the list, and the tick goes on with no readiness.
pub fn recover(loop: *Loop, registrations: u32, failure: ExchangeError) ExchangeError!u32 {
    assert(registrations <= loop.changes_used);
    loop.changes_used = registrations;
    // The failed call may not have armed the timer. A deadline left set for a timer that is not
    // armed would let a later wait block with no timer to end it.
    loop.wait_timer_deadline_ns = 0;
    // The trigger stays marked armed, so the next tick that polls asks the kernel, and takes back
    // the trigger if the failed call applied it.
    if (failure == error.SystemResources) {
        // A signal ended every attempt while it waited, and each attempt applied the list first.
        loop.changes_used = 0;
        return failure;
    }
    // Only a registration can be refused, so with none the kqueue itself failed.
    if (registrations == 0) return failure;
    submit_module.apply_with_receipts(loop) catch return failure;
    return 0;
}

const testing = std.testing;
const builtin = @import("builtin");
const core = @import("core");

/// A loop whose changelist holds one registration and the poll's trigger, as a tick that polls
/// leaves it before its call.
fn fill(loop: *Loop, descriptor: core.Descriptor) void {
    submit_module.register(loop, descriptor, .read, false);
    loop.changes[loop.changes_used] = queue_module.poll_trigger();
    loop.changes_used += 1;
    loop.wait_timer_deadline_ns = 1;
}

test "a call that ended in a signal applied its list, and the error stands" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
    defer loop.deinit();
    const pair = try kqueue.testing.nonblocking_pair();
    defer for (pair) |descriptor| {
        _ = std.c.close(descriptor);
    };

    // The kqueue works, so a call that sent the list again would succeed, and the tick would go on.
    fill(&loop, pair[0]);
    try testing.expectError(error.SystemResources, recover(&loop, 1, error.SystemResources));
    try testing.expectEqual(@as(u32, 0), loop.changes_used);
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
}

test "a call that failed with no registration on its list reports the kqueue's error" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
    defer loop.deinit();

    // Only the tick's own trigger. A call with nothing to send would succeed on a kqueue that works,
    // and must not hide the error.
    loop.changes[0] = queue_module.poll_trigger();
    loop.changes_used = 1;
    try testing.expectError(error.Unexpected, recover(&loop, 0, error.Unexpected));
    try testing.expectEqual(@as(u32, 0), loop.changes_used);
}

test "a registration the failed call may not have applied is applied, and the tick goes on" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, &options);
    defer loop.deinit();
    const pair = try kqueue.testing.nonblocking_pair();
    defer for (pair) |descriptor| {
        _ = std.c.close(descriptor);
    };

    fill(&loop, pair[0]);
    try testing.expectEqual(@as(u32, 0), try recover(&loop, 1, error.Unexpected));
    try testing.expectEqual(@as(u32, 0), loop.changes_used);
    try testing.expectEqual(@as(u64, 0), loop.wait_timer_deadline_ns);
    // The filter is there: a byte makes it report, and it was not reported before.
    try testing.expectEqual(@as(isize, 1), std.c.write(pair[1], "x", 1));
    var readiness: [2]queue_module.Kevent = undefined;
    try testing.expectEqual(@as(u32, 1), try loop.queue.exchange(&.{}, &readiness, 0));
    try testing.expectEqual(@as(usize, @intCast(pair[0])), readiness[0].ident);
}
