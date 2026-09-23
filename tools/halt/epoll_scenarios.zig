//! Halt scenarios for the `epoll` module: the assertions a caller's mistake can reach. Each runs
//! on a loop with tables and no epoll instance, because every one of them halts before the loop
//! would enter the kernel, so the check runs on every host, macOS included.
//!
//! This is `kqueue_scenarios.zig` less two of its scenarios, and the reason is where the check runs.
//! `zig build halt-check` runs on the developer's Mac, and a scenario proves an assertion only if,
//! with that assertion deleted, the scenario returns. On a Mac a Linux system call does not fail
//! cleanly: macOS reads the call number from another register, so it runs some other call of its
//! own. A scenario whose path after the violating statement reaches a Linux call could then die, or
//! not, for that reason, and a deleted assertion could pass for a halt. So every scenario here halts
//! on a path that makes no Linux call, and two of kqueue's are left out:
//!
//! - `tick` from another thread. With the owner check gone, the next statement reads the clock.
//!   `epoll_linux_scenarios.zig` has this scenario, and the Linux gate runs it on a real epoll
//!   instance.
//! - An offload worker the loop has no ring for. With the bound gone, the worker makes its `pread`.
//!   No scenario on any host proves this bound. With it gone, the worker indexes its ring next,
//!   and the bounds check on that index halts the scenario. On 2026-09-22 kqueue's copy of this
//!   scenario still halted with the bound deleted.
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

/// The offload's hand-off. Nothing calls it: every offload scenario here halts in `init_tables`,
/// before an operation could be handed out.
fn capture(context: ?*anyopaque, work: *core.offload.Work) void {
    _ = context;
    _ = work;
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

// The Remote's assertions (decision 4). Each is a mistake only the caller can make. A remote's
// `init` and `post` reach the registry and its rings before any system call, and with any of these
// assertions deleted, `post` answers `LoopNotFound` without one: the target of each is an id that
// no loop holds.

/// A registry of two ids, which the scenarios claim as a loop and a remote would.
const remote_ids: u16 = 2;
const remote_registry_bytes = epoll.Registry.memory_bytes(remote_ids);
var remote_registry_memory: [remote_registry_bytes]u8 align(core.layout.memory_alignment) =
    undefined;
var remote_registry: epoll.Registry = undefined;
var remote_one: epoll.Remote = undefined;

/// Two remotes claiming one id would put two producers on a single-producer ring.
fn claim_one_id_with_two_remotes() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    var remote_two: epoll.Remote = undefined;
    remote_one.init(&remote_registry, 1) catch return;
    scenario.reached_violation();
    remote_two.init(&remote_registry, 1) catch return;
}

/// A remote claiming an id a loop already holds: the loop published its eventfd there, and the
/// remote would overwrite it. The number is never written to: nothing here posts.
fn claim_a_loops_id_with_a_remote() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    const published_wake: core.Descriptor = 3;
    remote_registry.set(0, published_wake);
    scenario.reached_violation();
    remote_one.init(&remote_registry, 0) catch return;
}

/// A remote posting to its own id. It has nothing to receive with, so a message to itself is a
/// programmer error, as a loop posting to itself is.
fn post_from_a_remote_to_itself() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    remote_one.init(&remote_registry, 1) catch return;
    scenario.reached_violation();
    _ = remote_one.post(1, .{ .payload = 0, .tag = 0 }) catch {};
}

/// A remote used from a thread that did not create it: two producers on one ring.
fn post_from_a_remote_on_another_thread() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    remote_one.init(&remote_registry, 1) catch return;
    const thread = std.Thread.spawn(.{}, post_through_remote_one, .{}) catch return;
    thread.join();
}

fn post_through_remote_one() void {
    scenario.reached_violation();
    _ = remote_one.post(0, .{ .payload = 0, .tag = 0 }) catch {};
}

/// A tag above `message_tag_max`, which the receiving loop could not fit in an event's result.
fn post_a_tag_above_the_limit() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    remote_one.init(&remote_registry, 1) catch return;
    scenario.reached_violation();
    _ = remote_one.post(0, .{ .payload = 0, .tag = core.constants.message_tag_max + 1 }) catch {};
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
    .{ .name = "remote: claim one id with two remotes", .run = claim_one_id_with_two_remotes },
    .{ .name = "remote: claim a loop's id with a remote", .run = claim_a_loops_id_with_a_remote },
    .{ .name = "remote: post from a remote to itself", .run = post_from_a_remote_to_itself },
    .{
        .name = "remote: post from a remote on another thread",
        .run = post_from_a_remote_on_another_thread,
    },
    .{ .name = "remote: post a tag above the limit", .run = post_a_tag_above_the_limit },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
