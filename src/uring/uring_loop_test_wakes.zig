//! The wakes `Loop.deinit` drops, against the real kernel (decision 4, amended 2026-11-06). Split
//! from `uring_loop_test.zig` for the 500-line limit. The kernel answers EBUSY only while its
//! completion ring overflows, so these tests hand `deinit` that answer through `deinit_through`,
//! as `core.file_call.result` takes its system call as a parameter. Every test here makes a ring,
//! so each runs under Linux alone: `tools/linux_test.sh` runs them in Docker.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const linux = std.os.linux;
const core = @import("core");
const uring = @import("uring.zig");

const Loop = uring.Loop;
const Ring = uring.ring_module.Ring;

const operations = 4;
const memory_alignment = core.layout.memory_alignment;
const memory_bytes = Loop.memory_bytes(.{ .operations = operations, .entries = 2 });

/// The loops of the registry: the sender, loop 0, and three targets.
const loops = 4;

/// The submission entries of each target's ring. A target receives one wake at most.
const target_entries = 4;

/// Answers `overcommitted` to every enter and enters nothing. The kernel answers so while its
/// completion ring overflows, and the entries stay in the submission ring.
const Overcommitted = struct {
    pub fn enter(
        _: Overcommitted,
        ring: *Ring,
    ) uring.ring_module.EnterError!uring.ring_module.Entered {
        _ = ring;
        return .overcommitted;
    }
};

/// A registry whose loops 1 to 3 are rings that stand in for loops. Each says it sleeps, so a post
/// to one notes a wake.
const Targets = struct {
    registry: uring.Registry,
    registry_memory: [uring.Registry.memory_bytes(loops)]u8 align(memory_alignment),
    rings: [loops - 1]Ring,

    fn init(targets: *Targets) !void {
        targets.registry.init(&targets.registry_memory, loops);
        for (&targets.rings, 1..) |*ring, id| {
            ring.* = try Ring.init(target_entries);
            targets.registry.set(@intCast(id), ring.descriptor());
            targets.registry.begin_sleep(@intCast(id));
        }
    }

    fn deinit(targets: *Targets) void {
        for (&targets.rings, 1..) |*ring, id| {
            targets.registry.end_sleep(@intCast(id));
            targets.registry.clear(@intCast(id));
            ring.deinit();
        }
        // The sender's loop ended before this call, and the registry kept its wake.
        uring.wake_module.close_kept(&targets.registry);
    }

    /// The wakes the ring of loop `id` received, which this call consumes.
    fn wakes(targets: *Targets, id: core.LoopId) !u32 {
        const ring = &targets.rings[id - 1];
        _ = try ring.enter(null);
        const ready = ring.cq_ready();
        var received: u32 = 0;
        for (0..ready) |offset| {
            if (ring.cqe_at(@intCast(offset)).user_data == uring.constants.user_data_wake) {
                received += 1;
            }
        }
        ring.cq_advance(ready);
        return received;
    }
};

const Sender = struct {
    memory: [memory_bytes]u8 align(memory_alignment),
    loop: Loop,

    /// A loop with id 0 in `registry`, whose submission ring holds `entries`.
    fn init(sender: *Sender, registry: *uring.Registry, entries: u16) !void {
        try sender.loop.init(&sender.memory, .{
            .operations = operations,
            .entries = entries,
            .id = 0,
            .registry = registry,
        });
    }
};

test "deinit drops the wakes the kernel takes no entry for, and counts each one" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var targets: Targets = undefined;
    try targets.init();
    defer targets.deinit();
    var sender: Sender = undefined;
    try sender.init(&targets.registry, 1);
    for (1..loops) |id| try sender.loop.post(@intCast(id), .{ .payload = id, .tag = 1 });

    // Each pass puts one wake in the submission ring, which holds one entry, and the kernel takes
    // none. One wake waits in that ring when `deinit` frees it, and two are still noted.
    sender.loop.deinit_through(Overcommitted{});
    try testing.expectEqual(@as(u32, loops - 1), sender.loop.dropped_wakes());
    for (1..loops) |id| try testing.expectEqual(@as(u32, 0), try targets.wakes(@intCast(id)));
}

test "deinit sends a wake an overcommitted enter left, and counts no entry that is no wake" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var targets: Targets = undefined;
    try targets.init();
    defer targets.deinit();
    var sender: Sender = undefined;
    try sender.init(&targets.registry, 2);
    try testing.expectEqual(@as(u32, 0), sender.loop.dropped_wakes());

    // An entry that is no wake waits first, as a tick's wait timer does after an overcommitted
    // enter. The reap of `deinit` drops its completion.
    const other = sender.loop.ring.get_sqe().?;
    other.* = std.mem.zeroes(linux.io_uring_sqe);
    uring.ring_module.set_opcode(other, .NOP);
    other.user_data = uring.constants.user_data_cancel;
    try sender.loop.post(1, .{ .payload = 1, .tag = 1 });

    // The pass moves the wake from the note to the submission ring, and the enter takes nothing.
    const dropped = uring.submit_module.send_noted_wakes(&sender.loop, Overcommitted{});
    try testing.expectEqual(@as(u32, 1), dropped);
    try testing.expectEqual(@as(usize, 0), sender.loop.wakes.targets.count());
    try testing.expectEqual(@as(u32, 2), sender.loop.ring.sq_ready());

    // Nothing is noted now, and `deinit` still enters for what waits in the submission ring.
    sender.loop.deinit();
    try testing.expectEqual(@as(u32, 0), sender.loop.dropped_wakes());
    try testing.expectEqual(@as(u32, 1), try targets.wakes(1));
}
