//! The loop's state and lifecycle under test: what `Loop.init_tables` carves out of the caller's
//! memory, what `submit` claims, and the sleep handshake with a registry. None of it enters the
//! kernel, so every test here runs on every host; what does enter it is the conformance suite's,
//! which runs against this backend in Docker under the default seccomp profile (decision 20).
//!
//! Split from `epoll.zig` for the 500-line limit, as `uring_loop_test.zig` is from `uring.zig`.
const std = @import("std");
const core = @import("core");
const constants = @import("constants.zig");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
const Registry = epoll.Registry;
const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Slot = core.Slot;
const TimerHeap = core.timer_heap.TimerHeap;
const Waiters = core.waiters.Waiters;

const testing = std.testing;

/// Operations the sizing tests ask a loop for. Small, because what they measure is the arithmetic.
const sized_operations = 8;

test "the loop's memory holds the slots, the timers, the starts and the waiters, and no more" {
    const options: Loop.Options = .{ .operations = sized_operations };
    const slots = sized_operations * @sizeOf(Slot);
    const timers = sized_operations * @sizeOf(TimerHeap.Entry);
    const starts = sized_operations * @sizeOf(u64);
    const waiting = Waiters.capacity_for(sized_operations) * @sizeOf(core.waiters.Entry);
    // Each part is carved to `memory_alignment`, so the total is at least their sum and the padding
    // is bounded by one alignment per part.
    const sum = slots + timers + starts + waiting;
    try testing.expect(Loop.memory_bytes(options) >= sum);
    try testing.expect(Loop.memory_bytes(options) <= sum + 4 * core.layout.memory_alignment);
    // No offload was asked for, so not one byte of `Work` is counted.
    const works = sized_operations * @sizeOf(core.offload.Work);
    try testing.expect(Loop.memory_bytes(options) < sum + works);
}

test "an offload's works are counted only when the policy asks for one" {
    const offload: core.offload.Offload = comptime .{
        .context = null,
        .submit = &submit_nothing,
        .workers = 2,
    };
    const without: Loop.Options = .{ .operations = sized_operations };
    const with: Loop.Options = .{
        .operations = sized_operations,
        .file_policy = .offload,
        .offload = offload,
    };
    const works = sized_operations * @sizeOf(core.offload.Work);
    try testing.expect(Loop.memory_bytes(with) >= Loop.memory_bytes(without) + works);
    // An offload named without the policy that uses it holds no rings, so it counts no works.
    const named: Loop.Options = .{ .operations = sized_operations, .offload = offload };
    try testing.expectEqual(Loop.memory_bytes(without), Loop.memory_bytes(named));
}

/// An offload that takes work and does nothing with it. The sizing tests never hand it any: they
/// name an offload so that `memory_bytes` counts one.
fn submit_nothing(context: ?*anyopaque, work: *core.offload.Work) void {
    _ = context;
    _ = work;
}

test "init_tables leaves an empty loop that owns this thread and holds no group" {
    const options: Loop.Options = .{ .operations = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);
    loop.assert_owner();
    loop.assert_empty();
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
    try testing.expectEqual(@as(usize, 0), loop.inbox.completions.len);
    try testing.expectEqual(@as(usize, 0), loop.works.len);
    try testing.expectEqual(@as(u16, 0), loop.tables.buffers_registered);
    try testing.expect(!loop.inbox.sleeping);
    try testing.expect(loop.inbox.registry == null);
    try testing.expect(loop.offload == null);
    try testing.expectEqual(core.offload.FilePolicy.refuse, loop.file_policy);
    for (&loop.groups) |*group| try testing.expectEqual(@as(u32, 0), group.buffer_bytes);
    // The readiness array is where `epoll_pwait2` writes. There is no changelist beside it, and
    // that absence is the difference from kqueue's loop, so it is checked and not just described.
    try testing.expectEqual(@as(usize, constants.readiness_max), loop.readiness.len);
    try testing.expect(!@hasField(Loop, "changes"));
    try testing.expect(!@hasField(Loop, "changes_used"));
}

test "submit claims a slot per operation until the table is full, and makes no system call" {
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);

    const timer: Operation = .{
        .user_data = 1,
        .kind = .{ .timer = .{ .after_ns = core.constants.ns_per_ms } },
    };
    var handles: [3]Handle = undefined;
    const operations = [_]Operation{ timer, timer, timer };
    // The table holds two, so the third is refused and the caller is told how many were taken.
    // Nothing entered a kernel: this loop has no epoll instance, because `init_tables` opens none.
    try testing.expectEqual(@as(u32, 2), loop.submit(&operations, &handles));
    try testing.expectEqual(@as(u32, 2), loop.in_flight());
    try testing.expectEqual(@as(u32, 0), loop.submit(&operations, &handles));
    try testing.expect(handles[0].generation >= core.constants.generation_first);
}

test "a loop with no registry drains no mailbox and sleeps for the wait it was given" {
    const options: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);

    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 0), loop.drain_mailboxes(&events));
    // No registry and no offload, so nothing can hold a message back: the wait passes through.
    const wait = core.constants.ns_per_ms;
    try testing.expectEqual(@as(?u64, wait), loop.settle_to_sleep(wait));
    try testing.expectEqual(@as(?u64, null), loop.settle_to_sleep(null));
    try testing.expect(!loop.inbox.sleeping);
    loop.wake_up();
    try testing.expect(!loop.inbox.sleeping);
}

test "a loop with a registry says it sleeps, and a message already posted keeps it awake" {
    const loops = 2;
    const receiver: core.LoopId = 1;
    const sender: core.LoopId = 0;
    var registry_memory: [Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) =
        undefined;
    var registry: Registry = undefined;
    registry.init(&registry_memory, loops);

    // The memory is sized from the one field `memory_bytes` reads, because the options below hold a
    // pointer to the registry, which no array length can be.
    const sizing: Loop.Options = .{ .operations = 2 };
    var memory: [Loop.memory_bytes(sizing)]u8 align(core.layout.memory_alignment) = undefined;
    const options: Loop.Options = .{ .operations = 2, .id = receiver, .registry = &registry };
    var loop: Loop = undefined;
    loop.init_tables(&memory, options);

    const wait = core.constants.ns_per_ms;
    try testing.expectEqual(@as(?u64, wait), loop.settle_to_sleep(wait));
    try testing.expect(loop.inbox.sleeping);
    try testing.expect(registry.must_wake(receiver));
    loop.wake_up();
    try testing.expect(!loop.inbox.sleeping);
    try testing.expect(!registry.must_wake(receiver));

    // A sender pushes before the loop settles, so the loop must not sleep on that message.
    const payload = 0x5ec0_1234;
    const tag = 7;
    const message: core.Message = .{ .tag = tag, .payload = payload };
    try testing.expect(registry.mailbox(sender, receiver).push(message));
    try testing.expectEqual(@as(?u64, null), loop.settle_to_sleep(wait));

    var events: [4]Event = undefined;
    try testing.expectEqual(@as(u32, 1), loop.drain_mailboxes(&events));
    try testing.expectEqual(@as(u64, payload), events[0].user_data);
    try testing.expectEqual(@as(i32, tag), events[0].result);
    try testing.expect(events[0].flags.message);
    loop.wake_up();
}

/// Bytes the scenario below writes at a time to fill a socket's buffers.
const fill_chunk_bytes = 4096;
/// Writes it makes before it gives up on filling them. A socket pair's buffers hold a few hundred
/// kilobytes on the kernels measured, so this many chunks is far beyond them.
const fill_writes_max = 4096;

/// A connected pair of stream sockets that do not block, as every socket the loop sees.
fn socket_pair() ![2]core.Descriptor {
    const linux = std.os.linux;
    var ends: [2]i32 = undefined;
    const flags = linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
    const paired = linux.socketpair(linux.AF.UNIX, flags, 0, &ends);
    if (linux.errno(paired) != .SUCCESS) return error.Unexpected;
    return ends;
}

/// Writes into `descriptor` until the kernel refuses with EAGAIN, so its send side is full.
fn fill(descriptor: core.Descriptor) !void {
    const linux = std.os.linux;
    const chunk: [fill_chunk_bytes]u8 = @splat('f');
    for (0..fill_writes_max) |_| {
        const rc = linux.write(descriptor, &chunk, chunk.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            else => return error.Unexpected,
        }
    }
    return error.NeverFull;
}

/// Reads from `descriptor` until the kernel answers EAGAIN, so its receive side is empty.
fn drain(descriptor: core.Descriptor) !void {
    const linux = std.os.linux;
    var chunk: [fill_chunk_bytes]u8 = undefined;
    for (0..fill_writes_max) |_| {
        const rc = linux.read(descriptor, &chunk, chunk.len);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) return error.Unexpected,
            .AGAIN => return,
            else => return error.Unexpected,
        }
    }
    return error.NeverEmpty;
}

test "one readiness for a reader and a writer hands over what fits, and the rest next tick" {
    // Enters the kernel: a socket pair and a real epoll instance, so it runs where epoll does.
    if (!epoll.supported) return error.SkipZigTest;
    const linux = std.os.linux;
    const options: Loop.Options = .{ .operations = 4 };
    var memory: [Loop.memory_bytes(options)]u8 align(core.layout.memory_alignment) = undefined;
    var loop: Loop = undefined;
    try loop.init(&memory, options);
    defer loop.deinit();

    const ends = try socket_pair();
    defer for (ends) |end| epoll.sync.close_now(end);

    // One end with its send side full and nothing to read: a send and a receive on it both wait.
    try fill(ends[0]);
    var received: [8]u8 = undefined;
    const waiting = [_]Operation{
        .{ .user_data = 1, .kind = .{ .receive = .{
            .socket = ends[0],
            .target = .{ .buffer = .{ .bytes = &received } },
        } } },
        .{ .user_data = 2, .kind = .{ .send = .{
            .socket = ends[0],
            .buffer = .{ .bytes = "s" },
        } } },
    };
    var handles: [2]Handle = undefined;
    try testing.expectEqual(@as(u32, 2), loop.submit(&waiting, &handles));
    var events: [1]Event = undefined;
    try testing.expectEqual(@as(u32, 0), try loop.tick(&events, 0));

    // The other end reads everything and writes a byte: the first end is readable and writable at
    // once, which epoll reports as one readiness with both bits set.
    try drain(ends[1]);
    try testing.expectEqual(@as(usize, 1), linux.write(ends[1], "r", 1));

    // Room for one event: the reader is served, and the writer is not dropped but left for the next
    // tick, which the level-triggered registration reports again.
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expectEqual(@as(u64, 1), events[0].user_data);
    try testing.expectEqual(@as(u32, 1), try events[0].outcome());
    try testing.expectEqual(@as(u32, 1), try loop.tick(&events, 0));
    try testing.expectEqual(@as(u64, 2), events[0].user_data);
    try testing.expectEqual(@as(u32, 1), try events[0].outcome());
    try testing.expectEqual(@as(u32, 0), loop.in_flight());
}
