//! `Operation`, what the caller hands `submit` (decisions 1 and 2). `Kind` is a closed union: an
//! operation outside version one's scope does not compile, and a backend that does not handle a
//! kind fails its exhaustive switch.
//!
//! Every buffer and every `Address` an operation names belongs to the loop from `submit` until
//! the operation's final event is reaped (decision 5, rule 3).
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const datagram = @import("datagram.zig");

/// An open file, socket or listener. An integer, so a consumer's deterministic twin of the
/// surface can hand out indices.
pub const Descriptor = i32;

/// One loop or remote of this process, below `constants.loops_max` (decision 4).
pub const LoopId = u16;

/// What one loop posts to another: 16 bytes. Anything larger travels as an index or a pointer in
/// `payload`, into memory the two sides agreed on. `tag` is at most `constants.message_tag_max`.
pub const Message = extern struct {
    payload: u64,
    tag: u32,
    reserved: u32 = 0,
};

/// An IPv4 or IPv6 endpoint. rotor's own type, because no kernel type is part of the surface.
pub const Address = extern struct {
    family: Family,
    reserved: u8 = 0,
    /// Host byte order.
    port: u16,
    /// IPv6 only.
    scope_id: u32 = 0,
    /// The address in network byte order. IPv4 uses the first `ipv4_bytes`.
    bytes: [ipv6_bytes]u8,

    pub const Family = enum(u8) { ipv4 = 4, ipv6 = 6 };
    pub const ipv4_bytes = 4;
    pub const ipv6_bytes = 16;

    pub fn ipv4(octets: [ipv4_bytes]u8, port: u16) Address {
        var address: Address = .{ .family = .ipv4, .port = port, .bytes = @splat(0) };
        address.bytes[0..ipv4_bytes].* = octets;
        return address;
    }

    pub fn ipv6(octets: [ipv6_bytes]u8, port: u16, scope_id: u32) Address {
        return .{ .family = .ipv6, .port = port, .scope_id = scope_id, .bytes = octets };
    }
};

pub const Operation = struct {
    /// Copied into every event of this operation. rotor never reads it.
    user_data: u64,
    /// The operation's deadline, in nanoseconds from the tick that submits it, or 0 for none.
    /// When it passes first the loop cancels the operation (decision 5, rule 4). A `timer` and a
    /// `post` carry none.
    timeout_ns: u64 = 0,
    /// True when the descriptor the kind names is an index into the descriptors the loop
    /// registered (`register_descriptors`), and not a descriptor of the process: the kernel then
    /// skips its descriptor lookup and the reference count that goes with it (decision 3,
    /// source 1). A `close` names a descriptor of the process, always: a registered descriptor
    /// lives as long as the loop.
    descriptor_registered: bool = false,
    kind: Kind,

    /// The tag of `Kind`, 8 bits, which is what a `Slot` stores.
    pub const Code = enum(u8) {
        accept,
        connect,
        receive,
        send,
        shutdown,
        close,
        read,
        write,
        fdatasync,
        timer,
        post,
        nop,
        receive_from,
        send_to,
    };

    pub const Kind = union(Code) {
        accept: Accept,
        connect: Connect,
        receive: Receive,
        send: Send,
        shutdown: Shutdown,
        close: Close,
        read: Read,
        write: Write,
        fdatasync: Fdatasync,
        timer: Timer,
        post: Post,
        nop: void,
        receive_from: ReceiveFrom,
        send_to: SendTo,
    };

    /// Result: the accepted socket. With `multishot`, one event flagged `more` per connection
    /// until the operation is cancelled or fails.
    pub const Accept = struct { listener: Descriptor, multishot: bool = false };

    /// Result: 0. `address` stays the loop's until the final event.
    pub const Connect = struct { socket: Descriptor, address: *const Address };

    /// Result: bytes received, and 0 when the peer closed its side. Two receives in flight on one
    /// socket may complete in either order: io_uring wakes them in an order of its own. A caller
    /// that needs the bytes in order keeps one receive in flight per socket, which a multishot
    /// receive does by itself.
    ///
    /// A multishot receive ends at the end of the stream: its event of 0 is its final one, as
    /// io_uring's kernel ends it (decision 5). An event of 0 names no buffer, and the group keeps
    /// the buffer the receive would have used.
    pub const Receive = struct { socket: Descriptor, target: Target, multishot: bool = false };

    /// Where received bytes land: a buffer the caller names, or a buffer the kernel picks from
    /// the provided-buffer group, which the event then names in `buffer_id`. A multishot receive
    /// takes a group.
    pub const Target = union(enum) { buffer: Buffer, group: u16 };

    /// Result: bytes sent, which may be fewer than the buffer holds. Two sends in flight on one
    /// socket may reach the peer in either order, and a short one leaves a gap the other fills:
    /// a caller keeps one send in flight per socket.
    pub const Send = struct { socket: Descriptor, buffer: ConstBuffer };

    /// Result: 0.
    pub const Shutdown = struct { socket: Descriptor, how: How };
    pub const How = enum(u8) { receive, send, both };

    /// Result: 0, after every operation in flight for `descriptor` has had its final event
    /// (decision 5, rule 6).
    pub const Close = struct { descriptor: Descriptor };

    /// Result: bytes read, which may be fewer than the buffer holds.
    pub const Read = struct { file: Descriptor, buffer: Buffer, offset: u64 };

    /// Result: bytes written, which may be fewer than the buffer holds.
    pub const Write = struct { file: Descriptor, buffer: ConstBuffer, offset: u64 };

    /// Result: 0. Every completed write of `file` is durable when the event arrives.
    pub const Fdatasync = struct { file: Descriptor };

    /// Result: 0, once `after_ns` nanoseconds have passed since the tick that submitted it.
    ///
    /// With `repeat_ns` above 0 it fires again every `repeat_ns` after that, and every event but
    /// the last is flagged `more`, as a multishot accept's are (decision 14). Each fire is
    /// scheduled from the deadline of the one before and never from the clock, so a loop that
    /// was late does not make the period late. A deadline already past fires at the next tick
    /// and is not skipped, so a loop held off for ten periods hands over ten events.
    pub const Timer = struct { after_ns: u64, repeat_ns: u64 = 0 };

    // `nop`: result 0. The kernel does nothing, so its cost is the loop's own and the ring's: what
    // the cost probes and the assertion experiment of decision 8 submit.

    /// Result: 0 once the message is in the target's mailbox, or `mailbox_full`.
    pub const Post = struct { target: LoopId, message: Message };

    /// One datagram, into a buffer whose front holds what it carried (decision 15). Result: the
    /// datagram's own bytes, and 0 for a datagram that carries none. A datagram socket does not
    /// close, so 0 here is not the end of a stream as it is for `receive`.
    ///
    /// One event per datagram, each naming its own buffer of the group, until the operation is
    /// cancelled or fails. `loop.datagram` is the only supported reader of the buffer: the bytes
    /// do not start at its front.
    ///
    /// It names a group and no other target, and it is always multishot, so neither is a field.
    /// io_uring writes rotor's layout only for a multishot receive from a group: a single-shot
    /// one puts the datagram at the front of the buffer and answers the address through the
    /// submission instead (`tools/uring_probe_datagram.zig`, 2026-09-20). One accessor cannot
    /// read two layouts, and an illegal state the type cannot express beats one an assertion
    /// refuses.
    pub const ReceiveFrom = struct { socket: Descriptor, group: u16 };

    /// One datagram out. Result: the bytes sent, which is every byte of `buffer` or none — a
    /// datagram send is not short. `to` says where it goes, what address to send it from, what
    /// codepoint to mark it with, and whether to cut it into segments; it belongs to the loop
    /// until the final event (decision 5, rule 3), as `Connect.address` does.
    pub const SendTo = struct {
        socket: Descriptor,
        buffer: ConstBuffer,
        to: *const datagram.Outbound,
    };

    /// Bytes the kernel writes. `registered` names the registered buffer that contains `bytes`.
    pub const Buffer = struct { bytes: []u8, registered: ?u16 = null };

    /// Bytes the kernel reads.
    pub const ConstBuffer = struct { bytes: []const u8, registered: ?u16 = null };

    // Each builds the common shape of one kind in a call, with no deadline and no registered
    // descriptor: set `timeout_ns` or `descriptor_registered` on the result when either is wanted.
    // A receive into a registered buffer, or a group receive that is not multishot, is written out.
    pub fn accept(user_data: u64, listener: Descriptor, multishot: bool) Operation {
        return .{ .user_data = user_data, .kind = .{ .accept = .{ .listener = listener, .multishot = multishot } } };
    }
    pub fn connect(user_data: u64, socket: Descriptor, address: *const Address) Operation {
        return .{ .user_data = user_data, .kind = .{ .connect = .{ .socket = socket, .address = address } } };
    }
    /// One receive into `bytes`.
    pub fn receive(user_data: u64, socket: Descriptor, bytes: []u8) Operation {
        return .{ .user_data = user_data, .kind = .{ .receive = .{ .socket = socket, .target = .{ .buffer = .{ .bytes = bytes } } } } };
    }
    /// A multishot receive from provided-buffer group `group`.
    pub fn receive_group(user_data: u64, socket: Descriptor, group: u16) Operation {
        return .{ .user_data = user_data, .kind = .{ .receive = .{ .socket = socket, .target = .{ .group = group }, .multishot = true } } };
    }
    pub fn send(user_data: u64, socket: Descriptor, bytes: []const u8) Operation {
        return .{ .user_data = user_data, .kind = .{ .send = .{ .socket = socket, .buffer = .{ .bytes = bytes } } } };
    }
    pub fn shutdown(user_data: u64, socket: Descriptor, how: How) Operation {
        return .{ .user_data = user_data, .kind = .{ .shutdown = .{ .socket = socket, .how = how } } };
    }
    pub fn close(user_data: u64, closing: Descriptor) Operation {
        return .{ .user_data = user_data, .kind = .{ .close = .{ .descriptor = closing } } };
    }
    pub fn read(user_data: u64, file: Descriptor, bytes: []u8, offset: u64) Operation {
        return .{ .user_data = user_data, .kind = .{ .read = .{ .file = file, .buffer = .{ .bytes = bytes }, .offset = offset } } };
    }
    pub fn write(user_data: u64, file: Descriptor, bytes: []const u8, offset: u64) Operation {
        return .{ .user_data = user_data, .kind = .{ .write = .{ .file = file, .buffer = .{ .bytes = bytes }, .offset = offset } } };
    }
    pub fn fdatasync(user_data: u64, file: Descriptor) Operation {
        return .{ .user_data = user_data, .kind = .{ .fdatasync = .{ .file = file } } };
    }
    pub fn timer(user_data: u64, after_ns: u64, repeat_ns: u64) Operation {
        return .{ .user_data = user_data, .kind = .{ .timer = .{ .after_ns = after_ns, .repeat_ns = repeat_ns } } };
    }
    pub fn post(user_data: u64, target: LoopId, message: Message) Operation {
        return .{ .user_data = user_data, .kind = .{ .post = .{ .target = target, .message = message } } };
    }
    pub fn receive_from(user_data: u64, socket: Descriptor, group: u16) Operation {
        return .{ .user_data = user_data, .kind = .{ .receive_from = .{ .socket = socket, .group = group } } };
    }
    pub fn send_to(user_data: u64, socket: Descriptor, bytes: []const u8, to: *const datagram.Outbound) Operation {
        return .{ .user_data = user_data, .kind = .{ .send_to = .{ .socket = socket, .buffer = .{ .bytes = bytes }, .to = to } } };
    }

    pub fn code(operation: *const Operation) Code {
        return std.meta.activeTag(operation.kind);
    }

    /// The descriptor the kind names, or null for a kind that names none.
    pub fn descriptor(operation: *const Operation) ?Descriptor {
        return switch (operation.kind) {
            .accept => |kind| kind.listener,
            .connect => |kind| kind.socket,
            .receive => |kind| kind.socket,
            .send => |kind| kind.socket,
            .shutdown => |kind| kind.socket,
            .close => |kind| kind.descriptor,
            .read => |kind| kind.file,
            .write => |kind| kind.file,
            .fdatasync => |kind| kind.file,
            .receive_from => |kind| kind.socket,
            .send_to => |kind| kind.socket,
            .timer, .post, .nop => null,
        };
    }

    /// Halts on an operation the caller built wrong. Runs once per operation in `submit`; every
    /// value it reads is in the operation it was handed (decision 8, class A).
    pub fn assert_valid(operation: *const Operation) void {
        assert(operation.timeout_ns <= constants.timeout_ns_max);
        if (operation.descriptor_registered) {
            assert(operation.code() != .close);
            // Halts on a kind that names no descriptor.
            assert(operation.descriptor().? < constants.registered_descriptors_max);
        }
        switch (operation.kind) {
            .accept => |kind| assert(kind.listener >= 0),
            .connect => |kind| assert(kind.socket >= 0),
            .receive => |kind| assert_receive(kind),
            .send => |kind| {
                assert_transfer(kind.socket, kind.buffer.bytes.len);
                assert_socket_buffer(kind.buffer.registered);
            },
            .shutdown => |kind| assert(kind.socket >= 0),
            .close => |kind| assert(kind.descriptor >= 0),
            .read => |kind| {
                assert_transfer(kind.file, kind.buffer.bytes.len);
                assert_file_buffer(kind.buffer.registered);
            },
            .write => |kind| {
                assert_transfer(kind.file, kind.buffer.bytes.len);
                assert_file_buffer(kind.buffer.registered);
            },
            .fdatasync => |kind| assert(kind.file >= 0),
            .timer => |kind| {
                // A timer is a deadline, so it carries none: `Slot.timeout_ns` holds its period
                // instead (decision 14).
                assert(operation.timeout_ns == 0);
                assert(kind.after_ns <= constants.timeout_ns_max);
                assert(kind.repeat_ns <= constants.timeout_ns_max);
            },
            .nop => assert(operation.timeout_ns == 0),
            .post => |kind| {
                assert(operation.timeout_ns == 0);
                assert(kind.target < constants.loops_max);
                assert(kind.message.tag <= constants.message_tag_max);
            },
            .receive_from => |kind| assert_receive_from(kind),
            .send_to => |kind| assert_send_to(kind),
        }
    }

    fn assert_receive(kind: Receive) void {
        assert(kind.socket >= 0);
        switch (kind.target) {
            .buffer => |buffer| {
                assert(!kind.multishot);
                assert_transfer(kind.socket, buffer.bytes.len);
                assert_socket_buffer(buffer.registered);
            },
            .group => |group| assert(group < constants.buffer_groups_max),
        }
    }

    /// A registered buffer on a socket transfer is refused, not ignored. A backend sends and
    /// receives with the plain opcodes, which take no registered buffer: only the zero-copy send
    /// does, and decision 3 puts that outside version one. Before this assertion the index was
    /// accepted, recorded in the slot, and then read by nobody, so a caller that registered its
    /// buffers and named one got an ordinary transfer against an unregistered pointer and no
    /// word of it. A caller that wants a registered buffer wants it on a file.
    fn assert_socket_buffer(registered: ?u16) void {
        assert(registered == null);
    }

    /// A datagram receive names an open socket and a buffer group below `buffer_groups_max`.
    fn assert_receive_from(kind: ReceiveFrom) void {
        assert(kind.socket >= 0);
        assert(kind.group < constants.buffer_groups_max);
    }

    /// A datagram send names where it goes. A segment size, when it names one, is smaller than
    /// the buffer: cutting a buffer into one piece is what 0 already means.
    fn assert_send_to(kind: SendTo) void {
        assert_transfer(kind.socket, kind.buffer.bytes.len);
        assert_socket_buffer(kind.buffer.registered);
        assert(kind.to.flags.peer or kind.to.flags.local);
        if (kind.to.segment_bytes != 0) {
            assert(kind.to.segment_bytes < kind.buffer.bytes.len);
            assert(kind.buffer.bytes.len / kind.to.segment_bytes <= constants.segments_max);
        }
    }

    /// A registered buffer on a file transfer names one the loop registered.
    fn assert_file_buffer(registered: ?u16) void {
        if (registered) |index| assert(index < constants.registered_buffers_max);
    }

    fn assert_transfer(file_or_socket: Descriptor, len: usize) void {
        assert(file_or_socket >= 0);
        assert(len >= 1);
        assert(len <= constants.transfer_bytes_max);
    }
};

comptime {
    assert(@sizeOf(Message) == constants.event_bytes);
    const codes = @typeInfo(Operation.Code).@"enum".fields.len;
    assert(codes == @typeInfo(Operation.Kind).@"union".fields.len);
}

const testing = std.testing;

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
    };
    const named = [_]Descriptor{ last, 1, 2, 3, 4, 5, 6, 0 };
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
    };
    const codes = [_]Operation.Code{
        .accept, .connect, .receive,   .receive, .send, .shutdown,     .close,
        .read,   .write,   .fdatasync, .timer,   .post, .receive_from, .send_to,
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
}
