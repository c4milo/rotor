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
pub const descriptors = @import("uring_descriptors.zig");
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
pub const DrainError = TickError || error{StillInFlight};

const Event = core.Event;
const Handle = core.Handle;
const Operation = core.Operation;
const Slot = core.Slot;
const Tables = core.Tables;
const TimerHeap = core.timer_heap.TimerHeap;
const Layout = core.layout.Layout;
const HandleQueue = cancel_module.HandleQueue;

pub const Loop = struct {
    ring: ring_module.Ring,
    /// What a loop holds whatever its kernel: the slot table, the timer heap, the pending and
    /// finished lists, the clock, the owner.
    tables: Tables,
    /// Handles `cancel` named whose operations the kernel holds, waiting for an entry.
    cancels: HandleQueue,
    /// The kernel's form of the address of each `connect` of the flush in progress. The kernel
    /// reads them while `enter` runs, and `tick` reuses the storage after it.
    addresses: []address.Storage,
    addresses_used: u32,
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
        /// How often the loop measures an operation (decision 9, rule 2).
        sampling: core.statistics.Options = .{},
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
        _ = layout.add(u64, options.operations);
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
        if (loop.registry) |registry| registry.set(loop.tables.id, loop.ring.descriptor());
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
        const starts = layout.take(memory, u64, options.operations);
        const handles = layout.take(memory, Handle, HandleQueue.capacity_for(options.operations));
        loop.addresses = layout.take(memory, address.Storage, options.entries);
        assert(layout.bytes == memory_bytes(options));
        loop.tables.init(slots, entries, starts, .{
            .id = options.id,
            .sampling = options.sampling,
        });
        loop.cancels.init(handles);
        loop.addresses_used = 0;
        loop.registry = options.registry;
        loop.groups = @splat(buffers.Group.none);
        loop.buffers_registered = false;
    }

    /// Every operation must have had its final event (decision 5, rule 7).
    pub fn deinit(loop: *Loop) void {
        loop.tables.assert_owner();
        loop.tables.assert_empty();
        if (loop.registry) |registry| registry.clear(loop.tables.id);
        loop.ring.deinit();
    }

    /// Halts when an operation has not had its final event. `deinit` calls it before it touches
    /// the ring.
    pub fn assert_empty(loop: *const Loop) void {
        loop.tables.assert_empty();
    }

    /// Halts when another thread calls into the loop (decision 4).
    pub fn assert_owner(loop: *const Loop) void {
        loop.tables.assert_owner();
    }

    /// Operations submitted whose final event the caller has not been handed.
    pub fn in_flight(loop: *const Loop) u32 {
        return loop.tables.in_flight();
    }

    /// Claims a slot per operation until the table is full, and returns how many it took. Makes
    /// no system call: the next `tick` submits.
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
    pub const register_descriptors = descriptors.register;
    pub const provide_buffers = buffers.provide;
    pub const give_back_buffer = buffers.give_back;

    /// The bytes of the provided buffer a receive event named: `buffer_id` of `group_id`.
    pub fn provided_buffer(loop: *const Loop, group_id: u16, buffer_id: u16) []u8 {
        assert(group_id < core.constants.buffer_groups_max);
        return loop.groups[group_id].bytes_of(buffer_id);
    }

    /// The ring of the loop a `post` names, or a negative value when there is none.
    pub fn registry_descriptor(loop: *const Loop, slot: *const Slot) core.Descriptor {
        assert(slot.code == .post);
        const registry = loop.registry orelse return registry_module.descriptor_none;
        const target: core.LoopId = @intCast(slot.descriptor);
        assert(target != loop.tables.id);
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
    _ = descriptors;
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
