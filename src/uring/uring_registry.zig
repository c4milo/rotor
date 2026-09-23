//! `Registry`: where the loops of one process find each other's rings, so a `post` can name its
//! target by `LoopId` (decision 4). One per process, owned by the application, handed to every
//! loop at init. It is the one structure two loops share: each entry is written by the loop it
//! belongs to, at init and at deinit, and read by the loops that post to it, so an atomic word
//! per entry is all the coordination it needs. No message passes through it.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");

/// The entry of a loop that has not started or has stopped, and of a `Remote`: the values the
/// readiness backends' registry uses, which `core/mailbox.zig` defines and explains.
pub const descriptor_none = core.mailbox.descriptor_none;
pub const descriptor_remote = core.mailbox.descriptor_remote;

pub const Registry = struct {
    descriptors: [core.constants.loops_max]std.atomic.Value(core.Descriptor),
    /// How many loops the application said it runs. A `post` to an id at or above it finds no
    /// loop.
    loop_count: u16,

    /// io_uring carries a message itself, so this registry needs no memory of the caller's. The
    /// call exists so that an application sizes and initialises the registry the same way on
    /// every backend: the kqueue backend's holds the mailboxes.
    pub fn memory_bytes(loop_count: u16) usize {
        assert(loop_count >= 1);
        assert(loop_count <= core.constants.loops_max);
        return 0;
    }

    pub fn init(
        registry: *Registry,
        memory: []align(core.layout.memory_alignment) u8,
        loop_count: u16,
    ) void {
        assert(memory.len >= memory_bytes(loop_count));
        for (&registry.descriptors) |*descriptor| descriptor.* = .init(descriptor_none);
        registry.loop_count = loop_count;
    }

    pub fn loops(registry: *const Registry) u16 {
        return registry.loop_count;
    }

    /// Publishes the ring of loop `id`. The id must be free: two loops with one id is a
    /// programmer error.
    pub fn set(registry: *Registry, id: core.LoopId, descriptor: core.Descriptor) void {
        assert(id < registry.loop_count);
        assert(descriptor >= 0);
        const previous = registry.descriptors[id].swap(descriptor, .release);
        assert(previous == descriptor_none);
    }

    /// A `Remote` claims `id` at init: it publishes no ring, because it receives nothing, and the
    /// sentinel is what makes a second claim on one id halt (decision 4).
    pub fn set_remote(registry: *Registry, id: core.LoopId) void {
        assert(id < registry.loop_count);
        const previous = registry.descriptors[id].swap(descriptor_remote, .release);
        assert(previous == descriptor_none);
    }

    pub fn clear(registry: *Registry, id: core.LoopId) void {
        assert(id < core.constants.loops_max);
        const previous = registry.descriptors[id].swap(descriptor_none, .release);
        // A loop publishes its ring and a `Remote` publishes the sentinel. Either way the id was
        // claimed, and withdrawing one that was not is a programmer error.
        assert(previous != descriptor_none);
    }

    /// The ring of loop `id`, or `descriptor_none`: for a loop that has not started or has
    /// stopped, and for an id the application never said it runs.
    pub fn get(registry: *const Registry, id: core.LoopId) core.Descriptor {
        assert(id < core.constants.loops_max);
        if (id >= registry.loop_count) return descriptor_none;
        return registry.descriptors[id].load(.acquire);
    }
};

const testing = std.testing;

test "a registry starts empty, publishes a ring and forgets it" {
    var registry: Registry = undefined;
    var memory: [Registry.memory_bytes(4)]u8 align(core.layout.memory_alignment) = undefined;
    registry.init(&memory, 4);
    try testing.expectEqual(@as(u16, 4), registry.loops());
    try testing.expectEqual(descriptor_none, registry.get(0));
    try testing.expectEqual(descriptor_none, registry.get(core.constants.loops_max - 1));
    registry.set(3, 17);
    try testing.expectEqual(@as(core.Descriptor, 17), registry.get(3));
    try testing.expectEqual(descriptor_none, registry.get(2));
    registry.clear(3);
    try testing.expectEqual(descriptor_none, registry.get(3));
}
