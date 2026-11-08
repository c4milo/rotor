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
const datagram_shapes = @import("datagram_shapes.zig").Scenario(Loop, uring.buffers);
const buffer_release = @import("buffer_release.zig").Scenario(Loop, uring.buffers);

const options: Loop.Options = .{ .operations = 4, .entries = 4 };

var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
var loop: Loop align(@alignOf(Loop)) = undefined;

/// A call's wake of the loop that makes it (decision 32). With the check deleted, the loop notes
/// its own id, which its next submit would wake, and the scenario returns.
fn wake_the_loop_that_makes_the_call() void {
    loop.init(&memory, &options) catch return;
    scenario.reached_violation();
    loop.wake_target(loop.tables.id, 0);
}

/// The wait the tick from another thread asks for. It is above 0 so that `tick` enters the kernel:
/// a loop with nothing to submit that asks for no wait makes no system call.
const tick_wait_ns = core.constants.ns_per_ms;

/// A loop belongs to the thread that initialised it (decision 4), and its ring is `SINGLE_ISSUER`,
/// so the kernel binds the ring to that thread. Decision 4 asks for this scenario. With the owner
/// check deleted, the second thread's `io_uring_enter` gets EEXIST from the kernel, `tick` returns
/// `Unexpected`, and the scenario returns.
fn tick_from_another_thread() void {
    loop.init(&memory, &options) catch return;
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

/// A watch that still reads the heartbeat when the loop ends (decision 28). With the check
/// deleted, `deinit` closes the loop's ring and returns.
fn end_a_loop_that_a_watch_reads() void {
    loop.init(&memory, &options) catch return;
    var watch = loop.heartbeat().watch();
    _ = &watch;
    scenario.reached_violation();
    loop.deinit();
}

/// The loop is empty, so with the owner check deleted `deinit` closes the ring from the second
/// thread, which the kernel allows, and returns.
fn end_a_loop_from_another_thread() void {
    loop.init(&memory, &options) catch return;
    on_another_thread(end_the_loop_on_this_thread);
}

fn end_the_loop_on_this_thread() void {
    scenario.reached_violation();
    loop.deinit();
}

var registered_block: [64]u8 = undefined;

fn register_the_buffers_from_another_thread() void {
    loop.init(&memory, &options) catch return;
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
    loop.init(&memory, &options) catch return;
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
    loop.init(&memory, &options) catch return;
    const group = loop.reserve_buffer_group() catch return;
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_alignment);
    const misaligned = blk: {
        @setRuntimeSafety(false);
        const start: [*]align(group_alignment) u8 =
            @ptrFromInt(base + @sizeOf(std.os.linux.io_uring_buf));
        break :blk start[0..group_scenario_bytes];
    };
    scenario.reached_violation();
    loop.provide_buffers(group, misaligned, group_buffers, group_buffer_bytes) catch {};
}

/// The group's memory, aligned forward at run time, as the scenario above aligns it.
fn aligned_group_memory() []align(group_alignment) u8 {
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_alignment);
    const start: [*]align(group_alignment) u8 = @ptrFromInt(base);
    return start[0..group_scenario_bytes];
}

/// The group the main thread reserved, which the second thread names (decision 29). With the owner
/// check deleted, a call that names it passes the check of a reserved group too.
var reserved_group: core.BufferGroup align(@alignOf(core.BufferGroup)) = undefined;

fn provide_a_group_from_another_thread() void {
    loop.init(&memory, &options) catch return;
    reserved_group = loop.reserve_buffer_group() catch return;
    on_another_thread(provide_a_group_on_this_thread);
}

fn provide_a_group_on_this_thread() void {
    scenario.reached_violation();
    loop.provide_buffers(reserved_group, aligned_group_memory(), group_buffers, group_buffer_bytes) catch {};
}

/// A datagram group needs buffers larger than a datagram's prefix, or `provide_datagram_buffers`
/// halts on that before it reaches the owner check.
const datagram_buffer_bytes = core.datagram.prefix_bytes(.{}) + group_buffer_bytes;
const datagram_group_bytes = uring.buffers.group_bytes(group_buffers, datagram_buffer_bytes);
var datagram_memory: [datagram_group_bytes + group_alignment]u8 align(group_alignment) = undefined;

/// With the owner check deleted, `provide` asks the kernel for the group from the second thread
/// and returns what it answers, and the scenario returns.
fn provide_datagram_buffers_from_another_thread() void {
    loop.init(&memory, &options) catch return;
    reserved_group = loop.reserve_buffer_group() catch return;
    on_another_thread(provide_datagram_buffers_on_this_thread);
}

fn provide_datagram_buffers_on_this_thread() void {
    const base = std.mem.alignForward(usize, @intFromPtr(&datagram_memory), group_alignment);
    const start: [*]align(group_alignment) u8 = @ptrFromInt(base);
    const group_memory_of = start[0..datagram_group_bytes];
    scenario.reached_violation();
    loop.provide_datagram_buffers(reserved_group, group_memory_of, group_buffers, datagram_buffer_bytes, .{}) catch {};
}

/// The main thread provides the group. With the owner check deleted, the second thread writes one
/// entry to the group's ring, which is memory the process shares with the kernel, and makes no
/// system call.
fn give_back_a_buffer_from_another_thread() void {
    loop.init(&memory, &options) catch return;
    reserved_group = loop.reserve_buffer_group() catch return;
    loop.provide_buffers(reserved_group, aligned_group_memory(), group_buffers, group_buffer_bytes) catch return;
    on_another_thread(give_back_a_buffer_on_this_thread);
}

fn give_back_a_buffer_on_this_thread() void {
    scenario.reached_violation();
    loop.give_back_buffer(reserved_group, 0);
}

/// The same group id twice. With the check deleted, `provide_buffers` asks the kernel for a second
/// ring under the same id and returns what it answers, and the scenario returns.
fn provide_one_group_id_twice() void {
    loop.init(&memory, &options) catch return;
    const group = loop.reserve_buffer_group() catch return;
    loop.provide_buffers(group, aligned_group_memory(), group_buffers, group_buffer_bytes) catch return;
    scenario.reached_violation();
    loop.provide_buffers(group, aligned_group_memory(), group_buffers, group_buffer_bytes) catch {};
}

/// The buffers twice. With the check deleted, `register_buffers` asks the kernel to register them
/// again and returns what it answers, and the scenario returns.
fn register_the_buffers_twice() void {
    loop.init(&memory, &options) catch return;
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
    loop.init(&memory, &options) catch return;
    scenario.reached_violation();
    _ = loop.tick(&no_events, 0) catch {};
}

fn tick_with_more_events_than_a_batch() void {
    loop.init(&memory, &options) catch return;
    scenario.reached_violation();
    _ = loop.tick(&too_many_events, 0) catch {};
}

/// A wait above `wait_ns_max`, in a tick that has an event to hand over: a timer cancelled while it
/// was still queued, which the flush ends without the kernel. Such a tick never asks `wait_bound`
/// how long to wait, and until 2026-09-23 that was the only place kqueue and epoll checked the
/// wait.
fn tick_with_a_wait_above_the_limit() void {
    loop.init(&memory, &options) catch return;
    var handle: [1]core.Handle = undefined;
    _ = loop.submit(&one_timer, &handle);
    loop.cancel(handle[0]);
    scenario.reached_violation();
    _ = loop.tick(&one_event, core.constants.wait_ns_max + 1) catch {};
}

/// Two datagram groups of different shapes on one loop (`datagram_shapes.zig`).
fn provide_datagram_groups_of_two_shapes() void {
    loop.init(&memory, &options) catch return;
    datagram_shapes.provide_two_shapes(&loop);
}

/// A group taken back while a receive from it is in flight (`buffer_release.zig`).
fn release_a_group_in_use() void {
    loop.init(&memory, &options) catch return;
    buffer_release.release_a_group_in_use(&loop);
}

/// A group taken back that was never provided (`buffer_release.zig`).
fn release_a_group_never_provided() void {
    loop.init(&memory, &options) catch return;
    buffer_release.release_a_group_never_provided(&loop);
}

/// A group provided that no caller reserved (`buffer_release.zig`). With the check deleted, the
/// kernel takes the group's ring and the scenario returns.
fn provide_a_group_never_reserved() void {
    loop.init(&memory, &options) catch return;
    buffer_release.provide_a_group_never_reserved(&loop);
}

/// An entry past those the kernel has not taken, which `send_noted_wakes` would count as a wake it
/// dropped. The ring holds no waiting entry after `init`. With the check deleted, `sqe_at` returns
/// an entry of the ring that holds what its last use left, and the scenario returns.
fn read_an_entry_the_ring_does_not_hold() void {
    loop.init(&memory, &options) catch return;
    scenario.reached_violation();
    _ = loop.ring.sqe_at(0);
}

// The descriptor a registry of one process keeps for a loop (`uring_wake.zig`; decision 4,
// amendment of 2026-11-06). With its assertion deleted, each scenario returns. `claim` in a group
// is handed a ring no process has open, so `dup3` answers EBADF and `claim` returns the error.
// `release` in a group points a pipe's read end at an eventfd, which the kernel allows. `release`
// with a stand-in that is not open closes that number, which the kernel refuses, and returns.

const wake_module = uring.wake_module;
const wake_loops = 2;
const wake_registry_bytes = uring.Registry.memory_bytes(wake_loops);
/// A group's memory is aligned to 128, as a mapping is.
var wake_registry_memory: [wake_registry_bytes]u8 align(128) = undefined;
var wake_registry: uring.Registry align(@alignOf(uring.Registry)) = undefined;

/// A descriptor no process has open. It is high rather than 0 so that a call made with it answers
/// EBADF at once.
const closed_descriptor: core.Descriptor = 4096;

/// The read end of a new pipe, or null when the kernel refused one. A scenario that cannot make it
/// returns without the marker, and the check counts that as a failure.
fn pipe_read_end() ?core.Descriptor {
    const linux = std.os.linux;
    var ends: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&ends, .{ .CLOEXEC = true })) != .SUCCESS) return null;
    return ends[0];
}

/// A group whose wakes are the read end of one real pipe, so a `dup3` onto them succeeds.
fn a_group_of_one_pipe() ?core.mailbox.Wake {
    const end = pipe_read_end() orelse return null;
    const wake: core.mailbox.Wake = .{ .send = end, .watch = end };
    const wakes = [wake_loops]core.mailbox.Wake{ wake, wake };
    wake_registry.init_group(&wake_registry_memory, wake_loops, &wakes);
    return wake;
}

fn claim_a_wake_in_a_group() void {
    _ = a_group_of_one_pipe() orelse return;
    scenario.reached_violation();
    _ = wake_module.claim(&wake_registry, 0, closed_descriptor) catch return;
}

fn release_a_wake_in_a_group() void {
    const wake = a_group_of_one_pipe() orelse return;
    wake_registry.set(0, wake.send);
    const stand_in = uring.group_module.make_private() catch return;
    scenario.reached_violation();
    wake_module.release(&wake_registry, 0, stand_in);
}

fn release_a_wake_to_a_stand_in_that_is_not_open() void {
    const end = pipe_read_end() orelse return;
    wake_registry.init(&wake_registry_memory, wake_loops);
    wake_registry.set(0, end);
    scenario.reached_violation();
    wake_module.release(&wake_registry, 0, closed_descriptor);
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "buffers: release a group in use", .run = release_a_group_in_use },
    .{ .name = "buffers: release a group never provided", .run = release_a_group_never_provided },
    .{ .name = "buffers: provide a group never reserved", .run = provide_a_group_never_reserved },
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
    .{
        .name = "datagrams: provide groups of two shapes",
        .run = provide_datagram_groups_of_two_shapes,
    },
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
    .{
        .name = "ring: read an entry the ring does not hold",
        .run = read_an_entry_the_ring_does_not_hold,
    },
    .{ .name = "loop: end a loop that a watch reads", .run = end_a_loop_that_a_watch_reads },
    .{ .name = "call: wake the loop that makes the call", .run = wake_the_loop_that_makes_the_call },
    .{ .name = "wake: claim a wake in a group", .run = claim_a_wake_in_a_group },
    .{ .name = "wake: release a wake in a group", .run = release_a_wake_in_a_group },
    .{
        .name = "wake: release a wake to a stand-in that is not open",
        .run = release_a_wake_to_a_stand_in_that_is_not_open,
    },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
