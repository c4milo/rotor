//! Registered descriptors on epoll. The kernel has no table to register them in, so the loop keeps
//! one: `register` copies the list, and the flush swaps the index an operation names for the
//! descriptor registered there, before anything else reads it. Nothing is gained here and nothing
//! is claimed (decision 3, source 1 is about io_uring): the table exists so that one program runs
//! on every backend, which is what `kqueue_descriptors.zig` does for the same reason.
//!
//! On io_uring the kernel keeps a reference of its own to each registered file. Here the table
//! holds a number, so the rule the caller follows on every backend is the strictest one: a
//! registered descriptor stays open until the loop's `deinit`.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const epoll = @import("epoll.zig");

const Loop = epoll.Loop;
const Slot = core.Slot;

pub const RegisterError = error{ DescriptorInvalid, SystemResources, Unexpected };

/// Registers `descriptors`, once per loop. An operation names one by its index here, with
/// `descriptor_registered` set. Fails with `DescriptorInvalid` when one is not open, as io_uring
/// does.
pub fn register(loop: *Loop, descriptors: []const core.Descriptor) RegisterError!void {
    loop.assert_owner();
    assert(loop.tables.descriptors_registered == 0);
    assert(descriptors.len >= 1);
    assert(descriptors.len <= core.constants.registered_descriptors_max);
    for (descriptors) |descriptor| {
        assert(descriptor >= 0);
        const rc = linux.fcntl(descriptor, linux.F.GETFD, 0);
        if (linux.errno(rc) != .SUCCESS) return error.DescriptorInvalid;
    }
    @memcpy(loop.descriptors[0..descriptors.len], descriptors);
    loop.tables.note_descriptors(descriptors.len);
}

/// Swaps the index `slot` names for the descriptor registered there. `core.Tables.submit` checked
/// the index against what the loop registered.
pub fn resolve(loop: *const Loop, slot: *Slot) void {
    assert(slot.flags.descriptor_registered);
    const index: u32 = @intCast(slot.descriptor);
    assert(index < loop.tables.descriptors_registered);
    slot.descriptor = loop.descriptors[index];
    slot.flags.descriptor_registered = false;
    assert(slot.descriptor >= 0);
}
