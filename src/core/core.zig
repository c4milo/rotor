//! The `core` module: what every backend shares (decision 1). The types the caller sees
//! (`Operation`, `Event`, `Handle`), the record of an in-flight operation (`Slot`) with its table,
//! the timer heap, the queue of events a loop produces itself, the list of declarations every
//! backend carries, the seeded generator the property tests draw from, and the named limits. It
//! imports nothing but std and reads no clock.
pub const constants = @import("constants.zig");
pub const event = @import("event.zig");
pub const event_queue = @import("event_queue.zig");
pub const handle = @import("handle.zig");
pub const layout = @import("layout.zig");
pub const operation = @import("operation.zig");
pub const random = @import("random.zig");
pub const slot = @import("slot.zig");
pub const slot_list = @import("slot_list.zig");
pub const slot_table = @import("slot_table.zig");
pub const surface = @import("surface.zig");
pub const timer_heap = @import("timer_heap.zig");

pub const Address = operation.Address;
pub const Code = event.Code;
pub const Descriptor = operation.Descriptor;
pub const Error = event.Error;
pub const Event = event.Event;
pub const Handle = handle.Handle;
pub const LoopId = operation.LoopId;
pub const Message = operation.Message;
pub const Operation = operation.Operation;
pub const Slot = slot.Slot;

test {
    _ = constants;
    _ = event;
    _ = event_queue;
    _ = handle;
    _ = layout;
    _ = operation;
    _ = random;
    _ = slot;
    _ = slot_list;
    _ = slot_table;
    _ = surface;
    _ = timer_heap;
}
