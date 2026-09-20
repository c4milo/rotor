//! The mailboxes of `kqueue_mailbox.zig` under real threads (decision 12, point 6): one ring
//! between two threads, the sleep handshake with a thread that really blocks, and several
//! producers into one consumer. No test here enters kqueue, so all of them run on every host.
//!
//! A test that fails prints its seed. The seed replays what the test drew. It cannot replay how
//! the threads interleaved: the kernel's scheduler decides that.
//!
//! What stands in for the kernel in the handshake test is a `std.Io.Event`. The consumer blocks on
//! it exactly where a loop blocks in `kevent`, and the producer sets it exactly where a loop
//! triggers the receiver's EVFILT_USER filter, which is when `must_wake` says so and at no other
//! time. A set event stays set until the consumer resets it, as a triggered filter stays triggered
//! until `kevent` reports it.
const std = @import("std");
const testing = std.testing;
const core = @import("core");
const constants = @import("constants.zig");
const mailbox_module = @import("kqueue_mailbox.zig");

const Mailbox = mailbox_module.Mailbox;
const Registry = mailbox_module.Registry;
const Random = core.random.Random;

const seed: u64 = 0x6D61_696C_626F_7821;

/// Tags are the payload modulo this prime, so a message whose halves come from two pushes does
/// not pass for a whole one.
const tag_modulus: u64 = 8191;

/// The most messages one `pop_into` of these tests asks for.
const out_max = 64;

/// Times a thread retries a step that waits for the other thread before the test fails. Every
/// retry yields the core, so the limit is minutes of waiting and a healthy run never nears it.
const attempts_max: u64 = 1 << 26;

/// How long the handshake's consumer stays blocked before it calls the wake lost. A wake that
/// was sent arrives in microseconds, so only a lost wake lasts this long.
const sleep_timeout_s = 10;

/// Spins of the handshake's consumer between taking messages and polling again, at most: the
/// stand-in for the work a loop's caller does between two ticks.
const work_spins_max = 1024;

/// Returns of the blocking wait that are neither a wake nor the timeout, per sleep, at most.
const spurious_returns_max = 1 << 10;

/// Spins of the handshake's producer while it waits for the consumer: more than the consumer's
/// timeout lasts, so a lost wake is reported by the consumer that suffered it.
const wait_spins_max: u64 = 1 << 40;

const Failure = enum(u32) {
    none,
    producer_stalled,
    consumer_stalled,
    wrong_message,
    ring_full,
    lost_wake,
};

/// The first failure of any thread of one test. Every waiting loop reads it, so one thread's
/// failure ends the others.
const Verdict = struct {
    failure: std.atomic.Value(Failure) = .init(.none),

    fn fail(verdict: *Verdict, reason: Failure) void {
        std.debug.assert(reason != .none);
        _ = verdict.failure.cmpxchgStrong(.none, reason, .seq_cst, .seq_cst);
    }

    fn failed(verdict: *const Verdict) bool {
        return verdict.failure.load(.seq_cst) != .none;
    }

    fn expect_none(verdict: *const Verdict) !void {
        const failure = verdict.failure.load(.seq_cst);
        if (failure != .none) std.debug.print("seed 0x{x}: {t}\n", .{ seed, failure });
        try testing.expectEqual(Failure.none, failure);
    }
};

/// The bits of a payload that number the message within its sender's stream. The sender's id
/// sits above them, so a message that turns up in another sender's ring does not pass.
const sequence_bits = 48;

fn message_of(sequence: u64, sender: core.LoopId) core.Message {
    std.debug.assert(sequence < 1 << sequence_bits);
    const payload = (@as(u64, sender) << sequence_bits) | sequence;
    return .{ .payload = payload, .tag = @intCast(payload % tag_modulus) };
}

/// True when `messages` are the messages of `sender` numbered from `expected.*`, which it then
/// advances.
fn in_order(messages: []const core.Message, sender: core.LoopId, expected: *u64) bool {
    for (messages) |message| {
        const wanted = message_of(expected.*, sender);
        if (message.payload != wanted.payload or message.tag != wanted.tag) return false;
        if (message.reserved != 0) return false;
        expected.* += 1;
    }
    return true;
}

/// Pushes `message`, yielding the core while the ring is full.
fn push_retrying(ring: *Mailbox, message: core.Message, verdict: *Verdict) bool {
    var attempt: u64 = 0;
    while (attempt < attempts_max) : (attempt += 1) {
        if (verdict.failed()) return false;
        if (ring.push(message)) return true;
        std.Thread.yield() catch {};
    }
    verdict.fail(.producer_stalled);
    return false;
}

// One ring between two threads.

const Stream = struct {
    ring: Mailbox = undefined,
    verdict: Verdict = .{},
    messages: u64,

    fn produce(stream: *Stream) void {
        var sequence: u64 = 0;
        while (sequence < stream.messages) : (sequence += 1) {
            const message = message_of(sequence, sender_id);
            if (!push_retrying(&stream.ring, message, &stream.verdict)) return;
        }
    }

    /// Pops with an `out` of a random length, so the batches cut the stream at every offset.
    fn consume(stream: *Stream) void {
        var random = Random.init(seed);
        var out: [out_max]core.Message = undefined;
        var expected: u64 = 0;
        var attempt: u64 = 0;
        while (attempt < attempts_max and expected < stream.messages) : (attempt += 1) {
            if (stream.verdict.failed()) return;
            const room: usize = @intCast(random.between(1, out_max));
            const count = stream.ring.pop_into(out[0..room]);
            if (count == 0) std.Thread.yield() catch {};
            if (!in_order(out[0..count], sender_id, &expected)) {
                return stream.verdict.fail(.wrong_message);
            }
        }
        if (expected < stream.messages) stream.verdict.fail(.consumer_stalled);
    }
};

test "a million messages cross one ring between two threads, each once and in order" {
    var stream: Stream = .{ .messages = 1_000_000 };
    stream.ring.init();
    const producer = try std.Thread.spawn(.{}, Stream.produce, .{&stream});
    stream.consume();
    producer.join();
    try stream.verdict.expect_none();
    try testing.expect(stream.ring.is_empty());
    try testing.expectEqual(@as(u32, 1_000_000), stream.ring.tail.load(.unordered));
    try testing.expectEqual(@as(u32, 1_000_000), stream.ring.head.load(.unordered));
}

// Several producers, each with its own ring to one consumer.

const fan_loops = 5;
const fan_bytes = Registry.memory_bytes(fan_loops);
const fan_receiver: core.LoopId = 0;

const Fan = struct {
    registry: Registry = undefined,
    verdict: Verdict = .{},
    messages_each: u64,

    fn produce(fan: *Fan, sender: core.LoopId) void {
        const ring = fan.registry.mailbox(sender, fan_receiver);
        var sequence: u64 = 0;
        while (sequence < fan.messages_each) : (sequence += 1) {
            if (!push_retrying(ring, message_of(sequence, sender), &fan.verdict)) return;
        }
    }

    /// Drains every inbound ring in turn, as a loop does at each tick.
    fn consume(fan: *Fan) void {
        var expected: [fan_loops]u64 = @splat(0);
        var attempt: u64 = 0;
        while (attempt < attempts_max) : (attempt += 1) {
            if (fan.verdict.failed()) return;
            const drained = fan.drain(&expected) orelse return fan.verdict.fail(.wrong_message);
            if (fan.finished(&expected)) return;
            if (drained == 0) std.Thread.yield() catch {};
        }
        fan.verdict.fail(.consumer_stalled);
    }

    /// One pass over the inbound rings. Null when a ring held a message that is not its next.
    fn drain(fan: *Fan, expected: *[fan_loops]u64) ?u32 {
        var out: [out_max]core.Message = undefined;
        var drained: u32 = 0;
        for (1..fan_loops) |sender| {
            const ring = fan.registry.mailbox(@intCast(sender), fan_receiver);
            const count = ring.pop_into(&out);
            if (!in_order(out[0..count], @intCast(sender), &expected[sender])) return null;
            drained += count;
        }
        return drained;
    }

    fn finished(fan: *const Fan, expected: *const [fan_loops]u64) bool {
        for (expected[1..]) |next| {
            if (next < fan.messages_each) return false;
        }
        return true;
    }

    /// Starts one producer per sender. A spawn that fails ends the producers already started,
    /// so none of them outlives the test's frame.
    fn spawn_producers(fan: *Fan, producers: *[fan_loops - 1]std.Thread) !void {
        for (producers, 1..) |*producer, sender| {
            const id: core.LoopId = @intCast(sender);
            producer.* = std.Thread.spawn(.{}, Fan.produce, .{ fan, id }) catch |err| {
                fan.verdict.fail(.producer_stalled);
                for (producers[0 .. sender - 1]) |started| started.join();
                return err;
            };
        }
    }
};

test "four producers with a ring each reach one consumer, every message once" {
    var memory: [fan_bytes]u8 align(core.layout.memory_alignment) = undefined;
    var fan: Fan = .{ .messages_each = 250_000 };
    fan.registry.init(&memory, fan_loops);
    var producers: [fan_loops - 1]std.Thread = undefined;
    try fan.spawn_producers(&producers);
    fan.consume();
    for (producers) |producer| producer.join();
    try fan.verdict.expect_none();
    for (0..fan_loops * fan_loops) |pair| {
        const ring = fan.registry.mailbox(@intCast(pair / fan_loops), @intCast(pair % fan_loops));
        try testing.expect(ring.is_empty());
        const used = pair / fan_loops != fan_receiver and pair % fan_loops == fan_receiver;
        try testing.expectEqual(@as(u32, if (used) 250_000 else 0), ring.tail.load(.unordered));
    }
}

// The sleep handshake.

const sender_id: core.LoopId = 0;
const receiver_id: core.LoopId = 1;
const handshake_bytes = Registry.memory_bytes(2);

/// The tag of the message that ends the handshake test. No counted message carries it.
const tag_stop = tag_modulus;

const Handshake = struct {
    registry: Registry = undefined,
    verdict: Verdict = .{},
    rounds: u32,
    /// The receiver's kqueue, as far as this test goes.
    wake: std.Io.Event = .unset,
    /// True while the consumer is in, or about to enter, its blocking wait. It is the test's own
    /// flag, so the producer can aim at a sleeping consumer without asking the code under test.
    blocking: std.atomic.Value(bool) align(constants.mailbox_index_alignment) = .init(false),
    /// How often the consumer blocked, and the messages it took. Written by the consumer alone.
    sleeps: u64 align(constants.mailbox_index_alignment) = 0,
    /// How often the check after `begin_sleep` found a message, so the consumer did not block.
    averted: u64 = 0,
    received: u64 = 0,
    /// How often `must_wake` told the producer to wake, and the messages it posted. Written by
    /// the producer alone.
    wakes: u64 align(constants.mailbox_index_alignment) = 0,
    sent: u64 = 0,

    fn ring(handshake: *Handshake) *Mailbox {
        return handshake.registry.mailbox(sender_id, receiver_id);
    }

    // The consumer: what a loop does at each tick.

    fn consume(handshake: *Handshake) void {
        var random = Random.init(seed +% 1);
        var out: [out_max]core.Message = undefined;
        var turn: u64 = 0;
        while (turn < attempts_max) : (turn += 1) {
            var count = handshake.ring().pop_into(&out);
            if (count == 0) count = handshake.sleep(&random, &out) orelse return;
            if (count == 0) continue;
            const stop = out[count - 1].tag == tag_stop;
            const counted = if (stop) count - 1 else count;
            if (!in_order(out[0..counted], sender_id, &handshake.received)) {
                return handshake.verdict.fail(.wrong_message);
            }
            if (stop) return;
            // The caller of a loop handles its events between two ticks. The time that takes
            // moves the consumer's way to sleep across the producer's next post.
            spin(random.below(work_spins_max));
        }
        handshake.verdict.fail(.consumer_stalled);
    }

    /// The handshake, then the blocking call. A loop may make the check after `begin_sleep`
    /// with `pop_into` or with `is_empty`, so this draws which. Returns how many messages that
    /// check took into `out`, or null when the consumer blocked and the wake never came.
    fn sleep(handshake: *Handshake, random: *Random, out: []core.Message) ?u32 {
        const pops = random.chance(1, 2);
        handshake.registry.begin_sleep(receiver_id);
        const taken = if (pops) handshake.ring().pop_into(out) else 0;
        const found = if (pops) taken != 0 else !handshake.ring().is_empty();
        if (found) {
            handshake.registry.end_sleep(receiver_id);
            handshake.averted += 1;
            return taken;
        }
        handshake.blocking.store(true, .seq_cst);
        const woken = handshake.block();
        handshake.blocking.store(false, .seq_cst);
        handshake.registry.end_sleep(receiver_id);
        handshake.sleeps += 1;
        if (!woken) handshake.verdict.fail(.lost_wake);
        return if (woken) 0 else null;
    }

    /// Where a loop blocks in `kevent`. False when the timeout expired with no wake.
    fn block(handshake: *Handshake) bool {
        const io = testing.io;
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .fromSeconds(sleep_timeout_s),
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

    // The producer: what a loop does when it flushes a `post`.

    /// One round waits until the consumer has taken the round before, and then posts a burst at
    /// a drawn moment. The wait is what makes a lost wake stall: no later message arrives to
    /// wake the consumer by accident.
    fn produce(handshake: *Handshake) void {
        var random = Random.init(seed);
        for (0..handshake.rounds) |_| {
            const moment = Moment.draw(&random);
            if (!handshake.aim(moment)) return;
            for (0..moment.burst) |_| {
                if (!handshake.post(message_of(handshake.sent, sender_id))) return;
                handshake.sent += 1;
            }
        }
        if (!handshake.wait_until(.drained)) return;
        _ = handshake.post(.{ .payload = 0, .tag = tag_stop });
    }

    /// The post, in the order the handshake needs: the push first, `must_wake` second.
    fn post(handshake: *Handshake, message: core.Message) bool {
        if (!handshake.ring().push(message)) {
            handshake.verdict.fail(.ring_full);
            return false;
        }
        if (handshake.registry.must_wake(receiver_id)) {
            handshake.wakes += 1;
            handshake.wake.set(testing.io);
        }
        return true;
    }

    /// When a round posts, drawn before the round waits, so that the draw delays no post.
    const Moment = struct {
        /// Wait until the consumer says it blocks. Such a post only a wake can deliver.
        after_blocking: bool,
        spins: u64,
        burst: u64,

        fn draw(random: *Random) Moment {
            const kind = random.below(4);
            return .{
                .after_blocking = kind == 3,
                .spins = switch (kind) {
                    0 => 0,
                    1 => random.below(256),
                    else => random.below(4096),
                },
                .burst = if (random.chance(1, 8)) random.between(2, 8) else 1,
            };
        }
    };

    /// Waits for the moment. When the consumer has taken the last round it is on its way to
    /// sleep: it handles what it took, polls once more, calls `begin_sleep`, checks the ring, and
    /// blocks. A post with no delay or a short one lands inside that sequence, which is where a
    /// wake can be lost.
    fn aim(handshake: *Handshake, moment: Moment) bool {
        if (!handshake.wait_until(.drained)) return false;
        if (moment.after_blocking and !handshake.wait_until(.blocking)) return false;
        spin(moment.spins);
        return true;
    }

    const Condition = enum { drained, blocking };

    fn wait_until(handshake: *Handshake, condition: Condition) bool {
        var spins: u64 = 0;
        while (spins < wait_spins_max) : (spins += 1) {
            if (handshake.verdict.failed()) return false;
            const met = switch (condition) {
                .drained => handshake.ring().is_empty(),
                .blocking => handshake.blocking.load(.seq_cst),
            };
            if (met) return true;
        }
        handshake.verdict.fail(.producer_stalled);
        return false;
    }
};

fn spin(iterations: u64) void {
    for (0..iterations) |iteration| std.mem.doNotOptimizeAway(iteration);
}

test "no wake is lost: a consumer that blocks is woken by the post that needs it" {
    var memory: [handshake_bytes]u8 align(core.layout.memory_alignment) = undefined;
    var handshake: Handshake = .{ .rounds = 60_000 };
    handshake.registry.init(&memory, 2);
    const consumer = try std.Thread.spawn(.{}, Handshake.consume, .{&handshake});
    handshake.produce();
    consumer.join();
    try handshake.verdict.expect_none();
    try testing.expect(handshake.ring().is_empty());
    try testing.expect(handshake.sent >= handshake.rounds);
    try testing.expectEqual(handshake.sent, handshake.received);
    // A quarter of the rounds wait for the consumer to block, so it blocked at least that often,
    // and each of those sleeps ended by a wake `must_wake` asked for.
    try testing.expect(handshake.sleeps >= handshake.rounds / 4);
    try testing.expect(handshake.wakes >= handshake.rounds / 4);
    try testing.expect(!handshake.registry.must_wake(receiver_id));
}
