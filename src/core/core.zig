//! The `core` module: what every backend shares (decision 1). The types the caller sees
//! (`Operation`, `Event`, `Handle`), the record of an in-flight operation (`Slot`) with its table
//! and its lists, the timer heap, the table of what waits for a descriptor, the layout of a loop's
//! memory, the list of declarations every backend carries, the port of decision 33, the stall
//! count and the heartbeat, the drain of a loop that is shutting down, the seeded generator the
//! property tests draw from, and the named limits. It imports std and the switch of decision 8's
//! class A assertions, and reads no clock.
//!
//! The records with callbacks, the pollers, the tasks, the scheduling groups, the cross-core calls
//! and the shared loop are the module `reactor`'s (decision 33). The core keeps the two types they
//! share with a plain loop, `WaitLimit` and the id `SchedulingGroup`, and declares them here, so
//! the compiler prints `core.WaitLimit` and `core.SchedulingGroup`.
const std = @import("std");

pub const assertion_class = @import("assertion_class.zig");
pub const attempt = @import("attempt.zig");
pub const buffer_group = @import("buffer_group.zig");
pub const constants = @import("constants.zig");
pub const datagram = @import("datagram.zig");
pub const datagram_split = @import("datagram_split.zig");
pub const errno = @import("errno.zig");
pub const event = @import("event.zig");
pub const file_call = @import("file_call.zig");
pub const handle = @import("handle.zig");
pub const inbox = @import("inbox.zig");
pub const layout = @import("layout.zig");
pub const loop_calls = @import("loop_calls.zig");
pub const mailbox = @import("mailbox.zig");
pub const offload = @import("offload.zig");
pub const operation = @import("operation.zig");
pub const random = @import("random.zig");
pub const remote = @import("remote.zig");
pub const reserved = @import("reserved.zig");
pub const shutdown = @import("shutdown.zig");
pub const shuffle = @import("shuffle.zig");
pub const slot = @import("slot.zig");
pub const slot_list = @import("slot_list.zig");
pub const slot_table = @import("slot_table.zig");
pub const spin = @import("spin.zig");
pub const stall = @import("stall.zig");
pub const stall_watch = @import("stall_watch.zig");
pub const statistics = @import("statistics.zig");
pub const surface = @import("surface.zig");
pub const sync = @import("sync.zig");
pub const tables = @import("tables/tables.zig");
pub const tick_error = @import("tick_error.zig");
pub const tick_share = @import("tick_share.zig");
pub const timer_heap = @import("timer_heap.zig");
pub const waiters = @import("waiters.zig");

/// How long a tick may wait, on the loop's clock (`now_ns`). A program bounds the wait of a plain
/// loop with `Loop.wait_until`, a poller of the reactor returns one (decision 29), and a host reads
/// one from `wait_limit`. Size 8 B: it comes back in one register.
pub const WaitLimit = enum(u64) {
    /// Work is left: do not wait. Decision 26's `true`.
    now = 0,
    /// Nothing here bounds the wait. Decision 26's `false`.
    none = std.math.maxInt(u64),
    _,

    /// Wait until `at_ns` at the latest. `.at(0)` is `.now`, and `.at(maxInt(u64))` is `.none`.
    /// Each value means one thing, and no value is wrong, so `at` has no assertion.
    pub fn at(at_ns: u64) WaitLimit {
        return @enumFromInt(at_ns);
    }
};

/// A task queue with shares on one loop (decision 30). Only the reactor's
/// `reserve_scheduling_group` and `NamedSchedulingGroup.group` make an id other than `.default`,
/// so a literal fails to compile. The stall line names the group of a stuck task with it
/// (`Statistics.Stall.group`), so the core keeps the id. Size 1 B.
pub const SchedulingGroup = enum(u8) { default = 0, _ };

comptime {
    std.debug.assert(@sizeOf(WaitLimit) == 8);
    std.debug.assert(@sizeOf(SchedulingGroup) == 1);
}

pub const Address = operation.Address;
pub const Code = event.Code;
pub const BufferGroup = buffer_group.BufferGroup;
pub const Descriptor = operation.Descriptor;
pub const Delivery = datagram.Delivery;
pub const Error = event.Error;
pub const Event = event.Event;
pub const Handle = handle.Handle;
pub const Heartbeat = stall.Heartbeat;
pub const HeartbeatView = stall_watch.HeartbeatView;
pub const LoopId = operation.LoopId;
pub const Message = operation.Message;
pub const Operation = operation.Operation;
pub const Slot = slot.Slot;
pub const Tables = tables.Tables;

const testing = std.testing;

test "a limit at the two ends of the clock is now and none" {
    try testing.expectEqual(WaitLimit.now, WaitLimit.at(0));
    try testing.expectEqual(WaitLimit.none, WaitLimit.at(std.math.maxInt(u64)));
    try testing.expectEqual(@as(u64, 5), @intFromEnum(WaitLimit.at(5)));
}

test "the core prints the names of the two types it declares" {
    try testing.expectEqualStrings("core.WaitLimit", @typeName(WaitLimit));
    try testing.expectEqualStrings("core.SchedulingGroup", @typeName(SchedulingGroup));
}

test {
    _ = assertion_class;
    _ = attempt;
    _ = buffer_group;
    _ = constants;
    _ = datagram;
    _ = datagram_split;
    _ = errno;
    _ = event;
    _ = file_call;
    _ = handle;
    _ = inbox;
    _ = @import("inbox_test.zig");
    _ = layout;
    _ = loop_calls;
    _ = mailbox;
    _ = @import("mailbox_registry.zig");
    _ = @import("mailbox_registry_test.zig");
    _ = offload;
    _ = @import("offload_in_flight.zig");
    _ = @import("offload_in_flight_close.zig");
    _ = operation;
    _ = @import("operation_test.zig");
    _ = random;
    _ = remote;
    _ = reserved;
    _ = shutdown;
    _ = shuffle;
    _ = slot;
    _ = slot_list;
    _ = slot_table;
    _ = spin;
    _ = stall;
    _ = stall_watch;
    _ = statistics;
    _ = @import("statistics_test.zig");
    _ = surface;
    _ = sync;
    _ = tables;
    _ = @import("tables/tables_test.zig");
    _ = @import("tables/tables_finish.zig");
    _ = @import("tables/tables_deadline.zig");
    _ = tick_error;
    _ = tick_share;
    _ = timer_heap;
    _ = waiters;
    _ = @import("waiters_test.zig");
}
