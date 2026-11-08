//! The tests of `uring_ring.zig` that need only the public `Ring`: setup, a wait, and a no-op
//! entry. The tests of the enter's private parts stay in that file.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const ring_module = @import("uring_ring.zig");

const Ring = ring_module.Ring;
const Entered = ring_module.Entered;
const testing = std.testing;

test "the files that fill an entry set its opcode only through set_opcode" {
    // An opcode set any other way escapes the compile-time check, and `init` would not probe it.
    const sources = [_][]const u8{
        @embedFile("uring_submit.zig"),
        @embedFile("uring_datagram.zig"),
        @embedFile("uring_remote.zig"),
    };
    for (sources) |source| try testing.expect(std.mem.indexOf(u8, source, ".opcode = ") == null);
}

test "init refuses on a host without io_uring" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, Ring.init(8));
}

test "a ring sets up, reports its space, and enters with nothing to do" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ring = try Ring.init(8);
    defer ring.deinit();
    try testing.expectEqual(@as(u32, 8), ring.sqe_space());
    try testing.expectEqual(@as(u32, 0), ring.cq_ready());
    try testing.expectEqual(Entered.submitted, try ring.enter(null));
    try testing.expect(ring.descriptor() >= 0);
}

test "a wait with nothing in flight returns when its timeout passes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ring = try Ring.init(8);
    defer ring.deinit();
    try testing.expectEqual(Entered.submitted, try ring.enter(core.constants.ns_per_ms));
    try testing.expectEqual(@as(u32, 0), ring.cq_ready());
}

test "a no-op entry completes with the user data it carried" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ring = try Ring.init(8);
    defer ring.deinit();
    const sqe = ring.get_sqe().?;
    sqe.prep_nop();
    sqe.user_data = 0xABCD;
    try testing.expectEqual(@as(u32, 7), ring.sqe_space());
    try testing.expectEqual(Entered.submitted, try ring.enter(core.constants.ns_per_s));
    try testing.expectEqual(@as(u32, 1), ring.cq_ready());
    try testing.expectEqual(@as(u64, 0xABCD), ring.cqe_at(0).user_data);
    try testing.expectEqual(@as(i32, 0), ring.cqe_at(0).res);
    ring.cq_advance(1);
    try testing.expectEqual(@as(u32, 0), ring.cq_ready());
}
