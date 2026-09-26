//! `Operation` under test: what each constructor builds, which kinds name a descriptor, and what
//! `assert_valid` passes. Split from `operation.zig` for the 500-line limit.
const std = @import("std");
const testing = std.testing;
const constants = @import("constants.zig");
const datagram = @import("datagram.zig");
const operation_module = @import("operation.zig");

const Address = operation_module.Address;
const Descriptor = operation_module.Descriptor;
const Operation = operation_module.Operation;

test "an address keeps its family, its port and its octets" {
    const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 8080);
    try testing.expectEqual(Address.Family.ipv4, loopback.family);
    try testing.expectEqual(@as(u16, 8080), loopback.port);
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, loopback.bytes[0..Address.ipv4_bytes]);
    try testing.expect(std.mem.allEqual(u8, loopback.bytes[Address.ipv4_bytes..], 0));
    var octets: [Address.ipv6_bytes]u8 = @splat(0);
    octets[Address.ipv6_bytes - 1] = 1;
    const loopback6 = Address.ipv6(octets, 443, 3);
    try testing.expectEqual(@as(u32, 3), loopback6.scope_id);
    try testing.expectEqual(@as(u8, 1), loopback6.bytes[Address.ipv6_bytes - 1]);
}

test "an operation names its code and a well-formed one passes assert_valid" {
    var bytes: [8]u8 = @splat(0);
    const operations = [_]Operation{
        .{ .user_data = 1, .kind = .{ .accept = .{ .listener = 3, .multishot = true } } },
        .{ .user_data = 2, .kind = .{ .receive = .{
            .socket = 4,
            .target = .{ .group = 0 },
            .multishot = true,
        } } },
        .{ .user_data = 3, .timeout_ns = constants.ns_per_s, .kind = .{ .read = .{
            .file = 5,
            .buffer = .{ .bytes = &bytes },
            .offset = 4096,
        } } },
        .{ .user_data = 4, .kind = .{ .timer = .{ .after_ns = constants.ns_per_ms } } },
        .{ .user_data = 5, .kind = .{ .post = .{
            .target = 1,
            .message = .{ .payload = 7, .tag = 9 },
        } } },
    };
    const codes = [_]Operation.Code{ .accept, .receive, .read, .timer, .post };
    const descriptors = [_]?Descriptor{ 3, 4, 5, null, null };
    for (&operations, codes, descriptors) |*operation, expected, named| {
        try testing.expectEqual(expected, operation.code());
        try testing.expectEqual(named, operation.descriptor());
        operation.assert_valid();
    }
}

test "every kind that names a descriptor may name a registered one, but a close" {
    var bytes: [8]u8 = @splat(0);
    const address = Address.ipv4(.{ 127, 0, 0, 1 }, 80);
    const last = constants.registered_descriptors_max - 1;
    const kinds = [_]Operation.Kind{
        .{ .accept = .{ .listener = last } },
        .{ .connect = .{ .socket = 1, .address = &address } },
        .{ .receive = .{ .socket = 2, .target = .{ .buffer = .{ .bytes = &bytes } } } },
        .{ .send = .{ .socket = 3, .buffer = .{ .bytes = &bytes } } },
        .{ .shutdown = .{ .socket = 4, .how = .both } },
        .{ .read = .{ .file = 5, .buffer = .{ .bytes = &bytes }, .offset = 0 } },
        .{ .write = .{ .file = 6, .buffer = .{ .bytes = &bytes }, .offset = 0 } },
        .{ .fdatasync = .{ .file = 0 } },
        .{ .fsync = .{ .file = 8 } },
    };
    const named = [_]Descriptor{ last, 1, 2, 3, 4, 5, 6, 0, 8 };
    for (kinds, named) |kind, index| {
        const operation: Operation = .{
            .user_data = 1,
            .descriptor_registered = true,
            .kind = kind,
        };
        operation.assert_valid();
        try testing.expectEqual(@as(?Descriptor, index), operation.descriptor());
    }
    const close: Operation = .{ .user_data = 1, .kind = .{ .close = .{ .descriptor = 7 } } };
    try testing.expectEqual(@as(?Descriptor, 7), close.descriptor());
    const nop: Operation = .{ .user_data = 1, .kind = .nop };
    try testing.expectEqual(@as(?Descriptor, null), nop.descriptor());
}

test "each constructor builds its kind with every field it was given, and nothing else set" {
    var bytes: [4]u8 = undefined;
    const address = Address.ipv4(.{ 127, 0, 0, 1 }, 53);
    const outbound: datagram.Outbound = .{
        .peer = address,
        .local = address,
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    const built = [_]Operation{
        Operation.accept(1, 3, true),
        Operation.connect(2, 4, &address),
        Operation.receive(3, 5, &bytes),
        Operation.receive_group(4, 6, 2),
        Operation.send(5, 7, bytes[0..3]),
        Operation.shutdown(6, 8, .send),
        Operation.close(7, 9),
        Operation.read(8, 10, &bytes, 4096),
        Operation.write(9, 11, bytes[0..2], 8192),
        Operation.fdatasync(10, 12),
        Operation.timer(11, 1_000, 500),
        Operation.post(12, 13, .{ .payload = 99, .tag = 7 }),
        Operation.receive_from(13, 14, 3),
        Operation.send_to(14, 15, bytes[0..1], &outbound),
        Operation.fsync(15, 16),
    };
    const codes = [_]Operation.Code{
        .accept, .connect, .receive,   .receive, .send, .shutdown,     .close,
        .read,   .write,   .fdatasync, .timer,   .post, .receive_from, .send_to,
        .fsync,
    };
    for (built, codes, 1..) |operation, expected, user_data| {
        try std.testing.expectEqual(expected, operation.code());
        try std.testing.expectEqual(@as(u64, user_data), operation.user_data);
        try std.testing.expectEqual(@as(u64, 0), operation.timeout_ns);
        try std.testing.expect(!operation.descriptor_registered);
    }
    try std.testing.expect(built[0].kind.accept.multishot and built[0].kind.accept.listener == 3);
    try std.testing.expect(built[1].kind.connect.socket == 4 and built[1].kind.connect.address == &address);
    try std.testing.expect(built[2].kind.receive.socket == 5 and !built[2].kind.receive.multishot);
    try std.testing.expect(built[2].kind.receive.target.buffer.bytes.len == 4);
    try std.testing.expect(built[3].kind.receive.multishot and built[3].kind.receive.target.group == 2);
    try std.testing.expect(built[4].kind.send.socket == 7 and built[4].kind.send.buffer.bytes.len == 3);
    try std.testing.expect(built[5].kind.shutdown.socket == 8 and built[5].kind.shutdown.how == .send);
    try std.testing.expect(built[6].kind.close.descriptor == 9);
    try std.testing.expect(built[7].kind.read.file == 10 and built[7].kind.read.offset == 4096);
    try std.testing.expect(built[8].kind.write.file == 11 and built[8].kind.write.buffer.bytes.len == 2);
    try std.testing.expect(built[8].kind.write.offset == 8192 and built[9].kind.fdatasync.file == 12);
    try std.testing.expect(built[10].kind.timer.after_ns == 1_000 and built[10].kind.timer.repeat_ns == 500);
    try std.testing.expect(built[11].kind.post.target == 13 and built[11].kind.post.message.payload == 99);
    try std.testing.expect(built[12].kind.receive_from.socket == 14 and built[12].kind.receive_from.group == 3);
    try std.testing.expect(built[13].kind.send_to.socket == 15 and built[13].kind.send_to.to == &outbound);
    try std.testing.expect(built[13].kind.send_to.buffer.bytes.len == 1);
    try std.testing.expect(built[14].kind.fsync.file == 16);
}
