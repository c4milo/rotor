//! Descriptors the kernel knows ahead of an operation (decision 3, source 1). An operation that
//! names one by its index (`Operation.descriptor_registered`) skips the kernel's lookup in the
//! process's descriptor table, and the reference count that goes with it, on every operation.
//!
//! The call runs once, before use (decision 2). The kernel keeps a reference of its own to each
//! file, so a registered descriptor's file stays open until the loop's `deinit`, whatever the
//! process closes. A `close` names a descriptor of the process, and it still cancels what is in
//! flight for the file under a registered index: the kernel matches the file, not the number.
//! The registration call is `linux.io_uring_register` and not std's wrapper around it, because
//! that wrapper's error path names the host's `posix`, which does not compile for Darwin. The
//! rest of this backend calls the kernel the same way (`uring_ring.zig`).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const uring = @import("uring.zig");

const Loop = uring.Loop;

pub const RegisterError = error{ DescriptorInvalid, SystemResources, Unexpected };

/// Registers `descriptors` with the kernel, once per loop. An operation names one by its index
/// here, with `descriptor_registered` set. Fails with `DescriptorInvalid` when one is not open.
pub fn register(loop: *Loop, descriptors: []const core.Descriptor) RegisterError!void {
    loop.assert_owner();
    assert(loop.tables.descriptors_registered == 0);
    assert(descriptors.len >= 1);
    assert(descriptors.len <= core.constants.registered_descriptors_max);
    for (descriptors) |descriptor| assert(descriptor >= 0);
    const rc = linux.io_uring_register(
        loop.ring.descriptor(),
        .REGISTER_FILES,
        descriptors.ptr,
        @intCast(descriptors.len),
    );
    try code_of(linux.errno(rc));
    loop.tables.note_descriptors(descriptors.len);
}

/// The errno of the registration call. EBADF is the descriptor that is not open, which is the
/// one refusal a caller can act on; the rest name resources or a kernel that refused.
fn code_of(errno: linux.E) RegisterError!void {
    return switch (errno) {
        .SUCCESS => {},
        .BADF => error.DescriptorInvalid,
        .NOMEM, .MFILE => error.SystemResources,
        else => error.Unexpected,
    };
}

const testing = std.testing;

test "every errno of the registration call maps to its named error, on every host" {
    try code_of(.SUCCESS);
    try testing.expectError(error.DescriptorInvalid, code_of(.BADF));
    try testing.expectError(error.SystemResources, code_of(.NOMEM));
    try testing.expectError(error.SystemResources, code_of(.MFILE));
    // A ring that is already registering files, and anything else the kernel answers.
    try testing.expectError(error.Unexpected, code_of(.NXIO));
    try testing.expectError(error.Unexpected, code_of(.BUSY));
    try testing.expectError(error.Unexpected, code_of(.INVAL));
}
