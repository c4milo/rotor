//! Halt scenarios for the `uring` module that need a Linux kernel. `zig build test-linux` builds
//! this file and `tools/halt_check.zig` for Linux, and `tools/linux_test.sh` runs the check on it
//! in Docker with `seccomp=unconfined`. `zig build halt-check` does not run it.
//!
//! A scenario proves an assertion only if the scenario returns once that assertion is deleted. Each
//! scenario here runs on a loop with a real ring (`Loop.init`), and each assertion under test comes
//! before an io_uring call or a call that closes the ring. With the assertion deleted, the loop
//! makes the call; the kernel either refuses it, and the loop returns the error, or performs it, and
//! the call returns. Either way the scenario returns. On a Mac the same call runs some other system
//! call (`uring_scenarios.zig`), and that is why these scenarios are here.
const std = @import("std");
const core = @import("core");
const uring = @import("uring");
const scenario = @import("scenario.zig");

const Loop = uring.Loop;

const options: Loop.Options = .{ .operations = 4, .entries = 4 };

var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
var loop: Loop align(@alignOf(Loop)) = undefined;

/// The wait the tick from another thread asks for. It is above 0 so that `tick` enters the kernel:
/// a loop with nothing to submit that asks for no wait makes no system call.
const tick_wait_ns = core.constants.ns_per_ms;

/// A loop belongs to the thread that initialised it (decision 4), and its ring is `SINGLE_ISSUER`,
/// so the kernel binds the ring to that thread. Decision 4 asks for this scenario. With the owner
/// check deleted, the second thread's `io_uring_enter` gets EEXIST from the kernel, `tick` returns
/// `Unexpected`, and the scenario returns.
fn tick_from_another_thread() void {
    loop.init(&memory, options) catch return;
    const thread = std.Thread.spawn(.{}, tick_on_this_thread, .{}) catch return;
    thread.join();
}

fn tick_on_this_thread() void {
    var events: [1]core.Event = undefined;
    scenario.reached_violation();
    _ = loop.tick(&events, tick_wait_ns) catch {};
}

/// Runs `call` on a second thread and waits for it. A scenario whose thread cannot start returns
/// without the marker, and the check counts that as a failure.
fn on_another_thread(comptime call: fn () void) void {
    const thread = std.Thread.spawn(.{}, call, .{}) catch return;
    thread.join();
}

/// The loop is empty, so with the owner check deleted `deinit` closes the ring from the second
/// thread, which the kernel allows, and returns.
fn end_a_loop_from_another_thread() void {
    loop.init(&memory, options) catch return;
    on_another_thread(end_the_loop_on_this_thread);
}

fn end_the_loop_on_this_thread() void {
    scenario.reached_violation();
    loop.deinit();
}

var registered_block: [64]u8 = undefined;

fn register_the_buffers_from_another_thread() void {
    loop.init(&memory, options) catch return;
    on_another_thread(register_the_buffers_on_this_thread);
}

fn register_the_buffers_on_this_thread() void {
    const registered = [_][]u8{&registered_block};
    scenario.reached_violation();
    loop.register_buffers(&registered) catch {};
}

/// Standard output, which is open, so whatever the kernel answers is about the thread and not about
/// the descriptor.
const open_descriptor: core.Descriptor = 1;

fn register_descriptors_from_another_thread() void {
    loop.init(&memory, options) catch return;
    on_another_thread(register_descriptors_on_this_thread);
}

fn register_descriptors_on_this_thread() void {
    const descriptors = [_]core.Descriptor{open_descriptor};
    scenario.reached_violation();
    loop.register_descriptors(&descriptors) catch {};
}

/// Memory for one small group, with two alignments of slack: the scenario aligns a pointer forward
/// inside this array and then moves it off the alignment, so it needs room for both steps.
const group_buffers = 2;
const group_buffer_bytes = 64;
const group_alignment = uring.buffers.group_alignment;
const group_scenario_bytes = uring.buffers.group_bytes(group_buffers, group_buffer_bytes);
var group_memory: [group_scenario_bytes + 2 * group_alignment]u8 align(group_alignment) = undefined;

/// A group whose memory starts one `io_uring_buf` past `group_alignment`. The kernel wants a buffer
/// ring on a page boundary and answers EINVAL otherwise. Until 2026-09-22 that EINVAL arrived as
/// one `Unexpected` with no name, and it cost a consumer a day. That consumer's memory passed every
/// cast and failed only in the kernel, and this offset has the same shape. With the check deleted,
/// `provide_buffers` returns `Unsupported` and the scenario returns.
///
/// The address is aligned forward at run time rather than taken from the array as declared, so the
/// scenario does not depend on how the loader aligns a static. The pointer is made with safety
/// checks off. In a checked build `@ptrFromInt` refuses an address that is not aligned as its type
/// says, as `@alignCast` does, and a caller built without checks gets no such refusal. rotor's
/// assertions stay on either way (CLAUDE.md non-negotiable 1).
fn provide_a_group_that_is_not_aligned() void {
    loop.init(&memory, options) catch return;
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_alignment);
    const misaligned = blk: {
        @setRuntimeSafety(false);
        const start: [*]align(group_alignment) u8 =
            @ptrFromInt(base + @sizeOf(std.os.linux.io_uring_buf));
        break :blk start[0..group_scenario_bytes];
    };
    scenario.reached_violation();
    loop.provide_buffers(0, misaligned, group_buffers, group_buffer_bytes) catch {};
}

/// The group's memory, aligned forward at run time, as the scenario above aligns it.
fn aligned_group_memory() []align(group_alignment) u8 {
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_alignment);
    const start: [*]align(group_alignment) u8 = @ptrFromInt(base);
    return start[0..group_scenario_bytes];
}

fn provide_a_group_from_another_thread() void {
    loop.init(&memory, options) catch return;
    on_another_thread(provide_a_group_on_this_thread);
}

fn provide_a_group_on_this_thread() void {
    scenario.reached_violation();
    loop.provide_buffers(0, aligned_group_memory(), group_buffers, group_buffer_bytes) catch {};
}

/// A datagram group needs buffers larger than a datagram's prefix, or `provide_datagram_buffers`
/// halts on that before it reaches the owner check.
const datagram_buffer_bytes = core.datagram.prefix_bytes(.{}) + group_buffer_bytes;
const datagram_group_bytes = uring.buffers.group_bytes(group_buffers, datagram_buffer_bytes);
var datagram_memory: [datagram_group_bytes + group_alignment]u8 align(group_alignment) = undefined;

/// With the owner check deleted, `provide` asks the kernel for the group from the second thread
/// and returns what it answers, and the scenario returns.
fn provide_datagram_buffers_from_another_thread() void {
    loop.init(&memory, options) catch return;
    on_another_thread(provide_datagram_buffers_on_this_thread);
}

fn provide_datagram_buffers_on_this_thread() void {
    const base = std.mem.alignForward(usize, @intFromPtr(&datagram_memory), group_alignment);
    const start: [*]align(group_alignment) u8 = @ptrFromInt(base);
    const group = start[0..datagram_group_bytes];
    scenario.reached_violation();
    loop.provide_datagram_buffers(0, group, group_buffers, datagram_buffer_bytes, .{}) catch {};
}

/// The main thread provides the group. With the owner check deleted, the second thread writes one
/// entry to the group's ring, which is memory the process shares with the kernel, and makes no
/// system call.
fn give_back_a_buffer_from_another_thread() void {
    loop.init(&memory, options) catch return;
    loop.provide_buffers(0, aligned_group_memory(), group_buffers, group_buffer_bytes) catch return;
    on_another_thread(give_back_a_buffer_on_this_thread);
}

fn give_back_a_buffer_on_this_thread() void {
    scenario.reached_violation();
    loop.give_back_buffer(0, 0);
}

/// The same group id twice. With the check deleted, `provide_buffers` asks the kernel for a second
/// ring under the same id and returns what it answers, and the scenario returns.
fn provide_one_group_id_twice() void {
    loop.init(&memory, options) catch return;
    loop.provide_buffers(0, aligned_group_memory(), group_buffers, group_buffer_bytes) catch return;
    scenario.reached_violation();
    loop.provide_buffers(0, aligned_group_memory(), group_buffers, group_buffer_bytes) catch {};
}

/// The buffers twice. With the check deleted, `register_buffers` asks the kernel to register them
/// again and returns what it answers, and the scenario returns.
fn register_the_buffers_twice() void {
    loop.init(&memory, options) catch return;
    const registered = [_][]u8{&registered_block};
    loop.register_buffers(&registered) catch return;
    scenario.reached_violation();
    loop.register_buffers(&registered) catch {};
}

/// A registry of two ids: the remote claims id 1.
const remote_ids: u16 = 2;
const remote_registry_bytes = uring.Registry.memory_bytes(remote_ids);
var remote_registry_memory: [remote_registry_bytes]u8 align(core.layout.memory_alignment) =
    undefined;
var remote_registry: uring.Registry align(@alignOf(uring.Registry)) = undefined;
var remote: uring.Remote align(@alignOf(uring.Remote)) = undefined;

/// With the owner check deleted, `deinit` gives the id back and closes the remote's ring from the
/// second thread, which the kernel allows, and returns.
fn end_a_remote_from_another_thread() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    remote.init(&remote_registry, 1) catch return;
    on_another_thread(end_the_remote_on_this_thread);
}

fn end_the_remote_on_this_thread() void {
    scenario.reached_violation();
    remote.deinit();
}

// The tick's entry checks (decision 8, class B), which `core.Tables.begin_tick` makes for every
// backend. After `begin_tick` the tick reads the clock, a Linux call, so these are
// here and not in the file a Mac runs.

const one_timer = [_]core.Operation{
    .{ .user_data = 1, .kind = .{ .timer = .{ .after_ns = 1 } } },
};

var no_events: [0]core.Event align(@alignOf(core.Event)) = .{};
var too_many_events: [core.constants.batch_max + 1]core.Event align(@alignOf(core.Event)) =
    undefined;
var one_event: [1]core.Event align(@alignOf(core.Event)) = undefined;

fn tick_with_no_room_for_an_event() void {
    loop.init(&memory, options) catch return;
    scenario.reached_violation();
    _ = loop.tick(&no_events, 0) catch {};
}

fn tick_with_more_events_than_a_batch() void {
    loop.init(&memory, options) catch return;
    scenario.reached_violation();
    _ = loop.tick(&too_many_events, 0) catch {};
}

/// A wait above `wait_ns_max`, in a tick that has an event to hand over: a timer cancelled while it
/// was still queued, which the flush ends without the kernel. Such a tick never asks `wait_bound`
/// how long to wait, and until 2026-09-23 that was the only place kqueue and epoll checked the
/// wait.
fn tick_with_a_wait_above_the_limit() void {
    loop.init(&memory, options) catch return;
    var handle: [1]core.Handle = undefined;
    _ = loop.submit(&one_timer, &handle);
    loop.cancel(handle[0]);
    scenario.reached_violation();
    _ = loop.tick(&one_event, core.constants.wait_ns_max + 1) catch {};
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "tick: tick with no room for an event", .run = tick_with_no_room_for_an_event },
    .{
        .name = "tick: tick with more events than a batch",
        .run = tick_with_more_events_than_a_batch,
    },
    .{ .name = "tick: tick with a wait above the limit", .run = tick_with_a_wait_above_the_limit },
    .{ .name = "owner: tick from another thread", .run = tick_from_another_thread },
    .{
        .name = "buffers: provide a group that is not aligned",
        .run = provide_a_group_that_is_not_aligned,
    },
    .{ .name = "buffers: provide one group id twice", .run = provide_one_group_id_twice },
    .{ .name = "buffers: register the buffers twice", .run = register_the_buffers_twice },
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
        .name = "owner: provide datagram buffers from another thread",
        .run = provide_datagram_buffers_from_another_thread,
    },
    .{
        .name = "owner: give back a buffer from another thread",
        .run = give_back_a_buffer_from_another_thread,
    },
    .{ .name = "owner: end a remote from another thread", .run = end_a_remote_from_another_thread },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
