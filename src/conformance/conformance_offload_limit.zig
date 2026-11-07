//! The offload's limit (decision 18, amendment of 2026-11-06): one worker, more file operations in
//! flight than its ring holds, and a loop that does not tick while the worker answers them.
//!
//! A worker pushes each result to its own ring of `core.constants.mailbox_messages`, and the push
//! must succeed. Before the limit, a loop handed out every file operation at once, so this scenario
//! filled the ring and halted the process on that push. With the limit, the loop hands out
//! `offload_in_flight_max` operations, keeps the rest queued, and hands them out as results come
//! back. Every operation then gets exactly one final event.
//!
//! It runs where a file operation blocks the loop: on kqueue and epoll. On io_uring the kernel
//! performs the reads without an offload, and the scenario skips.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const backend = @import("backend");
const conformance = @import("conformance.zig");

const Event = core.Event;
const Loop = backend.Loop;
const Operation = core.Operation;
const Work = core.offload.Work;
const sync = backend.sync;

/// More operations than the limit lets out at once, so some of them wait for room.
pub const operations = core.constants.offload_in_flight_max + operations_held;
/// The operations that wait for room after the first flush.
const operations_held = 44;
const entries = 16;
/// One worker, so one ring holds every result.
const workers: u16 = 1;
/// The bytes each read transfers. The file is not opened with O_DIRECT, so any size is legal.
pub const read_bytes = 8;
/// Events one tick may hand over: fewer than the operations, so the scenario takes several ticks.
pub const events_per_tick = 64;

/// Works the pool can hold, a power of two at or above `operations`. The pool has room for every
/// operation, so a loop that broke the limit reaches the worker's push and not this pool's check.
const pool_works = 512;

/// Idle turns the worker, or the scenario as it waits for the worker, takes before it gives up.
/// Zig 0.16 offers a thread `yield` and no sleep, so the bound is large, because a yield is cheap.
const idle_turns_max: u32 = 1 << 22;

comptime {
    std.debug.assert(std.math.isPowerOfTwo(pool_works));
    std.debug.assert(pool_works >= operations);
    std.debug.assert(operations > core.constants.mailbox_messages);
}

/// The caller's offload: one worker thread and a single-producer, single-consumer queue of works.
/// The loop thread is the producer and the worker the consumer.
pub const Pool = struct {
    works: [pool_works]*Work,
    /// Works the loop handed out. Written by the loop thread alone.
    tail: std.atomic.Value(u32),
    /// Works the worker took. Written by the worker alone.
    head: std.atomic.Value(u32),
    /// Works the worker ran. Written by the worker, read by the scenario.
    served: std.atomic.Value(u32),
    /// While set, the worker runs nothing, so the first flush hands out with no answer back.
    holding: std.atomic.Value(bool),
    stopping: std.atomic.Value(bool),
    thread: std.Thread,
    joined: bool,

    fn start(pool: *Pool) !void {
        pool.tail = .init(0);
        pool.head = .init(0);
        pool.served = .init(0);
        pool.holding = .init(true);
        pool.stopping = .init(false);
        pool.joined = false;
        pool.thread = try std.Thread.spawn(.{}, serve, .{pool});
    }

    pub fn stop(pool: *Pool) void {
        if (pool.joined) return;
        pool.joined = true;
        pool.holding.store(false, .release);
        pool.stopping.store(true, .release);
        pool.thread.join();
    }

    /// rotor calls this on the loop thread. The store of `tail` releases the work's fields, which
    /// the loop wrote before this call, to the worker.
    fn submit(context: ?*anyopaque, work: *Work) void {
        const pool: *Pool = @ptrCast(@alignCast(context.?));
        const tail = pool.tail.load(.unordered);
        std.debug.assert(tail -% pool.head.load(.acquire) < pool_works);
        pool.works[tail % pool_works] = work;
        pool.tail.store(tail +% 1, .release);
    }

    /// Works handed out so far. Read on the loop thread, which is the one writer.
    pub fn submitted(pool: *const Pool) u32 {
        return pool.tail.load(.unordered);
    }

    /// The worker thread. It owns no loop.
    fn serve(pool: *Pool) void {
        var idle: u32 = 0;
        while (idle < idle_turns_max) : (idle += 1) {
            if (!pool.holding.load(.acquire) and pool.run_one()) {
                idle = 0;
                continue;
            }
            if (pool.stopping.load(.acquire)) return;
            std.Thread.yield() catch {};
        }
    }

    /// Runs the oldest work, and returns false when there is none.
    fn run_one(pool: *Pool) bool {
        const head = pool.head.load(.unordered);
        if (head == pool.tail.load(.acquire)) return false;
        const work = pool.works[head % pool_works];
        pool.head.store(head +% 1, .release);
        work.run(0);
        _ = pool.served.fetchAdd(1, .release);
        return true;
    }

    /// Waits, without a tick, until the worker has run `count` works.
    pub fn wait_for_served(pool: *const Pool, count: u32) !void {
        var turn: u32 = 0;
        while (turn < idle_turns_max) : (turn += 1) {
            if (pool.served.load(.acquire) >= count) return;
            std.Thread.yield() catch {};
        }
        return error.WorkerTooSlow;
    }
};

pub const Fixture = struct {
    loop: Loop,
    pool: Pool,
    memory: [
        Loop.memory_bytes(&.{
            .operations = operations,
            .entries = entries,
            .file_policy = .offload,
            .offload = .{ .context = null, .submit = Pool.submit, .workers = workers },
        })
    ]u8 align(core.layout.memory_alignment),
    rings: [ring_bytes]u8 align(core.layout.memory_alignment),
    buffers: [operations][read_bytes]u8,
    batch: [operations]Operation,
    seen: [operations]bool,
    path_buffer: [96]u8,
    path: [:0]const u8,
    file: core.Descriptor,

    /// The rings one worker needs. Only a backend whose files block holds rings, and Zig has no
    /// zero-length array here, so the floor is one byte.
    const ring_bytes = if (backend.files_block) backend.offload_module.memory_bytes(workers) else 1;

    pub fn init(fixture: *Fixture) !void {
        fixture.path = try std.fmt.bufPrintZ(&fixture.path_buffer, "{s}/rotor_offload_limit_{d}", .{
            backend.testing.directory, backend.testing.process_id(),
        });
        fixture.file = try sync.open_file(fixture.path, .{ .create = true, .direct = false });
        errdefer {
            sync.close_now(fixture.file);
            backend.testing.remove_file(fixture.path);
        }
        try sync.set_file_size(fixture.file, operations * read_bytes);
        try fixture.pool.start();
        errdefer fixture.pool.stop();
        try fixture.loop.init(&fixture.memory, &.{
            .operations = operations,
            .entries = entries,
            .file_policy = .offload,
            .offload = .{ .context = &fixture.pool, .submit = Pool.submit, .workers = workers },
            .offload_memory = &fixture.rings,
        });
        fixture.seen = @splat(false);
    }

    /// The pool stops first: a worker still inside `run` reads the loop after its result is
    /// visible, so the loop must outlive it (decision 18).
    pub fn deinit(fixture: *Fixture) void {
        fixture.pool.stop();
        fixture.loop.deinit();
        sync.close_now(fixture.file);
        backend.testing.remove_file(fixture.path);
    }

    /// Submits one read per slot, each of its own bytes of the file.
    fn submit_reads(fixture: *Fixture) !void {
        for (&fixture.batch, &fixture.buffers, 0..) |*operation, *buffer, index| {
            operation.* = Operation.read(index, fixture.file, buffer, index * read_bytes);
        }
        const taken = fixture.loop.submit(&fixture.batch, &.{});
        try testing.expectEqual(@as(u32, operations), taken);
    }

    /// Ticks until every read has handed over its event, and requires exactly one event for each.
    fn collect(fixture: *Fixture) !void {
        var events: [events_per_tick]Event = undefined;
        var collected: u32 = 0;
        var round: u32 = 0;
        while (collected < operations and round < conformance.collect_rounds_max) : (round += 1) {
            const produced = try fixture.loop.tick(&events, 10 * core.constants.ns_per_ms);
            for (events[0..produced]) |event| {
                try testing.expect(event.user_data < operations);
                try testing.expect(!fixture.seen[event.user_data]);
                fixture.seen[event.user_data] = true;
                try testing.expectEqual(@as(u32, read_bytes), try event.outcome());
            }
            collected += produced;
        }
        try testing.expectEqual(@as(u32, operations), collected);
    }
};

// Restates its type's alignment, as every static of the suite does: Zig 0.16's own x86-64 backend
// places a static without it unless the static declares it.
var limit_fixture: Fixture align(@alignOf(Fixture)) = undefined;

test "more file operations than a ring holds, on one worker, each get one final event" {
    if (conformance.unsupported()) return error.SkipZigTest;
    if (!backend.files_block) return error.SkipZigTest;
    const fixture = &limit_fixture;
    try fixture.init();
    defer fixture.deinit();
    try fixture.submit_reads();

    // The worker holds, so no result comes back. The flush hands out exactly the limit, and the
    // rest stay queued: every operation is still in flight.
    var events: [events_per_tick]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    try testing.expectEqual(core.constants.offload_in_flight_max, fixture.pool.submitted());
    try testing.expectEqual(@as(u32, operations), fixture.loop.in_flight());

    // The worker answers all it was given while the loop does not tick. Every answer waits in the
    // one ring, which is now full: one more push would have halted the process.
    fixture.pool.holding.store(false, .release);
    try fixture.pool.wait_for_served(core.constants.offload_in_flight_max);

    try fixture.collect();
    try testing.expectEqual(@as(u32, 0), fixture.loop.in_flight());
    // Nothing more comes: each operation had one final event and no second one.
    try testing.expectEqual(@as(u32, 0), try fixture.loop.tick(&events, 0));
    fixture.pool.stop();
    try testing.expectEqual(@as(u32, operations), fixture.pool.served.load(.acquire));
    try testing.expectEqual(@as(u32, operations), fixture.pool.submitted());
}
