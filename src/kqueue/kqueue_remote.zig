//! `Remote`: how a thread that owns no loop posts to one on kqueue (decision 4, "What another thread
//! may do").
//!
//! It is the producer end of a mailbox pair and nothing more. `core/mailbox.zig` holds the rings,
//! one per ordered pair of ids, and the `EVFILT_USER` wake; a loop posting to another loop uses
//! them through `kqueue_submit.post`. A `Remote` makes the same two steps from a thread that has no
//! loop to submit through: push into the ring this id owns toward the target, and wake the target
//! when it said it would sleep.
//!
//! It needs no memory and no descriptor of its own. The rings belong to the registry the
//! application sized, and a `Remote` claims one id of it. So a caller pays one `LoopId` and nothing
//! else, which is why decision 4 says a remote counts against `loops_max`.
//!
//! A post is finished when it returns. The push either fitted or it did not, and the answer is the
//! return value, `core.remote.PostError`. Nothing here is asynchronous, so nothing here needs a
//! completion. Of the five errors in that set, this backend answers two: `MailboxFull` and
//! `LoopNotFound`.
//!
//! One thread owns a `Remote`, as one thread owns a loop. Two threads posting through one remote
//! would put two producers on a single-producer ring, which `core/mailbox.zig`'s ordering
//! argument forbids. `init` records the thread, and `post` and `deinit` halt on any other, with the
//! compare `core/tables.zig` makes for a loop. A caller that wants two threads takes two remotes.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const core = @import("core");
const group_module = @import("kqueue_group.zig");
const queue_module = @import("kqueue_queue.zig");

const Registry = core.mailbox.Registry;

pub const InitError = core.remote.InitError;
pub const PostError = core.remote.PostError;

pub const Remote = struct {
    registry: *Registry,
    /// The identity of the thread that called `init`, from `core.tables.thread_identity`.
    owner: usize,
    /// This remote's id among the ids of `registry`, which names it as the sender of a message.
    id: core.LoopId,

    /// Claims `id` for the calling thread. It creates nothing: on this backend a remote is a
    /// producer of rings the registry already holds. It cannot fail here; the error set is the
    /// io_uring backend's, so the two surfaces match.
    ///
    /// `id` must be below the count the registry was sized for, and free. Claiming one twice, or one
    /// a loop already holds, halts: two senders on one id would share a ring that has room for one
    /// producer.
    pub fn init(remote: *Remote, registry: *Registry, id: core.LoopId) InitError!void {
        assert(id < registry.loops());
        remote.* = .{ .registry = registry, .owner = core.tables.thread_identity(), .id = id };
        registry.set_remote(id);
        assert(registry.get(id) == core.mailbox.descriptor_remote);
    }

    /// Gives the id back. A `post` naming it is answered `LoopNotFound` again. A loop or another
    /// remote may then claim it, once this thread is done with it: the application decides when
    /// that is, and the claim carries this thread's last stores to the claimant
    /// (`core/mailbox.zig`, the ordering argument).
    pub fn deinit(remote: *Remote) void {
        remote.assert_owner();
        remote.registry.clear(remote.id);
    }

    /// Sends one message to the loop `target` runs, or says why it could not. It is
    /// `core.remote.send`, as a loop's post is, with this remote's id as the sender. A target that
    /// names no running loop, including another remote, is `LoopNotFound`; a target whose ring
    /// from this sender is full is `MailboxFull`.
    pub fn post(remote: *Remote, target: core.LoopId, message: core.Message) PostError!void {
        remote.assert_owner();
        assert(target != remote.id);
        assert(message.tag <= core.constants.message_tag_max);
        const wake = try core.remote.send(remote.registry, remote.id, target, message);
        const descriptor = wake orelse return;
        // In a group the target's wake is a pipe its group's creator made (decision 21, point 3).
        if (remote.registry.group) group_module.send(descriptor) else queue_module.Queue.wake(descriptor);
    }

    /// Halts when another thread calls into the remote: a programmer error, and one that would put
    /// two producers on one ring.
    fn assert_owner(remote: *const Remote) void {
        assert(remote.owner == core.tables.thread_identity());
    }
};

const testing = std.testing;

test "a remote claims an id, gives it back, and is refused a post to itself" {
    var registry: Registry = undefined;
    const loops: u16 = 3;
    var memory: [Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, loops);

    var remote: Remote = undefined;
    try remote.init(&registry, 2);
    try testing.expectEqual(@as(core.LoopId, 2), remote.id);
    try testing.expectEqual(core.tables.thread_identity(), remote.owner);
    // The id is claimed with the sentinel, so it names no queue and a post to it finds no loop.
    try testing.expectEqual(core.mailbox.descriptor_remote, registry.get(2));

    remote.deinit();
    try testing.expectEqual(core.mailbox.descriptor_none, registry.get(2));
}

test "a post to an id that runs no loop is refused, and nothing is queued" {
    // `post` reaches `Queue.wake`, which is Darwin's `EVFILT_USER`, so this test is analysed on
    // Darwin alone: the race gate compiles this module for Linux and must not see it.
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var registry: Registry = undefined;
    const loops: u16 = 3;
    var memory: [Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, loops);

    var remote: Remote = undefined;
    try remote.init(&registry, 2);
    defer remote.deinit();

    const message: core.Message = .{ .payload = 7, .tag = 1 };
    // Loop 0 never started.
    try testing.expectError(error.LoopNotFound, remote.post(0, message));
    // An id above the count the registry was sized for, and the largest id there is: both are
    // refused before the registry is asked, which would halt on the second.
    try testing.expectError(error.LoopNotFound, remote.post(loops, message));
    try testing.expectError(error.LoopNotFound, remote.post(core.constants.loops_max, message));
    // Nothing reached a ring, so the loop that starts later is handed no message it never saw sent.
    try testing.expect(registry.mailbox(2, 0).is_empty());
}

test "a post to another remote is refused, because a remote receives nothing" {
    // `post` reaches `Queue.wake`, which is Darwin's `EVFILT_USER`, so this test is analysed on
    // Darwin alone: the race gate compiles this module for Linux and must not see it.
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var registry: Registry = undefined;
    const loops: u16 = 3;
    var memory: [Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, loops);

    var first: Remote = undefined;
    var second: Remote = undefined;
    try first.init(&registry, 1);
    defer first.deinit();
    try second.init(&registry, 2);
    defer second.deinit();

    // The sentinel is negative, so the target check already answers this and needs no special case.
    try testing.expectError(error.LoopNotFound, first.post(2, .{ .payload = 1, .tag = 0 }));
    try testing.expectError(error.LoopNotFound, second.post(1, .{ .payload = 1, .tag = 0 }));
}

test "a message reaches the ring the target drains, and a full ring is refused" {
    // `post` reaches `Queue.wake`, which is Darwin's `EVFILT_USER`, so this test is analysed on
    // Darwin alone: the race gate compiles this module for Linux and must not see it.
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var registry: Registry = undefined;
    const loops: u16 = 2;
    var memory: [Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, loops);

    // Loop 0 publishes a descriptor, so the remote finds a target. It is a number and not a kqueue:
    // this test never wakes it, because `must_wake` is false while the loop does not sleep.
    registry.set(0, 3);
    var remote: Remote = undefined;
    try remote.init(&registry, 1);
    defer remote.deinit();

    try remote.post(0, .{ .payload = 11, .tag = 2 });
    const ring = registry.mailbox(1, 0);
    try testing.expect(!ring.is_empty());

    var out: [1]core.Message = undefined;
    try testing.expectEqual(@as(u32, 1), ring.pop_into(&out));
    try testing.expectEqual(@as(u64, 11), out[0].payload);
    try testing.expectEqual(@as(u32, 2), out[0].tag);

    // Fill the ring, then one more: the message is refused and not dropped silently.
    var sent: u32 = 0;
    while (sent < core.constants.mailbox_messages) : (sent += 1) {
        try remote.post(0, .{ .payload = sent, .tag = 0 });
    }
    try testing.expectError(error.MailboxFull, remote.post(0, .{ .payload = 0, .tag = 0 }));
}
