//! `Remote`: how a thread that owns no loop posts to one on io_uring (decision 4, "What another
//! thread may do").
//!
//! A post goes through the mailbox ring the remote has to the target, `core.remote.send`, as it
//! does on kqueue and epoll: Camilo ruled on 2026-09-25 that loops talk through shared memory on
//! io_uring too (decision 4). The remote carries a small ring of its own for one job. To wake a
//! target that sleeps, it submits an `IORING_OP_MSG_RING` that carries no message
//! (`uring_submit.prepare_wake`), and a thread with no loop has no other ring to submit it on. The
//! ring is `constants.remote_entries` deep, which is one.
//!
//! A post is finished once `send` has put the message in the ring. The wake is submitted and not
//! waited for; its answer comes back on this ring and is read and dropped before the next wake is
//! submitted. A wake the kernel refuses is dropped too, as kqueue and epoll drop theirs: the
//! message is already in the ring, and the target reads it the next time it ticks, at the latest
//! when its wait ends. So `Unanswered`, `SystemResources` and `Unexpected` no longer come from this
//! backend. `PostError` keeps them, by Camilo's ruling of the same day, so the surface does not
//! change.
//!
//! `dropped_wakes` counts the wakes dropped (decision 4, third amendment of 2026-11-06). A wake is
//! dropped when its answer is below 0, or when the ring has no free entry for it. It is also
//! dropped when it still waits in the submission ring at `deinit`.
//!
//! One thread owns a `Remote`. `init` records the thread, and `post` and `deinit` halt on any
//! other, as a loop does. The ring is also created with `SINGLE_ISSUER`, so the kernel would
//! refuse the submission anyway.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const ring_module = @import("uring_ring.zig");
const submit_module = @import("uring_submit.zig");
const group = @import("linux_shared").group;

const Registry = core.mailbox.Registry;
const Ring = ring_module.Ring;

pub const InitError = core.remote.InitError;
pub const PostError = core.remote.PostError;

pub const Remote = struct {
    registry: *Registry,
    /// The identity of the thread that called `init`, from `core.tables.thread_identity`.
    owner: usize,
    /// This remote's id among the ids of `registry`. It names no ring of its own to the others: a
    /// remote receives nothing.
    id: core.LoopId,
    /// The ring the remote wakes sleeping targets through.
    ring: Ring,
    /// The wakes dropped since `init`, which `dropped_wakes` reads. Only the owner thread writes
    /// it.
    dropped_wake_count: u64,

    /// Claims `id` for the calling thread and creates the ring the thread wakes targets through.
    /// Must run on the thread that will post: the ring is single-issuer.
    ///
    /// `id` must be below the count the registry was sized for, and free. Claiming one twice, or one
    /// a loop already holds, halts.
    pub fn init(remote: *Remote, registry: *Registry, id: core.LoopId) InitError!void {
        assert(id < registry.loops());
        const ring = try Ring.init(constants.remote_entries);
        remote.* = .{
            .registry = registry,
            .owner = core.tables.thread_identity(),
            .id = id,
            .ring = ring,
            .dropped_wake_count = 0,
        };
        registry.set_remote(id);
        assert(registry.get(id) == core.mailbox.descriptor_remote);
    }

    /// Gives the id back and closes the ring. A wake that an earlier enter left in the submission
    /// ring is sent first. A wake still in the kernel is answered before the ring closes (recalled:
    /// `io_ring_exit_work` in io_uring/io_uring.c waits for every request of the ring).
    pub fn deinit(remote: *Remote) void {
        remote.deinit_through(submit_module.KernelEnter{});
    }

    /// `deinit`, with its enter made through `enters.enter(&remote.ring)`. A test hands it an
    /// answer the kernel gives only under load, as `Loop.deinit_through` takes one.
    fn deinit_through(remote: *Remote, enters: anytype) void {
        remote.assert_owner();
        remote.drop_answers();
        if (remote.ring.sq_ready() != 0) {
            _ = enters.enter(&remote.ring) catch {};
            remote.drop_answers();
        }
        // Every entry of this ring is a wake. An answer the kernel posts after the last enter is
        // not read, so a refusal in it is not counted.
        remote.dropped_wake_count += remote.ring.sq_ready();
        remote.registry.clear(remote.id);
        remote.ring.deinit();
    }

    /// Sends one message to the loop `target` runs, or says why it could not, and wakes the target
    /// when it said it sleeps.
    pub fn post(remote: *Remote, target: core.LoopId, message: core.Message) PostError!void {
        remote.assert_owner();
        assert(target != remote.id);
        assert(message.tag <= core.constants.message_tag_wake);
        const wake = try core.remote.send(remote.registry, remote.id, target, message);
        const descriptor = wake orelse return;
        // In a group the target published its eventfd, and not its ring (decision 21, point 3).
        if (remote.registry.group) {
            if (!group.wake_sent(descriptor)) remote.dropped_wake_count += 1;
        } else {
            remote.send_wake(descriptor, submit_module.KernelEnter{});
        }
    }

    /// The wakes dropped since `init`. Read it on the owner thread, or after that thread ended. It
    /// stays readable after `deinit`, until the next `init`. Each message is in its target's ring,
    /// and the target reads it when its wait ends (decision 4, third amendment of 2026-11-06).
    pub fn dropped_wakes(remote: *const Remote) u64 {
        return remote.dropped_wake_count;
    }

    /// Submits a wake to the loop that owns `target_ring`, and waits for nothing. The answers to
    /// earlier wakes are dropped first, so the completion ring never fills. A wake an earlier
    /// failed enter left in the submission ring goes first, in an enter of its own. Each enter is
    /// `enters.enter(&remote.ring)`, as in `deinit_through`.
    fn send_wake(remote: *Remote, target_ring: core.Descriptor, enters: anytype) void {
        assert(target_ring >= 0);
        remote.drop_answers();
        if (remote.ring.sqe_space() == 0) _ = enters.enter(&remote.ring) catch {};
        const sqe = remote.ring.get_sqe() orelse {
            remote.dropped_wake_count += 1;
            return;
        };
        submit_module.prepare_wake(sqe, target_ring);
        _ = enters.enter(&remote.ring) catch {};
    }

    /// Reads the answers to earlier wakes and drops them. Each answer below 0 is a wake the kernel
    /// refused, for example to a descriptor that is no ring, and counts as dropped.
    fn drop_answers(remote: *Remote) void {
        const ready = remote.ring.cq_ready();
        assert(ready <= remote.ring.io.cq.cqes.len);
        var offset: u32 = 0;
        while (offset < ready) : (offset += 1) {
            if (remote.ring.cqe_at(offset).res < 0) remote.dropped_wake_count += 1;
        }
        remote.ring.cq_advance(ready);
    }

    /// Halts when another thread calls into the remote: a programmer error, which the kernel
    /// would otherwise report as an `io_uring_enter` refused.
    fn assert_owner(remote: *const Remote) void {
        assert(remote.owner == core.tables.thread_identity());
    }
};

const testing = std.testing;

test "a remote claims an id with the sentinel, and gives it back" {
    if (!@import("uring.zig").supported) return error.SkipZigTest;
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(3)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 3);

    var remote: Remote = undefined;
    try remote.init(&registry, 2);
    try testing.expectEqual(core.tables.thread_identity(), remote.owner);
    try testing.expectEqual(core.mailbox.descriptor_remote, registry.get(2));
    remote.deinit();
    try testing.expectEqual(core.mailbox.descriptor_none, registry.get(2));
}

test "a post to an id that runs no loop, or to another remote, is refused" {
    if (!@import("uring.zig").supported) return error.SkipZigTest;
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(3)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 3);

    var first: Remote = undefined;
    var second: Remote = undefined;
    try first.init(&registry, 1);
    defer first.deinit();
    try second.init(&registry, 2);
    defer second.deinit();

    const message: core.Message = .{ .payload = 7, .tag = 1 };
    try testing.expectError(error.LoopNotFound, first.post(0, message));
    // An id above the count the registry was sized for, and the largest id there is: both are
    // refused before the registry is asked, which would halt on the second.
    try testing.expectError(error.LoopNotFound, first.post(3, message));
    try testing.expectError(error.LoopNotFound, first.post(core.constants.loops_max, message));
    try testing.expectError(error.LoopNotFound, first.post(2, message));
    try testing.expectError(error.LoopNotFound, second.post(1, message));
}

test "a post lands in the mailbox, and a target that sleeps gets one wake on its ring" {
    if (!@import("uring.zig").supported) return error.SkipZigTest;
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 2);
    // A ring stands in for loop 0, so the wake has somewhere real to land.
    var target = try Ring.init(4);
    defer target.deinit();
    registry.set(0, target.descriptor());
    defer registry.clear(0);
    var remote: Remote = undefined;
    try remote.init(&registry, 1);
    defer remote.deinit();

    // Awake: the message is in the mailbox, and nothing reaches the target's ring.
    try remote.post(0, .{ .payload = 7, .tag = 1 });
    _ = try target.enter(null);
    try testing.expectEqual(@as(u32, 0), target.cq_ready());

    // Asleep: the next post wakes it, with a completion that names no operation.
    registry.begin_sleep(0);
    try remote.post(0, .{ .payload = 8, .tag = 1 });
    _ = try target.enter(null);
    try testing.expectEqual(@as(u32, 1), target.cq_ready());
    try testing.expectEqual(constants.user_data_wake, target.cqe_at(0).user_data);
    target.cq_advance(1);
    registry.end_sleep(0);

    // Both messages wait in the mailbox, in order.
    var received: [2]core.Message = undefined;
    try testing.expectEqual(@as(u32, 2), registry.mailbox(1, 0).pop_into(&received));
    try testing.expectEqual(@as(u64, 7), received[0].payload);
    try testing.expectEqual(@as(u64, 8), received[1].payload);
}

/// Answers `overcommitted` to every enter and enters nothing. The kernel answers so while its
/// completion ring overflows, and the entries stay in the submission ring.
const Overcommitted = struct {
    pub fn enter(_: Overcommitted, ring: *Ring) ring_module.EnterError!ring_module.Entered {
        _ = ring;
        return .overcommitted;
    }
};

/// The completions on `target` that wake a loop, which this call consumes.
fn wakes_received(target: *Ring) !u32 {
    _ = try target.enter(null);
    const ready = target.cq_ready();
    var received: u32 = 0;
    for (0..ready) |offset| {
        if (target.cqe_at(@intCast(offset)).user_data == constants.user_data_wake) received += 1;
    }
    target.cq_advance(ready);
    return received;
}

test "a wake with no free entry is dropped, and deinit drops one the kernel never takes" {
    if (!@import("uring.zig").supported) return error.SkipZigTest;
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 2);
    var target = try Ring.init(4);
    defer target.deinit();
    var remote: Remote = undefined;
    try remote.init(&registry, 1);
    try testing.expectEqual(@as(u64, 0), remote.dropped_wakes());

    // The first wake takes the one entry, and the enter takes nothing. The second finds no entry.
    remote.send_wake(target.descriptor(), Overcommitted{});
    try testing.expectEqual(@as(u64, 0), remote.dropped_wakes());
    remote.send_wake(target.descriptor(), Overcommitted{});
    try testing.expectEqual(@as(u64, 1), remote.dropped_wakes());

    // `deinit` enters once more for the wake that waits, and the kernel takes nothing again.
    remote.deinit_through(Overcommitted{});
    try testing.expectEqual(@as(u64, 2), remote.dropped_wakes());
    try testing.expectEqual(@as(u32, 0), try wakes_received(&target));
}

test "deinit sends a wake an overcommitted enter left, and counts no drop" {
    if (!@import("uring.zig").supported) return error.SkipZigTest;
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 2);
    var target = try Ring.init(4);
    defer target.deinit();
    var remote: Remote = undefined;
    try remote.init(&registry, 1);

    remote.send_wake(target.descriptor(), Overcommitted{});
    try testing.expectEqual(@as(u32, 1), remote.ring.sq_ready());
    remote.deinit();
    try testing.expectEqual(@as(u64, 0), remote.dropped_wakes());
    try testing.expectEqual(@as(u32, 1), try wakes_received(&target));
}

test "a wake the kernel answers with an error is counted when its answer is read" {
    if (!@import("uring.zig").supported) return error.SkipZigTest;
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 2);
    // Loop 0 publishes the read end of a pipe. It is no ring, so the kernel answers each wake to it
    // with EBADFD.
    var ends: [2]i32 = undefined;
    try testing.expectEqual(@as(usize, 0), linux.pipe2(&ends, .{ .CLOEXEC = true }));
    defer for (ends) |end| {
        _ = linux.close(end);
    };
    registry.set(0, ends[0]);
    defer registry.clear(0);
    var remote: Remote = undefined;
    try remote.init(&registry, 1);

    registry.begin_sleep(0);
    try remote.post(0, .{ .payload = 1, .tag = 0 });
    // The answer is read before the next wake is submitted.
    try testing.expectEqual(@as(u64, 0), remote.dropped_wakes());
    try remote.post(0, .{ .payload = 2, .tag = 0 });
    try testing.expectEqual(@as(u64, 1), remote.dropped_wakes());
    registry.end_sleep(0);
    // `deinit` reads the last answer.
    remote.deinit();
    try testing.expectEqual(@as(u64, 2), remote.dropped_wakes());
}

test "in a group, a wake the kernel refuses is counted" {
    if (!@import("uring.zig").supported) return error.SkipZigTest;
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(2)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 2);
    var ends: [2]i32 = undefined;
    try testing.expectEqual(@as(usize, 0), linux.pipe2(&ends, .{ .CLOEXEC = true }));
    defer for (ends) |end| {
        _ = linux.close(end);
    };
    registry.set(0, ends[0]);
    defer registry.clear(0);
    var remote: Remote = undefined;
    try remote.init(&registry, 1);
    defer remote.deinit();

    // In a group the wake is a write to an eventfd, and the kernel refuses one to a pipe's read end.
    registry.group = true;
    defer registry.group = false;
    registry.begin_sleep(0);
    defer registry.end_sleep(0);
    try remote.post(0, .{ .payload = 1, .tag = 0 });
    try testing.expectEqual(@as(u64, 1), remote.dropped_wakes());
}
