//! The `core` module: what every backend shares (decision 1). The types the caller sees
//! (`Operation`, `Event`, `Handle`), the record of an in-flight operation (`Slot`) with its table
//! and its lists, the timer heap, the table of what waits for a descriptor, the layout of a loop's
//! memory, the list of declarations every backend carries, the view a library holds of a shared
//! loop, the stall count and the heartbeat, the drain of a loop that is shutting down, the seeded
//! generator the property tests draw from, and the named limits. It imports std
//! and the switch of decision 8's class A assertions, and reads no clock.
pub const assertion_class = @import("assertion_class.zig");
pub const attempt = @import("attempt.zig");
pub const buffer_group = @import("buffer_group.zig");
pub const constants = @import("constants.zig");
pub const datagram = @import("datagram.zig");
pub const dispatch = @import("dispatch/dispatch.zig");
pub const datagram_split = @import("datagram_split.zig");
pub const errno = @import("errno.zig");
pub const event = @import("event.zig");
pub const file_call = @import("file_call.zig");
pub const handle = @import("handle.zig");
pub const inbox = @import("inbox.zig");
pub const layout = @import("layout.zig");
pub const mailbox = @import("mailbox.zig");
pub const offload = @import("offload.zig");
pub const operation = @import("operation.zig");
pub const random = @import("random.zig");
pub const remote = @import("remote.zig");
pub const shutdown = @import("shutdown.zig");
pub const shared_loop = @import("shared_loop.zig");
pub const shuffle = @import("shuffle.zig");
pub const slot = @import("slot.zig");
pub const slot_list = @import("slot_list.zig");
pub const slot_table = @import("slot_table.zig");
pub const spin = @import("spin.zig");
pub const stall = @import("stall.zig");
pub const statistics = @import("statistics.zig");
pub const surface = @import("surface.zig");
pub const sync = @import("sync.zig");
pub const tables = @import("tables.zig");
pub const tasks = @import("tasks.zig");
pub const tick_error = @import("tick_error.zig");
pub const timer_heap = @import("timer_heap.zig");
pub const waiters = @import("waiters.zig");

pub const Address = operation.Address;
pub const Code = event.Code;
pub const Completion = dispatch.Completion;
pub const Poller = dispatch.Poller;
pub const Task = tasks.Task;
pub const ScheduleError = tasks.ScheduleError;
pub const Descriptor = operation.Descriptor;
pub const Delivery = datagram.Delivery;
pub const Error = event.Error;
pub const Event = event.Event;
pub const Handle = handle.Handle;
pub const Heartbeat = stall.Heartbeat;
pub const LoopId = operation.LoopId;
pub const Message = operation.Message;
pub const Operation = operation.Operation;
pub const Slot = slot.Slot;
pub const Tables = tables.Tables;

test {
    _ = assertion_class;
    _ = attempt;
    _ = buffer_group;
    _ = constants;
    _ = datagram;
    _ = datagram_split;
    _ = dispatch;
    _ = @import("dispatch/dispatch_calls.zig");
    _ = @import("dispatch/dispatch_test.zig");
    _ = errno;
    _ = event;
    _ = file_call;
    _ = handle;
    _ = inbox;
    _ = layout;
    _ = mailbox;
    _ = @import("mailbox_registry.zig");
    _ = @import("mailbox_registry_test.zig");
    _ = offload;
    _ = @import("offload_in_flight.zig");
    _ = operation;
    _ = @import("operation_test.zig");
    _ = random;
    _ = remote;
    _ = shutdown;
    _ = shared_loop;
    _ = shuffle;
    _ = slot;
    _ = slot_list;
    _ = slot_table;
    _ = spin;
    _ = stall;
    _ = statistics;
    _ = @import("statistics_test.zig");
    _ = surface;
    _ = sync;
    _ = tables;
    _ = @import("tables_test.zig");
    _ = tasks;
    _ = @import("tasks_test.zig");
    _ = tick_error;
    _ = timer_heap;
    _ = waiters;
    _ = @import("waiters_test.zig");
}
