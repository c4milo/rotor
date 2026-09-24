//! Halt scenarios for the `uring` module: the assertions a caller's mistake can reach. Each runs
//! with no ring, because every one of them halts before anything would enter the kernel, so the
//! check runs on every host.
//!
//! A scenario proves an assertion only if the scenario returns once that assertion is deleted. So,
//! with the assertion deleted, the path after the violating statement must make no Linux system
//! call. The halt check runs on macOS. On arm64 a Linux system call puts its number in x8, macOS
//! reads the number from x16, and so macOS runs whatever call x16 happens to name. A scenario whose
//! assertion was deleted could then die for that reason, and the check would count a halt.
//!
//! A scenario that breaks this rule is in `uring_linux_scenarios.zig`, which the Linux gate runs on
//! a real ring. The first two moved there on 2026-09-22, and they show why:
//!
//! - `tick` from another thread. With the owner check deleted, `tick` reads the clock next. On
//!   2026-09-22 macOS ran `writev` in place of `clock_gettime`, nothing wrote the time, and the
//!   scenario died on the assertion that reads it.
//! - `provide_buffers` with a group that is not aligned. With the check deleted, `provide` calls
//!   `io_uring_register` next. On 2026-09-22 macOS ran `chown` in its place, which failed, and the
//!   scenario returned; another value in x16 could have halted it.
//!
//! The owner checks of `deinit`, `register_buffers`, `register_descriptors`, `provide_buffers`,
//! `give_back_buffer` and a remote's `deinit` are there as well: each needs a ring to be set up, or
//! enters the kernel once its check is deleted.
//!
//! With its assertion deleted, no scenario here makes a Linux system call: `submit`, `cancel`,
//! `cancel_all`, `assert_empty` and the registry make none, and each remote `post` answers
//! `LoopNotFound` from the registry before it reaches the ring.
const std = @import("std");
const core = @import("core");
const uring = @import("uring");
const scenario = @import("scenario.zig");

const Loop = uring.Loop;

const options: Loop.Options = .{ .operations = 4, .entries = 4, .id = 2 };

var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
var loop: Loop align(@alignOf(Loop)) = undefined;

const one_timer = [_]core.Operation{
    .{ .user_data = 1, .kind = .{ .timer = .{ .after_ns = 1 } } },
};

fn submit_from_another_thread() void {
    loop.init_tables(&memory, options);
    const thread = std.Thread.spawn(.{}, submit_on_this_thread, .{}) catch return;
    thread.join();
}

fn submit_on_this_thread() void {
    scenario.reached_violation();
    _ = loop.submit(&one_timer, &.{});
}

/// The handle names a timer still queued, so with the owner check deleted the cancel marks it and
/// returns: the next flush would end it before the kernel saw it.
var timer_handle: [1]core.Handle align(@alignOf(core.Handle)) = undefined;

fn cancel_from_another_thread() void {
    loop.init_tables(&memory, options);
    _ = loop.submit(&one_timer, &timer_handle);
    const thread = std.Thread.spawn(.{}, cancel_on_this_thread, .{}) catch return;
    thread.join();
}

fn cancel_on_this_thread() void {
    scenario.reached_violation();
    loop.cancel(timer_handle[0]);
}

fn cancel_every_operation_from_another_thread() void {
    loop.init_tables(&memory, options);
    _ = loop.submit(&one_timer, &.{});
    const thread = std.Thread.spawn(.{}, cancel_every_operation_on_this_thread, .{}) catch return;
    thread.join();
}

fn cancel_every_operation_on_this_thread() void {
    scenario.reached_violation();
    loop.cancel_all();
}

/// `deinit` checks this first. The scenario calls the check itself, because its loop has no ring
/// for `deinit` to close, and a halt inside the ring's own close would pass for the wrong reason.
fn end_a_loop_with_an_operation_in_flight() void {
    loop.init_tables(&memory, options);
    _ = loop.submit(&one_timer, &.{});
    scenario.reached_violation();
    loop.assert_empty();
}

fn post_to_the_loop_itself() void {
    loop.init_tables(&memory, options);
    const post = [_]core.Operation{.{ .user_data = 1, .kind = .{ .post = .{
        .target = options.id,
        .message = .{ .payload = 0, .tag = 0 },
    } } }};
    scenario.reached_violation();
    _ = loop.submit(&post, &.{});
}

fn submit_more_handles_than_operations() void {
    loop.init_tables(&memory, options);
    var handles: [2]core.Handle = undefined;
    scenario.reached_violation();
    _ = loop.submit(&one_timer, &handles);
}

// The offload's options (decision 18). io_uring uses none of them, and checks them as kqueue and
// epoll do, so options that halt there halt here. Each check comes before the ring would exist.

/// One worker, so the rings the options must carry are one ring's.
const offload_workers: u16 = 1;

fn submit_nothing(context: ?*anyopaque, work: *core.offload.Work) void {
    _ = context;
    _ = work;
}

const offload_options: Loop.Options = .{
    .operations = 4,
    .entries = 4,
    .id = 2,
    .file_policy = .offload,
    .offload = .{ .context = null, .submit = submit_nothing, .workers = offload_workers },
};

const alignment = core.layout.memory_alignment;
const ring_bytes = core.offload.memory_bytes(offload_workers);
var ring_memory: [ring_bytes]u8 align(alignment) = undefined;

/// Ring memory with room to spare, so the worker count is the only thing wrong with the options.
var ample_ring_memory: [1 << 20]u8 align(alignment) = undefined;

/// The `offload` policy with no offload: on epoll nothing would ever answer a file operation.
fn choose_the_offload_policy_without_an_offload() void {
    var options_without: Loop.Options = offload_options;
    options_without.offload = null;
    options_without.offload_memory = &ring_memory;
    scenario.reached_violation();
    loop.init_tables(&memory, options_without);
}

fn give_an_offload_no_workers() void {
    var options_empty: Loop.Options = offload_options;
    options_empty.offload = .{ .context = null, .submit = submit_nothing, .workers = 0 };
    options_empty.offload_memory = &ring_memory;
    scenario.reached_violation();
    loop.init_tables(&memory, options_empty);
}

fn give_an_offload_more_workers_than_the_limit() void {
    var options_many: Loop.Options = offload_options;
    options_many.offload = .{
        .context = null,
        .submit = submit_nothing,
        .workers = core.constants.offload_workers_max + 1,
    };
    options_many.offload_memory = &ample_ring_memory;
    scenario.reached_violation();
    loop.init_tables(&memory, options_many);
}

/// Less ring memory than the workers need. kqueue and epoll halt on this twice, once here and once
/// when they carve their rings, so only this backend's scenario can prove the first check.
fn give_an_offload_too_little_ring_memory() void {
    var options_short: Loop.Options = offload_options;
    options_short.offload_memory = ring_memory[0 .. ring_bytes - alignment];
    scenario.reached_violation();
    loop.init_tables(&memory, options_short);
}

fn name_an_offload_under_another_policy() void {
    var options_blocking: Loop.Options = offload_options;
    options_blocking.file_policy = .blocking;
    scenario.reached_violation();
    loop.init_tables(&memory, options_blocking);
}

// The Remote's assertions (decision 4). Each is a mistake only the caller can make. On io_uring a
// Remote's `init` creates a ring, which this host may not have, so the scenarios claim the registry
// slot themselves and fill the remote's fields by hand; each assertion then fires before the ring
// would be touched, so the check runs on every host.

/// A registry of two slots, which the scenarios claim as a loop and a remote would.
const remote_ids: u16 = 2;
const remote_registry_bytes = uring.Registry.memory_bytes(remote_ids);
var remote_registry_memory: [remote_registry_bytes]u8 align(core.layout.memory_alignment) =
    undefined;
var remote_registry: uring.Registry align(@alignOf(uring.Registry)) = undefined;
var remote_one: uring.Remote align(@alignOf(uring.Remote)) = undefined;

/// What `Remote.init` would record for `id` on this thread, without the ring.
fn claim_remote_one_by_hand(id: core.LoopId) void {
    remote_one.registry = &remote_registry;
    remote_one.owner = core.tables.thread_identity();
    remote_one.id = id;
    remote_one.unanswered = false;
    remote_registry.set_remote(id);
}

/// Two remotes claiming one id: the second would take a slot whose messages name the first.
fn claim_one_id_with_two_remotes() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    remote_registry.set_remote(1);
    scenario.reached_violation();
    remote_registry.set_remote(1);
}

/// A remote claiming an id a loop already holds: the loop published its ring there, and the remote
/// would overwrite it.
fn claim_a_loops_id_with_a_remote() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    remote_registry.set(0, 3);
    scenario.reached_violation();
    remote_registry.set_remote(0);
}

/// A remote posting to its own id. It has no ring to receive with, so a message to oneself is a
/// programmer error, as a loop posting to itself is.
fn post_from_a_remote_to_itself() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    claim_remote_one_by_hand(1);
    scenario.reached_violation();
    _ = remote_one.post(1, .{ .payload = 0, .tag = 0 }) catch {};
}

/// A remote used from a thread that did not create it: the ring is single-issuer, and the halt
/// comes before the kernel would refuse the entry.
fn post_from_a_remote_on_another_thread() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    claim_remote_one_by_hand(1);
    const thread = std.Thread.spawn(.{}, post_through_remote_one, .{}) catch return;
    thread.join();
}

fn post_through_remote_one() void {
    scenario.reached_violation();
    _ = remote_one.post(0, .{ .payload = 0, .tag = 0 }) catch {};
}

/// A tag above `message_tag_max`, which would collide with the flag the reap tells a message by.
fn post_a_tag_above_the_limit() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    claim_remote_one_by_hand(1);
    scenario.reached_violation();
    _ = remote_one.post(0, .{ .payload = 0, .tag = core.constants.message_tag_max + 1 }) catch {};
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "owner: submit from another thread", .run = submit_from_another_thread },
    .{ .name = "owner: cancel from another thread", .run = cancel_from_another_thread },
    .{
        .name = "owner: cancel every operation from another thread",
        .run = cancel_every_operation_from_another_thread,
    },
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
        .name = "offload: give an offload too little ring memory",
        .run = give_an_offload_too_little_ring_memory,
    },
    .{
        .name = "offload: name an offload under another policy",
        .run = name_an_offload_under_another_policy,
    },
    .{ .name = "remote: claim one id with two remotes", .run = claim_one_id_with_two_remotes },
    .{ .name = "remote: claim a loop's id with a remote", .run = claim_a_loops_id_with_a_remote },
    .{ .name = "remote: post from a remote to itself", .run = post_from_a_remote_to_itself },
    .{
        .name = "owner: post from a remote on another thread",
        .run = post_from_a_remote_on_another_thread,
    },
    .{ .name = "remote: post a tag above the limit", .run = post_a_tag_above_the_limit },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
