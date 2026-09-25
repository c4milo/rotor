//! The pure half of the submit path under test: a slot in, a submission entry out, on every host.
const std = @import("std");
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const submit_module = @import("uring_submit.zig");

const Slot = core.Slot;
const Operation = core.Operation;
const Extra = submit_module.Extra;
const prepare = submit_module.prepare;
const prepare_cancel = submit_module.prepare_cancel;
const prepare_close_cancel = submit_module.prepare_close_cancel;

const testing = std.testing;

/// The `user_data` the tests prepare with: index 5, generation 3.
const test_user_data: u64 = (3 << 32) | 5;

fn filled(operation: Operation) Slot {
    var slot: Slot = std.mem.zeroes(Slot);
    slot.state = .queued;
    slot.generation = core.constants.generation_first;
    slot.next = core.slot.next_none;
    slot.fill(&operation);
    return slot;
}

fn prepared(operation: Operation, extra: Extra) linux.io_uring_sqe {
    var sqe: linux.io_uring_sqe = undefined;
    @memset(std.mem.asBytes(&sqe), 0xAA);
    const slot = filled(operation);
    prepare(&sqe, &slot, test_user_data, extra);
    return sqe;
}

test "prepare writes every field, whatever the entry held before" {
    const sqe = prepared(.{ .user_data = 1, .kind = .{ .close = .{ .descriptor = 9 } } }, .{});
    var expected = std.mem.zeroes(linux.io_uring_sqe);
    expected.opcode = .CLOSE;
    expected.fd = 9;
    expected.user_data = test_user_data;
    try testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&sqe));
}

test "a read names its buffer, length and offset, and a registered one its buffer index" {
    var buffer: [4096]u8 = undefined;
    const plain = prepared(.{ .user_data = 1, .kind = .{ .read = .{
        .file = 4,
        .buffer = .{ .bytes = &buffer },
        .offset = 8192,
    } } }, .{});
    try testing.expectEqual(linux.IORING_OP.READ, plain.opcode);
    try testing.expectEqual(@as(i32, 4), plain.fd);
    try testing.expectEqual(@intFromPtr(&buffer), plain.addr);
    try testing.expectEqual(@as(u32, 4096), plain.len);
    try testing.expectEqual(@as(u64, 8192), plain.off);

    const fixed = prepared(.{ .user_data = 1, .kind = .{ .write = .{
        .file = 4,
        .buffer = .{ .bytes = &buffer, .registered = 7 },
        .offset = 0,
    } } }, .{});
    try testing.expectEqual(linux.IORING_OP.WRITE_FIXED, fixed.opcode);
    try testing.expectEqual(@as(u16, 7), fixed.buf_index);
}

test "a send never raises SIGPIPE and an fdatasync asks for data only" {
    const bytes = [_]u8{ 1, 2, 3 };
    const send = prepared(.{ .user_data = 1, .kind = .{ .send = .{
        .socket = 6,
        .buffer = .{ .bytes = &bytes },
    } } }, .{});
    try testing.expectEqual(linux.IORING_OP.SEND, send.opcode);
    try testing.expectEqual(@as(u32, linux.MSG.NOSIGNAL), send.rw_flags);
    try testing.expectEqual(@as(u32, 3), send.len);

    const sync = prepared(.{ .user_data = 1, .kind = .{ .fdatasync = .{ .file = 6 } } }, .{});
    try testing.expectEqual(linux.IORING_OP.FSYNC, sync.opcode);
    try testing.expectEqual(@as(u32, linux.IORING_FSYNC_DATASYNC), sync.rw_flags);
}

test "a multishot accept and a multishot receive from a group set their flags" {
    const accept = prepared(.{ .user_data = 1, .kind = .{ .accept = .{
        .listener = 3,
        .multishot = true,
    } } }, .{});
    try testing.expectEqual(linux.IORING_OP.ACCEPT, accept.opcode);
    try testing.expectEqual(@as(u16, linux.IORING_ACCEPT_MULTISHOT), accept.ioprio);
    try testing.expectEqual(@as(u32, linux.SOCK.CLOEXEC), accept.rw_flags);

    const receive = prepared(.{ .user_data = 1, .kind = .{ .receive = .{
        .socket = 8,
        .target = .{ .group = 2 },
        .multishot = true,
    } } }, .{});
    try testing.expectEqual(linux.IORING_OP.RECV, receive.opcode);
    try testing.expectEqual(@as(u16, linux.IORING_RECV_MULTISHOT), receive.ioprio);
    try testing.expectEqual(@as(u8, linux.IOSQE_BUFFER_SELECT), receive.flags);
    try testing.expectEqual(@as(u16, 2), receive.buf_index);
    try testing.expectEqual(@as(u64, 0), receive.addr);
}

test "a registered descriptor's index rides in fd, with the fixed-file flag beside the others" {
    var bytes: [8]u8 = undefined;
    const plain = prepared(.{ .user_data = 1, .kind = .{ .fdatasync = .{ .file = 6 } } }, .{});
    try testing.expectEqual(@as(u8, 0), plain.flags);

    const sync = prepared(.{
        .user_data = 1,
        .descriptor_registered = true,
        .kind = .{ .fdatasync = .{ .file = 6 } },
    }, .{});
    try testing.expectEqual(linux.IORING_OP.FSYNC, sync.opcode);
    try testing.expectEqual(@as(i32, 6), sync.fd);
    try testing.expectEqual(@as(u8, linux.IOSQE_FIXED_FILE), sync.flags);

    // A receive from a group keeps its own flag: the two are or-ed, not assigned.
    const receive = prepared(.{ .user_data = 1, .descriptor_registered = true, .kind = .{
        .receive = .{ .socket = 2, .target = .{ .group = 1 }, .multishot = true },
    } }, .{});
    const both: u8 = linux.IOSQE_FIXED_FILE | linux.IOSQE_BUFFER_SELECT;
    try testing.expectEqual(both, receive.flags);
    try testing.expectEqual(@as(i32, 2), receive.fd);

    const send = prepared(.{ .user_data = 1, .descriptor_registered = true, .kind = .{
        .send = .{ .socket = 0, .buffer = .{ .bytes = &bytes } },
    } }, .{});
    try testing.expectEqual(@as(u8, linux.IOSQE_FIXED_FILE), send.flags);
    try testing.expectEqual(@as(i32, 0), send.fd);
}

test "a shutdown's how is the kernel's own value" {
    try testing.expectEqual(linux.SHUT.RD, @intFromEnum(Operation.How.receive));
    try testing.expectEqual(linux.SHUT.WR, @intFromEnum(Operation.How.send));
    try testing.expectEqual(linux.SHUT.RDWR, @intFromEnum(Operation.How.both));
    const sqe = prepared(.{ .user_data = 1, .kind = .{ .shutdown = .{
        .socket = 5,
        .how = .send,
    } } }, .{});
    try testing.expectEqual(linux.IORING_OP.SHUTDOWN, sqe.opcode);
    try testing.expectEqual(@as(u32, linux.SHUT.WR), sqe.len);
}

test "a wake is a MSG_RING that carries no message, whatever the entry held before" {
    var sqe: linux.io_uring_sqe = undefined;
    @memset(std.mem.asBytes(&sqe), 0xAA);
    submit_module.prepare_wake(&sqe, 11);
    var expected = std.mem.zeroes(linux.io_uring_sqe);
    expected.opcode = .MSG_RING;
    expected.fd = 11;
    expected.addr = @intFromEnum(linux.IORING_MSG_RING_COMMAND.DATA);
    // The target's completion and the sender's answer both carry the wake's `user_data`, which
    // names no operation, and the target's has result 0.
    expected.off = constants.user_data_wake;
    expected.user_data = constants.user_data_wake;
    try testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&sqe));
}

test "a connect names the kernel's form of the address and its length" {
    const address = core.Address.ipv4(.{ 127, 0, 0, 1 }, 80);
    const sqe = prepared(
        .{ .user_data = 1, .kind = .{ .connect = .{ .socket = 5, .address = &address } } },
        .{ .address = 0x1000, .address_len = 16 },
    );
    try testing.expectEqual(linux.IORING_OP.CONNECT, sqe.opcode);
    try testing.expectEqual(@as(u64, 0x1000), sqe.addr);
    try testing.expectEqual(@as(u64, 16), sqe.off);
}

test "a cancel names its target, and a close's cancel names the descriptor and is hard-linked" {
    var sqe: linux.io_uring_sqe = undefined;
    prepare_cancel(&sqe, test_user_data);
    try testing.expectEqual(linux.IORING_OP.ASYNC_CANCEL, sqe.opcode);
    try testing.expectEqual(test_user_data, sqe.addr);
    try testing.expectEqual(constants.user_data_cancel, sqe.user_data);

    prepare_close_cancel(&sqe, 12);
    try testing.expectEqual(@as(i32, 12), sqe.fd);
    const all_of_descriptor = linux.IORING_ASYNC_CANCEL_FD | linux.IORING_ASYNC_CANCEL_ALL;
    try testing.expectEqual(@as(u32, all_of_descriptor), sqe.rw_flags);
    try testing.expectEqual(@as(u8, linux.IOSQE_IO_HARDLINK), sqe.flags);
    try testing.expectEqual(constants.user_data_close_cancel, sqe.user_data);
}
