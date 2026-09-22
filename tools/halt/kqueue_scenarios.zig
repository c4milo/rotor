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
/// below needs a real number, and the assertions under test all fire before the system call is
/// made. It is deliberately high rather than 0: if a mutation deleted the assertion under test,
/// this answers `EBADF` at once, where a `pread` of descriptor 0 could block on standard input and
/// hang the check instead of reporting that it did not halt.
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
/// caller that answers as worker 1 is answering a loop that never gave it a ring.
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
};

pub fn main(init: std.process.Init) !void {
    return scenario.main(init, &scenarios);
}
