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
pub const errno = core.errno;
pub const mailbox = core.mailbox;
pub const offload_module = @import("kqueue_offload.zig");
pub const perform = @import("kqueue_perform.zig");
pub const remote_module = @import("kqueue_remote.zig");
pub const queue_module = @import("kqueue_queue.zig");
pub const reap_module = @import("kqueue_reap.zig");
pub const submit_module = @import("kqueue_submit.zig");
pub const sync = @import("kqueue_sync.zig");
pub const testing = @import("kqueue_testing.zig");
pub const tick_module = @import("kqueue_tick.zig");
/// Whether this backend's file operations block the loop thread, which is what decides whether
/// `Options.file_policy` and an offload mean anything here. kqueue reports readiness and never
/// completes a file operation, so this backend makes the `pread`, `pwrite` and `fsync` calls
/// itself and they block the loop thread (decision 18).
pub const files_block = true;

/// Whether a `post` can be refused for lack of room at the target, which decides what a caller
/// may assume of `mailbox_full` and what the conformance suite asserts (decision 4). A mailbox
/// holds `core.constants.mailbox_messages`, and a post to a full one is refused with
/// `mailbox_full`, from a loop or from a `Remote`.
pub const post_bounded = true;

/// True on a host whose kernel this backend can run on. The conformance suite skips elsewhere.
pub const supported = @import("builtin").os.tag.isDarwin();

pub const Registry = mailbox.Registry;
pub const Remote = remote_module.Remote;
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
const Waiters = core.waiters.Waiters;
const Kevent = queue_module.Kevent;

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
    /// What other threads send this loop, and the sleep handshake that wakes it for them.
    inbox: core.inbox.Inbox,
    /// What this loop does with a file operation it cannot perform without blocking (decision 18).
    file_policy: core.offload.FilePolicy,
    /// The caller's offload, set when `file_policy` is `offload` and null otherwise.
    offload: ?core.offload.Offload,
    /// One per slot, filled when an operation is handed out. Empty unless the policy is `offload`.
    works: []core.offload.Work,
    /// The reserve every datagram group of this loop uses (decision 15). One loop serves one
    /// shape, so a receive knows where a datagram starts without a lookup per completion.
    datagram_group: core.datagram.GroupOptions,
    /// The provided-buffer groups `provide_buffers` named, by group id.
    groups: [core.constants.buffer_groups_max]buffers.Group,
    /// The descriptors `register_descriptors` named, by index. `tables.descriptors_registered`
    /// says how many hold one.
    descriptors: [core.constants.registered_descriptors_max]core.Descriptor,

    pub const Options = struct {
        /// The most operations in flight, which is the slots in the table:
        /// [1, core.constants.operations_max].
        operations: u32,
        /// What the uring backend sizes its submission ring by, or 0 for its default. This
        /// backend sizes nothing by it, and takes it so that a caller's options are the same on
        /// both.
        entries: u16 = 0,
        /// How often the loop measures an operation (decision 9, rule 2).
        sampling: core.statistics.Options = .{},
        /// This loop's id among the loops of `registry`.
        id: core.LoopId = 0,
        registry: ?*Registry = null,
        /// What the loop does with `read`, `write` and `fdatasync`, which this backend cannot
        /// perform without blocking (decision 18). The uring backend checks it and ignores it.
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
        // byte for one (decision 12, point 6 makes the same argument for the registry).
        // The rings are not here: they are 128-byte aligned, which `Layout` does not carve, and
        // the caller's threads write them. `offload_module.memory_bytes` sizes those.
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
        if (loop.inbox.registry) |registry| registry.set(loop.tables.id, loop.queue.descriptor);
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
        core.offload.assert_options(options.file_policy, options.offload, options.offload_memory);
        var layout: Layout = .{};
        const slots = layout.take(memory, Slot, options.operations);
        const entries = layout.take(memory, TimerHeap.Entry, options.operations);
        const starts = layout.take(memory, u64, options.operations);
        const waiting = Waiters.capacity_for(options.operations);
        loop.waiters.init(layout.take(memory, core.waiters.Entry, waiting));
        const workers = workers_of(options);
        loop.works = if (workers == 0)
            &.{}
        else
            layout.take(memory, core.offload.Work, options.operations);
        assert(layout.bytes == memory_bytes(options));
        const completions = offload_module.init_rings(options.offload_memory, workers);
        loop.inbox = core.inbox.Inbox.init(options.registry, completions);
        loop.file_policy = options.file_policy;
        loop.offload = options.offload;
        loop.tables.init(slots, entries, starts, .{
            .id = options.id,
            .sampling = options.sampling,
        });
        loop.changes_used = 0;
        loop.groups = @splat(buffers.Group.none);
        loop.datagram_group = .{};
    }

    /// Every operation must have had its final event (decision 5, rule 7).
    pub fn deinit(loop: *Loop) void {
        loop.tables.assert_owner();
        loop.tables.assert_empty();
        if (loop.inbox.registry) |registry| registry.clear(loop.tables.id);
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

    /// The monotonic clock in nanoseconds, as the last `tick` read it: at its start, or after its
    /// wait when it waited. Timers expire against this reading. The next tick arms a timer
    /// submitted now at that tick's own reading plus its `after_ns`, so the timer fires no earlier
    /// than this reading plus its `after_ns`. 0 until the first tick. Reading it makes no system
    /// call.
    pub fn now_ns(loop: *const Loop) u64 {
        return loop.tables.now_ns;
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
        memory: []align(buffers.group_alignment) u8,
        count: u16,
        buffer_bytes: u32,
        group: core.datagram.GroupOptions,
    ) buffers.ProvideError!void {
        assert(buffer_bytes > core.datagram.prefix_bytes(group));
        loop.datagram_group = group;
        return buffers.provide(loop, group_id, memory, count, buffer_bytes);
    }

    /// The datagram an event of group `group_id` names: the only supported reader of that
    /// buffer, because a datagram's bytes do not start at its front. The buffer stays the
    /// caller's until `give_back_buffer`.
    pub fn datagram(loop: *const Loop, group_id: u16, event: core.Event) core.Delivery {
        assert(!event.flags.message);
        assert(event.flags.buffer);
        const buffer = loop.provided_buffer(group_id, event.flags.buffer_id);
        const bytes: u32 = @intCast(event.result);
        return datagram_module.delivery(buffer, bytes, loop.datagram_group);
    }

    /// The bytes of the provided buffer a receive event named: `buffer_id` of `group_id`.
    pub fn provided_buffer(loop: *const Loop, group_id: u16, buffer_id: u16) []u8 {
        assert(group_id < core.constants.buffer_groups_max);
        return loop.groups[group_id].bytes_of(buffer_id);
    }

    /// Moves the messages other loops posted into `events`: `core.inbox`'s.
    pub fn drain_mailboxes(loop: *Loop, events: []Event) u32 {
        return loop.inbox.drain_mailboxes(loop.tables.id, events);
    }

    /// Tells the registry and the offload's workers this loop is about to sleep: `core.inbox`'s.
    pub fn settle_to_sleep(loop: *Loop, wait: ?u64) ?u64 {
        return loop.inbox.settle_to_sleep(loop.tables.id, wait);
    }

    /// Tells the registry, and the offload's workers, that the loop is awake again.
    pub fn wake_up(loop: *Loop) void {
        loop.inbox.wake_up(loop.tables.id);
    }
};

comptime {
    core.surface.check(Loop);
    core.surface.check_remote(Remote);
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
    _ = remote_module;
    _ = queue_module;
    _ = reap_module;
    _ = submit_module;
    _ = sync;
    _ = testing;
    _ = tick_module;
    _ = offload_module;
    _ = @import("kqueue_file_call.zig");
    _ = @import("kqueue_mailbox_test.zig");
    _ = @import("kqueue_offload_test.zig");
    _ = @import("kqueue_perform_test.zig");
    _ = @import("kqueue_sync_socket_test.zig");
}
