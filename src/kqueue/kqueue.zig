//! The `kqueue` module: the macOS backend (decisions 1 and 12), over kqueue. It imports `core`
//! and nothing else. kqueue reports readiness, so this backend performs each operation itself
//! when its descriptor is ready, and presents the caller the behaviour `uring` presents: the
//! conformance suite runs against both.
//!
//! `Loop` holds the state; the paths are one file each: `kqueue_submit.zig`, `kqueue_reap.zig`,
//! `kqueue_cancel.zig`, `kqueue_tick.zig`. What is the same on every kernel is `core.Tables`. A
//! loop belongs to the thread that initialised it, holds no lock and starts no thread
//! (decision 4).
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");

pub const constants = @import("constants.zig");
pub const address = @import("kqueue_address.zig");
pub const buffers = @import("kqueue_buffers.zig");
const datagram_module = @import("kqueue_datagram.zig");
pub const cancel_module = @import("kqueue_cancel.zig");
pub const descriptors_module = @import("kqueue_descriptors.zig");
pub const errno = @import("kqueue_errno.zig");
pub const mailbox = @import("kqueue_mailbox.zig");
pub const perform = @import("kqueue_perform.zig");
pub const queue_module = @import("kqueue_queue.zig");
pub const reap_module = @import("kqueue_reap.zig");
pub const submit_module = @import("kqueue_submit.zig");
pub const sync = @import("kqueue_sync.zig");
pub const testing = @import("kqueue_testing.zig");
pub const tick_module = @import("kqueue_tick.zig");
pub const waiters_module = @import("kqueue_waiters.zig");

/// True on a host whose kernel this backend can run on. The conformance suite skips elsewhere.
pub const supported = @import("builtin").os.tag.isDarwin();

pub const Registry = mailbox.Registry;
pub const InitError = queue_module.InitError;
pub const TickError = tick_module.TickError;
pub const DrainError = TickError || error{StillInFlight};

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Slot = core.Slot;
const Tables = core.Tables;
const TimerHeap = core.timer_heap.TimerHeap;
const Layout = core.layout.Layout;
const Waiters = waiters_module.Waiters;
const Kevent = queue_module.Kevent;

/// Messages one call of `drain_mailboxes` moves out of one ring at a time.
const messages_per_drain = 32;

pub const Loop = struct {
    queue: queue_module.Queue,
    /// What a loop holds whatever its kernel: the slot table, the timer heap, the pending and
    /// finished lists, the clock, the owner.
    tables: Tables,
    /// From a descriptor to the operations that wait for it to become ready.
    waiters: Waiters,
    /// The registrations the next `kevent` call carries in.
    changes: [constants.changes_max]Kevent,
    changes_used: u32,
    /// Where the `kevent` call writes the descriptors that became ready.
    readiness: [constants.readiness_max]Kevent,
    /// Where loops find each other's mailboxes. Null for a loop that posts to none and that
    /// none posts to.
    registry: ?*Registry,
    /// True while the registry says this loop sleeps, so `wake_up` ends it once.
    sleeping: bool,
    /// The provided-buffer groups `provide_buffers` named, by group id.
    /// The reserve every datagram group of this loop uses (decision 15). One loop serves one
    /// shape, so a receive knows where a datagram starts without a lookup per completion.
    datagram_group: core.datagram.GroupOptions,
    groups: [core.constants.buffer_groups_max]buffers.Group,
    buffers_registered: bool,
    /// The descriptors `register_descriptors` named, by index. `tables.descriptors_registered`
    /// says how many hold one.
    descriptors: [core.constants.registered_descriptors_max]core.Descriptor,

    pub const Options = struct {
        /// The most operations in flight, which is the slots in the table:
        /// [1, core.constants.operations_max].
        operations: u32,
        /// What the uring backend sizes its submission ring by. This backend sizes nothing by
        /// it, and takes it so that a caller's options are the same on both.
        entries: u16,
        /// How often the loop measures an operation (decision 9, rule 2).
        sampling: core.statistics.Options = .{},
        /// This loop's id among the loops of `registry`.
        id: core.LoopId = 0,
        registry: ?*Registry = null,
    };

    /// The bytes of memory `init` needs for `options`, aligned to `core.layout.memory_alignment`.
    pub fn memory_bytes(options: Options) usize {
        var layout: Layout = .{};
        _ = layout.add(Slot, options.operations);
        _ = layout.add(TimerHeap.Entry, options.operations);
        _ = layout.add(u64, options.operations);
        _ = layout.add(waiters_module.Entry, Waiters.capacity_for(options.operations));
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

    /// Everything but the kqueue: what the paths that enter no kernel run on.
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
        loop.waiters.init(layout.take(memory, waiters_module.Entry, waiting));
        assert(layout.bytes == memory_bytes(options));
        loop.tables.init(slots, entries, starts, .{
            .id = options.id,
            .sampling = options.sampling,
        });
        loop.changes_used = 0;
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

    pub fn cancel(loop: *Loop, handle: Handle) void {
        loop.tables.assert_owner();
        cancel_module.cancel(loop, handle);
    }

    pub fn tick(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
        return tick_module.tick(loop, events, wait_ns);
    }

    /// Asks for the cancel of every operation in flight (decision 5, rule 7). Each still ends
    /// with its own final event, which `drain` or the caller's ticks hand over.
    pub fn cancel_all(loop: *Loop) void {
        loop.tables.assert_owner();
        var from: u32 = 0;
        while (loop.tables.next_cancellable(from)) |index| : (from = index + 1) {
            cancel_module.request(loop, index, loop.tables.table.at(index));
        }
    }

    /// Ticks until no operation is in flight, discarding the events into `scratch`: what a
    /// caller that is shutting down, and has no use for them, calls after `cancel_all`. Fails
    /// when the loop is still not empty after `core.constants.drain_rounds_max` ticks.
    pub fn drain(loop: *Loop, scratch: []Event) DrainError!void {
        const rounds_max = core.constants.drain_rounds_max;
        return core.shutdown.drain(loop, scratch, rounds_max, core.constants.drain_wait_ns);
    }

    /// What the loop has counted about itself, sampled (decision 9). Read by the caller alone.
    pub fn statistics(loop: *const Loop) *const core.statistics.Statistics {
        return &loop.tables.statistics;
    }

    pub const register_buffers = buffers.register;
    pub const register_descriptors = descriptors_module.register;
    pub const provide_buffers = buffers.provide;
    pub const give_back_buffer = buffers.give_back;

    /// A buffer group for datagrams (decision 15). The reserve in front of each datagram is
    /// chosen here, once, and `provide_buffers` is untouched, so no stream caller gains a
    /// precondition. One loop serves one datagram shape.
    pub fn provide_datagram_buffers(
        loop: *Loop,
        group_id: u16,
        ring_memory: []align(buffers.ring_alignment) u8,
        memory: []u8,
        buffer_bytes: u32,
        group: core.datagram.GroupOptions,
    ) buffers.ProvideError!void {
        assert(buffer_bytes > core.datagram.prefix_bytes(group));
        loop.datagram_group = group;
        return buffers.provide(loop, group_id, ring_memory, memory, buffer_bytes);
    }

    /// The datagram an event names, out of the buffer it named. The only supported reader of
    /// that buffer: a datagram's bytes do not start at its front.
    pub fn datagram(loop: *const Loop, buffer: []u8, event: core.Event) core.Delivery {
        assert(!event.flags.message);
        const bytes: u32 = @intCast(event.result);
        return datagram_module.delivery(buffer, bytes, loop.datagram_group);
    }

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
        const registry = loop.registry orelse return bound;
        registry.begin_sleep(loop.tables.id);
        loop.sleeping = true;
        for (0..registry.loops()) |sender| {
            if (sender == loop.tables.id) continue;
            if (!registry.mailbox(@intCast(sender), loop.tables.id).is_empty()) return null;
        }
        return bound;
    }

    /// Tells the registry the loop is awake again, when it had said it would sleep.
    pub fn wake_up(loop: *Loop) void {
        if (!loop.sleeping) return;
        loop.registry.?.end_sleep(loop.tables.id);
        loop.sleeping = false;
    }
};

comptime {
    core.surface.check(Loop);
}

test {
    _ = constants;
    _ = address;
    _ = buffers;
    _ = cancel_module;
    _ = descriptors_module;
    _ = errno;
    _ = mailbox;
    _ = perform;
    _ = queue_module;
    _ = reap_module;
    _ = submit_module;
    _ = sync;
    _ = testing;
    _ = tick_module;
    _ = waiters_module;
    _ = @import("kqueue_mailbox_test.zig");
    _ = @import("kqueue_perform_test.zig");
    _ = @import("kqueue_waiters_test.zig");
}
