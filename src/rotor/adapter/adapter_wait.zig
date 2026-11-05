//! Futexes and time (decision 22, "Which calls run on rotor").
//!
//! A futex wait puts the context on the adapter's futex list, in the order the waits came, and a
//! wake takes the first waiters on the word. A wait with a timeout also runs a timer on the loop,
//! and a wake then asks the loop to end the timer early: the context resumes at the timer's final
//! event, so no event of the adapter comes after the wait it belongs to (decision 5).
//!
//! The awake and boot clocks read `Loop.now_ns`, the time of the loop's last tick, which a timer's
//! delay runs from (decision 14, rule 6). The other clocks go to `rest`.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const rotor = @import("../rotor.zig");
const constants = @import("constants.zig");
const adapter_module = @import("adapter.zig");
const scheduler = @import("adapter_scheduler.zig");
const tasks = @import("adapter_tasks.zig");
const Adapter = adapter_module.Adapter;
const index_none = adapter_module.index_none;

pub fn futex_wait(userdata: ?*anyopaque, word: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    const adapter = adapter_module.from(userdata);
    const fiber = scheduler.current(adapter);
    try tasks.cancel_point(fiber);
    if (@atomicLoad(u32, word, .acquire) != expected) return;
    const after_ns = timeout_ns(adapter, timeout);
    if (after_ns) |ns| if (ns == 0) return;
    push_futex(adapter, @intFromPtr(word));
    // A wake may come early, which the interface allows, so a long timeout is cut to the most a
    // timer takes.
    if (after_ns) |ns| scheduler.submit(adapter, .{ .timer = .{ .after_ns = @min(ns, rotor.constants.timeout_ns_max) } });
    scheduler.block(adapter, .futex, true);
    _ = try scheduler.end_wait(fiber);
}

pub fn futex_wait_uncancelable(userdata: ?*anyopaque, word: *const u32, expected: u32) void {
    const adapter = adapter_module.from(userdata);
    if (@atomicLoad(u32, word, .acquire) != expected) return;
    push_futex(adapter, @intFromPtr(word));
    scheduler.block(adapter, .futex, false);
}

/// Wakes the first `max_waiters` contexts that wait on `word`.
pub fn futex_wake(userdata: ?*anyopaque, word: *const u32, max_waiters: u32) void {
    const adapter = adapter_module.from(userdata);
    const address = @intFromPtr(word);
    var woken: u32 = 0;
    var link = &adapter.futex_head;
    var steps: usize = 0;
    while (link.* != index_none and woken < max_waiters) : (steps += 1) {
        assert(steps <= constants.fibers_max);
        const index = link.*;
        const fiber = &adapter.fibers[index];
        if (fiber.futex_address != address) {
            link = &fiber.next;
            continue;
        }
        link.* = fiber.next;
        fiber.next = index_none;
        scheduler.end_futex_wait(adapter, index, 0);
        woken += 1;
    }
}

/// Puts the running context at the end of the futex list.
fn push_futex(adapter: *Adapter, address: usize) void {
    const index = adapter.current;
    const fiber = &adapter.fibers[index];
    assert(fiber.next == index_none);
    fiber.futex_address = address;
    var link = &adapter.futex_head;
    var steps: usize = 0;
    while (link.* != index_none) : (steps += 1) {
        assert(steps <= constants.fibers_max);
        link = &adapter.fibers[link.*].next;
    }
    link.* = index;
}

pub fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const adapter = adapter_module.from(userdata);
    const fiber = scheduler.current(adapter);
    try tasks.cancel_point(fiber);
    var remaining = timeout_ns(adapter, timeout) orelse {
        // No timeout: only a cancel ends the sleep.
        scheduler.block(adapter, .cancel, true);
        _ = try scheduler.end_wait(fiber);
        return;
    };
    while (remaining > 0) {
        const step = @min(remaining, rotor.constants.timeout_ns_max);
        scheduler.submit(adapter, .{ .timer = .{ .after_ns = step } });
        scheduler.block(adapter, .operation, true);
        _ = try scheduler.end_wait(fiber);
        remaining -= step;
    }
}

/// The nanoseconds from now until `timeout` passes, 0 when it has passed, or null for none.
fn timeout_ns(adapter: *Adapter, timeout: Io.Timeout) ?u64 {
    const nanoseconds: i96 = switch (timeout) {
        .none => return null,
        .duration => |duration| duration.raw.nanoseconds,
        .deadline => |deadline| deadline.raw.nanoseconds - now(adapter, deadline.clock).nanoseconds,
    };
    return @intCast(std.math.clamp(nanoseconds, 0, std.math.maxInt(u64)));
}

pub fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    const adapter = adapter_module.from(userdata);
    switch (clock) {
        .awake, .boot => {
            // The loop reads its clock in a tick, and has none before the first.
            if (adapter.loop.now_ns() == 0) scheduler.poll(adapter);
            const now_ns = adapter.loop.now_ns();
            assert(now_ns != 0);
            return .{ .nanoseconds = now_ns };
        },
        else => return adapter.rest.vtable.now(adapter.rest.userdata, clock),
    }
}
