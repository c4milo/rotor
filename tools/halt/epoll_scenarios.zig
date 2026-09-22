//! Halt scenarios for the `epoll` module: the assertions a caller's mistake can reach. Each runs
//! on a loop with tables and no epoll instance, because every one of them halts before the loop
//! would enter the kernel, so the check runs on every host, macOS included.
//!
//! This is `kqueue_scenarios.zig` for the organs decision 20's build has reached. The scenarios of
//! `tick`, `cancel` and the `Remote` join it as those are built; until then this file covers the
//! loop's lifecycle, its options, the offload's options and the buffer groups.
const std = @import("std");
const core = @import("core");
const epoll = @import("epoll");
const scenario = @import("scenario.zig");

const Loop = epoll.Loop;

const options: Loop.Options = .{ .operations = 4, .entries = 4, .id = 2 };

var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
var loop: Loop = undefined;

const one_timer = [_]core.Operation{
    .{ .user_data = 1, .kind = .{ .timer = .{ .after_ns = 1 } } },
};

/// A loop belongs to the thread that initialised it (decision 4), so a `submit` from another
/// thread halts on `assert_owner` before it touches the table.
fn submit_from_another_thread() void {
    loop.init_tables(&memory, options);
    const thread = std.Thread.spawn(.{}, submit_on_this_thread, .{}) catch return;
    thread.join();
}

fn submit_on_this_thread() void {
    scenario.reached_violation();
    _ = loop.submit(&one_timer, &.{});
}

/// Decision 5, rule 7: every operation must have had its final event before the loop ends. The
/// scenario calls the check itself rather than `deinit`, because this loop has no epoll instance
/// for `deinit` to close and a halt inside that close would pass for the wrong reason.
fn end_a_loop_with_an_operation_in_flight() void {
    loop.init_tables(&memory, options);
    _ = loop.submit(&one_timer, &.{});
    scenario.reached_violation();
    loop.assert_empty();
}

/// A loop cannot post to itself: it would be the producer and the consumer of one ring, which the
/// ordering argument of `core/mailbox.zig` does not hold for.
fn post_to_the_loop_itself() void {
    loop.init_tables(&memory, options);
    const post = [_]core.Operation{.{ .user_data = 1, .kind = .{ .post = .{
        .target = options.id,
        .message = .{ .payload = 0, .tag = 0 },
    } } }};
    scenario.reached_violation();
    _ = loop.submit(&post, &.{});
}

/// One handle per operation. More handles than operations means the caller would read a handle the
/// loop never wrote.
fn submit_more_handles_than_operations() void {
    loop.init_tables(&memory, options);
    var handles: [2]core.Handle = undefined;
    scenario.reached_violation();
    _ = loop.submit(&one_timer, &handles);
}

// The offload's assertions (decision 18). Each is a mistake only the caller can make at init, and
// each halts before the loop would enter the kernel, so these run on every host like the rest.

/// One worker, so ring 0 is the only ring there is.
const offload_workers: u16 = 1;

const offload_options: Loop.Options = .{
    .operations = 4,
    .entries = 4,
    .id = 2,
    .file_policy = .offload,
    .offload = .{ .context = null, .submit = capture, .workers = offload_workers },
};

const alignment = core.layout.memory_alignment;
var offload_memory: [Loop.memory_bytes(offload_options)]u8 align(alignment) = undefined;
const ring_bytes = epoll.offload_module.memory_bytes(offload_workers);
var ring_memory: [ring_bytes]u8 align(alignment) = undefined;

/// Ring memory with room to spare, for the scenario that asks for more workers than the limit. With
/// a small block, `init_rings` would refuse the memory before the worker count was ever judged, and
/// the scenario would halt for the wrong reason: deleting the bound it tests would still halt.
var ample_ring_memory: [1 << 20]u8 align(alignment) = undefined;

/// The work the loop handed out, kept so a scenario can answer with it.
var captured: ?*core.offload.Work = null;

fn capture(context: ?*anyopaque, work: *core.offload.Work) void {
    _ = context;
    captured = work;
}

/// The `offload` policy with no offload: nothing would ever answer, so every file operation would
/// wait for a final event that cannot come (decision 5, rule 1).
fn choose_the_offload_policy_without_an_offload() void {
    var options_without: Loop.Options = offload_options;
    options_without.offload = null;
    scenario.reached_violation();
    loop.init_tables(&offload_memory, options_without);
}

/// An offload with no worker: `submit` would be called and no thread would ever run the work.
fn give_an_offload_no_workers() void {
    var options_empty: Loop.Options = offload_options;
    options_empty.offload = .{ .context = null, .submit = capture, .workers = 0 };
    options_empty.offload_memory = &ring_memory;
    scenario.reached_violation();
    loop.init_tables(&offload_memory, options_empty);
}

/// An offload with more workers than a loop holds rings for.
fn give_an_offload_more_workers_than_the_limit() void {
    var options_many: Loop.Options = offload_options;
    options_many.offload = .{
        .context = null,
        .submit = capture,
        .workers = core.constants.offload_workers_max + 1,
    };
    options_many.offload_memory = &ample_ring_memory;
    scenario.reached_violation();
    loop.init_tables(&offload_memory, options_many);
}

// The buffer groups' assertions. `provide` takes `[]align(group_alignment) u8`, so the type carries
// io_uring's figure; what this backend actually needs is u16, because the free list is read through
// a `[*]u16`. A consumer spent a day on the io_uring one before the assert existed (2026-09-22), so
// the assert is here on every backend and this scenario proves it fires.

const group_buffers = 2;
const group_buffer_bytes = 64;
const group_alignment = epoll.buffers.group_alignment;
const group_scenario_bytes = epoll.buffers.group_bytes(group_buffers, group_buffer_bytes);
const group_slack = group_scenario_bytes + 2 * group_alignment;
var group_memory: [group_slack]u8 align(group_alignment) = undefined;

/// A group whose memory is one byte past the alignment the call requires. Safety is off for the
/// cast alone: the pointer's declared alignment is a lie the scenario tells on purpose, which is
/// exactly the lie a caller tells when its own memory is not aligned.
fn provide_a_group_that_is_not_aligned() void {
    loop.init_tables(&memory, options);
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_alignment);
    const misaligned = blk: {
        @setRuntimeSafety(false);
        const start: [*]align(group_alignment) u8 = @ptrFromInt(base + 1);
        break :blk start[0..group_scenario_bytes];
    };
    scenario.reached_violation();
    loop.provide_buffers(0, misaligned, group_buffers, group_buffer_bytes) catch {};
}

/// Aligned memory, so the group is made, and then the same group id again: the second call would
/// leave the first group's buffers with the caller and no way to give them back.
fn provide_one_group_id_twice() void {
    loop.init_tables(&memory, options);
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_alignment);
    const aligned: []align(group_alignment) u8 = blk: {
        const start: [*]align(group_alignment) u8 = @ptrFromInt(base);
        break :blk start[0..group_scenario_bytes];
    };
    loop.provide_buffers(0, aligned, group_buffers, group_buffer_bytes) catch return;
    scenario.reached_violation();
    loop.provide_buffers(0, aligned, group_buffers, group_buffer_bytes) catch {};
}

/// The buffers are registered once per loop. A second call would replace what the first recorded
/// while the kernel still held the first set, on the backend where registering means something.
fn register_buffers_twice() void {
    loop.init_tables(&memory, options);
    var block: [64]u8 = undefined;
    const registered = [_][]u8{&block};
    loop.register_buffers(&registered) catch return;
    scenario.reached_violation();
    loop.register_buffers(&registered) catch {};
}

/// A buffer id the group does not hold: giving one back would grow the free stack past the count.
fn give_back_a_buffer_the_group_does_not_hold() void {
    loop.init_tables(&memory, options);
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_alignment);
    const aligned: []align(group_alignment) u8 = blk: {
        const start: [*]align(group_alignment) u8 = @ptrFromInt(base);
        break :blk start[0..group_scenario_bytes];
    };
    loop.provide_buffers(0, aligned, group_buffers, group_buffer_bytes) catch return;
    scenario.reached_violation();
    loop.give_back_buffer(0, group_buffers);
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "loop: submit from another thread", .run = submit_from_another_thread },
    .{
        .name = "loop: end a loop with an operation in flight",
        .run = end_a_loop_with_an_operation_in_flight,
    },
    .{ .name = "loop: post to the loop itself", .run = post_to_the_loop_itself },
    .{
        .name = "loop: submit with more handles than operations",
        .run = submit_more_handles_than_operations,
    },
    .{
        .name = "offload: choose the offload policy without an offload",
        .run = choose_the_offload_policy_without_an_offload,
    },
    .{ .name = "offload: give an offload no workers", .run = give_an_offload_no_workers },
    .{
        .name = "offload: give an offload more workers than the limit",
        .run = give_an_offload_more_workers_than_the_limit,
    },
    .{
        .name = "buffers: provide a group that is not aligned",
        .run = provide_a_group_that_is_not_aligned,
    },
    .{ .name = "buffers: provide one group id twice", .run = provide_one_group_id_twice },
    .{ .name = "buffers: register the buffers twice", .run = register_buffers_twice },
    .{
        .name = "buffers: give back a buffer the group does not hold",
        .run = give_back_a_buffer_the_group_does_not_hold,
    },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
