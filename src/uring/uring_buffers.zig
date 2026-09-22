//! Buffers the kernel knows ahead of an operation (decision 3, sources 1 and 2). Both calls run
//! once, before use, and never per operation.
//!
//! - `register`: buffers the kernel pins once, so a transfer that names one by index skips the
//!   pinning of its pages.
//! - `provide`: a group of equal buffers the kernel picks from itself, which is what a multishot
//!   receive needs: one submission, many receives, each event naming the buffer that holds its
//!   bytes. The caller reads the bytes and gives the buffer back with `give_back`, which writes
//!   one ring entry and makes no system call.
//!
//! All memory is the caller's. The ring of a group sits in memory aligned to
//! `constants.buffer_ring_alignment`.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const IoUring = linux.IoUring;
const core = @import("core");
const constants = @import("constants.zig");
const uring = @import("uring.zig");

const Loop = uring.Loop;

/// The alignment of the memory a group's ring sits in.
/// The alignment of a group's memory: what the kernel's buffer ring needs, and it sits at the
/// front of the memory.
pub const group_alignment = constants.buffer_ring_alignment;

pub const RegisterError = error{ SystemResources, Unexpected };
/// `Unsupported`: the kernel refused the buffer ring itself. io_uring answers EINVAL for that, and
/// for a misaligned ring and a count that is not a power of two; both of those are now assertions,
/// so what is left is a kernel that cannot do provided buffer rings at all. Before this the three
/// arrived as one `Unexpected`, and a consumer spent a day on the alignment one (2026-09-22).
///
/// The kqueue backend never enters the kernel here and so never answers `Unsupported`. The set is
/// the same on both because a caller writes one handler for both (decision 1).
pub const ProvideError = error{ Unsupported, SystemResources, Unexpected };

/// One provided-buffer group. `ring` is null until `provide` names the group.
pub const Group = struct {
    ring: ?*align(constants.buffer_ring_alignment) linux.io_uring_buf_ring,
    buffers: []u8,
    buffer_bytes: u32,
    /// Buffers in the group, a power of two, so the ring's wrap is a mask.
    count: u16,

    pub const none: Group = .{ .ring = null, .buffers = &.{}, .buffer_bytes = 0, .count = 0 };

    /// The bytes of buffer `buffer_id`.
    pub fn bytes_of(group: *const Group, buffer_id: u16) []u8 {
        assert(group.ring != null);
        assert(buffer_id < group.count);
        const start = @as(usize, buffer_id) * group.buffer_bytes;
        return group.buffers[start..][0..group.buffer_bytes];
    }
};

/// The bytes of ring memory a group of `count` buffers needs.
pub fn ring_bytes(count: u16) usize {
    assert(count >= 1);
    assert(std.math.isPowerOfTwo(count));
    return @as(usize, count) * @sizeOf(linux.io_uring_buf);
}

/// Registers `buffers` with the kernel, once per loop. An operation names one by its index here
/// (`Operation.Buffer.registered`), and its bytes must lie inside it.
pub fn register(loop: *Loop, buffers: []const []u8) RegisterError!void {
    loop.assert_owner();
    assert(buffers.len >= 1);
    assert(buffers.len <= core.constants.registered_buffers_max);
    assert(!loop.buffers_registered);
    var vectors: [core.constants.registered_buffers_max]std.posix.iovec = undefined;
    for (buffers, vectors[0..buffers.len]) |buffer, *vector| {
        assert(buffer.len >= 1);
        vector.* = .{ .base = buffer.ptr, .len = buffer.len };
    }
    loop.ring.io.register_buffers(vectors[0..buffers.len]) catch |err| return switch (err) {
        error.SystemResources, error.UserFdQuotaExceeded => error.SystemResources,
        else => error.Unexpected,
    };
    loop.buffers_registered = true;
}

/// The bytes a group of `count` buffers of `buffer_bytes` needs: the kernel's ring, then the
/// buffers, so buffer 0 starts `ring_bytes(count)` bytes in.
pub fn group_bytes(count: u16, buffer_bytes: u32) usize {
    assert(buffer_bytes >= 1);
    return ring_bytes(count) + @as(usize, count) * buffer_bytes;
}

/// Makes group `group_id` of this loop out of `memory`: `count` buffers of `buffer_bytes` each,
/// every one handed to the kernel. `memory` holds `group_bytes(count, buffer_bytes)` bytes aligned
/// to `group_alignment`, the kernel's ring first and the buffers after it, and stays the loop's
/// until `deinit`.
pub fn provide(
    loop: *Loop,
    group_id: u16,
    memory: []align(group_alignment) u8,
    count: u16,
    buffer_bytes: u32,
) ProvideError!void {
    loop.assert_owner();
    assert(group_id < core.constants.buffer_groups_max);
    assert(loop.groups[group_id].ring == null);
    // The parameter's type says `align(group_alignment)`, which the compiler checks at the call
    // site and cannot check for memory whose alignment a caller asserted rather than declared: an
    // `@alignCast` in a build without safety checks passes anything. rotor's assertions stay on in
    // production (CLAUDE.md non-negotiable 1), so this catches what the caller's build did not.
    // Without it a misaligned group cost a consumer a day: io_uring answers EINVAL, which was
    // mapped to `Unexpected`, and the kqueue backend never enters the kernel at all and would read
    // its ring through a misaligned pointer (2026-09-22).
    assert(std.mem.isAligned(@intFromPtr(memory.ptr), group_alignment));
    assert(count >= 1);
    assert(count <= core.constants.buffers_per_group_max);
    assert(memory.len >= group_bytes(count, buffer_bytes));
    const ring_memory = memory[0..ring_bytes(count)];
    const buffers = memory[ring_bytes(count)..][0 .. @as(usize, count) * buffer_bytes];

    var registration = std.mem.zeroInit(linux.io_uring_buf_reg, .{
        .ring_addr = @intFromPtr(ring_memory.ptr),
        .ring_entries = count,
        .bgid = group_id,
        .flags = .{ .inc = false },
    });
    const rc = linux.io_uring_register(loop.ring.io.fd, .REGISTER_PBUF_RING, &registration, 1);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOMEM => return error.SystemResources,
        // Every EINVAL this call can answer for a reason rotor caused is an assertion above, so one
        // that arrives here is the kernel declining provided buffer rings.
        .INVAL => return error.Unsupported,
        else => return error.Unexpected,
    }

    const group = &loop.groups[group_id];
    group.* = .{
        .ring = @ptrCast(ring_memory.ptr),
        .buffers = buffers,
        .buffer_bytes = buffer_bytes,
        .count = count,
    };
    IoUring.buf_ring_init(group.ring.?);
    const mask = IoUring.buf_ring_mask(count);
    for (0..count) |index| {
        const buffer_id: u16 = @intCast(index);
        IoUring.buf_ring_add(group.ring.?, group.bytes_of(buffer_id), buffer_id, mask, buffer_id);
    }
    IoUring.buf_ring_advance(group.ring.?, count);
}

/// Hands buffer `buffer_id` of group `group_id` back to the kernel, after the caller has read the
/// bytes the receive event named. One ring entry written, and no system call.
pub fn give_back(loop: *Loop, group_id: u16, buffer_id: u16) void {
    loop.assert_owner();
    assert(group_id < core.constants.buffer_groups_max);
    const group = &loop.groups[group_id];
    const ring = group.ring.?;
    const mask = IoUring.buf_ring_mask(group.count);
    IoUring.buf_ring_add(ring, group.bytes_of(buffer_id), buffer_id, mask, 0);
    IoUring.buf_ring_advance(ring, 1);
}

const testing = std.testing;

test "a group cuts its memory into equal buffers and a ring entry is 16 bytes" {
    var memory: [64]u8 = undefined;
    var ring: linux.io_uring_buf_ring align(constants.buffer_ring_alignment) = undefined;
    const group: Group = .{ .ring = &ring, .buffers = &memory, .buffer_bytes = 16, .count = 4 };
    try testing.expectEqual(@intFromPtr(&memory) + 32, @intFromPtr(group.bytes_of(2).ptr));
    try testing.expectEqual(@as(usize, 16), group.bytes_of(3).len);
    try testing.expectEqual(@as(usize, 64), ring_bytes(4));
    try testing.expectEqual(@as(usize, 16), ring_bytes(1));
}
