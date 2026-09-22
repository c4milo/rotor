//! The `epoll` module: the second Linux backend (decision 20), for a host that refuses io_uring. It
//! imports `core` and nothing else.
//!
//! epoll reports readiness, so this backend is `kqueue`'s shape and not `uring`'s: it performs each
//! operation itself when the descriptor is ready, and emulates multishot and provided buffer groups
//! in user space because epoll has neither. The conformance suite runs against it unchanged, and in
//! Docker under the default seccomp profile, which is the environment that justifies it.
//!
//! `Loop` holds the state; the paths are one file each, as on kqueue. What is the same on every
//! kernel is `core.Tables`. A loop belongs to the thread that initialised it, holds no lock and
//! starts no thread (decision 4).
//!
//! Two things differ from `kqueue`'s `Loop`. There is no changelist, because `epoll_ctl` takes one
//! descriptor per call and has no batched form, so a registration is made as it is needed and
//! nothing accumulates. And `readiness` holds `linux.epoll_event` rather than `Kevent`.
//!
//! **No speed claim is made for this backend.** epoll has none of decision 3's speed sources: no
//! registered descriptors, no provided buffer rings, no multishot, no batched submission. It exists
//! so that rotor runs where io_uring does not, and the comparison gains no row for it.
//!
//! **Under construction.** Decision 20 was accepted on 2026-09-22 and this module is being built
//! organ by organ, `kqueue`'s file by `kqueue`'s file. What is here compiles and is tested; what is
//! not here yet is listed below, so nobody reads the module as finished.
//!
//! Built: `constants.zig`, `epoll_queue.zig`, `epoll_buffers.zig`, `epoll_offload.zig`, and the
//! loop's state and lifecycle below. The waiters table, the mailboxes, the errno map and the
//! offload's rings are `core`'s, shared with `kqueue` rather than copied.
//!
//! Not built: submit's kernel half, reap, perform, cancel, tick, the datagram path, the registered
//! descriptors, `Remote`, the address and sync helpers, the surface check, and `supported` becoming
//! true. Until the last of those, `supported` stays false and the conformance suite skips this
//! backend everywhere, so no gate can pass by accident.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");

pub const constants = @import("constants.zig");
pub const buffers = @import("epoll_buffers.zig");
pub const offload_module = @import("epoll_offload.zig");
pub const queue_module = @import("epoll_queue.zig");

/// Whether this backend's file operations block the loop thread, which is what decides whether
/// `Options.file_policy` and an offload mean anything here. epoll reports readiness and never
/// reports a regular file as anything but ready, exactly as kqueue does not report one at all, so
/// this backend makes the `pread`, `pwrite` and `fsync` calls itself and they block the loop thread
/// (decisions 18 and 20).
pub const files_block = true;

/// Whether a `post` can be refused for lack of room at the target (decision 4). The mailbox rings
/// are `core`'s and hold `core.constants.mailbox_messages`, as on every backend, so a post to a
/// full one is refused with `mailbox_full`.
pub const post_bounded = true;

/// True on a host whose kernel this backend can run on, and only once it can actually run there.
/// **False while the module is under construction**: the conformance suite skips a backend that
/// says false, and a half-built backend that claimed a host would let a gate pass on nothing.
pub const supported = false;

/// What `supported` will read when the module is finished: Linux, where epoll is.
pub const supported_when_built = @import("builtin").os.tag == .linux;

/// The rings are `core`'s, and so is the table of which loop is where: this backend's `post` is
/// kqueue's, because neither kernel carries a message the way io_uring's `msg_ring` does
/// (decision 20, open question 3).
pub const Registry = core.mailbox.Registry;
pub const InitError = queue_module.InitError;

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Slot = core.Slot;
const Tables = core.Tables;
const TimerHeap = core.timer_heap.TimerHeap;
const Layout = core.layout.Layout;
const Waiters = core.waiters.Waiters;

/// Messages one call of `drain_mailboxes` moves out of one ring at a time.
const messages_per_drain = 32;

pub const Loop = struct {
    queue: queue_module.Queue,
    /// What a loop holds whatever its kernel: the slot table, the timer heap, the pending and
    /// finished lists, the clock, the owner.
    tables: Tables,
    /// From a descriptor to the operations that wait for it to become ready.
    waiters: Waiters,
    /// Where the `epoll_pwait2` call writes the descriptors that became ready. There is no
    /// changelist beside it: kqueue carries its registrations in the call that waits, and
    /// `epoll_ctl` has no batched form, so each registration is its own call as it is needed
    /// (decision 20, "The shape").
    readiness: [constants.readiness_max]queue_module.Event,
    /// Where loops find each other's mailboxes. Null for a loop that posts to none and that
    /// none posts to.
    registry: ?*Registry,
    /// True while the registry says this loop sleeps, so `wake_up` ends it once.
    sleeping: bool,
    /// What this loop does with a file operation it cannot perform without blocking (decision 18).
    file_policy: core.offload.FilePolicy,
    /// The caller's offload, set when `file_policy` is `offload` and null otherwise.
    offload: ?core.offload.Offload,
    /// One ring per worker of the offload, which the worker writes and this loop reads. Empty
    /// unless the policy is `offload`.
    completions: []core.mailbox.Mailbox,
    /// One per slot, filled when an operation is handed out. Empty unless the policy is `offload`.
    works: []core.offload.Work,
    /// Set while this loop is inside a blocking `epoll_pwait2` call, so a worker on another thread
    /// knows to wake it. It is read by the workers, so it is atomic, where `sleeping` is not
    /// (decision 18, and decision 12's point 6 for the race it settles).
    offload_asleep: std.atomic.Value(bool),
    /// The reserve every datagram group of this loop uses (decision 15). One loop serves one
    /// shape, so a receive knows where a datagram starts without a lookup per completion.
    datagram_group: core.datagram.GroupOptions,
    /// The provided-buffer groups `provide_buffers` named, by group id.
    groups: [core.constants.buffer_groups_max]buffers.Group,
    buffers_registered: bool,
    /// The descriptors `register_descriptors` named, by index. `tables.descriptors_registered`
    /// says how many hold one.
    descriptors: [core.constants.registered_descriptors_max]core.Descriptor,

    pub const Options = struct {
        /// The most operations in flight, which is the slots in the table:
        /// [1, core.constants.operations_max].
        operations: u32,
        /// What the uring backend sizes its submission ring by, or 0 for its default. This
        /// backend sizes nothing by it, and takes it so that a caller's options are the same on
        /// every backend.
        entries: u16 = 0,
        /// How often the loop measures an operation (decision 9, rule 2).
        sampling: core.statistics.Options = .{},
        /// This loop's id among the loops of `registry`.
        id: core.LoopId = 0,
        registry: ?*Registry = null,
        /// What the loop does with `read`, `write` and `fdatasync`, which this backend cannot
        /// perform without blocking (decision 18). The uring backend takes it and ignores it.
        file_policy: core.offload.FilePolicy = .refuse,
        /// The caller's threads, required when `file_policy` is `offload` and refused otherwise.
        offload: ?core.offload.Offload = null,
        /// Memory for the offload's rings, of at least
        /// `offload_module.memory_bytes(offload.?.workers)`. The caller owns it because its own
        /// threads write it, as the application owns the registry's.
        offload_memory: []align(core.layout.memory_alignment) u8 = &.{},
    };

    /// The workers `options` asks the loop to hold rings for: the offload's, or none.
    fn workers_of(options: Options) u16 {
        if (options.file_policy != .offload) return 0;
        return (options.offload orelse return 0).workers;
    }

    /// The bytes of memory `init` needs for `options`, aligned to `core.layout.memory_alignment`.
    pub fn memory_bytes(options: Options) usize {
        var layout: Layout = .{};
        _ = layout.add(Slot, options.operations);
        _ = layout.add(TimerHeap.Entry, options.operations);
        _ = layout.add(u64, options.operations);
        _ = layout.add(core.waiters.Entry, Waiters.capacity_for(options.operations));
        // Nothing for an offload the options did not ask for, so a caller that wants none pays no
        // byte for one. The rings are not here: they are 128-byte aligned, which `Layout` does not
        // carve, and the caller's threads write them. `core.offload.memory_bytes` sizes those.
        // `Layout.add` takes at least one entry, so a loop with no offload adds nothing at all.
        if (workers_of(options) != 0) _ = layout.add(core.offload.Work, options.operations);
        return layout.bytes;
    }

    /// Must run on the thread that will own the loop (decision 4).
    pub fn init(
        loop: *Loop,
        memory: []align(core.layout.memory_alignment) u8,
        options: Options,
    ) InitError!void {
        loop.init_tables(memory, options);
        loop.queue = try queue_module.Queue.init();
        if (loop.registry) |registry| registry.set(loop.tables.id, loop.queue.descriptor);
    }

    /// Everything but the epoll instance: what the paths that enter no kernel run on.
    pub fn init_tables(
        loop: *Loop,
        memory: []align(core.layout.memory_alignment) u8,
        options: Options,
    ) void {
        assert(options.operations >= 1);
        assert(options.operations <= core.constants.operations_max);
        assert(memory.len >= memory_bytes(options));
        var layout: Layout = .{};
        const slots = layout.take(memory, Slot, options.operations);
        const entries = layout.take(memory, TimerHeap.Entry, options.operations);
        const starts = layout.take(memory, u64, options.operations);
        const waiting = Waiters.capacity_for(options.operations);
        loop.waiters.init(layout.take(memory, core.waiters.Entry, waiting));
        const workers = workers_of(options);
        // An `offload` policy without an offload, or one with workers the rings cannot hold, is a
        // programmer error and not an operational one: it is a mistake at init and nothing can
        // recover from it later (CLAUDE.md, Conventions).
        assert((options.file_policy == .offload) == (workers != 0));
        loop.works = if (workers == 0)
            &.{}
        else
            layout.take(memory, core.offload.Work, options.operations);
        assert(layout.bytes == memory_bytes(options));
        loop.completions = offload_module.init_rings(options.offload_memory, workers);
        loop.file_policy = options.file_policy;
        loop.offload = options.offload;
        loop.offload_asleep = .init(false);
        loop.tables.init(slots, entries, starts, .{
            .id = options.id,
            .sampling = options.sampling,
        });
        loop.registry = options.registry;
        loop.sleeping = false;
        loop.groups = @splat(buffers.Group.none);
        loop.datagram_group = .{};
        loop.buffers_registered = false;
    }

    /// Every operation must have had its final event (decision 5, rule 7).
    pub fn deinit(loop: *Loop) void {
        loop.tables.assert_owner();
        loop.tables.assert_empty();
        if (loop.registry) |registry| registry.clear(loop.tables.id);
        loop.queue.deinit();
    }

    pub fn assert_empty(loop: *const Loop) void {
        loop.tables.assert_empty();
    }

    pub fn assert_owner(loop: *const Loop) void {
        loop.tables.assert_owner();
    }

    /// Operations submitted whose final event the caller has not been handed.
    pub fn in_flight(loop: *const Loop) u32 {
        return loop.tables.in_flight();
    }

    /// Claims a slot per operation until the table is full, and returns how many it took. Makes
    /// no system call: the next `tick` tries them.
    pub fn submit(loop: *Loop, operations: []const Operation, handles: []Handle) u32 {
        loop.tables.assert_owner();
        return loop.tables.submit(operations, handles);
    }

    /// What the loop has counted about itself, sampled (decision 9). Read by the caller alone.
    pub fn statistics(loop: *const Loop) *const core.statistics.Statistics {
        return &loop.tables.statistics;
    }

    pub const register_buffers = buffers.register;
    pub const provide_buffers = buffers.provide;
    pub const give_back_buffer = buffers.give_back;

    /// The bytes of the provided buffer a receive event named: `buffer_id` of `group_id`.
    pub fn provided_buffer(loop: *const Loop, group_id: u16, buffer_id: u16) []u8 {
        assert(group_id < core.constants.buffer_groups_max);
        return loop.groups[group_id].bytes_of(buffer_id);
    }

    /// Moves the messages other loops posted into `events`, oldest first per sender, until the
    /// events run out. A ring that still holds messages then is drained by the next tick, which
    /// does not wait while one does.
    pub fn drain_mailboxes(loop: *Loop, events: []Event) u32 {
        const registry = loop.registry orelse return 0;
        var produced: u32 = 0;
        var messages: [messages_per_drain]core.Message = undefined;
        for (0..registry.loops()) |sender| {
            if (sender == loop.tables.id) continue;
            const room = @min(events.len - produced, messages_per_drain);
            if (room == 0) break;
            const ring = registry.mailbox(@intCast(sender), loop.tables.id);
            const moved = ring.pop_into(messages[0..room]);
            for (messages[0..moved]) |message| {
                events[produced] = .{
                    .user_data = message.payload,
                    .result = @intCast(message.tag),
                    .flags = .{ .message = true },
                };
                produced += 1;
            }
        }
        assert(produced <= events.len);
        return produced;
    }

    /// Tells the registry this loop is about to sleep, then looks at its mailboxes once more: a
    /// sender that posted before it saw the flag did not wake the loop, so the loop must not
    /// sleep on that message (decision 12, point 6). Returns the wait to sleep for, or null.
    pub fn settle_to_sleep(loop: *Loop, wait: ?u64) ?u64 {
        const bound = wait orelse return null;
        // The offload's workers are told the same thing the other loops are told, through a flag of
        // this loop's own: an offload works without a registry, because its workers own no loop.
        if (loop.completions.len != 0) {
            loop.offload_asleep.store(true, .seq_cst);
            if (offload_module.pending(loop)) return null;
        }
        const registry = loop.registry orelse return bound;
        registry.begin_sleep(loop.tables.id);
        loop.sleeping = true;
        for (0..registry.loops()) |sender| {
            if (sender == loop.tables.id) continue;
            if (!registry.mailbox(@intCast(sender), loop.tables.id).is_empty()) return null;
        }
        return bound;
    }

    /// Tells the registry, and the offload's workers, that the loop is awake again.
    pub fn wake_up(loop: *Loop) void {
        if (loop.completions.len != 0) loop.offload_asleep.store(false, .seq_cst);
        if (!loop.sleeping) return;
        loop.registry.?.end_sleep(loop.tables.id);
        loop.sleeping = false;
    }
};

// `core.surface.check(Loop)` is not called yet: `cancel`, `tick`, `cancel_all`, `drain`,
// `register_descriptors`, `provide_datagram_buffers` and `datagram` are not built. It goes in with
// the last of them, in the commit that sets `supported`, so the check never passes on a Loop a
// caller cannot use.

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
    try testing.expectEqual(@as(usize, 0), loop.completions.len);
    try testing.expectEqual(@as(usize, 0), loop.works.len);
    try testing.expect(!loop.buffers_registered);
    try testing.expect(!loop.sleeping);
    try testing.expect(loop.registry == null);
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
    try testing.expect(!loop.sleeping);
    loop.wake_up();
    try testing.expect(!loop.sleeping);
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
    try testing.expect(loop.sleeping);
    try testing.expect(registry.must_wake(receiver));
    loop.wake_up();
    try testing.expect(!loop.sleeping);
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

test {
    _ = constants;
    _ = buffers;
    _ = offload_module;
    _ = queue_module;
}
