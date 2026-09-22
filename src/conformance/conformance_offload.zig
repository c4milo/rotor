//! Offload scenarios: decision 18's three file policies, one scenario each.
//!
//! **The two backends are asked the same thing and answer differently on purpose.** On kqueue a
//! file operation blocks the loop thread, so the policy decides what happens: `refuse` ends the
//! operation with `unsupported`, `blocking` performs it inline, and `offload` hands it to the
//! caller's thread. On io_uring the kernel completes it without a thread, so the option is taken
//! and ignored and every policy reads the block. `backend.files_block` is what tells them apart,
//! and each scenario asserts the answer its own backend owes.
//!
//! The `offload` scenario runs a real thread, because the point of the policy is that a thread
//! which owns no loop hands a result back. A synchronous stand-in would pass while the cross-thread
//! path was broken. `zig build test-race` is where that thread meets ThreadSanitizer.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Event = core.Event;
const Loop = backend.Loop;
const Work = core.offload.Work;
const sync = backend.sync;

/// O_DIRECT transfers in whole blocks, so every buffer, offset and length is a multiple of this.
const block_bytes = 4096;
const file_blocks = 2;

const operations = 16;
const entries = 16;

/// One worker, so one ring, which is what keeps that ring single-producer.
const workers: u16 = 1;

/// Idle turns the worker takes before it gives up. Zig 0.16 offers a spinning thread `yield` and
/// no sleep, so the worker yields, and the bound is large because a yield is cheap: a scenario that
/// wedged would fail on `conformance.collect_rounds_max` first, two seconds in.
const idle_turns_max: u32 = 1 << 22;

/// The caller's offload for these scenarios: one thread, and room for the one operation a scenario
/// has in flight at a time.
///
/// It is deliberately the smallest thing that is still a real hand-off. A caller with a real pool
/// puts a queue here; rotor never sees the difference, which is the point of decision 18's shape.
const Pool = struct {
    /// The work the loop handed out and the worker has not taken. The loop thread stores it and the
    /// worker takes it, so one writer each way.
    handed: std.atomic.Value(?*Work),
    stopping: std.atomic.Value(bool),
    thread: std.Thread,
    /// How many operations the worker actually ran. Written by the worker, read after it is joined.
    ///
    /// Without it a scenario cannot tell an offload from an inline read: both end with the same
    /// event and the same bytes. It is what says the policy was honoured and not ignored.
    served: std.atomic.Value(u32),
    /// While set, the worker holds the work instead of running it. A scenario that wants to act
    /// while an operation is genuinely out on a thread sets it, acts, then clears it.
    holding: std.atomic.Value(bool),

    fn start(pool: *Pool) !void {
        pool.handed = .init(null);
        pool.stopping = .init(false);
        pool.served = .init(0);
        pool.holding = .init(false);
        pool.thread = try std.Thread.spawn(.{}, serve, .{pool});
    }

    fn stop(pool: *Pool) void {
        pool.stopping.store(true, .release);
        pool.thread.join();
        // Nothing may be left: a work still here is an operation whose final event never came,
        // which decision 5, rule 1 forbids.
        std.debug.assert(pool.handed.load(.acquire) == null);
    }

    /// rotor calls this on the loop thread.
    fn submit(context: ?*anyopaque, work: *Work) void {
        const pool: *Pool = @ptrCast(@alignCast(context.?));
        const previous = pool.handed.swap(work, .release);
        // A scenario collects each operation's event before it submits the next, so the slot is
        // free. A scenario that broke that would drop an operation, so it halts here instead.
        std.debug.assert(previous == null);
    }

    /// The worker thread. It owns no loop, which is the whole reason this scenario exists.
    fn serve(pool: *Pool) void {
        var idle: u32 = 0;
        while (idle < idle_turns_max) : (idle += 1) {
            if (pool.holding.load(.acquire)) {
                std.Thread.yield() catch {};
                continue;
            }
            if (pool.handed.swap(null, .acquire)) |work| {
                work.run(work, 0);
                _ = pool.served.fetchAdd(1, .monotonic);
                idle = 0;
                continue;
            }
            if (pool.stopping.load(.acquire)) return;
            std.Thread.yield() catch {};
        }
    }
};

/// One loop with a file policy, its memory, and the rings an offload needs.
const Fixture = struct {
    loop: Loop,
    memory: [
        Loop.memory_bytes(.{
            .operations = operations,
            .entries = entries,
            .file_policy = .offload,
            .offload = .{ .context = null, .submit = Pool.submit, .workers = workers },
        })
    ]u8 align(core.layout.memory_alignment),
    rings: [ring_bytes]u8 align(core.layout.memory_alignment),
    path_buffer: [96]u8,
    path: [:0]const u8,
    file: core.Descriptor,

    /// The rings one worker needs. Asked of the backend that holds them; the other holds none, and
    /// an empty array is not allowed in Zig, so the floor is one byte.
    const ring_bytes = if (backend.files_block)
        backend.offload_module.memory_bytes(workers)
    else
        1;

    fn init(fixture: *Fixture, policy: core.offload.FilePolicy, pool: ?*Pool) !void {
        fixture.path = try std.fmt.bufPrintZ(&fixture.path_buffer, "{s}/rotor_offload_{d}_{s}", .{
            backend.testing.directory, backend.testing.process_id(), @tagName(policy),
        });
        fixture.file = try sync.open_file(fixture.path, .{ .create = true, .direct = true });
        errdefer sync.close_now(fixture.file);
        try sync.set_file_size(fixture.file, file_blocks * block_bytes);

        try fixture.loop.init(&fixture.memory, .{
            .operations = operations,
            .entries = entries,
            .file_policy = policy,
            .offload = if (pool) |given| .{
                .context = given,
                .submit = Pool.submit,
                .workers = workers,
            } else null,
            .offload_memory = &fixture.rings,
        });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.loop.deinit();
        sync.close_now(fixture.file);
        backend.testing.remove_file(fixture.path);
    }

    /// Submits one read of block 0 into `into` and returns its one event.
    fn read_block(fixture: *Fixture, into: []u8) !Event {
        var events: [1]Event = undefined;
        const taken = fixture.loop.submit(&.{.{ .user_data = 7, .kind = .{ .read = .{
            .file = fixture.file,
            .buffer = .{ .bytes = into },
            .offset = 0,
        } } }}, &.{});
        if (taken != 1) return error.TableFull;

        var round: u32 = 0;
        while (round < conformance.collect_rounds_max) : (round += 1) {
            const produced = try fixture.loop.tick(&events, 10 * core.constants.ns_per_ms);
            if (produced == 1) return events[0];
        }
        return error.EventsMissing;
    }
};

var loop_fixture: Fixture = undefined;
var worker_pool: Pool = undefined;

test "the refuse policy ends a file read with unsupported, where a file blocks the loop" {
    if (conformance.unsupported()) return error.SkipZigTest;
    try loop_fixture.init(.refuse, null);
    defer loop_fixture.deinit();

    var into: [block_bytes]u8 align(block_bytes) = @splat(0);
    const event = try loop_fixture.read_block(&into);

    if (backend.files_block) {
        // Decision 18's default: the caller who asked for nothing is told, not silently stalled.
        try testing.expectError(error.Unsupported, event.outcome());
    } else {
        // The kernel did it without a thread, so there was nothing to refuse.
        try testing.expectEqual(@as(u32, block_bytes), try event.outcome());
    }
}

test "the blocking policy performs a file read inline, on both backends" {
    if (conformance.unsupported()) return error.SkipZigTest;
    try loop_fixture.init(.blocking, null);
    defer loop_fixture.deinit();

    var into: [block_bytes]u8 align(block_bytes) = @splat(0xaa);
    const event = try loop_fixture.read_block(&into);
    try testing.expectEqual(@as(u32, block_bytes), try event.outcome());
    // The file was set to its size and never written, so it reads as zeros. That the bytes changed
    // is what says the read happened rather than the event being fabricated.
    try testing.expectEqualSlices(u8, &@as([block_bytes]u8, @splat(0)), &into);
}

test "the offload policy completes a file read on the caller's own thread" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    try worker_pool.start();
    try loop_fixture.init(.offload, &worker_pool);
    defer {
        loop_fixture.deinit();
        worker_pool.stop();
    }

    var into: [block_bytes]u8 align(block_bytes) = @splat(0xaa);
    const event = try loop_fixture.read_block(&into);
    try testing.expectEqual(@as(u32, block_bytes), try event.outcome());
    try testing.expectEqualSlices(u8, &@as([block_bytes]u8, @splat(0)), &into);
    // One final event and no more, which is decision 5, rule 1 across the thread boundary.
    try testing.expectEqual(@as(u32, 0), loop_fixture.loop.in_flight());
    // The worker ran it. Without this the scenario would pass on a loop that quietly performed the
    // read inline, which is the `blocking` policy and not this one.
    try testing.expectEqual(@as(u32, 1), worker_pool.served.load(.monotonic));
}

test "an offloaded read of every block completes, so the ring is drained and reused" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    try worker_pool.start();
    try loop_fixture.init(.offload, &worker_pool);
    defer {
        loop_fixture.deinit();
        worker_pool.stop();
    }

    // More operations than one, one after another, so the ring's head and tail both advance. A
    // ring that only ever held one message would pass the scenario above and fail here.
    var into: [block_bytes]u8 align(block_bytes) = undefined;
    var completed: u32 = 0;
    while (completed < file_blocks * 3) : (completed += 1) {
        const event = try loop_fixture.read_block(&into);
        try testing.expectEqual(@as(u32, block_bytes), try event.outcome());
    }
    try testing.expectEqual(@as(u32, 0), loop_fixture.loop.in_flight());
    // Every one of them went to the worker, and none was quietly performed inline.
    try testing.expectEqual(completed, worker_pool.served.load(.monotonic));
}

test "an offloaded result lands in the tick that waited for it, not the one after" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    try worker_pool.start();
    try loop_fixture.init(.offload, &worker_pool);
    defer {
        loop_fixture.deinit();
        worker_pool.stop();
    }

    var into: [block_bytes]u8 align(block_bytes) = undefined;
    const taken = loop_fixture.loop.submit(&.{.{ .user_data = 9, .kind = .{ .read = .{
        .file = loop_fixture.file,
        .buffer = .{ .bytes = &into },
        .offset = 0,
    } } }}, &.{});
    try testing.expectEqual(@as(u32, 1), taken);

    // One tick, with a wait long enough for the worker to answer. The worker's wake is what ends
    // the wait, and the drain after the wait is what turns it into an event. A tick that only
    // drained before its wait would answer 0 here and make the caller tick again for no reason.
    var events: [2]Event = undefined;
    const produced = try loop_fixture.loop.tick(&events, core.constants.ns_per_s);
    try testing.expectEqual(@as(u32, 1), produced);
    try testing.expectEqual(@as(u64, 9), events[0].user_data);
    try testing.expectEqual(@as(u32, block_bytes), try events[0].outcome());
}

test "an offloaded read that is cancelled still ends with exactly one final event" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    try worker_pool.start();
    try loop_fixture.init(.offload, &worker_pool);
    defer {
        loop_fixture.deinit();
        worker_pool.stop();
    }

    // Hold the worker, so the operation is genuinely out on a thread when the cancel arrives. A
    // `pread` already running cannot be stopped, so a cancel means "end it when it returns"
    // (decision 18's open question 2, and decision 5 for an operation the kernel owns).
    worker_pool.holding.store(true, .release);

    var into: [block_bytes]u8 align(block_bytes) = undefined;
    var handles: [1]core.Handle = undefined;
    const taken = loop_fixture.loop.submit(&.{.{ .user_data = 11, .kind = .{ .read = .{
        .file = loop_fixture.file,
        .buffer = .{ .bytes = &into },
        .offset = 0,
    } } }}, &handles);
    try testing.expectEqual(@as(u32, 1), taken);

    // The flush hands it out, so it is submitted and on a thread, not queued.
    var events: [2]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try loop_fixture.loop.tick(&events, 0));
    try testing.expectEqual(@as(u32, 1), loop_fixture.loop.in_flight());

    loop_fixture.loop.cancel(handles[0]);
    worker_pool.holding.store(false, .release);

    // Exactly one event, and nothing left in flight. Whether it carries the read's count or
    // `canceled` is the kernel's race to win; that there is one of it is decision 5, rule 1.
    var round: u32 = 0;
    var produced: u32 = 0;
    while (round < conformance.collect_rounds_max and produced == 0) : (round += 1) {
        produced = try loop_fixture.loop.tick(&events, 10 * core.constants.ns_per_ms);
    }
    try testing.expectEqual(@as(u32, 1), produced);
    try testing.expectEqual(@as(u64, 11), events[0].user_data);
    try testing.expectEqual(@as(u32, 0), loop_fixture.loop.in_flight());
}

test "the offload policy leaves a socket operation's cancel alone" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    try worker_pool.start();
    try loop_fixture.init(.offload, &worker_pool);
    defer {
        loop_fixture.deinit();
        worker_pool.stop();
    }

    // A socket is never handed to an offload: kqueue reports its readiness, so it never blocks the
    // loop. So its cancel stays the synchronous one, and ends with `canceled` at once. A loop that
    // treated every operation under this policy as offloaded would wait for a worker that was never
    // given anything, and this accept would never end.
    const listener = try sync.listen(
        &core.Address.ipv4(.{ 127, 0, 0, 1 }, 0),
        .{ .backlog = 1, .reuse_port = false },
    );
    defer sync.close_now(listener);

    var handles: [1]core.Handle = undefined;
    const taken = loop_fixture.loop.submit(&.{.{
        .user_data = 13,
        .kind = .{ .accept = .{ .listener = listener, .multishot = false } },
    }}, &handles);
    try testing.expectEqual(@as(u32, 1), taken);

    var events: [2]Event = undefined;
    // The flush registers the filter, so the accept is submitted and waiting on readiness.
    try testing.expectEqual(@as(u32, 0), try loop_fixture.loop.tick(&events, 0));
    loop_fixture.loop.cancel(handles[0]);

    try testing.expectEqual(@as(u32, 1), try loop_fixture.loop.tick(&events, 0));
    try testing.expectEqual(@as(u64, 13), events[0].user_data);
    try testing.expectError(error.Canceled, events[0].outcome());
    try testing.expectEqual(@as(u32, 0), loop_fixture.loop.in_flight());
    // And the worker was never given anything, because a socket is not an offload's work.
    try testing.expectEqual(@as(u32, 0), worker_pool.served.load(.monotonic));
}

test "the io_uring backend takes the policy and nothing changes" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (backend.files_block) return error.SkipZigTest;
    // Decision 18 says the uring backend takes the option and ignores it. So the two policies a
    // caller can set without an offload read the same block, and neither refuses.
    for ([_]core.offload.FilePolicy{ .refuse, .blocking }) |policy| {
        try loop_fixture.init(policy, null);
        defer loop_fixture.deinit();
        var into: [block_bytes]u8 align(block_bytes) = @splat(0xaa);
        const event = try loop_fixture.read_block(&into);
        try testing.expectEqual(@as(u32, block_bytes), try event.outcome());
    }
}
