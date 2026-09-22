//! The offload `bench/files/rotor_reads.zig` hands its loop under the `offload` policy
//! (decision 18): a fixed set of threads, a queue per thread, and nothing rotor can see.
//!
//! It has four threads, matching libuv's default (`src/threadpool.c:39`,
//! `static uv_thread_t default_threads[4]`). This feeds a row comparing rotor's offload with
//! libuv's pool. A pool of a different size would measure the sizing instead of the loops;
//! `bench/competitors/README.md` records a case where that happened with buffers.
//!
//! Workers block instead of spinning. Four spinning threads would use four cores and slow every
//! other measurement on the machine. Each worker waits on a `std.Io.Event`, which
//! `src/kqueue/kqueue_mailbox_test.zig` also uses across threads.
//!
//! Each worker has its own queue. The loop thread is the only producer and picks one worker per
//! operation, so no queue has two writers and no lock is needed. libuv uses a mutex and a
//! condition for one shared queue instead.
//!
//! This file is outside `src/` and still allocates nothing: every array is static and sized by a
//! named limit.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");

const Work = core.offload.Work;

/// Threads, matching libuv's default so the file rows compare pools of one size.
pub const workers: u16 = 4;

/// Operations one worker's queue holds. A power of two, so the index wraps with a mask.
pub const queue_max: u32 = 256;

const queue_mask: u32 = queue_max - 1;

comptime {
    assert(std.math.isPowerOfTwo(queue_max));
}

/// One worker: its queue, its wake, and the thread that serves it.
const Worker = struct {
    /// Written by the loop thread alone, read by this worker alone.
    queue: [queue_max]*Work = undefined,
    /// Pushed by the loop thread.
    tail: std.atomic.Value(u32) = .init(0),
    /// Popped by this worker.
    head: std.atomic.Value(u32) = .init(0),
    wake: std.Io.Event = .unset,
    stopping: std.atomic.Value(bool) = .init(false),
};

pub const Pool = struct {
    io: std.Io,
    slots: [workers]Worker = @splat(.{}),
    threads: [workers]std.Thread = undefined,
    started: u16 = 0,
    /// The worker the next operation goes to, round robin. The loop thread alone touches it.
    next: u16 = 0,

    /// Starts every thread. Each is given the worker index it will answer with, which decides the
    /// ring in the loop its results go into.
    pub fn start(pool: *Pool, io: std.Io) !void {
        pool.* = .{ .io = io };
        while (pool.started < workers) : (pool.started += 1) {
            pool.threads[pool.started] = try std.Thread.spawn(.{}, serve, .{ pool, pool.started });
        }
    }

    /// Stops every thread and waits for it.
    ///
    /// The caller must drain the loop first. Only the worker can end an operation it holds, so
    /// stopping the threads with work queued leaves an operation that never ends (decision 18).
    /// The assertion below checks the caller drained first.
    pub fn stop(pool: *Pool) void {
        for (&pool.slots) |*worker| {
            assert(worker.head.load(.acquire) == worker.tail.load(.acquire));
            worker.stopping.store(true, .release);
            worker.wake.set(pool.io);
        }
        for (pool.threads[0..pool.started]) |thread| thread.join();
        pool.started = 0;
    }

    /// The `Offload.submit` rotor calls, on the loop thread.
    pub fn submit(context: ?*anyopaque, work: *Work) void {
        const pool: *Pool = @ptrCast(@alignCast(context.?));
        const chosen = pool.next;
        pool.next = (pool.next + 1) % workers;
        const worker = &pool.slots[chosen];

        const tail = worker.tail.load(.unordered);
        // A full queue means the run's depth is above `queue_max`, which `rotor_reads` refuses at
        // its own start rather than discovering it here.
        assert(tail -% worker.head.load(.acquire) < queue_max);
        worker.queue[tail & queue_mask] = work;
        worker.tail.store(tail +% 1, .seq_cst);
        worker.wake.set(pool.io);
    }

    /// The worker thread: run queued work, and wait when the queue is empty.
    fn serve(pool: *Pool, index: u16) void {
        const worker = &pool.slots[index];
        while (true) {
            const head = worker.head.load(.unordered);
            if (head != worker.tail.load(.seq_cst)) {
                const work = worker.queue[head & queue_mask];
                worker.head.store(head +% 1, .release);
                work.run(work, index);
                continue;
            }
            if (worker.stopping.load(.acquire)) return;
            worker.wake.waitUncancelable(pool.io);
            worker.wake.reset();
        }
    }
};

const testing = std.testing;

test "the pool matches libuv's thread count, and its queue holds a full run" {
    // Four matches libuv's default. A different size would measure the sizing instead of the
    // loops; `bench/competitors/README.md` records a case where that happened with buffers.
    try testing.expectEqual(@as(u16, 4), workers);
    try testing.expect(queue_max >= 128);
    try testing.expect(std.math.isPowerOfTwo(queue_max));
}

test "submit spreads the operations over every worker, one at a time" {
    // Spreading the work keeps each queue single-producer and keeps three workers from idling
    // while one does everything. A pool that always chose worker 0 would pass the other tests here
    // and measure one thread.
    var pool: Pool = .{ .io = testing.io };
    var works: [workers * 2]Work = undefined;
    for (&works, 0..) |*work, index| work.index = @intCast(index);

    for (&works) |*work| Pool.submit(&pool, work);
    for (&pool.slots) |*worker| {
        try testing.expectEqual(@as(u32, 2), worker.tail.load(.seq_cst));
    }
    // Worker 0 has the first and the fifth operation, so the choice is round robin.
    try testing.expectEqual(@as(u32, 0), pool.slots[0].queue[0].index);
    try testing.expectEqual(@as(u32, workers), pool.slots[0].queue[1].index);
    try testing.expectEqual(@as(u32, 1), pool.slots[1].queue[0].index);
}
