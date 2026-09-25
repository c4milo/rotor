//! The registry: where loops find each other's mailboxes, the descriptor that wakes each loop, and
//! whether each loop sleeps (decision 4, "How cores talk"; decision 12, point 6). It lived in
//! `mailbox.zig` until 2026-09-25, when decision 21 gave it a header and a table of wakes and that
//! file reached its length limit. `mailbox.zig` argues the orderings of `set`, `clear` and the sleep
//! flag, and exports what is here.
//!
//! Nothing in a registry's memory is a pointer, so the memory may be a mapping several processes
//! share (decision 21). Each process builds its own `Registry` value over it: the process that
//! creates it with `init` or `init_group`, and every other process of a group with `attach`. The
//! memory holds, from its first address aligned to 128:
//!
//! 1. `Header`, 128 bytes.
//! 2. One `Wake` per loop, in whole 128-byte lines. Every wake is absent in a registry `init` made.
//! 3. One `Entry` per loop.
//! 4. One `Mailbox` per ordered pair of loops.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const layout = @import("layout.zig");
const mailbox_module = @import("mailbox.zig");
const operation_module = @import("operation.zig");

const Descriptor = operation_module.Descriptor;
const LoopId = operation_module.LoopId;
const Mailbox = mailbox_module.Mailbox;

/// The entry of a loop that has not started or has stopped.
pub const descriptor_none: Descriptor = -1;

/// The entry of a `Remote`: an id a thread claimed so its messages can name a sender, which runs no
/// loop and receives nothing (decision 4). It is distinct from `descriptor_none` so that claiming an
/// id twice is caught, and negative so that every `post` to it is already answered `loop_not_found`
/// by the check each backend makes on a target's descriptor.
pub const descriptor_remote: Descriptor = -2;

/// The fewest loops a registry serves: one loop alone has nobody to post to.
const loops_min: u16 = 2;

/// The first bytes of a registry, which `attach` checks.
const header_magic: u64 = 0x726f_746f_725f_7267;

/// The layout of the memory after the header. A change to `Header`, `Wake`, `Entry` or `Mailbox`
/// changes it, so that a process built from an older rotor refuses a registry a newer one made.
const header_version: u32 = 1;

/// What a registry's memory starts with. The process that creates the registry writes it once,
/// before any other process attaches, and nobody writes it after. 128 bytes aligned to 128.
const Header = extern struct {
    magic: u64 align(constants.mailbox_index_alignment),
    version: u32,
    loop_count: u16,
    /// 1 when `init_group` made the registry, 0 when `init` did.
    group: u8,
};

/// The wake the creator of a group made for one loop (decision 21, point 3). Every process of the
/// group inherited both descriptors at these numbers. 8 bytes aligned to 4.
pub const Wake = extern struct {
    /// What a sender writes one byte or one count to: a pipe's write end on kqueue, an eventfd on
    /// Linux.
    send: Descriptor,
    /// What the loop waits on: the pipe's read end on kqueue, the same eventfd on Linux.
    watch: Descriptor,

    pub const none: Wake = .{ .send = descriptor_none, .watch = descriptor_none };
};

/// What the registry holds for one loop. 128 bytes aligned to 128: a loop stores its `sleeping`
/// flag around every blocking tick, and that store never dirties the line of another loop's
/// entry.
const Entry = extern struct {
    /// The descriptor that wakes the loop, or a negative value: its kqueue on kqueue, its eventfd
    /// on epoll, its ring on io_uring, and its `Wake.send` in a group. Written by the loop, at init
    /// and at deinit. Read by the loops that post to it.
    queue: std.atomic.Value(Descriptor) align(constants.mailbox_index_alignment),
    /// True from `begin_sleep` to `end_sleep`. Written by the loop. Read by the loops that post
    /// to it.
    sleeping: std.atomic.Value(bool),
};

comptime {
    assert(@sizeOf(Header) == constants.mailbox_index_alignment);
    assert(@alignOf(Header) == @alignOf(Mailbox));
    assert(@sizeOf(Wake) == 8);
    assert(@alignOf(Wake) == @alignOf(Descriptor));
    assert(@sizeOf(Entry) == constants.mailbox_index_alignment);
    assert(@alignOf(Entry) == @alignOf(Mailbox));
}

/// Why `attach` refused the memory it was handed. Another program wrote it, so these are errors and
/// not assertions.
pub const AttachError = error{
    /// The memory does not start with a registry's header, or the header's loop count is outside
    /// what a registry holds.
    NotARegistry,
    /// The header names a layout this build of rotor does not lay out.
    VersionMismatch,
    /// The memory is shorter than the registry its header describes.
    MemoryTooShort,
    /// `init` made the registry, for one process: it has no wakes another process can use.
    NotAGroup,
};

/// The bytes of the wake table for `count` loops, in whole lines so the entries after it stay
/// aligned.
fn wakes_bytes(count: usize) usize {
    return std.mem.alignForward(usize, count * @sizeOf(Wake), @alignOf(Mailbox));
}

/// The loops that post to each other: their mailboxes, their wakes, the descriptors that wake them,
/// and whether each sleeps. The application owns the memory and hands this value to every loop at
/// init. The slices never change after `init` or `attach`, so every thread may read them. Three
/// slices and a flag: 56 bytes aligned to 8 on a 64-bit target.
pub const Registry = struct {
    /// One per loop, by id.
    entries: []Entry,
    /// One per ordered pair of loops: the ring `sender` writes and `receiver` reads is at
    /// `receiver * loops + sender`, so the rings one loop drains at every tick are adjacent. The
    /// ring from a loop to itself is there and unused, which keeps the index one multiply and
    /// one add.
    mailboxes: []Mailbox,
    /// One per loop, by id. Every wake is `Wake.none` unless `group` is set.
    wakes: []Wake,
    /// True when `init_group` made the registry, and its loops may run in several processes.
    group: bool,

    /// The bytes a registry of `loop_count` loops needs: a function of the loops the application
    /// runs, never of `constants.loops_max` (decision 12, point 6).
    pub fn memory_bytes(loop_count: u16) usize {
        assert(loop_count >= loops_min);
        assert(loop_count <= constants.loops_max);
        const count: usize = loop_count;
        const tables_bytes = @sizeOf(Header) + wakes_bytes(count) + count * @sizeOf(Entry) +
            count * count * @sizeOf(Mailbox);
        return mailbox_module.alignment_slack_bytes + tables_bytes;
    }

    /// A registry for loops of one process. `loop_count` is in [2, constants.loops_max] and
    /// `memory.len` is at least `memory_bytes(loop_count)`. Afterwards every mailbox is empty,
    /// every descriptor is absent, no loop sleeps, and there are no wakes.
    ///
    /// `memory` is aligned to `layout.memory_alignment`, 64, and a `Mailbox` and an `Entry` need
    /// 128. So `memory_bytes` asks for `alignment_slack_bytes` more than the tables take, and `init`
    /// skips to the first address aligned to 128, which is at most that far in.
    pub fn init(
        registry: *Registry,
        memory: []align(layout.memory_alignment) u8,
        loop_count: u16,
    ) void {
        write_header(memory, loop_count, false);
        registry.* = carve(memory, loop_count);
        for (registry.wakes) |*stored| stored.* = Wake.none;
        registry.empty();
    }

    /// A registry whose loops may run in several processes (decision 21). `wakes` holds one wake
    /// per loop, which the backend created and every process of the group will inherit. `memory`
    /// is aligned to 128, so every process finds the header at its first byte whatever address its
    /// mapping has: a mapping is page-aligned.
    pub fn init_group(
        registry: *Registry,
        memory: []align(layout.memory_alignment) u8,
        loop_count: u16,
        wakes: []const Wake,
    ) void {
        assert(@intFromPtr(memory.ptr) % @alignOf(Mailbox) == 0);
        assert(wakes.len == loop_count);
        write_header(memory, loop_count, true);
        registry.* = carve(memory, loop_count);
        for (registry.wakes, 0..) |*stored, id| {
            assert(wakes[id].send >= 0 and wakes[id].watch >= 0);
            stored.* = wakes[id];
        }
        registry.empty();
    }

    /// Builds this process's value over a registry another process of the group made with
    /// `init_group`. `memory` is the same bytes, aligned to 128 as `init_group` requires. It writes
    /// nothing: the rings, the entries and the sleep flags are as the other processes left them.
    pub fn attach(
        registry: *Registry,
        memory: []align(layout.memory_alignment) u8,
    ) AttachError!void {
        assert(@intFromPtr(memory.ptr) % @alignOf(Mailbox) == 0);
        if (memory.len < @sizeOf(Header)) return error.MemoryTooShort;
        const header = header_at(memory);
        if (header.magic != header_magic) return error.NotARegistry;
        if (header.version != header_version) return error.VersionMismatch;
        const loop_count = header.loop_count;
        if (loop_count < loops_min or loop_count > constants.loops_max) return error.NotARegistry;
        if (memory.len < memory_bytes(loop_count)) return error.MemoryTooShort;
        if (header.group != 1) return error.NotAGroup;
        registry.* = carve(memory, loop_count);
        assert(registry.group);
    }

    /// Splits `memory` into the tables of `loop_count` loops. It reads the header's group flag and
    /// writes nothing.
    fn carve(memory: []align(layout.memory_alignment) u8, loop_count: u16) Registry {
        assert(memory.len >= memory_bytes(loop_count));
        const count: usize = loop_count;
        const header = header_at(memory);
        const skipped = @intFromPtr(header) - @intFromPtr(memory.ptr);
        const wakes_start = skipped + @sizeOf(Header);
        const entries_start = wakes_start + wakes_bytes(count);
        const mailboxes_start = entries_start + count * @sizeOf(Entry);
        assert(mailboxes_start + count * count * @sizeOf(Mailbox) <= memory.len);
        const wakes: [*]Wake = @ptrCast(@alignCast(memory.ptr + wakes_start));
        const entries: [*]Entry = @ptrCast(@alignCast(memory.ptr + entries_start));
        const mailboxes: [*]Mailbox = @ptrCast(@alignCast(memory.ptr + mailboxes_start));
        assert(@intFromPtr(mailboxes) % @alignOf(Mailbox) == 0);
        return .{
            .entries = entries[0..count],
            .mailboxes = mailboxes[0 .. count * count],
            .wakes = wakes[0..count],
            .group = header.group == 1,
        };
    }

    /// The header, at the first address of `memory` aligned to 128.
    fn header_at(memory: []align(layout.memory_alignment) u8) *Header {
        const base = @intFromPtr(memory.ptr);
        const skipped = std.mem.alignForward(usize, base, @alignOf(Mailbox)) - base;
        assert(skipped <= mailbox_module.alignment_slack_bytes);
        assert(skipped + @sizeOf(Header) <= memory.len);
        return @ptrCast(@alignCast(memory.ptr + skipped));
    }

    fn write_header(memory: []align(layout.memory_alignment) u8, loop_count: u16, group: bool) void {
        assert(memory.len >= memory_bytes(loop_count));
        header_at(memory).* = .{
            .magic = header_magic,
            .version = header_version,
            .loop_count = loop_count,
            .group = @intFromBool(group),
        };
    }

    fn empty(registry: *Registry) void {
        for (registry.entries) |*entry| {
            entry.* = .{ .queue = .init(descriptor_none), .sleeping = .init(false) };
        }
        for (registry.mailboxes) |*ring| ring.init();
        assert(registry.entries.len >= loops_min);
    }

    /// How many loops the registry was sized for.
    pub fn loops(registry: *const Registry) u16 {
        assert(registry.entries.len >= loops_min);
        assert(registry.entries.len <= constants.loops_max);
        return @intCast(registry.entries.len);
    }

    /// The wake the creator of a group made for loop `id`, or null in a registry of one process.
    pub fn wake(registry: *const Registry, id: LoopId) ?Wake {
        assert(id < registry.entries.len);
        if (!registry.group) return null;
        const found = registry.wakes[id];
        assert(found.send >= 0 and found.watch >= 0);
        return found;
    }

    /// A loop publishes the descriptor that wakes it at init. The id must be free: two loops with
    /// one id is a programmer error. `.acq_rel`: the claim carries the previous holder's ring
    /// stores to this loop, which is about to read those rings (`mailbox.zig` says why).
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

    /// Withdraws loop `id` on behalf of a process of the group that died while it ran it (decision
    /// 21, point 5). Posts to it are then answered `loop_not_found`, and a loop of a new process
    /// may claim the id and take its rings over as they are. Only for a process known to be dead: a
    /// process that is only stopped would come back to find a second producer on its rings.
    pub fn release(registry: *Registry, id: LoopId) void {
        assert(registry.group);
        registry.clear(id);
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
const Message = operation_module.Message;

const pair_loops = 5;
const pair_bytes = Registry.memory_bytes(pair_loops);

/// A distinct message for the ring from `sender` to `receiver`.
fn pair_message(sender: usize, receiver: usize) Message {
    return .{ .payload = sender * constants.loops_max + receiver, .tag = @intCast(sender) };
}

/// The first made-up descriptor `made_up_wakes` hands out. Nothing here calls the kernel with it.
const made_up_descriptor_first: usize = 100;

/// Wakes a test hands `init_group`: two made-up descriptors per loop, all distinct.
fn made_up_wakes() [pair_loops]Wake {
    var wakes: [pair_loops]Wake = undefined;
    var next: usize = made_up_descriptor_first;
    for (&wakes) |*made| {
        made.* = .{ .send = @intCast(next), .watch = @intCast(next + 1) };
        next += @sizeOf(Wake) / @sizeOf(Descriptor);
    }
    return wakes;
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
    const before_rings = @sizeOf(Header) + wakes_bytes(pair_loops) + pair_loops * @sizeOf(Entry);
    for (bases) |memory| {
        var registry: Registry = undefined;
        registry.init(memory, pair_loops);
        const first = @intFromPtr(registry.mailbox(0, 0));
        const end = @intFromPtr(memory.ptr) + memory.len;
        try testing.expect(first >= @intFromPtr(memory.ptr) + before_rings);
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

test "a registry for one process has no wakes, and one for a group has the creator's" {
    var memory: [pair_bytes]u8 align(@alignOf(Mailbox)) = undefined;
    var registry: Registry = undefined;
    registry.init(&memory, pair_loops);
    try testing.expect(!registry.group);
    for (0..pair_loops) |id| try testing.expectEqual(@as(?Wake, null), registry.wake(@intCast(id)));

    const wakes = made_up_wakes();
    registry.init_group(&memory, pair_loops, &wakes);
    try testing.expect(registry.group);
    for (wakes, 0..) |made, id| try testing.expectEqual(made, registry.wake(@intCast(id)).?);
    for (0..pair_loops) |id| try testing.expectEqual(descriptor_none, registry.get(@intCast(id)));
}

test "a process that attaches sees the rings, the entries and the wakes the creator made" {
    var memory: [pair_bytes]u8 align(@alignOf(Mailbox)) = undefined;
    var creator: Registry = undefined;
    const wakes = made_up_wakes();
    creator.init_group(&memory, pair_loops, &wakes);
    creator.set(1, wakes[1].send);
    try testing.expect(creator.mailbox(1, 3).push(pair_message(1, 3)));

    var member: Registry = undefined;
    try member.attach(&memory);
    try testing.expect(member.group);
    try testing.expectEqual(@as(u16, pair_loops), member.loops());
    try testing.expectEqual(wakes[4], member.wake(4).?);
    try testing.expectEqual(wakes[1].send, member.get(1));
    var out: [2]Message = undefined;
    try testing.expectEqual(@as(u32, 1), member.mailbox(1, 3).pop_into(&out));
    try testing.expectEqual(pair_message(1, 3).payload, out[0].payload);

    // A survivor releases the loop of a process that died, and the id is free to claim again.
    member.release(1);
    try testing.expectEqual(descriptor_none, creator.get(1));
    creator.set(1, wakes[1].send);
}

test "attach refuses memory that holds no group registry this build laid out" {
    var memory: [pair_bytes]u8 align(@alignOf(Mailbox)) = @splat(0);
    var registry: Registry = undefined;
    try testing.expectError(error.NotARegistry, registry.attach(&memory));

    const wakes = made_up_wakes();
    registry.init_group(&memory, pair_loops, &wakes);
    try testing.expectError(error.MemoryTooShort, registry.attach(memory[0 .. pair_bytes - 1]));
    try testing.expectError(error.MemoryTooShort, registry.attach(memory[0..0]));

    const header = Registry.header_at(&memory);
    header.version = header_version + 1;
    try testing.expectError(error.VersionMismatch, registry.attach(&memory));
    header.version = header_version;
    header.loop_count = constants.loops_max + 1;
    try testing.expectError(error.NotARegistry, registry.attach(&memory));
    header.loop_count = 1;
    try testing.expectError(error.NotARegistry, registry.attach(&memory));

    registry.init(&memory, pair_loops);
    try testing.expectError(error.NotAGroup, registry.attach(&memory));
}
