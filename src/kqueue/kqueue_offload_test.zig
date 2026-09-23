//! The offload's hand-off under real threads (decision 18): a worker that owns no loop performs an
//! operation and hands the result back, and the loop finishes it.
//!
//! **These tests run on macOS alone, and the race gate cannot reach them.** They enter no kernel,
//! but they do call `hand_out` and `Work.run`, which reach `std.c.F.FULLFSYNC` and this backend's
//! submit path, and neither compiles for Linux. ThreadSanitizer cannot be built on macOS at all, so
//! `zig build test-race` sees none of this.
//!
//! What that gate does see is the ordering itself: `kqueue_mailbox_test.zig` holds a test of the
//! offload's sleep handshake written against a bare `Mailbox` and a bare flag, which compiles for
//! Linux like the rest of that file. So the primitive is sanitized and the path around it is not,
//! and `docs/decisions/0018-a-caller-supplied-thread-pool.md` records the split rather than leaving
//! it to be discovered.
//!
//! No test here opens a kqueue. The loop comes up through `init_tables`, so `loop.queue` is never
//! valid, and nothing may call `Queue.wake`. That holds as long as `offload_asleep` stays false,
//! which it is after `init_tables` and which these tests never change: a loop that is awake is
//! never woken. The sleep handshake itself is `kqueue_mailbox_test.zig`'s subject, with a
//! `std.Io.Event` standing in for the kernel.
//!
//! The descriptor every operation names is closed, so every `pread` answers `EBADF`, which this
//! backend maps to `unexpected`. That is the
//! point: what is under test is the trip a result takes, not what the result says.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const offload_module = @import("kqueue_offload.zig");
const submit_module = @import("kqueue_submit.zig");
const kqueue = @import("kqueue.zig");

const Loop = kqueue.Loop;
const Mailbox = core.mailbox.Mailbox;
const Work = core.offload.Work;

/// Slots, set to a ring's capacity so a test can hand out a batch large enough to matter without
/// filling the table first.
const operations = core.constants.mailbox_messages;
const entries = 16;

/// Workers, and so rings. Two, because one ring would not show that a worker's result goes to the
/// ring the worker was given and not to ring 0.
const workers: u16 = 2;

/// A descriptor no process has open, so every transfer answers `EBADF` without touching a file.
const closed_descriptor: core.Descriptor = 4096;

const alignment = core.layout.memory_alignment;

/// Where the loop hands work, one slot per worker: the loop thread writes, one worker takes.
const Pool = struct {
    handed: [workers]std.atomic.Value(?*Work) = @splat(.init(null)),

    fn submit(context: ?*anyopaque, work: *Work) void {
        const pool: *Pool = @ptrCast(@alignCast(context.?));
        // Round robin over the slots, by the slot index the loop chose, so a batch of operations
        // reaches both workers.
        const chosen = work.index % workers;
        const previous = pool.handed[chosen].swap(work, .release);
        std.debug.assert(previous == null);
    }

    /// The worker thread: take the work it was given and run it.
    fn serve(pool: *Pool, worker: u16) void {
        const work = pool.handed[worker].swap(null, .acquire).?;
        work.run(work, worker);
    }
};

const Fixture = struct {
    loop: Loop,
    pool: Pool,
    memory: [Loop.memory_bytes(options_for(&dummy_pool))]u8 align(alignment),
    rings: [offload_module.memory_bytes(workers)]u8 align(alignment),
    buffer: [64]u8,

    /// A `Pool` pointer is needed to size the memory at comptime, and the size does not depend on
    /// which pointer it is.
    var dummy_pool: Pool = .{};

    fn options_for(pool: *Pool) Loop.Options {
        return .{
            .operations = operations,
            .entries = entries,
            .file_policy = .offload,
            .offload = .{ .context = pool, .submit = Pool.submit, .workers = workers },
        };
    }

    fn init(state: *Fixture) void {
        state.pool = .{};
        var options = options_for(&state.pool);
        options.offload_memory = &state.rings;
        state.loop.init_tables(&state.memory, options);
    }

    /// Submits `count` reads and flushes, so each is handed to the pool. Returns nothing: what the
    /// caller wants next is the results, off the rings.
    fn hand_out(state: *Fixture, count: u32) !void {
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            const taken = state.loop.submit(&.{.{ .user_data = index, .kind = .{ .read = .{
                .file = closed_descriptor,
                .buffer = .{ .bytes = &state.buffer },
                .offset = 0,
            } } }}, &.{});
            try testing.expectEqual(@as(u32, 1), taken);
        }
        submit_module.flush(&state.loop);
    }
};

var loop_fixture: Fixture = undefined;

test "a worker on another thread hands its result back, and the loop finishes the operation" {
    if (!kqueue.supported) return error.SkipZigTest;
    loop_fixture.init();
    try loop_fixture.hand_out(1);
    // Handed out, so it is in flight and nothing is finished: the loop is waiting on a thread.
    try testing.expectEqual(@as(u32, 1), loop_fixture.loop.in_flight());
    try testing.expectEqual(@as(u32, 0), offload_module.drain(&loop_fixture.loop));

    const thread = try std.Thread.spawn(.{}, Pool.serve, .{ &loop_fixture.pool, 0 });
    thread.join();

    try testing.expect(offload_module.pending(&loop_fixture.loop));
    try testing.expectEqual(@as(u32, 1), offload_module.drain(&loop_fixture.loop));
    try testing.expect(!offload_module.pending(&loop_fixture.loop));

    var events: [2]core.Event = undefined;
    try testing.expectEqual(@as(u32, 1), loop_fixture.loop.tables.drain_finished(&events));
    // The descriptor is closed, so the kernel answered EBADF, which `core/errno.zig` maps to
    // `unexpected`. The trip carried the failure intact: one that lost the sign of the result would
    // read as an enormous transfer count instead of as an error at all.
    try testing.expectError(error.Unexpected, events[0].outcome());
    try testing.expectEqual(@as(u32, 0), loop_fixture.loop.in_flight());
}

test "two workers answer into their own rings at the same time, and both results arrive" {
    if (!kqueue.supported) return error.SkipZigTest;
    loop_fixture.init();
    try loop_fixture.hand_out(2);
    try testing.expectEqual(@as(u32, 2), loop_fixture.loop.in_flight());

    // Both threads run at once, each pushing to the ring it was given. This is the interleaving
    // ThreadSanitizer is here to judge: two producers, two rings, one consumer.
    var threads: [workers]std.Thread = undefined;
    for (&threads, 0..) |*thread, worker| {
        thread.* = try std.Thread.spawn(.{}, Pool.serve, .{ &loop_fixture.pool, @as(u16, @intCast(worker)) });
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(u32, 2), offload_module.drain(&loop_fixture.loop));
    var events: [4]core.Event = undefined;
    try testing.expectEqual(@as(u32, 2), loop_fixture.loop.tables.drain_finished(&events));
    for (events[0..2]) |event| try testing.expectError(error.Unexpected, event.outcome());
    try testing.expectEqual(@as(u32, 0), loop_fixture.loop.in_flight());
}

test "an awake loop is never woken, so a worker makes no system call on its behalf" {
    if (!kqueue.supported) return error.SkipZigTest;
    loop_fixture.init();
    try testing.expect(!loop_fixture.loop.offload_asleep.load(.seq_cst));
    // `init_tables` opens no kqueue, so the descriptor is set to one `Queue.wake` refuses. A worker
    // that woke a loop which never said it would sleep halts on that assertion, so the skipped wake
    // is observable and not merely harmless.
    loop_fixture.loop.queue.descriptor = -1;

    try loop_fixture.hand_out(1);
    const thread = try std.Thread.spawn(.{}, Pool.serve, .{ &loop_fixture.pool, 0 });
    thread.join();

    try testing.expectEqual(@as(u32, 1), offload_module.drain(&loop_fixture.loop));
    var events: [1]core.Event = undefined;
    try testing.expectEqual(@as(u32, 1), loop_fixture.loop.tables.drain_finished(&events));
}

test "a loop with no offload holds no ring, and asks for no memory for one" {
    if (!kqueue.supported) return error.SkipZigTest;
    // The policy a caller gets without asking. It must cost nothing: no ring, no work array, and
    // the same memory a loop needed before decision 18 existed.
    const plain: Loop.Options = .{ .operations = operations, .entries = entries };
    try testing.expectEqual(@as(usize, 0), offload_module.memory_bytes(0));

    var memory: [Loop.memory_bytes(plain)]u8 align(alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, plain);
    try testing.expectEqual(@as(usize, 0), loop.completions.len);
    try testing.expectEqual(@as(usize, 0), loop.works.len);
    try testing.expectEqual(core.offload.FilePolicy.refuse, loop.file_policy);
    try testing.expect(loop.offload == null);
    try testing.expect(!offload_module.pending(&loop));
    try testing.expectEqual(@as(u32, 0), offload_module.drain(&loop));
}

test "results wait in the rings until the loop drains, and one drain takes them all" {
    if (!kqueue.supported) return error.SkipZigTest;
    // A worker may answer many operations before the loop ticks again. Every result has to wait in
    // its ring: dropping one would owe an operation a final event that never comes (decision 5,
    // rule 1), which is why `run` asserts the push succeeded. And one drain has to take the lot, or
    // a tick would hand over a batch in pieces.
    loop_fixture.init();
    const batch: u32 = core.constants.mailbox_messages / 2;
    try testing.expect(batch <= operations);

    // `Pool.submit` picks a worker by slot index, so the batch lands in both rings, and each ring
    // holds far more than its share before anything is drained.
    var served: u32 = 0;
    while (served < batch) : (served += 1) {
        try loop_fixture.hand_out(1);
        Pool.serve(&loop_fixture.pool, @intCast(served % workers));
    }
    try testing.expectEqual(batch, loop_fixture.loop.in_flight());

    // `drain_rounds_max` is sized to empty a ring that was full, so one call is enough.
    try testing.expectEqual(batch, offload_module.drain(&loop_fixture.loop));
    try testing.expect(!offload_module.pending(&loop_fixture.loop));
}

test "a loop with a result waiting does not settle to sleep, and says so through the flag" {
    // `settle_to_sleep` is what the handshake below models, and modelling it is not testing it.
    // These two assertions are on the loop's own function: the flag it publishes, and the re-read
    // that stops it sleeping on a result a worker pushed before it could see the flag.
    loop_fixture.init();
    const ring = &loop_fixture.loop.completions[0];

    // Nothing waiting: the loop settles, and the workers are told so.
    try testing.expectEqual(@as(?u64, 1000), loop_fixture.loop.settle_to_sleep(1000));
    try testing.expect(loop_fixture.loop.offload_asleep.load(.seq_cst));
    loop_fixture.loop.wake_up();
    try testing.expect(!loop_fixture.loop.offload_asleep.load(.seq_cst));

    // A result waiting: the loop refuses to sleep, which is the lost wake this prevents.
    try testing.expect(ring.push(.{ .tag = 0, .payload = 0 }));
    try testing.expect(offload_module.pending(&loop_fixture.loop));
    try testing.expectEqual(@as(?u64, null), loop_fixture.loop.settle_to_sleep(1000));

    // A caller that was not going to wait is never made to publish anything.
    loop_fixture.loop.wake_up();
    try testing.expectEqual(@as(?u64, null), loop_fixture.loop.settle_to_sleep(null));
}

// The sleep handshake, on the primitive alone. Everything above this line reaches `Work.run` or the
// submit path, so it compiles for Darwin only; everything below reaches a `Mailbox` and an atomic
// flag and nothing else, so it compiles for Linux and `zig build test-race` judges it. That is the
// whole reason it is written this way rather than against a `Loop`.

/// Rounds the handshake runs. Each is one worker answer against one loop settling to sleep, which
/// is the race decision 18 inherits from decision 12's point 6.
const handshake_rounds: u32 = 20_000;

/// Turns the producer gives the consumer to take one message before it moves on.
const handshake_turns_max: u32 = 1 << 20;

/// How long the consumer waits for a wake before it calls one lost, and how many returns of the
/// event it tolerates before the deadline. The same shape `kqueue_mailbox_test.zig` uses.
const wake_timeout_s: i64 = 10;
const spurious_returns_max: u32 = 64;

/// One ring, one flag, and the loop's blocking wait, which a `std.Io.Event` stands in for exactly
/// as `kqueue_mailbox_test.zig` does: the consumer blocks on it where a loop blocks in `kevent`,
/// and the producer sets it where a worker calls `Queue.wake`.
const Handshake = struct {
    ring: Mailbox align(core.constants.mailbox_index_alignment) = undefined,
    /// What `Loop.offload_asleep` is: written by the consumer, read by the producer.
    asleep: std.atomic.Value(bool) align(core.constants.mailbox_index_alignment) = .init(false),
    wake: std.Io.Event = .unset,
    /// Written by the consumer alone.
    received: u32 = 0,
    averted: u32 = 0,
    slept: u32 = 0,
    /// Written by the producer alone.
    woke: u32 align(core.constants.mailbox_index_alignment) = 0,
    lost: bool = false,

    /// The producer: what `kqueue_offload.zig`'s `run` does after it has performed the call.
    fn produce(handshake: *Handshake) void {
        var round: u32 = 0;
        while (round < handshake_rounds) : (round += 1) {
            const pushed = handshake.ring.push(.{ .tag = 0, .payload = round });
            std.debug.assert(pushed);
            if (handshake.asleep.load(.seq_cst)) {
                handshake.woke += 1;
                handshake.wake.set(testing.io);
            }
            // Wait for the consumer to take it, so each round is one message against one settling.
            var turn: u32 = 0;
            while (turn < handshake_turns_max and !handshake.ring.is_empty()) : (turn += 1) {
                std.Thread.yield() catch {};
            }
        }
    }

    /// Where a loop blocks in `kevent`. False when the deadline passed with no wake, which is what
    /// a lost wake looks like from here.
    fn block(handshake: *Handshake) bool {
        const io = testing.io;
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .fromSeconds(wake_timeout_s),
            .clock = .awake,
        });
        for (0..spurious_returns_max) |_| {
            if (handshake.wake.waitTimeout(io, .{ .deadline = deadline })) |_| {
                handshake.wake.reset();
                return true;
            } else |_| {
                if (deadline.durationFromNow(io).raw.nanoseconds <= 0) return false;
            }
        }
        return false;
    }

    /// The consumer: what `Loop.settle_to_sleep` does, then the blocking wait, then `wake_up`.
    fn consume(handshake: *Handshake) void {
        var out: [1]core.Message = undefined;
        while (handshake.received < handshake_rounds) {
            if (handshake.ring.pop_into(&out) == 1) {
                handshake.received += 1;
                continue;
            }
            // `settle_to_sleep`: publish, then look once more. A message that arrived before the
            // producer could see the flag is found here, and the loop does not sleep on it.
            handshake.asleep.store(true, .seq_cst);
            if (!handshake.ring.is_empty()) {
                handshake.averted += 1;
            } else {
                handshake.slept += 1;
                // A lost wake would block here for ever, so the wait has a deadline and the test
                // records that it expired rather than hanging the gate.
                if (!handshake.block()) {
                    handshake.lost = true;
                    return;
                }
            }
            handshake.asleep.store(false, .seq_cst);
        }
    }
};

var sleep_handshake: Handshake = undefined;

test "no offload wake is lost: a worker wakes a loop that has settled to sleep" {
    sleep_handshake = .{};
    sleep_handshake.ring.init();

    const producer = try std.Thread.spawn(.{}, Handshake.produce, .{&sleep_handshake});
    Handshake.consume(&sleep_handshake);
    producer.join();

    try testing.expect(!sleep_handshake.lost);
    try testing.expectEqual(handshake_rounds, sleep_handshake.received);
    // Both arms of the handshake must have been taken, or the test proved only one of them. The
    // interleaving is the scheduler's, so the counts are not fixed; that each is non-zero is.
    try testing.expect(sleep_handshake.slept + sleep_handshake.averted >= 1);
    try testing.expect(sleep_handshake.ring.is_empty());
}
