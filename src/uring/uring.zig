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
pub const datagram_module = @import("uring_datagram.zig");
pub const buffers = @import("uring_buffers.zig");
pub const cancel_module = @import("uring_cancel.zig");
pub const descriptors = @import("uring_descriptors.zig");
pub const errno = @import("uring_errno.zig");
pub const reap_module = @import("uring_reap.zig");
pub const registry_module = @import("uring_registry.zig");
pub const remote_module = @import("uring_remote.zig");
pub const ring_module = @import("uring_ring.zig");
pub const submit_module = @import("uring_submit.zig");
pub const sync = @import("uring_sync.zig");
pub const testing = @import("uring_testing.zig");
pub const tick_module = @import("uring_tick.zig");

pub const Registry = registry_module.Registry;
pub const Remote = remote_module.Remote;
/// Whether this backend's file operations block the loop thread, which is what decides whether
/// `Options.file_policy` and an offload mean anything here. io_uring completes a file operation
/// without a thread, so there is nothing to hand out, and `Options.file_policy` is checked and then
/// ignored (decision 18).
pub const files_block = false;

/// Whether a `post` can be refused for lack of room at the target, which decides what a caller
/// may assume of `mailbox_full` and what the conformance suite asserts (decision 4). The ring is
/// created with `IORING_FEAT_NODROP` required, so a target whose completion ring is full has the
/// completion kept by the kernel in an overflow list, bounded by kernel memory and not by rotor.
/// A `MSG_RING` to a running loop therefore lands unless the kernel is out of memory. What it
/// answers then depends on the kernel: `EOVERFLOW`, `mailbox_full`, when the overflow entry could
/// not be allocated (Linux 6.1, and 6.3 to 6.9 from the target's task work); `ENOMEM`,
/// `system_resources`, when the request that carries the message could not be allocated (6.10
/// and later, where a later failure to allocate the overflow entry drops the message with no
/// answer to the sender). Recalled from `io_uring/msg_ring.c`; `uring_errno.zig` records what
/// was read there.
pub const post_bounded = false;

/// True on a host whose kernel this backend can run on. The conformance suite skips elsewhere.
pub const supported = @import("builtin").os.tag == .linux;

pub const InitError = ring_module.InitError;
pub const TickError = tick_module.TickError;
pub const DrainError = TickError || error{StillInFlight};

/// True when this kernel refuses the ring this backend needs, which is when a process should run
/// the epoll backend instead (decision 20, open question 5). It asks the way `Loop.init` asks, with
/// the same flags, features and opcodes, on a ring of one entry that it closes again, so its answer
/// is the one a loop would get.
///
/// Refused means `PermissionDenied`, which is a seccomp profile or `io_uring_disabled`, or
/// `Unsupported`, which is a kernel without io_uring or without something this backend requires.
/// Any other failure is not a refusal: a process short of descriptors or memory is short of them
/// on either backend, and `Loop.init` reports it.
pub fn refused() bool {
    const probe_entries = 1;
    var ring = ring_module.Ring.init(probe_entries) catch |err| return switch (err) {
        error.PermissionDenied, error.Unsupported => true,
        error.SystemResources, error.Unexpected => false,
    };
    ring.deinit();
    return false;
}

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
    /// One per submission entry, for a `receive_from` or a `send_to`: the kernel reads the
    /// `msghdr` while `io_uring_enter` runs, so it lives exactly as long as `addresses` does
    /// and is reused the same way (decision 15).
    messages: []datagram_module.Message,
    messages_used: u32,
    /// The reserve every datagram group of this loop uses, set by `provide_datagram_buffers`.
    /// One loop serves one shape, so the prefix a reap subtracts is a constant it already holds
    /// rather than a lookup per completion (decision 15).
    datagram_group: core.datagram.GroupOptions,
    /// `core.datagram.prefix_bytes(datagram_group)`, held here because the reap subtracts it from
    /// every datagram completion and must not recompute it per event.
    datagram_prefix: i32,
    registry: ?*Registry,
    /// The provided-buffer groups `provide_buffers` named, by group id.
    groups: [core.constants.buffer_groups_max]buffers.Group,
    buffers_registered: bool,

    pub const Options = struct {
        /// The most operations in flight, which is the slots in the table:
        /// [1, core.constants.operations_max].
        operations: u32,
        /// Submission ring entries, a power of two in [1, constants.entries_max], or 0 for the
        /// default: `operations` rounded up to a power of two and capped at `entries_max`. One
        /// tick submits at most this many operations; the rest wait for the next.
        entries: u16 = 0,
        /// How often the loop measures an operation (decision 9, rule 2).
        sampling: core.statistics.Options = .{},
        /// This loop's id among the loops of `registry`.
        id: core.LoopId = 0,
        /// Where loops find each other's rings. Null for a loop that posts to none and that
        /// none posts to.
        registry: ?*Registry = null,
        /// **Checked and ignored** (decision 18). The kernel performs `read`, `write` and
        /// `fdatasync` without a thread here, which is the whole point of this backend, so there is
        /// nothing to hand out and no policy to apply. It is in the options so that a caller's
        /// options are the same on every backend, as `entries` is on the others. `init` checks it
        /// with `offload` and `offload_memory` as kqueue and epoll do
        /// (`core.offload.assert_options`), so options that halt there halt here.
        file_policy: core.offload.FilePolicy = .refuse,
        /// Checked and ignored, for the same reason as `file_policy`: required when `file_policy`
        /// is `offload`, and refused otherwise.
        offload: ?core.offload.Offload = null,
        /// Checked and ignored, for the same reason as `file_policy`. This backend holds no ring for
        /// an offload and asks for no memory for one, but under the `offload` policy it requires
        /// `core.offload.memory_bytes(offload.?.workers)` bytes, as epoll does.
        offload_memory: []align(core.layout.memory_alignment) u8 = &.{},
    };

    /// The submission ring entries `options` asks for: its own, or the default derived from
    /// `operations` when it names none.
    pub fn entries_of(options: Options) u16 {
        if (options.entries != 0) return options.entries;
        const wanted: u32 = @min(options.operations, constants.entries_max);
        return @intCast(std.math.ceilPowerOfTwoAssert(u32, wanted));
    }

    /// The bytes of memory `init` needs for `options`, aligned to `core.layout.memory_alignment`.
    pub fn memory_bytes(options: Options) usize {
        var layout: Layout = .{};
        _ = layout.add(Slot, options.operations);
        _ = layout.add(TimerHeap.Entry, options.operations);
        _ = layout.add(u64, options.operations);
        _ = layout.add(Handle, HandleQueue.capacity_for(options.operations));
        _ = layout.add(address.Storage, entries_of(options));
        _ = layout.add(datagram_module.Message, entries_of(options));
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
        loop.ring = try ring_module.Ring.init(entries_of(options));
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
        core.offload.assert_options(options.file_policy, options.offload, options.offload_memory);
        var layout: Layout = .{};
        const slots = layout.take(memory, Slot, options.operations);
        const entries = layout.take(memory, TimerHeap.Entry, options.operations);
        const starts = layout.take(memory, u64, options.operations);
        const handles = layout.take(memory, Handle, HandleQueue.capacity_for(options.operations));
        loop.addresses = layout.take(memory, address.Storage, entries_of(options));
        loop.messages = layout.take(memory, datagram_module.Message, entries_of(options));
        assert(layout.bytes == memory_bytes(options));
        loop.tables.init(slots, entries, starts, .{
            .id = options.id,
            .sampling = options.sampling,
        });
        loop.cancels.init(handles);
        loop.addresses_used = 0;
        loop.messages_used = 0;
        loop.datagram_group = .{};
        loop.datagram_prefix = @intCast(core.datagram.prefix_bytes(.{}));
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

    /// The monotonic clock in nanoseconds, as the last `tick` read it: at its start, or after its
    /// wait when it waited. Timers expire against this reading. The next tick arms a timer
    /// submitted now at that tick's own reading plus its `after_ns`, so the timer fires no earlier
    /// than this reading plus its `after_ns`. 0 until the first tick. Reading it makes no system
    /// call.
    pub fn now_ns(loop: *const Loop) u64 {
        return loop.tables.now_ns;
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

    /// A buffer group for datagrams (decision 15). The reserve in front of each datagram is
    /// chosen here, once, so a reap subtracts a constant the loop already holds and a fourth
    /// control message later costs no caller a layout change. `provide_buffers` is untouched, so
    /// no stream caller gains a precondition.
    ///
    /// One loop serves one datagram shape: a second group with a different reserve would make
    /// the prefix a per-completion lookup, which is what the constant exists to avoid.
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
        loop.datagram_prefix = @intCast(core.datagram.prefix_bytes(group));
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
    core.surface.check_remote(Remote);
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
    _ = remote_module;
    _ = ring_module;
    _ = submit_module;
    _ = sync;
    _ = tick_module;
    _ = @import("uring_reap_test.zig");
    _ = @import("uring_submit_test.zig");
    _ = @import("uring_loop_test.zig");
}

test "entries default to the operations rounded up to a power of two, capped at the ring's most" {
    try std.testing.expectEqual(@as(u16, 1), Loop.entries_of(.{ .operations = 1 }));
    try std.testing.expectEqual(@as(u16, 1024), Loop.entries_of(.{ .operations = 1000 }));
    try std.testing.expectEqual(@as(u16, 1024), Loop.entries_of(.{ .operations = 1024 }));
    try std.testing.expectEqual(constants.entries_max, Loop.entries_of(.{ .operations = 1 << 20 }));
    // A caller that names a count keeps it.
    try std.testing.expectEqual(@as(u16, 8), Loop.entries_of(.{ .operations = 1000, .entries = 8 }));
}
