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
//! This rule changes two scenarios:
//!
//! - `tick` from another thread is left out. With the owner check deleted, `tick` reads the clock
//!   next. On 2026-09-22 macOS ran `writev` in place of `clock_gettime`, nothing wrote the time,
//!   and the scenario died on the assertion that reads it. The check is `core.Tables.assert_owner`:
//!   `submit` from another thread proves it here, and kqueue's `tick` from another thread proves it
//!   through a tick.
//! - The scenario for a group that is not aligned calls `buffers.assert_aligned` directly. It used
//!   to call `provide_buffers`, which calls `io_uring_register` after the check. With the check
//!   deleted, on 2026-09-22 macOS ran `chown` in its place, which failed, and the scenario
//!   returned; another value in x16 could have halted it.
//!
//! No scenario proves that uring's own `tick` and `provide_buffers` make these checks. That needs a
//! halt check run under Linux. With its assertion deleted, no scenario here makes a Linux system
//! call: `submit`, `assert_empty`, `assert_aligned` and the registry make none, and each remote
//! `post` answers `LoopNotFound` from the registry before it reaches the ring.
const std = @import("std");
const core = @import("core");
const uring = @import("uring");
const scenario = @import("scenario.zig");

const Loop = uring.Loop;

const options: Loop.Options = .{ .operations = 4, .entries = 4, .id = 2 };

var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
var loop: Loop = undefined;

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

// The Remote's assertions (decision 4). Each is a mistake only the caller can make. On io_uring a
// Remote's `init` creates a ring, which this host may not have, so the scenarios claim the registry
// slot themselves and fill the remote's fields by hand; each assertion then fires before the ring
// would be touched, so the check runs on every host.

/// A registry of two slots, which the scenarios claim as a loop and a remote would.
const remote_ids: u16 = 2;
const remote_registry_bytes = uring.Registry.memory_bytes(remote_ids);
var remote_registry_memory: [remote_registry_bytes]u8 align(core.layout.memory_alignment) =
    undefined;
var remote_registry: uring.Registry = undefined;
var remote_one: uring.Remote = undefined;

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

/// Memory for one small group, with two alignments of slack: the scenario aligns a pointer forward
/// inside this array and then spoils it, so it needs room for both steps.
const group_scenario_buffers = 2;
const group_scenario_buffer_bytes = 64;
const group_scenario_alignment = uring.buffers.group_alignment;
const group_scenario_bytes =
    uring.buffers.group_bytes(group_scenario_buffers, group_scenario_buffer_bytes);
const group_scenario_slack = group_scenario_bytes + 2 * group_scenario_alignment;
var group_memory: [group_scenario_slack]u8 align(group_scenario_alignment) = undefined;

/// A group whose memory is one `io_uring_buf` past `group_alignment`, which io_uring's buffer ring
/// requires. The kernel answers EINVAL for it, and that arrived as one nameless `Unexpected` until
/// 2026-09-22, which cost a consumer a day. That consumer's memory passed every cast and failed only
/// in the kernel, and this offset has the same shape.
///
/// The scenario calls `buffers.assert_aligned` itself, the check `provide_buffers` makes. With that
/// check deleted, `provide_buffers` would call `io_uring_register` next, which on macOS runs some
/// other call (this file's header).
///
/// The address is aligned forward first and spoiled after, rather than taken from the array as
/// declared: macOS does not always give a static the alignment it asks for, and this check runs on
/// every host. The slice is built with safety checks off, because an `@alignCast` in a checked build
/// refuses the cast at the call site while a caller built without checks does not; rotor's
/// assertions stay on either way (CLAUDE.md non-negotiable 1).
fn provide_a_group_that_is_not_aligned() void {
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_scenario_alignment);
    const misaligned = blk: {
        @setRuntimeSafety(false);
        const start: [*]align(group_scenario_alignment) u8 =
            @ptrFromInt(base + @sizeOf(std.os.linux.io_uring_buf));
        break :blk start[0..group_scenario_bytes];
    };
    scenario.reached_violation();
    uring.buffers.assert_aligned(misaligned);
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
    .{ .name = "remote: claim one id with two remotes", .run = claim_one_id_with_two_remotes },
    .{ .name = "remote: claim a loop's id with a remote", .run = claim_a_loops_id_with_a_remote },
    .{ .name = "remote: post from a remote to itself", .run = post_from_a_remote_to_itself },
    .{
        .name = "remote: post from a remote on another thread",
        .run = post_from_a_remote_on_another_thread,
    },
    .{ .name = "remote: post a tag above the limit", .run = post_a_tag_above_the_limit },
    .{
        .name = "buffers: provide a group that is not aligned",
        .run = provide_a_group_that_is_not_aligned,
    },
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
