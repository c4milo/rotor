//! The `uring` module: the Linux backend (decision 1), over io_uring. It imports `core` and
//! nothing else. Its pure parts, which turn a slot into a submission entry and a completion entry
//! into an event, compile and are tested on every host, with completion entries a test builds
//! itself (decision 10). Everything that enters the kernel is tested under Linux alone, by
//! `tools/linux_test.sh`.
//!
//! `Loop` holds the state; the paths are one file each: `uring_submit.zig`, `uring_reap.zig`,
//! `uring_cancel.zig`, `uring_tick.zig`. A loop belongs to the thread that initialised it, holds
//! no lock and starts no thread (decision 4).
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");

pub const constants = @import("constants.zig");
pub const address = @import("uring_address.zig");
pub const buffers = @import("uring_buffers.zig");
pub const cancel_module = @import("uring_cancel.zig");
pub const errno = @import("uring_errno.zig");
pub const reap_module = @import("uring_reap.zig");
pub const registry_module = @import("uring_registry.zig");
pub const ring_module = @import("uring_ring.zig");
pub const submit_module = @import("uring_submit.zig");
pub const sync = @import("uring_sync.zig");
pub const testing = @import("uring_testing.zig");
pub const tick_module = @import("uring_tick.zig");

pub const Registry = registry_module.Registry;
/// True on a host whose kernel this backend can run on. The conformance suite skips elsewhere.
pub const supported = @import("builtin").os.tag == .linux;

pub const InitError = ring_module.InitError;
pub const TickError = tick_module.TickError;

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Slot = core.Slot;
const SlotList = core.slot_list.SlotList;
const SlotTable = core.slot_table.SlotTable;
const TimerHeap = core.timer_heap.TimerHeap;
const Layout = core.layout.Layout;
const HandleQueue = cancel_module.HandleQueue;

/// One per thread, and its address is that thread's identity: a loop compares it against the
/// address it recorded at init, which costs one thread-local address and one compare (C21).
threadlocal var thread_marker: u8 = 0;

pub const Loop = struct {
    ring: ring_module.Ring,
    table: SlotTable,
    timers: TimerHeap,
    /// Slots that are `queued`, oldest first: claimed, and waiting for a submission entry.
    pending: SlotList,
    /// Slots that are `finishing`, oldest first: each holds its final result in `Slot.result`.
    finished: SlotList,
    /// Handles `cancel` named whose operations the kernel holds, waiting for an entry.
    cancels: HandleQueue,
    /// The kernel's form of the address of each `connect` of the flush in progress. The kernel
    /// reads them while `enter` runs, and `tick` reuses the storage after it.
    addresses: []address.Storage,
    addresses_used: u32,
    /// The monotonic clock as `tick` last read it.
    now_ns: u64,
    /// Operations accepted since init: what a sampling decision is a function of (decision 9).
    operation_sequence: u64,
    /// The address of the owning thread's `thread_marker`.
    owner: usize,
    id: core.LoopId,
    registry: ?*Registry,
    /// The provided-buffer groups `provide_buffers` named, by group id.
    groups: [core.constants.buffer_groups_max]buffers.Group,
    buffers_registered: bool,

    pub const Options = struct {
        /// The most operations in flight, which is the slots in the table:
        /// [1, core.constants.operations_max].
        operations: u32,
        /// Submission ring entries, a power of two in [1, constants.entries_max]. One tick
        /// submits at most this many operations; the rest wait for the next.
        entries: u16,
        /// This loop's id among the loops of `registry`.
        id: core.LoopId = 0,
        /// Where loops find each other's rings. Null for a loop that posts to none and that
        /// none posts to.
        registry: ?*Registry = null,
    };

    /// The bytes of memory `init` needs for `options`, aligned to `core.layout.memory_alignment`.
    pub fn memory_bytes(options: Options) usize {
        var layout: Layout = .{};
        _ = layout.add(Slot, options.operations);
        _ = layout.add(TimerHeap.Entry, options.operations);
        _ = layout.add(Handle, HandleQueue.capacity_for(options.operations));
        _ = layout.add(address.Storage, options.entries);
        return layout.bytes;
    }

    /// Must run on the thread that will own the loop, after that thread is pinned: the ring
    /// binds to it, and the pages of `memory` it touches first land on its node (decision 4).
    pub fn init(
        loop: *Loop,
        memory: []align(core.layout.memory_alignment) u8,
        options: Options,
    ) InitError!void {
        loop.init_tables(memory, options);
        loop.ring = try ring_module.Ring.init(options.entries);
        if (loop.registry) |registry| registry.set(loop.id, loop.ring.descriptor());
    }

    /// Everything but the ring: what the paths that enter no kernel run on, so their tests
    /// build a loop on any host.
    pub fn init_tables(
        loop: *Loop,
        memory: []align(core.layout.memory_alignment) u8,
        options: Options,
    ) void {
        assert(options.operations >= 1);
        assert(options.operations <= core.constants.operations_max);
        assert(options.id < core.constants.loops_max);
        assert(memory.len >= memory_bytes(options));
        var layout: Layout = .{};
        const slots = layout.take(memory, Slot, options.operations);
        const entries = layout.take(memory, TimerHeap.Entry, options.operations);
        const handles = layout.take(memory, Handle, HandleQueue.capacity_for(options.operations));
        loop.addresses = layout.take(memory, address.Storage, options.entries);
        assert(layout.bytes == memory_bytes(options));
        loop.table.init(slots);
        loop.timers.init(entries, slots);
        loop.cancels.init(handles);
        loop.pending = SlotList.empty;
        loop.finished = SlotList.empty;
        loop.addresses_used = 0;
        loop.now_ns = 0;
        loop.operation_sequence = 0;
        loop.owner = @intFromPtr(&thread_marker);
        loop.id = options.id;
        loop.registry = options.registry;
        loop.groups = @splat(buffers.Group.none);
        loop.buffers_registered = false;
    }

    /// Every operation must have had its final event (decision 5, rule 7).
    pub fn deinit(loop: *Loop) void {
        loop.assert_owner();
        loop.assert_empty();
        if (loop.registry) |registry| registry.clear(loop.id);
        loop.ring.deinit();
    }

    /// Halts when an operation has not had its final event. `deinit` calls it before it touches
    /// the ring.
    pub fn assert_empty(loop: *const Loop) void {
        assert(loop.in_flight() == 0);
        assert(loop.pending.count == 0 and loop.finished.count == 0);
    }

    /// Operations submitted whose final event the caller has not been handed.
    pub fn in_flight(loop: *const Loop) u32 {
        return loop.table.in_use();
    }

    pub fn submit(loop: *Loop, operations: []const Operation, handles: []Handle) u32 {
        loop.assert_owner();
        return submit_module.submit(loop, operations, handles);
    }

    pub fn cancel(loop: *Loop, handle: Handle) void {
        loop.assert_owner();
        cancel_module.cancel(loop, handle);
    }

    pub fn tick(loop: *Loop, events: []Event, wait_ns: u64) TickError!u32 {
        return tick_module.tick(loop, events, wait_ns);
    }

    pub const register_buffers = buffers.register;
    pub const provide_buffers = buffers.provide;
    pub const give_back_buffer = buffers.give_back;

    /// The bytes of the provided buffer a receive event named: `buffer_id` of `group_id`.
    pub fn provided_buffer(loop: *const Loop, group_id: u16, buffer_id: u16) []u8 {
        assert(group_id < core.constants.buffer_groups_max);
        return loop.groups[group_id].bytes_of(buffer_id);
    }

    /// Halts when another thread calls into the loop (decision 4): a call from the wrong thread
    /// is a programmer error, and by the time it is seen the tables may already be torn.
    pub fn assert_owner(loop: *const Loop) void {
        assert(loop.owner == @intFromPtr(&thread_marker));
    }

    /// The kernel produced the operation's last completion: its deadline is disarmed and its
    /// slot released, as the event is handed to the caller (decision 5, rule 1).
    pub fn finish(loop: *Loop, index: u32, slot: *Slot) void {
        assert(slot.state == .submitted);
        if (slot.heap_position != core.slot.heap_position_none) loop.timers.disarm(index);
        loop.table.release(index);
    }

    /// The loop produced the operation's final result itself. The slot waits on `finished`, and
    /// the next `tick` hands its event over and releases it.
    pub fn finish_local(loop: *Loop, index: u32, result: i32) void {
        const slot = loop.table.at(index);
        assert(slot.state == .queued or slot.state == .submitted);
        if (slot.heap_position != core.slot.heap_position_none) loop.timers.disarm(index);
        slot.state = .finishing;
        slot.result = result;
        loop.finished.push(loop.table.slots, index);
    }

    /// What a cancelled operation's final event says: `timeout` when the loop cancelled it for
    /// its deadline, `canceled` when the caller did (decision 5, rule 4).
    pub fn cancel_code(loop: *const Loop, slot: *const Slot) core.Code {
        _ = loop;
        assert(slot.flags.cancel_requested);
        return if (slot.flags.timed_out) .timeout else .canceled;
    }

    /// The ring of the loop a `post` names, or a negative value when there is none.
    pub fn registry_descriptor(loop: *const Loop, slot: *const Slot) core.Descriptor {
        assert(slot.code == .post);
        const registry = loop.registry orelse return registry_module.descriptor_none;
        const target: core.LoopId = @intCast(slot.descriptor);
        assert(target != loop.id);
        return registry.get(target);
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
    _ = errno;
    _ = reap_module;
    _ = registry_module;
    _ = ring_module;
    _ = submit_module;
    _ = sync;
    _ = tick_module;
    _ = @import("uring_reap_test.zig");
    _ = @import("uring_submit_test.zig");
    _ = @import("uring_loop_test.zig");
}
