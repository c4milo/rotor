//! The calls of the public `Loop` that name its buffers: registered buffers and descriptors
//! (decision 3), and provided-buffer groups (decisions 12, 15 and 29). Each one makes the call of
//! the same name on the backend this process runs. Split from `rotor_loop.zig` for the 500-line
//! limit. `Loop` declares each one, so a caller writes `loop.provide_buffers(...)`.
const core = @import("core");
const loop_module = @import("rotor_loop.zig");

const BufferGroup = core.buffer_group.BufferGroup;
const Loop = loop_module.Loop;
const ProvideError = Loop.ProvideError;
const RegisterError = Loop.RegisterError;
const group_alignment = loop_module.group_alignment;

/// Registers buffers once, before an operation names one by index (decision 3, source 1).
pub fn register_buffers(loop: *Loop, blocks: []const []u8) RegisterError!void {
    return switch (loop.inner) {
        inline else => |*inner| inner.register_buffers(blocks),
    };
}

/// Registers descriptors once, before an operation names one by index.
pub fn register_descriptors(loop: *Loop, descriptors: []const core.Descriptor) RegisterError!void {
    return switch (loop.inner) {
        inline else => |*inner| inner.register_descriptors(descriptors),
    };
}

/// Reserves the lowest buffer group id that no caller holds, and returns it (decision 29). A
/// library calls it once, at init, and keeps the id until the loop's `deinit`: no call gives it
/// back. Each call that names a group takes a `BufferGroup`, so a literal id fails to compile.
/// `BufferGroupsFull` when all `buffer_groups_max` ids are reserved.
pub fn reserve_buffer_group(loop: *Loop) error{BufferGroupsFull}!BufferGroup {
    return switch (loop.inner) {
        inline else => |*inner| inner.reserve_buffer_group(),
    };
}

/// Makes group `group` out of `memory`: `count` buffers of `buffer_bytes`, in one block of
/// `buffers.group_bytes(count, buffer_bytes)` bytes aligned to `buffers.group_alignment`. Halts on
/// a group that `reserve_buffer_group` did not give.
pub fn provide_buffers(
    loop: *Loop,
    group: BufferGroup,
    memory: []align(group_alignment) u8,
    count: u16,
    buffer_bytes: u32,
) ProvideError!void {
    return switch (loop.inner) {
        inline else => |*inner| inner.provide_buffers(group, memory, count, buffer_bytes),
    };
}

/// A buffer group for datagrams, with room in front of every buffer for what a datagram carries
/// (decision 15). One loop serves one datagram shape: the first call fixes it, and a later call
/// with a different `GroupOptions` halts.
pub fn provide_datagram_buffers(
    loop: *Loop,
    group: BufferGroup,
    memory: []align(group_alignment) u8,
    count: u16,
    buffer_bytes: u32,
    options: core.datagram.GroupOptions,
) ProvideError!void {
    return switch (loop.inner) {
        inline else => |*inner| inner.provide_datagram_buffers(
            group,
            memory,
            count,
            buffer_bytes,
            options,
        ),
    };
}

/// The datagram an event of group `group` names: the only reader of such a buffer.
pub fn datagram(loop: *const Loop, group: BufferGroup, event: core.Event) core.Delivery {
    return switch (loop.inner) {
        inline else => |*inner| inner.datagram(group, event),
    };
}

/// Returns a provided buffer to its group, after the caller has read it.
pub fn give_back_buffer(loop: *Loop, group: BufferGroup, buffer_id: u16) void {
    switch (loop.inner) {
        inline else => |*inner| inner.give_back_buffer(group, buffer_id),
    }
}

/// Takes group `group` back, so its memory is the caller's and the group may be provided again.
/// The id stays reserved. Halts while an operation in flight names the group (rotor issue 13).
pub fn release_buffers(loop: *Loop, group: BufferGroup) void {
    switch (loop.inner) {
        inline else => |*inner| inner.release_buffers(group),
    }
}

/// The bytes of the provided buffer a receive event named.
pub fn provided_buffer(loop: *const Loop, group: BufferGroup, buffer_id: u16) []u8 {
    return switch (loop.inner) {
        inline else => |*inner| inner.provided_buffer(group, buffer_id),
    };
}
