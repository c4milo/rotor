//! `Remote`: how a thread that owns no loop posts to one on epoll (decision 4, "What another thread
//! may do").
//!
//! It is the producer end of a mailbox pair and nothing more. `core/mailbox.zig` holds the rings,
//! one per ordered pair of ids; a loop posting to another loop uses them through
//! `epoll_submit.post`. A `Remote` makes the same two steps from a thread that has no loop to
//! submit through: push into the ring this id owns toward the target, and wake the target when it
//! said it would sleep.
//!
//! This is `kqueue_remote.zig` with one difference, which is the wake: the registry holds each
//! epoll loop's eventfd rather than its epoll instance, because an epoll descriptor cannot be
//! written to, and one 8-byte write to the eventfd is the whole wake (decision 20).
//!
//! It needs no memory and no descriptor of its own. The rings belong to the registry the
//! application sized, and a `Remote` claims one id of it, which is why decision 4 says a remote
//! counts against `loops_max`.
//!
//! One thread owns a `Remote`, as one thread owns a loop. Two threads posting through one remote
//! would put two producers on a single-producer ring, which `core/mailbox.zig`'s ordering argument
//! forbids. `init` records the thread, and `post` and `deinit` halt on any other.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const core = @import("core");
const queue_module = @import("epoll_queue.zig");

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
    /// io_uring backend's, so the surfaces match.
    ///
    /// `id` must be below the count the registry was sized for, and free. Claiming one twice, or
    /// one a loop already holds, halts: two senders on one id would share a ring that has room for
    /// one producer.
    pub fn init(remote: *Remote, registry: *Registry, id: core.LoopId) InitError!void {
        assert(id < registry.loops());
        remote.* = .{ .registry = registry, .owner = core.tables.thread_identity(), .id = id };
        registry.set_remote(id);
        assert(registry.get(id) == core.mailbox.descriptor_remote);
    }

    /// Gives the id back. A `post` naming it is answered `LoopNotFound` again.
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
        if (wake) |descriptor| queue_module.Queue.wake(descriptor);
    }

    /// Halts when another thread calls into the remote: a programmer error, and one that would put
    /// two producers on one ring.
    fn assert_owner(remote: *const Remote) void {
        assert(remote.owner == core.tables.thread_identity());
    }
};

const testing = std.testing;

/// `post` can reach `Queue.wake`, which is a Linux system call, so a test that posts runs where the
/// backend does and no other host.
const posts_run_here = builtin.os.tag == .linux;

test "a remote claims an id, gives it back, and holds no descriptor of its own" {
    var registry: Registry = undefined;
    const loops: u16 = 3;
    var memory: [Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, loops);

    var remote: Remote = undefined;
    try remote.init(&registry, 2);
    try testing.expectEqual(@as(core.LoopId, 2), remote.id);
    try testing.expectEqual(core.tables.thread_identity(), remote.owner);
    // The id is claimed with the sentinel, so it names no eventfd and a post to it finds no loop.
    try testing.expectEqual(core.mailbox.descriptor_remote, registry.get(2));

    remote.deinit();
    try testing.expectEqual(core.mailbox.descriptor_none, registry.get(2));
}

test "a post to an id that runs no loop, or to another remote, is refused and queues nothing" {
    if (!posts_run_here) return error.SkipZigTest;
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

    const message: core.Message = .{ .payload = 7, .tag = 1 };
    // Loop 0 never started, and an id past the registry's count names nothing.
    try testing.expectError(error.LoopNotFound, first.post(0, message));
    try testing.expectError(error.LoopNotFound, first.post(loops, message));
    try testing.expectError(error.LoopNotFound, first.post(core.constants.loops_max, message));
    // A remote receives nothing, and its sentinel is negative, so the same check answers this.
    try testing.expectError(error.LoopNotFound, first.post(2, message));
    try testing.expectError(error.LoopNotFound, second.post(1, message));
    try testing.expect(registry.mailbox(1, 0).is_empty());
}

test "a message reaches the ring, a sleeping target is woken, and a full ring is refused" {
    if (!posts_run_here) return error.SkipZigTest;
    var registry: Registry = undefined;
    const loops: u16 = 2;
    var memory: [Registry.memory_bytes(loops)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, loops);

    // Loop 0's side: an epoll instance with its eventfd, published as a loop publishes it.
    var queue = try queue_module.Queue.init();
    defer queue.deinit();
    registry.set(0, queue.wake_descriptor);
    defer registry.clear(0);
    var remote: Remote = undefined;
    try remote.init(&registry, 1);
    defer remote.deinit();

    try remote.post(0, .{ .payload = 11, .tag = 2 });
    const ring = registry.mailbox(1, 0);
    var out: [1]core.Message = undefined;
    try testing.expectEqual(@as(u32, 1), ring.pop_into(&out));
    try testing.expectEqual(@as(u64, 11), out[0].payload);
    try testing.expectEqual(@as(u32, 2), out[0].tag);

    // Awake, the target is not woken: nothing is ready on its instance.
    var readiness: [2]queue_module.Event = undefined;
    try testing.expectEqual(@as(u32, 0), try queue.wait(&readiness, 0));
    // Asleep, it is: the post writes the eventfd, and the instance reports it.
    registry.begin_sleep(0);
    try remote.post(0, .{ .payload = 12, .tag = 3 });
    registry.end_sleep(0);
    try testing.expectEqual(@as(u32, 1), try queue.wait(&readiness, 0));
    queue.drain_wake();
    _ = ring.pop_into(&out);

    // Fill the ring, then one more: the message is refused and not dropped silently.
    var sent: u32 = 0;
    while (sent < core.constants.mailbox_messages) : (sent += 1) {
        try remote.post(0, .{ .payload = sent, .tag = 0 });
    }
    try testing.expectError(error.MailboxFull, remote.post(0, .{ .payload = 0, .tag = 0 }));
}
