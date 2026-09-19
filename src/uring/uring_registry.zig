//! `Registry`: where the loops of one process find each other's rings, so a `post` can name its
//! target by `LoopId` (decision 4). One per process, owned by the application, handed to every
//! loop at init. It is the one structure two loops share: each entry is written by the loop it
//! belongs to, at init and at deinit, and read by the loops that post to it, so an atomic word
//! per entry is all the coordination it needs. No message passes through it.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");

/// The entry of a loop that has not started or has stopped.
pub const descriptor_none: core.Descriptor = -1;

pub const Registry = struct {
    descriptors: [core.constants.loops_max]std.atomic.Value(core.Descriptor),

    pub fn init(registry: *Registry) void {
        for (&registry.descriptors) |*descriptor| descriptor.* = .init(descriptor_none);
    }

    /// Publishes the ring of loop `id`. The id must be free: two loops with one id is a
    /// programmer error.
    pub fn set(registry: *Registry, id: core.LoopId, descriptor: core.Descriptor) void {
        assert(id < core.constants.loops_max);
        assert(descriptor >= 0);
        const previous = registry.descriptors[id].swap(descriptor, .release);
        assert(previous == descriptor_none);
    }

    pub fn clear(registry: *Registry, id: core.LoopId) void {
        assert(id < core.constants.loops_max);
        const previous = registry.descriptors[id].swap(descriptor_none, .release);
        assert(previous >= 0);
    }

    /// The ring of loop `id`, or `descriptor_none`.
    pub fn get(registry: *const Registry, id: core.LoopId) core.Descriptor {
        assert(id < core.constants.loops_max);
        return registry.descriptors[id].load(.acquire);
    }
};

const testing = std.testing;

test "a registry starts empty, publishes a ring and forgets it" {
    var registry: Registry = undefined;
    registry.init();
    try testing.expectEqual(descriptor_none, registry.get(0));
    try testing.expectEqual(descriptor_none, registry.get(core.constants.loops_max - 1));
    registry.set(3, 17);
    try testing.expectEqual(@as(core.Descriptor, 17), registry.get(3));
    try testing.expectEqual(descriptor_none, registry.get(2));
    registry.clear(3);
    try testing.expectEqual(descriptor_none, registry.get(3));
}
