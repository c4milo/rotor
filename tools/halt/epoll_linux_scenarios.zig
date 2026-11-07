//! Halt scenarios for the `epoll` module that need a Linux kernel. `zig build test-linux` builds
//! this file and `tools/halt_check.zig` for Linux, and `tools/linux_test.sh` runs the check on it
//! in Docker under the default seccomp profile, which refuses io_uring: the environment the epoll
//! backend exists for (decision 20). `zig build halt-check` does not run it.
//!
//! A scenario proves an assertion only if the scenario returns once that assertion is deleted. Each
//! scenario here makes Linux calls, before its check or after it, and on a Mac those calls run
//! other system calls (`epoll_scenarios.zig`). That is why the scenarios are here. All but the
//! offload's run on a loop with a real epoll instance (`Loop.init`), so with the assertion deleted
//! the loop makes its Linux calls and the scenario returns.
const std = @import("std");
const core = @import("core");
const epoll = @import("epoll");
const scenario = @import("scenario.zig");

const Loop = epoll.Loop;

const options: Loop.Options = .{ .operations = 4, .entries = 4 };

var memory: [Loop.memory_bytes(&options)]u8 align(core.layout.memory_alignment) = undefined;
var loop: Loop align(@alignOf(Loop)) = undefined;

/// A loop belongs to the thread that initialised it (decision 4). An epoll instance has no owning
/// thread, so with the owner check deleted the second thread's `epoll_pwait2` returns at once with
/// nothing ready, `tick` returns 0, and the scenario returns.
fn tick_from_another_thread() void {
    loop.init(&memory, &options) catch return;
    const thread = std.Thread.spawn(.{}, tick_on_this_thread, .{}) catch return;
    thread.join();
}

fn tick_on_this_thread() void {
    var events: [1]core.Event = undefined;
    scenario.reached_violation();
    _ = loop.tick(&events, 0) catch {};
}

/// A descriptor no process has open. It is high rather than 0 so that `fcntl` answers `EBADF` for
/// it, whatever the container left open.
const closed_descriptor: core.Descriptor = 4096;

/// With the owner check deleted, the second thread's `fcntl` of the closed descriptor fails,
/// `register_descriptors` returns `DescriptorInvalid`, and the scenario returns.
fn register_descriptors_from_another_thread() void {
    loop.init(&memory, &options) catch return;
    const thread = std.Thread.spawn(.{}, register_descriptors_on_this_thread, .{}) catch return;
    thread.join();
}

fn register_descriptors_on_this_thread() void {
    const descriptors = [_]core.Descriptor{closed_descriptor};
    scenario.reached_violation();
    loop.register_descriptors(&descriptors) catch {};
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

/// The wait timer's bounds (decision 20, "The wait timer"). A timer of 0 ns would disarm it and
/// leave the wait unbounded. With a check deleted, `timerfd_settime` takes the value and the
/// scenario returns.
fn arm_a_wait_timer_of_nothing() void {
    loop.init(&memory, &options) catch return;
    scenario.reached_violation();
    _ = loop.queue.arm_wait_timer(0);
}

fn arm_a_wait_timer_above_the_wait_limit() void {
    loop.init(&memory, &options) catch return;
    scenario.reached_violation();
    _ = loop.queue.arm_wait_timer(core.constants.wait_ns_max + 1);
}

/// A watch that still reads the heartbeat when the loop ends (decision 28). With the check
/// deleted, `deinit` closes the loop's epoll instance and returns.
fn end_a_loop_that_a_watch_reads() void {
    loop.init(&memory, &options) catch return;
    var watch = loop.heartbeat().watch();
    _ = &watch;
    scenario.reached_violation();
    loop.deinit();
}

// A worker's push into a full ring (decision 18, amendment of 2026-11-06). `run` makes its
// system call before the push, a Linux `pread`, so this scenario is here and not in the file a Mac
// runs. The loop comes up through `init_tables` and holds no epoll instance: an awake loop is never
// woken, so `run` makes no other call.

/// One worker, so ring 0 is the only ring there is.
const offload_workers: u16 = 1;

const offload_options: Loop.Options = .{
    .operations = 4,
    .entries = 4,
    .file_policy = .offload,
    .offload = .{ .context = null, .submit = capture, .workers = offload_workers },
};

const alignment = core.layout.memory_alignment;
var offload_memory: [Loop.memory_bytes(&offload_options)]u8 align(alignment) = undefined;
const ring_bytes = epoll.offload_module.memory_bytes(offload_workers);
var ring_memory: [ring_bytes]u8 align(alignment) = undefined;

/// The work the loop handed out, kept so the scenario can run it as a worker would.
var captured: ?*core.offload.Work = null;

fn capture(context: ?*anyopaque, work: *core.offload.Work) void {
    _ = context;
    captured = work;
}

var read_buffer: [64]u8 = undefined;

/// The loop hands out at most `offload_in_flight_max` operations, so only rotor's own count can
/// fill a ring. The scenario fills it itself. With the check deleted, the result is dropped, no
/// wake is due, and `run` returns.
fn push_a_result_into_a_full_ring() void {
    var options_with_rings = offload_options;
    options_with_rings.offload_memory = &ring_memory;
    loop.init_tables(&offload_memory, &options_with_rings);
    const read = core.Operation.read(1, closed_descriptor, &read_buffer, 0);
    _ = loop.submit(&.{read}, &.{});
    epoll.submit_module.flush(&loop);
    const work = captured orelse return;
    const ring = &loop.inbox.completions[0];
    for (0..core.constants.mailbox_messages) |_| {
        if (!ring.push(.{ .tag = 0, .payload = work.index })) return;
    }
    scenario.reached_violation();
    work.run(0);
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "loop: end a loop that a watch reads", .run = end_a_loop_that_a_watch_reads },
    .{ .name = "offload: push a result into a full ring", .run = push_a_result_into_a_full_ring },
    .{ .name = "tick: arm a wait timer of 0 ns", .run = arm_a_wait_timer_of_nothing },
    .{
        .name = "tick: arm a wait timer above the wait limit",
        .run = arm_a_wait_timer_above_the_wait_limit,
    },
    .{ .name = "tick: tick with no room for an event", .run = tick_with_no_room_for_an_event },
    .{
        .name = "tick: tick with more events than a batch",
        .run = tick_with_more_events_than_a_batch,
    },
    .{ .name = "tick: tick with a wait above the limit", .run = tick_with_a_wait_above_the_limit },
    .{ .name = "owner: tick from another thread", .run = tick_from_another_thread },
    .{
        .name = "owner: register descriptors from another thread",
        .run = register_descriptors_from_another_thread,
    },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
