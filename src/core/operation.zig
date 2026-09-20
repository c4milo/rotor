//! `Operation`, what the caller hands `submit` (decisions 1 and 2). `Kind` is a closed union: an
//! operation outside version one's scope does not compile, and a backend that does not handle a
//! kind fails its exhaustive switch.
//!
//! Every buffer and every `Address` an operation names belongs to the loop from `submit` until
//! the operation's final event is reaped (decision 5, rule 3).
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

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
    pub const Timer = struct { after_ns: u64 };

    // `nop`: result 0. The kernel does nothing, so its cost is the loop's own and the ring's: what
    // the cost probes and the assertion experiment of decision 8 submit.

    /// Result: 0 once the message is in the target's mailbox, or `mailbox_full`.
    pub const Post = struct { target: LoopId, message: Message };

    /// Bytes the kernel writes. `registered` names the registered buffer that contains `bytes`.
    pub const Buffer = struct { bytes: []u8, registered: ?u16 = null };

    /// Bytes the kernel reads.
    pub const ConstBuffer = struct { bytes: []const u8, registered: ?u16 = null };

    pub fn code(operation: *const Operation) Code {
        return std.meta.activeTag(operation.kind);
    }

    /// Halts on an operation the caller built wrong. Runs once per operation in `submit`; every
    /// value it reads is in the operation it was handed (decision 8, class A).
    pub fn assert_valid(operation: *const Operation) void {
        assert(operation.timeout_ns <= constants.timeout_ns_max);
        switch (operation.kind) {
            .accept => |accept| assert(accept.listener >= 0),
            .connect => |connect| assert(connect.socket >= 0),
            .receive => |receive| assert_receive(receive),
            .send => |send| assert_transfer(send.socket, send.buffer.bytes.len),
            .shutdown => |shutdown| assert(shutdown.socket >= 0),
            .close => |close| assert(close.descriptor >= 0),
            .read => |read| assert_transfer(read.file, read.buffer.bytes.len),
            .write => |write| assert_transfer(write.file, write.buffer.bytes.len),
            .fdatasync => |fdatasync| assert(fdatasync.file >= 0),
            .timer => |timer| {
                assert(operation.timeout_ns == 0);
                assert(timer.after_ns <= constants.timeout_ns_max);
            },
            .nop => assert(operation.timeout_ns == 0),
            .post => |post| {
                assert(operation.timeout_ns == 0);
                assert(post.target < constants.loops_max);
                assert(post.message.tag <= constants.message_tag_max);
            },
        }
    }

    fn assert_receive(receive: Receive) void {
        assert(receive.socket >= 0);
        switch (receive.target) {
            .buffer => |buffer| {
                assert(!receive.multishot);
                assert_transfer(receive.socket, buffer.bytes.len);
            },
            .group => |group| assert(group < constants.buffer_groups_max),
        }
    }

    fn assert_transfer(descriptor: Descriptor, len: usize) void {
        assert(descriptor >= 0);
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
    for (&operations, codes) |*operation, expected| {
        try testing.expectEqual(expected, operation.code());
        operation.assert_valid();
    }
}
