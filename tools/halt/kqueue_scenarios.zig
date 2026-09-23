//! Halt scenarios for the `kqueue` module: the assertions a caller's mistake can reach. Each runs
//! on a loop with tables and no kqueue, because every one of them halts before the loop would
//! enter the kernel, so the check runs on every host.
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

fn submit_from_another_thread() void {
    loop.init_tables(&memory, options);
    const thread = std.Thread.spawn(.{}, submit_on_this_thread, .{}) catch return;
    thread.join();
}

fn submit_on_this_thread() void {
    scenario.reached_violation();
    _ = loop.submit(&one_timer, &.{});
}

fn tick_from_another_thread() void {
    loop.init_tables(&memory, options);
    const thread = std.Thread.spawn(.{}, tick_on_this_thread, .{}) catch return;
    thread.join();
}

fn tick_on_this_thread() void {
    var events: [1]core.Event = undefined;
    scenario.reached_violation();
    _ = loop.tick(&events, 0) catch {};
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

// The offload's assertions (decision 18). Each is a mistake only the caller can make, and each
// halts before the loop would enter the kernel, so these run on every host like the rest.

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
const ring_bytes = kqueue.offload_module.memory_bytes(offload_workers);
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

/// A descriptor no process has open. `Operation.assert_valid` refuses a negative one, so the read
/// below needs a real number, and the check under test fires before the system call is made. It is
/// deliberately high rather than 0: if a mutation moved that check after the call, this answers
/// `EBADF` at once, where a `pread` of descriptor 0 could block on standard input and hang the
/// check instead of reporting that it did not halt.
const closed_descriptor: core.Descriptor = 4096;

var read_buffer: [64]u8 = undefined;

const one_read = [_]core.Operation{
    .{ .user_data = 1, .kind = .{ .read = .{
        .file = closed_descriptor,
        .buffer = .{ .bytes = &read_buffer },
        .offset = 0,
    } } },
};

/// Hands one file read to the offload without entering the kernel: under the `offload` policy the
/// flush calls the caller's `submit` and makes no system call.
fn hand_out_one() *core.offload.Work {
    var options_with_rings = offload_options;
    options_with_rings.offload_memory = &ring_memory;
    loop.init_tables(&offload_memory, options_with_rings);
    _ = loop.submit(&one_read, &.{});
    kqueue.submit_module.flush(&loop);
    return captured.?;
}

/// A worker index the loop holds no ring for. With one worker there is one ring, index 0, so a
/// caller that answers as worker 1 is answering a loop that never gave it a ring. `run` halts on
/// the bounds check of its ring lookup, which comes before the system call. This scenario cannot
/// show that order: with the lookup moved after the call, it still halts, one system call later.
fn answer_as_a_worker_the_loop_has_no_ring_for() void {
    const work = hand_out_one();
    scenario.reached_violation();
    work.run(work, offload_workers);
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

// The Remote's assertions (decision 4). Each is a mistake only the caller can make, and each halts
// before anything would enter the kernel: on kqueue a Remote's `init` and `post` reach the
// registry and its rings before any system call, so a remote here is set up as a caller sets one
// up.

/// A registry of two slots, which the scenarios claim as a loop and a remote would.
const remote_ids: u16 = 2;
const remote_registry_bytes = kqueue.Registry.memory_bytes(remote_ids);
var remote_registry_memory: [remote_registry_bytes]u8 align(core.layout.memory_alignment) =
    undefined;
var remote_registry: kqueue.Registry = undefined;
var remote_one: kqueue.Remote = undefined;

/// Two remotes claiming one id would put two producers on a single-producer ring.
fn claim_one_id_with_two_remotes() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    var remote_two: kqueue.Remote = undefined;
    remote_one.init(&remote_registry, 1) catch return;
    scenario.reached_violation();
    remote_two.init(&remote_registry, 1) catch return;
}

/// A remote claiming an id a loop already holds: the loop published a queue there, and the remote
/// would overwrite it.
fn claim_a_loops_id_with_a_remote() void {
    remote_registry.init(&remote_registry_memory, remote_ids);
    remote_registry.set(0, 3);
    scenario.reached_violation();
    remote_one.init(&remote_registry, 0) catch return;
}

/// A remote posting to its own id. It has no queue to receive with, so a message to oneself is a
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

/// Memory for one small group, with two alignments of slack: the scenario aligns a pointer forward
/// inside this array and then spoils it, so it needs room for both steps.
const group_scenario_buffers = 2;
const group_scenario_buffer_bytes = 64;
const group_scenario_alignment = kqueue.buffers.group_alignment;
const group_scenario_bytes =
    kqueue.buffers.group_bytes(group_scenario_buffers, group_scenario_buffer_bytes);
const group_scenario_slack = group_scenario_bytes + 2 * group_scenario_alignment;
var group_memory: [group_scenario_slack]u8 align(group_scenario_alignment) = undefined;

/// A group whose memory is one byte past the alignment the call requires, which on this backend is
/// u16: the free list is read through a .
///
/// The address is aligned forward first and spoiled after, rather than taken from the array as
/// declared. This platform does not always give a static the alignment it asks for: a
/// `[N]u8 align(64 KiB)` came back 16 KiB aligned under `zig run` on macOS on 2026-09-22, which is
/// why relying on the declaration would make this scenario halt whether or not the offset was there.
///
/// The slice is built with safety checks off, which is what makes this test rotor's own assertion
/// and not the compiler's: an `@alignCast` in a checked build refuses the cast at the call site, and
/// a caller built without checks does not. rotor's assertions stay on either way (CLAUDE.md
/// non-negotiable 1), and that is the gap this covers.
fn provide_a_group_that_is_not_aligned() void {
    loop.init_tables(&memory, options);
    const base = std.mem.alignForward(usize, @intFromPtr(&group_memory), group_scenario_alignment);
    const misaligned = blk: {
        @setRuntimeSafety(false);
        const start: [*]align(group_scenario_alignment) u8 = @ptrFromInt(base + 1);
        break :blk start[0..group_scenario_bytes];
    };
    scenario.reached_violation();
    loop.provide_buffers(
        0,
        misaligned,
        group_scenario_buffers,
        group_scenario_buffer_bytes,
    ) catch {};
}

const scenarios = [_]scenario.Scenario{
    .{ .name = "loop: submit from another thread", .run = submit_from_another_thread },
    .{ .name = "loop: tick from another thread", .run = tick_from_another_thread },
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
        .name = "offload: answer as a worker the loop has no ring for",
        .run = answer_as_a_worker_the_loop_has_no_ring_for,
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
