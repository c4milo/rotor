//! Tasks, groups and cancellation (decision 22, "Which calls run on rotor").
//!
//! A task runs on a free fiber. Its arguments and its result live at the top of the fiber's stack,
//! so a task allocates nothing. When no fiber is free, or the arguments or the result are larger
//! than the top of a stack holds, `async` runs the task inline and `concurrent` returns
//! `error.ConcurrencyUnavailable`, as the interface allows.
//!
//! Cancellation follows std's own evented implementations. A cancel marks the task, and ends the
//! wait it blocks in when that wait is a cancel point. The next cancel point returns
//! `error.Canceled`, and none after it does until `recancel`.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Alignment = std.mem.Alignment;
const constants = @import("constants.zig");
const adapter_module = @import("adapter.zig");
const scheduler = @import("adapter_scheduler.zig");
const switching = @import("adapter_switch.zig");
const Adapter = adapter_module.Adapter;
const Fiber = adapter_module.Fiber;
const Index = adapter_module.Index;
const index_none = adapter_module.index_none;

const FutureStart = fn (context: *const anyopaque, result: *anyopaque) void;
const GroupStart = fn (context: *const anyopaque) void;

/// What the adapter keeps in `Io.Group.state`: the members that have not returned, and the
/// context that awaits them.
const GroupState = packed struct(usize) {
    members: u32,
    awaiter: Index,
    awaited: bool,
    reserved: u15 = 0,
};

/// True when a task's arguments and result fit the top of a stack.
fn fits(context: []const u8, context_alignment: Alignment, result_len: usize, result_alignment: Alignment) bool {
    return context.len <= constants.context_bytes_max and
        result_len <= constants.result_bytes_max and
        context_alignment.toByteUnits() <= constants.closure_alignment and
        result_alignment.toByteUnits() <= constants.closure_alignment;
}

/// Starts a task on a free fiber and makes it ready, or returns null.
fn spawn(
    adapter: *Adapter,
    context: []const u8,
    context_alignment: Alignment,
    result_len: usize,
    result_alignment: Alignment,
    start: *const anyopaque,
    member: bool,
) ?Index {
    if (!fits(context, context_alignment, result_len, result_alignment)) return null;
    const index = scheduler.take_free(adapter) orelse return null;
    const fiber = &adapter.fibers[index];
    @memcpy(adapter.context_bytes(index)[0..context.len], context);
    fiber.start = start;
    fiber.member = member;
    fiber.context = switching.initial_context(adapter.stack_end(index), @intFromPtr(adapter), fiber_main);
    scheduler.make_ready(adapter, index);
    return index;
}

/// A fiber's whole life: run the task, record that it returned, and hand the thread on for good.
fn fiber_main(argument: usize) callconv(.withStackAlign(.c, switching.stack_end_alignment)) noreturn {
    const adapter: *Adapter = @ptrFromInt(argument);
    const index = adapter.current;
    const fiber = &adapter.fibers[index];
    const context = adapter.context_bytes(index).ptr;
    if (fiber.member) {
        const start: *const GroupStart = @ptrCast(@alignCast(fiber.start.?));
        start(context);
        end_member(adapter, index);
    } else {
        const start: *const FutureStart = @ptrCast(@alignCast(fiber.start.?));
        start(context, adapter.result_bytes(index).ptr);
        end_future(adapter, index);
    }
    scheduler.leave(adapter);
}

fn end_future(adapter: *Adapter, index: Index) void {
    const fiber = &adapter.fibers[index];
    assert(fiber.state == .running);
    fiber.state = .finished;
    if (fiber.awaiter != index_none) scheduler.make_ready(adapter, fiber.awaiter);
}

/// A member's fiber goes back on the free list as its task returns, as `Io.Group` promises.
fn end_member(adapter: *Adapter, index: Index) void {
    const group = adapter.fibers[index].group.?;
    const state = group_state(group);
    assert(state.members >= 1);
    state.members -= 1;
    if (state.members == 0 and state.awaited) {
        const awaiter = &adapter.fibers[state.awaiter];
        if (awaiter.state == .blocked and awaiter.wait == .group) scheduler.make_ready(adapter, state.awaiter);
    }
    scheduler.push_free(adapter, index);
}

fn future_of(adapter: *Adapter, index: Index) *Io.AnyFuture {
    return @ptrCast(&adapter.fibers[index]);
}

fn index_of(adapter: *Adapter, future: *Io.AnyFuture) Index {
    const offset = @intFromPtr(future) - @intFromPtr(adapter.fibers.ptr);
    assert(offset % @sizeOf(Fiber) == 0);
    const index: Index = @intCast(offset / @sizeOf(Fiber));
    assert(index != adapter_module.index_main);
    assert(index < adapter.fibers.len);
    return index;
}

pub fn async_task(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const FutureStart,
) ?*Io.AnyFuture {
    const adapter = adapter_module.from(userdata);
    const index = spawn(adapter, context, context_alignment, result.len, result_alignment, @ptrCast(start), false) orelse {
        start(context.ptr, result.ptr);
        return null;
    };
    return future_of(adapter, index);
}

pub fn concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const FutureStart,
) Io.ConcurrentError!*Io.AnyFuture {
    const adapter = adapter_module.from(userdata);
    const index = spawn(adapter, context, context_alignment, result_len, result_alignment, @ptrCast(start), false) orelse
        return error.ConcurrencyUnavailable;
    return future_of(adapter, index);
}

pub fn await_task(userdata: ?*anyopaque, future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
    const adapter = adapter_module.from(userdata);
    assert(result_alignment.toByteUnits() <= constants.closure_alignment);
    const index = index_of(adapter, future);
    const fiber = &adapter.fibers[index];
    assert(!fiber.member);
    assert(fiber.awaiter == index_none);
    if (fiber.state != .finished) {
        fiber.awaiter = adapter.current;
        scheduler.block(adapter, .future, false);
    }
    assert(fiber.state == .finished);
    @memcpy(result, adapter.result_bytes(index)[0..result.len]);
    scheduler.push_free(adapter, index);
}

pub fn cancel(userdata: ?*anyopaque, future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
    const adapter = adapter_module.from(userdata);
    request_cancel(adapter, index_of(adapter, future));
    await_task(userdata, future, result, result_alignment);
}

fn request_cancel(adapter: *Adapter, index: Index) void {
    const fiber = &adapter.fibers[index];
    assert(fiber.state != .free);
    fiber.cancel_requested = true;
    scheduler.interrupt(adapter, index);
}

/// A cancel point: `error.Canceled` once for a cancel the protection allows.
pub fn cancel_point(fiber: *Fiber) error{Canceled}!void {
    assert(fiber.state == .running);
    if (!fiber.cancel_requested or fiber.protection == .blocked or fiber.acknowledged) return;
    fiber.acknowledged = true;
    return error.Canceled;
}

pub fn recancel(userdata: ?*anyopaque) void {
    const fiber = scheduler.current(adapter_module.from(userdata));
    // Only a requested cancel is ever acknowledged, so this also says one was requested.
    assert(fiber.acknowledged);
    fiber.acknowledged = false;
}

pub fn swap_cancel_protection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    const fiber = scheduler.current(adapter_module.from(userdata));
    const old = fiber.protection;
    fiber.protection = new;
    return old;
}

pub fn check_cancel(userdata: ?*anyopaque) Io.Cancelable!void {
    return cancel_point(scheduler.current(adapter_module.from(userdata)));
}

fn group_state(group: *Io.Group) *GroupState {
    return @ptrCast(&group.state);
}

pub fn group_async(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const GroupStart,
) void {
    const adapter = adapter_module.from(userdata);
    const index = spawn(adapter, context, context_alignment, 0, .@"1", @ptrCast(start), true) orelse {
        start(context.ptr);
        return;
    };
    join(adapter, group, index);
}

pub fn group_concurrent(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const GroupStart,
) Io.ConcurrentError!void {
    const adapter = adapter_module.from(userdata);
    const index = spawn(adapter, context, context_alignment, 0, .@"1", @ptrCast(start), true) orelse
        return error.ConcurrencyUnavailable;
    join(adapter, group, index);
}

fn join(adapter: *Adapter, group: *Io.Group, index: Index) void {
    const state = group_state(group);
    assert(state.members < constants.fibers_max);
    adapter.fibers[index].group = group;
    state.members += 1;
    group.token.store(adapter, .release);
}

/// Waits for every member. A cancel of the awaiting context goes on to every member, and the call
/// still waits for them all before it returns `error.Canceled`.
pub fn group_await(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
    const adapter = adapter_module.from(userdata);
    assert(token == @as(*anyopaque, adapter));
    const fiber = scheduler.current(adapter);
    var canceled = false;
    cancel_point(fiber) catch {
        canceled = true;
        cancel_members(adapter, group);
    };
    while (group_state(group).members != 0) {
        wait_members(adapter, group, !canceled);
        _ = scheduler.end_wait(fiber) catch {
            canceled = true;
            cancel_members(adapter, group);
        };
    }
    close(group);
    if (canceled) return error.Canceled;
}

pub fn group_cancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
    const adapter = adapter_module.from(userdata);
    assert(token == @as(*anyopaque, adapter));
    cancel_members(adapter, group);
    while (group_state(group).members != 0) wait_members(adapter, group, false);
    close(group);
}

fn wait_members(adapter: *Adapter, group: *Io.Group, cancelable: bool) void {
    const state = group_state(group);
    assert(!state.awaited);
    state.awaiter = adapter.current;
    state.awaited = true;
    scheduler.block(adapter, .group, cancelable);
    state.awaited = false;
}

fn cancel_members(adapter: *Adapter, group: *Io.Group) void {
    for (adapter.fibers[1..], 1..) |*fiber, index| {
        if (fiber.member and fiber.group == group) request_cancel(adapter, @intCast(index));
    }
}

fn close(group: *Io.Group) void {
    assert(group_state(group).members == 0);
    group.token.store(null, .release);
    group.state = 0;
}
