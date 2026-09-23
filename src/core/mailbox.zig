//! The mailboxes a `post` travels through on a readiness backend (decision 4, "How cores talk";
//! decision 12, point 6). `Mailbox` is one single-producer single-consumer ring of `Message`, and
//! there is one per ordered pair of loops. `Registry` holds the rings, each loop's readiness
//! descriptor, and whether each loop sleeps.
//!
//! It is in `core` because `kqueue` and `epoll` both need it and it names no kernel type: neither
//! has io_uring's `msg_ring`, so a message crosses in user space on both, and only the wake differs,
//! which is the loop's job. `uring` holds its own `Registry` with no rings. It lived in
//! `src/kqueue/` until the second readiness backend needed it, on 2026-09-22.
//!
//! Nothing here enters the kernel, so this file compiles on every host. The tests that start a
//! thread are in `src/kqueue/kqueue_mailbox_test.zig`, which says why they are there.
//!
//! These rings are the one place in rotor where two threads touch the same memory. Every atomic
//! operation has its ordering for a reason, and the reasons follow.
//!
//! The ring. `tail` counts the messages pushed and `head` the messages popped. Both only ever
//! increase, and they wrap as u32. `constants.mailbox_messages` is a power of two, so it divides
//! 2^32: `tail -% head` is the number of messages in the ring and `index & slot_mask` is the
//! slot, before and after the wrap. The producer alone writes `tail` and the slots. The consumer
//! alone writes `head`.
//!
//! - A side loads its own index with `.unordered`. No other thread writes that index, so the
//!   load returns that side's last store.
//! - `push` loads `head` with `.acquire`, and `pop_into` stores it with `.release`. A stale
//!   `head` shows the producer a fuller ring than the real one, so the worst it does is refuse a
//!   push the ring had room for. The consumer reads a slot with plain loads, and the producer
//!   later overwrites that slot with plain stores. The `.release` store and the `.acquire` load
//!   order the two: a producer that sees the new `head` runs after every read the consumer made
//!   before it stored `head`.
//! - `push` writes the slot first and stores `tail` second. `pop_into` and `is_empty` load
//!   `tail`. A stale `tail` shows the consumer an emptier ring than the real one, so the worst it
//!   does is deliver a message one call later. The slot is written with plain stores, so the
//!   store of `tail` must be `.release` or stronger and the load `.acquire` or stronger: then a
//!   consumer that sees the new `tail` also sees the message bytes written before it. Both are
//!   `.seq_cst`, which is stronger, for the handshake.
//!
//! The sleep handshake. A consumer that blocks in the kernel needs the producer of the next
//! message to wake it, and a wake costs the producer a system call, so it should pay only when the
//! consumer sleeps. The consumer stores `sleeping` (`begin_sleep`), then loads every inbound
//! `tail` (`is_empty` or `pop_into`), and blocks only when every ring was empty. The producer
//! stores `tail` (`push`), then loads `sleeping` (`must_wake`), and wakes the consumer when it is
//! set. So each side stores its own word and then loads the other's.
//!
//! - Those four operations are `.seq_cst`. Sequentially consistent operations have one total
//!   order, and each load sees the last store before it in that order. Take the store that comes
//!   second. Its thread's load comes after it, so that load sees the other side's store, which
//!   came first. So the consumer sees the message and does not block, or the producer sees
//!   `sleeping` and wakes it. Both can happen: then the wake is wasted, which is harmless. With
//!   any weaker ordering there is no one order. Each store can wait in its core's store buffer
//!   while the other core's load runs, so both loads return the old value. A message then sits
//!   in the ring, its receiver blocks, and nobody is obliged to wake it. That lost wake is the
//!   bug. On AArch64 the orderings are different instructions, seen in Zig 0.16's output: a
//!   `.seq_cst` load is LDAR, an `.acquire` load is LDAPR, and a plain load is LDR. On an Apple
//!   M1 Pro the handshake test of `kqueue/kqueue_mailbox_test.zig` loses a wake when any one of
//!   the four is weakened to a different instruction. A `.release` store of `tail` is the
//!   instruction a `.seq_cst` store is, STLR, so there the argument is the only evidence.
//! - `end_sleep` stores `sleeping` with `.seq_cst` too, so every access to the flag has a place
//!   in the one order and the argument needs no case for a weaker store. A producer that still
//!   sees the flag set wakes a consumer that is awake: wasted, harmless. It runs once per
//!   blocking call into the kernel, so its cost is lost in the system call.
//! - `begin_sleep` first loads the flag with `.unordered` to assert it is clear. The loop is the
//!   flag's only writer, so the load returns the loop's last store.
//! - `clear` swaps a descriptor with `.release` and `get` loads it with `.acquire`, as the
//!   `uring` registry does. The entry is one word, and a reader that sees the old value behaves
//!   as if it ran before the swap. The swap returns the value it replaced, so the assertion
//!   tests the value that was overwritten and not an earlier one.
//! - `set` and `set_remote` swap with `.acq_rel`. The thread that claims an id becomes the
//!   producer of the rings from that id, and for a loop the consumer of the rings toward it. The
//!   previous holder of the id wrote those rings' slots with plain stores and read its own index
//!   with `.unordered` loads, and the claimant will do the same. The claimant learns that the id
//!   is free from the application, through a signal that may order nothing, so the swap that
//!   reads the `descriptor_none` the previous holder's `clear` stored is the one edge rotor
//!   controls: its acquire half makes every store before that `clear` visible to the claimant.
//!   No test shows it, because the claimant's first loads would have to be served stale; the
//!   argument is the evidence. The `uring` registry holds no rings, so its claim stays `.release`.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const layout = @import("layout.zig");
const operation_module = @import("operation.zig");

const Descriptor = operation_module.Descriptor;
const LoopId = operation_module.LoopId;
const Message = operation_module.Message;

/// The entry of a loop that has not started or has stopped.
pub const descriptor_none: Descriptor = -1;

/// The entry of a `Remote`: an id a thread claimed so its messages can name a sender, which runs no
/// loop and receives nothing (decision 4). It is distinct from `descriptor_none` so that claiming an
/// id twice is caught, and negative so that every `post` to it is already answered `loop_not_found`
/// by the check each backend makes on a target's descriptor.
pub const descriptor_remote: Descriptor = -2;

/// The fewest loops a registry serves: one loop alone has nobody to post to.
const loops_min: u16 = 2;

/// What `index & slot_mask` keeps: the slot of a message index.
const slot_mask: u32 = constants.mailbox_messages - 1;

/// One ring: one loop writes it and one loop reads it. 4352 bytes aligned to 128: one line for
/// `tail`, one for `head`, and 32 lines of messages.
pub const Mailbox = extern struct {
    /// Messages pushed so far. Written by the producer alone. On its own 128-byte line.
    tail: std.atomic.Value(u32) align(constants.mailbox_index_alignment),
    /// Messages popped so far. Written by the consumer alone. On its own 128-byte line.
    head: std.atomic.Value(u32) align(constants.mailbox_index_alignment),
    /// Written by the producer alone. It starts on the line after `head`, so a slot the
    /// producer writes never shares a line with the index the consumer writes.
    messages: [constants.mailbox_messages]Message align(constants.mailbox_index_alignment),

    /// Leaves the ring empty. It writes no slot: no slot is read before `push` has written it.
    pub fn init(mailbox: *Mailbox) void {
        mailbox.tail = .init(0);
        mailbox.head = .init(0);
        assert(mailbox.is_empty());
    }

    /// Producer only. False when the ring is full, and the message is not written.
    pub fn push(mailbox: *Mailbox, message: Message) bool {
        const tail = mailbox.tail.load(.unordered);
        const head = mailbox.head.load(.acquire);
        const used = tail -% head;
        assert(used <= constants.mailbox_messages);
        if (used == constants.mailbox_messages) return false;
        mailbox.messages[tail & slot_mask] = message;
        mailbox.tail.store(tail +% 1, .seq_cst);
        return true;
    }

    /// Consumer only. Moves the oldest messages into `out`, oldest first, at most `out.len`, and
    /// returns how many. An empty ring costs no store, so polling it leaves the producer's copy
    /// of the `head` line valid.
    pub fn pop_into(mailbox: *Mailbox, out: []Message) u32 {
        const head = mailbox.head.load(.unordered);
        const tail = mailbox.tail.load(.seq_cst);
        const available = tail -% head;
        assert(available <= constants.mailbox_messages);
        const count: u32 = @intCast(@min(available, out.len));
        if (count == 0) return 0;
        for (out[0..count], 0..) |*message, offset| {
            const index = head +% @as(u32, @intCast(offset));
            message.* = mailbox.messages[index & slot_mask];
        }
        mailbox.head.store(head +% count, .release);
        assert(count <= available);
        return count;
    }

    /// Either side. A hint: it may be stale by the time the caller acts on it. To the consumer
    /// "not empty" is exact, because only the consumer removes messages.
    pub fn is_empty(mailbox: *const Mailbox) bool {
        return mailbox.tail.load(.seq_cst) == mailbox.head.load(.seq_cst);
    }
};

/// What the registry holds for one loop. 128 bytes aligned to 128: a loop stores its `sleeping`
/// flag around every blocking tick, and that store never dirties the line of another loop's
/// entry.
const Entry = extern struct {
    /// The descriptor that wakes the loop, or `descriptor_none`: its kqueue on kqueue, its
    /// eventfd on epoll. Written by the loop, at init and at deinit. Read by the loops that post
    /// to it.
    queue: std.atomic.Value(Descriptor) align(constants.mailbox_index_alignment),
    /// True from `begin_sleep` to `end_sleep`. Written by the loop. Read by the loops that post
    /// to it.
    sleeping: std.atomic.Value(bool),
};

/// The bytes `init` may have to skip to reach an address aligned for a `Mailbox`.
pub const alignment_slack_bytes: usize = @alignOf(Mailbox) - layout.memory_alignment;

comptime {
    assert(@sizeOf(Message) == 16);
    assert(@alignOf(Mailbox) == constants.mailbox_index_alignment);
    assert(@offsetOf(Mailbox, "tail") == 0);
    assert(@offsetOf(Mailbox, "head") == constants.mailbox_index_alignment);
    assert(@offsetOf(Mailbox, "messages") == 2 * constants.mailbox_index_alignment);
    assert(@sizeOf(Mailbox) == 4352);
    assert(@sizeOf(Entry) == constants.mailbox_index_alignment);
    assert(@alignOf(Entry) == @alignOf(Mailbox));
    assert(@alignOf(Mailbox) >= layout.memory_alignment);
    assert(std.math.isPowerOfTwo(layout.memory_alignment));
    assert(slot_mask & constants.mailbox_messages == 0);
}

/// The loops of one process: their mailboxes, the descriptors that wake them, and whether each
/// sleeps. One per process, owned by the application, which hands it to every loop at init.
/// `init` runs before any loop starts, and the two slices never change afterwards, so every
/// thread may read them. Two slices: 32 bytes aligned to 8 on a 64-bit target.
pub const Registry = struct {
    /// One per loop, by id.
    entries: []Entry,
    /// One per ordered pair of loops: the ring `sender` writes and `receiver` reads is at
    /// `receiver * loops + sender`, so the rings one loop drains at every tick are adjacent. The
    /// ring from a loop to itself is there and unused, which keeps the index one multiply and
    /// one add.
    mailboxes: []Mailbox,

    /// The bytes `init` needs for `loop_count` loops: a function of the loops the application
    /// runs, never of `constants.loops_max` (decision 12, point 6).
    pub fn memory_bytes(loop_count: u16) usize {
        assert(loop_count >= loops_min);
        assert(loop_count <= constants.loops_max);
        const count: usize = loop_count;
        const tables_bytes = count * @sizeOf(Entry) + count * count * @sizeOf(Mailbox);
        return alignment_slack_bytes + tables_bytes;
    }

    /// `loop_count` is in [2, constants.loops_max] and `memory.len` is at least
    /// `memory_bytes(loop_count)`. Afterwards every mailbox is empty, every descriptor is
    /// absent, and no loop sleeps.
    ///
    /// `memory` is aligned to `layout.memory_alignment`, 64, and a `Mailbox` and an `Entry`
    /// need 128. So `memory_bytes` asks for `alignment_slack_bytes` more than the tables take,
    /// and `init` skips to the first address aligned to 128, which is at most that far in.
    pub fn init(
        registry: *Registry,
        memory: []align(layout.memory_alignment) u8,
        loop_count: u16,
    ) void {
        assert(memory.len >= memory_bytes(loop_count));
        const count: usize = loop_count;
        const base = @intFromPtr(memory.ptr);
        const skipped = std.mem.alignForward(usize, base, @alignOf(Mailbox)) - base;
        assert(skipped <= alignment_slack_bytes);
        const entries_bytes = count * @sizeOf(Entry);
        assert(skipped + entries_bytes + count * count * @sizeOf(Mailbox) <= memory.len);
        const entries: [*]Entry = @ptrCast(@alignCast(memory.ptr + skipped));
        const mailboxes: [*]Mailbox = @ptrCast(@alignCast(memory.ptr + skipped + entries_bytes));
        assert(@intFromPtr(mailboxes) % @alignOf(Mailbox) == 0);
        registry.* = .{ .entries = entries[0..count], .mailboxes = mailboxes[0 .. count * count] };
        for (registry.entries) |*entry| {
            entry.* = .{ .queue = .init(descriptor_none), .sleeping = .init(false) };
        }
        for (registry.mailboxes) |*ring| ring.init();
    }

    /// How many loops the registry was sized for.
    pub fn loops(registry: *const Registry) u16 {
        assert(registry.entries.len >= loops_min);
        assert(registry.entries.len <= constants.loops_max);
        return @intCast(registry.entries.len);
    }

    /// A loop publishes the descriptor that wakes it at init. The id must be free: two loops with
    /// one id is a programmer error. `.acq_rel`: the claim carries the previous holder's ring
    /// stores to this loop, which is about to read those rings (the header says why).
    pub fn set(registry: *Registry, id: LoopId, queue: Descriptor) void {
        assert(id < registry.entries.len);
        assert(queue >= 0);
        const previous = registry.entries[id].queue.swap(queue, .acq_rel);
        assert(previous == descriptor_none);
    }

    /// A `Remote` claims `id` at init: it publishes no queue, because it receives nothing, and the
    /// sentinel is what makes a second claim on one id halt (decision 4).
    pub fn set_remote(registry: *Registry, id: LoopId) void {
        assert(id < registry.entries.len);
        const previous = registry.entries[id].queue.swap(descriptor_remote, .acq_rel);
        assert(previous == descriptor_none);
    }

    /// A loop withdraws its descriptor at deinit. Withdrawing an absent loop is a programmer
    /// error.
    pub fn clear(registry: *Registry, id: LoopId) void {
        assert(id < registry.entries.len);
        const previous = registry.entries[id].queue.swap(descriptor_none, .release);
        // A loop publishes its queue and a `Remote` publishes the sentinel. Either way the id was
        // claimed, and withdrawing one that was not is a programmer error.
        assert(previous != descriptor_none);
    }

    /// The descriptor that wakes loop `id`, or a negative value when it has none.
    pub fn get(registry: *const Registry, id: LoopId) Descriptor {
        assert(id < registry.entries.len);
        return registry.entries[id].queue.load(.acquire);
    }

    /// The ring `sender` writes and `receiver` reads.
    pub fn mailbox(registry: *Registry, sender: LoopId, receiver: LoopId) *Mailbox {
        const count = registry.entries.len;
        assert(sender < count);
        assert(receiver < count);
        return &registry.mailboxes[@as(usize, receiver) * count + sender];
    }

    /// Consumer: call right before blocking in the kernel. After it returns, the consumer MUST
    /// check its inbound mailboxes once more, and must not block when any holds a message. A
    /// loop that begins a sleep twice forgot `end_sleep`, and every post to it would then pay
    /// for a wake: a programmer error.
    pub fn begin_sleep(registry: *Registry, id: LoopId) void {
        assert(id < registry.entries.len);
        const sleeping = &registry.entries[id].sleeping;
        assert(!sleeping.load(.unordered));
        sleeping.store(true, .seq_cst);
    }

    /// Consumer: call after the blocking call returns, or when the check after `begin_sleep` found
    /// a message. Harmless for a loop that is not marked asleep.
    pub fn end_sleep(registry: *Registry, id: LoopId) void {
        assert(id < registry.entries.len);
        registry.entries[id].sleeping.store(false, .seq_cst);
    }

    /// Producer: call after a successful `push`. True when the receiver is, or may be, asleep,
    /// and the producer must then wake it through the descriptor `get` returns.
    pub fn must_wake(registry: *const Registry, id: LoopId) bool {
        assert(id < registry.entries.len);
        return registry.entries[id].sleeping.load(.seq_cst);
    }
};

const testing = std.testing;

/// Tags in these tests are the payload modulo this prime, so a message whose halves come from
/// two pushes does not pass for a whole one.
const tag_modulus: u64 = 8191;

fn message_of(sequence: u64) Message {
    return .{ .payload = sequence, .tag = @intCast(sequence % tag_modulus) };
}

fn expect_message(sequence: u64, message: Message) !void {
    const expected = message_of(sequence);
    try testing.expectEqual(expected.payload, message.payload);
    try testing.expectEqual(expected.tag, message.tag);
    try testing.expectEqual(@as(u32, 0), message.reserved);
}

test "a mailbox hands its messages over in the order they were pushed" {
    var ring: Mailbox = undefined;
    ring.init();
    var out: [8]Message = undefined;
    try testing.expect(ring.is_empty());
    try testing.expectEqual(@as(u32, 0), ring.pop_into(&out));
    for (0..5) |sequence| try testing.expect(ring.push(message_of(sequence)));
    try testing.expect(!ring.is_empty());
    try testing.expectEqual(@as(u32, 5), ring.pop_into(&out));
    for (out[0..5], 0..) |message, sequence| try expect_message(sequence, message);
    try testing.expect(ring.is_empty());
    try testing.expectEqual(@as(u32, 0), ring.pop_into(&out));
}

test "a full mailbox refuses a message and writes nothing" {
    var ring: Mailbox = undefined;
    ring.init();
    for (0..constants.mailbox_messages) |sequence| {
        try testing.expect(ring.push(message_of(sequence)));
    }
    try testing.expect(!ring.push(message_of(77_777)));
    try testing.expectEqual(constants.mailbox_messages, ring.tail.load(.unordered));
    var out: [constants.mailbox_messages]Message = undefined;
    try testing.expectEqual(constants.mailbox_messages, ring.pop_into(&out));
    for (out, 0..) |message, sequence| try expect_message(sequence, message);
    // The ring has room again, and the message it refused was never in it.
    try testing.expect(ring.push(message_of(77_777)));
    try testing.expectEqual(@as(u32, 1), ring.pop_into(&out));
    try expect_message(77_777, out[0]);
}

test "pop_into takes no more than out holds and leaves the rest in the ring" {
    var ring: Mailbox = undefined;
    ring.init();
    for (0..10) |sequence| try testing.expect(ring.push(message_of(sequence)));
    var out: [4]Message = undefined;
    try testing.expectEqual(@as(u32, 0), ring.pop_into(out[0..0]));
    try testing.expectEqual(@as(u32, 4), ring.pop_into(&out));
    for (out, 0..) |message, sequence| try expect_message(sequence, message);
    try testing.expectEqual(@as(u32, 4), ring.pop_into(&out));
    for (out, 4..) |message, sequence| try expect_message(sequence, message);
    try testing.expectEqual(@as(u32, 2), ring.pop_into(&out));
    for (out[0..2], 8..) |message, sequence| try expect_message(sequence, message);
    try testing.expectEqual(@as(u32, 0), ring.pop_into(&out));
    try testing.expectEqual(@as(u32, 10), ring.head.load(.unordered));
}

test "the indices wrap past 2^32 and the ring keeps its count and its order" {
    var ring: Mailbox = undefined;
    ring.init();
    const start: u32 = std.math.maxInt(u32) - 100;
    ring.tail = .init(start);
    ring.head = .init(start);
    try testing.expect(ring.is_empty());
    for (0..constants.mailbox_messages) |sequence| {
        try testing.expect(ring.push(message_of(sequence)));
    }
    try testing.expect(!ring.push(message_of(77_777)));
    try testing.expectEqual(@as(u32, 155), ring.tail.load(.unordered));
    var out: [100]Message = undefined;
    var popped: u64 = 0;
    for ([_]u32{ 100, 100, 56, 0 }) |expected| {
        const count = ring.pop_into(&out);
        try testing.expectEqual(expected, count);
        for (out[0..count], popped..) |message, sequence| try expect_message(sequence, message);
        popped += count;
    }
    try testing.expectEqual(@as(u32, 155), ring.head.load(.unordered));
    try testing.expect(ring.is_empty());
}

const pair_loops = 5;
const pair_bytes = Registry.memory_bytes(pair_loops);

/// A distinct payload for the ring from `sender` to `receiver`.
fn pair_sequence(sender: usize, receiver: usize) u64 {
    return sender * constants.loops_max + receiver;
}

test "every ordered pair of loops has a mailbox of its own" {
    var memory: [pair_bytes]u8 align(layout.memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    try testing.expectEqual(@as(u16, pair_loops), registry.loops());
    for (0..pair_loops * pair_loops) |pair| {
        const sender = pair / pair_loops;
        const receiver = pair % pair_loops;
        const ring = registry.mailbox(@intCast(sender), @intCast(receiver));
        try testing.expect(ring.is_empty());
        try testing.expect(ring.push(message_of(pair_sequence(sender, receiver))));
    }
    var out: [2]Message = undefined;
    for (0..pair_loops * pair_loops) |pair| {
        const sender = pair / pair_loops;
        const receiver = pair % pair_loops;
        const ring = registry.mailbox(@intCast(sender), @intCast(receiver));
        try testing.expectEqual(@as(u32, 1), ring.pop_into(&out));
        try expect_message(pair_sequence(sender, receiver), out[0]);
    }
}

test "the rings one loop reads are adjacent, aligned, and inside the memory, at either base" {
    // `buffer` is aligned to 128. Its first slice starts on a 128-byte line and its second 64
    // bytes past one, which are the two bases memory aligned to 64 can have.
    const slack = layout.memory_alignment;
    var buffer: [pair_bytes + slack]u8 align(@alignOf(Mailbox)) = undefined;
    const bases = [_][]align(layout.memory_alignment) u8{
        buffer[0..pair_bytes],
        buffer[slack..][0..pair_bytes],
    };
    for (bases) |memory| {
        var registry: Registry = undefined;
        registry.init(memory, pair_loops);
        const first = @intFromPtr(registry.mailbox(0, 0));
        const end = @intFromPtr(memory.ptr) + memory.len;
        try testing.expect(first >= @intFromPtr(memory.ptr) + pair_loops * @sizeOf(Entry));
        for (0..pair_loops * pair_loops) |pair| {
            const sender = pair % pair_loops;
            const receiver = pair / pair_loops;
            const address = @intFromPtr(registry.mailbox(@intCast(sender), @intCast(receiver)));
            try testing.expectEqual(first + pair * @sizeOf(Mailbox), address);
            try testing.expectEqual(@as(usize, 0), address % @alignOf(Mailbox));
            try testing.expect(address + @sizeOf(Mailbox) <= end);
        }
    }
}

test "a registry starts with no descriptor, publishes one and forgets it" {
    var memory: [pair_bytes]u8 align(layout.memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    for (0..pair_loops) |id| try testing.expect(registry.get(@intCast(id)) < 0);
    registry.set(3, 17);
    registry.set(pair_loops - 1, 0);
    try testing.expectEqual(@as(Descriptor, 17), registry.get(3));
    try testing.expectEqual(@as(Descriptor, 0), registry.get(pair_loops - 1));
    try testing.expectEqual(descriptor_none, registry.get(2));
    registry.clear(3);
    try testing.expectEqual(descriptor_none, registry.get(3));
    try testing.expectEqual(@as(Descriptor, 0), registry.get(pair_loops - 1));
    registry.set(3, 21);
    try testing.expectEqual(@as(Descriptor, 21), registry.get(3));
}

test "a loop must be woken from begin_sleep to end_sleep, and no other loop with it" {
    var memory: [pair_bytes]u8 align(layout.memory_alignment) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    for (0..pair_loops) |id| try testing.expect(!registry.must_wake(@intCast(id)));
    registry.begin_sleep(2);
    for (0..pair_loops) |id| try testing.expectEqual(id == 2, registry.must_wake(@intCast(id)));
    registry.end_sleep(2);
    for (0..pair_loops) |id| try testing.expect(!registry.must_wake(@intCast(id)));
    // A loop that found a message after `begin_sleep` ends the sleep without blocking, and a
    // loop that is awake may end a sleep it never began.
    registry.begin_sleep(2);
    registry.end_sleep(2);
    registry.end_sleep(2);
    registry.begin_sleep(2);
    try testing.expect(registry.must_wake(2));
}

test "memory_bytes grows with the square of the loops and not with loops_max" {
    const two = Registry.memory_bytes(2);
    try testing.expectEqual(@as(usize, 64 + 2 * 128 + 4 * 4352), two);
    try testing.expectEqual(@as(usize, 64 + 5 * 128 + 25 * 4352), pair_bytes);
    const most = Registry.memory_bytes(constants.loops_max);
    try testing.expectEqual(@as(usize, 64 + 256 * 128 + 65536 * 4352), most);
}
