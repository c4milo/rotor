//! The `core` module: what every backend shares (decision 1). The types the caller sees
//! (`Operation`, `Event`, `Handle`), the record of an in-flight operation (`Slot`) with its table
//! and its lists, the timer heap, the table of what waits for a descriptor, the layout of a loop's
//! memory, the list of declarations every backend carries, the drain of a loop that is shutting
//! down, the seeded generator the property tests draw from, and the named limits. It imports
//! nothing but std and reads no clock.
pub const attempt = @import("attempt.zig");
pub const buffer_group = @import("buffer_group.zig");
pub const constants = @import("constants.zig");
pub const datagram = @import("datagram.zig");
pub const errno = @import("errno.zig");
pub const event = @import("event.zig");
pub const file_call = @import("file_call.zig");
pub const handle = @import("handle.zig");
pub const layout = @import("layout.zig");
pub const mailbox = @import("mailbox.zig");
pub const offload = @import("offload.zig");
pub const operation = @import("operation.zig");
pub const random = @import("random.zig");
pub const remote = @import("remote.zig");
pub const shutdown = @import("shutdown.zig");
pub const slot = @import("slot.zig");
pub const slot_list = @import("slot_list.zig");
pub const slot_table = @import("slot_table.zig");
pub const statistics = @import("statistics.zig");
pub const surface = @import("surface.zig");
pub const sync = @import("sync.zig");
pub const tables = @import("tables.zig");
pub const timer_heap = @import("timer_heap.zig");
pub const waiters = @import("waiters.zig");

pub const Address = operation.Address;
pub const Code = event.Code;
pub const Descriptor = operation.Descriptor;
pub const Delivery = datagram.Delivery;
pub const Error = event.Error;
pub const Event = event.Event;
pub const Handle = handle.Handle;
pub const LoopId = operation.LoopId;
pub const Message = operation.Message;
pub const Operation = operation.Operation;
pub const Slot = slot.Slot;
pub const Tables = tables.Tables;

test {
    _ = attempt;
    _ = buffer_group;
    _ = constants;
    _ = datagram;
    _ = errno;
    _ = event;
    _ = file_call;
    _ = handle;
    _ = layout;
    _ = mailbox;
    _ = offload;
    _ = operation;
    _ = random;
    _ = remote;
    _ = shutdown;
    _ = slot;
    _ = slot_list;
    _ = slot_table;
    _ = statistics;
    _ = @import("statistics_test.zig");
    _ = surface;
    _ = sync;
    _ = tables;
    _ = @import("tables_test.zig");
    _ = timer_heap;
    _ = waiters;
    _ = @import("waiters_test.zig");
}
