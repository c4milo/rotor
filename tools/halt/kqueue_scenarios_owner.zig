//! The owner checks of the `kqueue` module: one scenario per entry point that calls
//! `assert_owner`. A loop and a remote belong to the thread that initialised them (decision 4), so
//! each scenario sets one up on the main thread and calls into it from a second thread.
//!
//! With its owner check deleted, every call here returns without a halt, and each scenario says
//! how. The loop has tables and no kqueue, as in `kqueue_scenarios.zig`, and a call that would
//! reach the kernel is given a descriptor no process has open, so libc answers `EBADF` and the
//! call returns.
const std = @import("std");
const core = @import("core");
const kqueue = @import("kqueue");
const scenario = @import("scenario.zig");

const Loop = kqueue.Loop;

const options: Loop.Options = .{ .operations = 4, .entries = 4, .id = 2 };

var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
var loop: Loop = undefined;

const one_timer = [_]core.Operation{
    .{ .user_data = 1, .kind = .{ .timer = .{ .after_ns = 1 } } },
};

/// A descriptor no process has open. It is high rather than 0 so that a call made with it answers
/// `EBADF` at once and never waits on standard input.
const closed_descriptor: core.Descriptor = 4096;

/// Runs `call` on a second thread and waits for it. A scenario whose thread cannot start returns
/// without the marker, and the check counts that as a failure.
fn on_another_thread(comptime call: fn () void) void {
    const thread = std.Thread.spawn(.{}, call, .{}) catch return;
    thread.join();
}

fn submit_from_another_thread() void {
    loop.init_tables(&memory, options);
    on_another_thread(submit_on_this_thread);
}

fn submit_on_this_thread() void {
    scenario.reached_violation();
    _ = loop.submit(&one_timer, &.{});
}

/// With the check deleted, the tick reads the clock and makes its `kevent` call on the closed
/// descriptor, which fails, and `tick` returns the error.
fn tick_from_another_thread() void {
    loop.init_tables(&memory, options);
    loop.queue = .{ .descriptor = closed_descriptor };
    on_another_thread(tick_on_this_thread);
}

fn tick_on_this_thread() void {
    var events: [1]core.Event = undefined;
    scenario.reached_violation();
    _ = loop.tick(&events, 0) catch {};
}

/// The handle names a timer still queued, so with the check deleted the cancel marks it and
/// returns: the next flush would end it.
var timer_handle: [1]core.Handle = undefined;

fn cancel_from_another_thread() void {
    loop.init_tables(&memory, options);
    _ = loop.submit(&one_timer, &timer_handle);
    on_another_thread(cancel_on_this_thread);
}

fn cancel_on_this_thread() void {
    scenario.reached_violation();
    loop.cancel(timer_handle[0]);
}

fn cancel_every_operation_from_another_thread() void {
    loop.init_tables(&memory, options);
    _ = loop.submit(&one_timer, &.{});
    on_another_thread(cancel_every_operation_on_this_thread);
}

fn cancel_every_operation_on_this_thread() void {
    scenario.reached_violation();
    loop.cancel_all();
}

/// The loop is empty, so with the check deleted `deinit` closes the queue's descriptor and
/// returns. The descriptor is the closed one: `close` answers `EBADF`, which `deinit` ignores.
fn end_a_loop_from_another_thread() void {
    loop.init_tables(&memory, options);
    loop.queue = .{ .descriptor = closed_descriptor };
    on_another_thread(end_the_loop_on_this_thread);
}

fn end_the_loop_on_this_thread() void {
    scenario.reached_violation();
    loop.deinit();
}

var registered_block: [64]u8 = undefined;

fn register_the_buffers_from_another_thread() void {
    loop.init_tables(&memory, options);
    on_another_thread(register_the_buffers_on_this_thread);
}

fn register_the_buffers_on_this_thread() void {
    const registered = [_][]u8{&registered_block};
    scenario.reached_violation();
    loop.register_buffers(&registered) catch {};
}

/// With the check deleted, the `fcntl` of the closed descriptor fails, and the call returns
/// `DescriptorInvalid`.
fn register_descriptors_from_another_thread() void {
    loop.init_tables(&memory, options);
    on_another_thread(register_descriptors_on_this_thread);
}

fn register_descriptors_on_this_thread() void {
    const descriptors = [_]core.Descriptor{closed_descriptor};
    scenario.reached_violation();
    loop.register_descriptors(&descriptors) catch {};
}

const group_buffers = 2;
const group_buffer_bytes = 64;
const group_alignment = kqueue.buffers.group_alignment;
const group_scenario_bytes = kqueue.buffers.group_bytes(group_buffers, group_buffer_bytes);
var group_memory: [group_scenario_bytes + group_alignment]u8 align(group_alignment) = undefined;

/// The group's memory, aligned forward at run time: macOS does not always give a static the
/// alignment it declares (`kqueue_scenarios.zig`, the group that is not aligned).
fn aligned_group_memory() []align(group_alignment) u8 {
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_alignment);
    const start: [*]align(group_alignment) u8 = @ptrFromInt(base);
    return start[0..group_scenario_bytes];
}

fn provide_a_group_from_another_thread() void {
    loop.init_tables(&memory, options);
    on_another_thread(provide_a_group_on_this_thread);
}

fn provide_a_group_on_this_thread() void {
    scenario.reached_violation();
    loop.provide_buffers(0, aligned_group_memory(), group_buffers, group_buffer_bytes) catch {};
}

/// The main thread provides the group and takes one buffer out, as a receive would. So with the
/// check deleted, the second thread's give-back fits the free list and returns.
var taken_buffer: u16 = undefined;

fn give_back_a_buffer_from_another_thread() void {
    loop.init_tables(&memory, options);
    loop.provide_buffers(0, aligned_group_memory(), group_buffers, group_buffer_bytes) catch return;
    taken_buffer = loop.groups[0].take() orelse return;
    on_another_thread(give_back_a_buffer_on_this_thread);
}

fn give_back_a_buffer_on_this_thread() void {
    scenario.reached_violation();
    loop.give_back_buffer(0, taken_buffer);
}

/// A registry of two ids, which the scenarios claim as a loop and a remote would.
const remote_ids: u16 = 2;
const remote_registry_bytes = kqueue.Registry.memory_bytes(remote_ids);
var remote_registry_memory: [remote_registry_bytes]u8 align(core.layout.memory_alignment) =
    undefined;
var remote_registry: kqueue.Registry = undefined;
var remote: kqueue.Remote = undefined;

/// A remote used from a thread that did not create it: two producers on one ring. With the check
/// deleted, `post` answers `LoopNotFound`, because no loop holds id 0.
fn post_from_a_remote_on_another_thread() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    remote.init(&remote_registry, 1) catch return;
    on_another_thread(post_through_the_remote);
}

fn post_through_the_remote() void {
    scenario.reached_violation();
    _ = remote.post(0, .{ .payload = 0, .tag = 0 }) catch {};
}

/// With the check deleted, `deinit` gives the id back to the registry, which makes no system call.
fn end_a_remote_from_another_thread() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    remote.init(&remote_registry, 1) catch return;
    on_another_thread(end_the_remote_on_this_thread);
}

fn end_the_remote_on_this_thread() void {
    scenario.reached_violation();
    remote.deinit();
}

pub const scenarios = [_]scenario.Scenario{
    .{ .name = "owner: submit from another thread", .run = submit_from_another_thread },
    .{ .name = "owner: tick from another thread", .run = tick_from_another_thread },
    .{ .name = "owner: cancel from another thread", .run = cancel_from_another_thread },
    .{
        .name = "owner: cancel every operation from another thread",
        .run = cancel_every_operation_from_another_thread,
    },
    .{ .name = "owner: end a loop from another thread", .run = end_a_loop_from_another_thread },
    .{
        .name = "owner: register the buffers from another thread",
        .run = register_the_buffers_from_another_thread,
    },
    .{
        .name = "owner: register descriptors from another thread",
        .run = register_descriptors_from_another_thread,
    },
    .{
        .name = "owner: provide a group from another thread",
        .run = provide_a_group_from_another_thread,
    },
    .{
        .name = "owner: give back a buffer from another thread",
        .run = give_back_a_buffer_from_another_thread,
    },
    .{
        .name = "owner: post from a remote on another thread",
        .run = post_from_a_remote_on_another_thread,
    },
    .{ .name = "owner: end a remote from another thread", .run = end_a_remote_from_another_thread },
};
