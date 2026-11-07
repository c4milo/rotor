//! A loop that hands its file operations to the program's own threads (decision 18), so that a file
//! call that blocks never stalls the loop (decision 28, "Prevention"). It writes a block to a file,
//! syncs it and reads it back, then shuts down in the order decision 18 asks for:
//!
//! 1. drain the loop, so no operation is left with a worker;
//! 2. stop the workers, and wait for each thread to end;
//! 3. end the loop.
//!
//! A worker still inside `Work.run` reads the loop after its result is visible, so the threads stop
//! before `deinit` and not before the drain. `zig build test` runs it. The Linux gate runs it on
//! io_uring, which performs a file call without a thread and leaves the pool idle, and on epoll.
//! It exits 0 only when the bytes it read are the bytes it wrote.
//!
//! Run:  zig build examples && ./zig-out/bin/offload
const std = @import("std");
const assert = std.debug.assert;
const rotor = @import("rotor");

const Work = rotor.offload.Work;

/// The pool's threads. Two are enough for one file; a server sizes it by its disks.
const workers: u16 = 2;
/// The operations one worker's queue holds: a power of two, at least the loop's operations, so a
/// full queue is a bug and not a load.
const queue_max: u32 = 16;
const queue_mask: u32 = queue_max - 1;

comptime {
    assert(std.math.isPowerOfTwo(queue_max));
    assert(queue_max >= options_operations);
}

/// One worker: its queue, written by the loop's thread alone, and the thread that serves it.
const Worker = struct {
    queue: [queue_max]*Work = undefined,
    tail: std.atomic.Value(u32) = .init(0),
    head: std.atomic.Value(u32) = .init(0),
    wake: std.Io.Event = .unset,
    stopping: std.atomic.Value(bool) = .init(false),
};

/// A bounded pool: a fixed set of threads, a queue for each, and no allocation.
const Pool = struct {
    io: std.Io,
    slots: [workers]Worker = @splat(.{}),
    threads: [workers]std.Thread = undefined,
    started: u16 = 0,
    /// The worker that the next operation goes to. Only the loop's thread reads it.
    next: u16 = 0,

    fn start(pool: *Pool, io: std.Io) !void {
        pool.* = .{ .io = io };
        for (0..workers) |index| {
            const worker: u16 = @intCast(index);
            pool.threads[index] = try std.Thread.spawn(.{}, serve, .{ pool, worker });
            pool.started += 1;
        }
    }

    /// What the loop holds: this pool as its context, and `submit`.
    fn offload(pool: *Pool) rotor.offload.Offload {
        return .{ .context = pool, .submit = submit, .workers = workers };
    }

    /// Called by the loop, on its thread, for each file operation.
    fn submit(context: ?*anyopaque, work: *Work) void {
        const pool: *Pool = @ptrCast(@alignCast(context.?));
        const worker = &pool.slots[pool.next];
        pool.next = (pool.next + 1) % workers;
        const tail = worker.tail.load(.unordered);
        assert(tail -% worker.head.load(.acquire) < queue_max);
        worker.queue[tail & queue_mask] = work;
        worker.tail.store(tail +% 1, .seq_cst);
        worker.wake.set(pool.io);
    }

    /// Step 2 of the shutdown: every queue is empty, because the loop is drained. Each thread ends
    /// and is joined.
    fn stop(pool: *Pool) void {
        for (&pool.slots) |*worker| {
            assert(worker.head.load(.acquire) == worker.tail.load(.acquire));
            worker.stopping.store(true, .release);
            worker.wake.set(pool.io);
        }
        for (pool.threads[0..pool.started]) |thread| thread.join();
        pool.started = 0;
    }

    /// A worker's thread: runs its queued work, and waits while its queue is empty.
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

const options_operations = 8;
/// The bytes the program writes and reads back.
const block_bytes = 512;
/// Ticks one operation may take before the program calls it stuck.
const ticks_max = 1000;

var the_pool: Pool align(@alignOf(Pool)) = undefined;
var rings: [rotor.offload_memory_bytes(workers)]u8 align(rotor.memory_alignment) = undefined;

/// The options the loop's memory is sized for. The offload's context is the pool, which only the
/// running program has, so `main` fills it in.
const sizing: rotor.Loop.Options = .{
    .operations = options_operations,
    .file_policy = .offload,
    .offload = .{ .context = null, .submit = Pool.submit, .workers = workers },
};
var memory: [rotor.Loop.memory_bytes(sizing)]u8 align(rotor.memory_alignment) = undefined;

pub fn main(init: std.process.Init) !void {
    try the_pool.start(init.io);
    var options = sizing;
    options.offload = the_pool.offload();
    options.offload_memory = &rings;
    var loop: rotor.Loop = undefined;
    try loop.init(&memory, options);

    // A file of its own: the loop's first clock stamp names it.
    var events: [8]rotor.Event = undefined;
    _ = try loop.tick(&events, 0);
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "/tmp/rotor_offload_{d}", .{loop.now_ns()});
    const file = try rotor.sync.open_file(path, .{ .create = true, .direct = false });
    defer std.Io.Dir.deleteFileAbsolute(init.io, path) catch {};

    var written: [block_bytes]u8 = undefined;
    for (&written, 0..) |*byte, index| byte.* = @truncate(index * 13 + 5);
    var read: [block_bytes]u8 = @splat(0);
    const write = rotor.Operation.write(1, file, &written, 0);
    if (try run(&loop, write) != block_bytes) return error.Short;
    if (try run(&loop, rotor.Operation.fdatasync(2, file)) != 0) return error.NotSynced;
    if (try run(&loop, rotor.Operation.read(3, file, &read, 0)) != block_bytes) return error.Short;
    if (!std.mem.eql(u8, &written, &read)) return error.BytesDiffer;
    rotor.sync.close_now(file);

    // The shutdown of decision 18: drain, stop the workers, end the loop.
    loop.cancel_all();
    try loop.drain(&events);
    the_pool.stop();
    loop.deinit();
    std.debug.print("offload: wrote, synced and read back {d} bytes on the {t} backend\n", .{
        block_bytes, rotor.backend(),
    });
}

/// Submits `operation` and ticks until its final event, and returns its result.
fn run(loop: *rotor.Loop, operation: rotor.Operation) !u32 {
    if (loop.submit(&.{operation}, &.{}) != 1) return error.NotTaken;
    var events: [8]rotor.Event = undefined;
    for (0..ticks_max) |_| {
        const count = try loop.tick(&events, rotor.constants.ns_per_ms);
        for (events[0..count]) |event| {
            if (event.user_data == operation.user_data) return event.outcome();
        }
    }
    return error.Stuck;
}
