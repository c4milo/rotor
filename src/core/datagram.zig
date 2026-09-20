//! What a datagram carries beside its bytes (decision 15), in rotor's own types. No control
//! message and no kernel structure appears here: each backend walks its own kernel's control
//! messages once, where it turns a completion into an event, and fills a `Received`.
//!
//! **Where a received datagram's bytes are.** io_uring's multishot `recvmsg` writes a head, then
//! the peer address, then the control messages, then the datagram, into one provided buffer. The
//! kernel lays the payload out after the space the submission *reserved*, and reports the bytes
//! it *used* in the head, so the two differ whenever the address or the control block is shorter
//! than its reserve. `tools/uring_probe_datagram.zig` measured it on 2026-09-20: a `sockaddr.in`
//! reports 16 against a reserve of 32, so an offset taken from the written lengths lands 24 bytes
//! short, inside the control block.
//!
//! The payload therefore sits at a constant offset, fixed when the group is registered, and
//! `Event.result` is the completion's count less that constant. The kqueue backend writes the
//! same head itself, so one `Delivery` reads either kernel's buffer.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const operation = @import("operation.zig");

const Address = operation.Address;

/// The two congestion bits of the IP header (RFC 3168). The values are the codepoints the bits
/// hold, so nothing here turns one into the other.
pub const Ecn = enum(u8) { not_ect = 0, ect1 = 1, ect0 = 2, ce = 3 };

/// Bytes of `Received` and of `Outbound`: one cache line, so a reply reads and writes one.
pub const metadata_bytes = 64;

/// The addresses each carries: the peer and this host's.
const addresses = 2;

/// The bytes each spends beside its addresses: `segment_bytes`, `ecn` and `flags`.
const described_bytes = @sizeOf(u16) + @sizeOf(Ecn) + @sizeOf(u8);

/// The padding each carries so that both are exactly `metadata_bytes`.
const reserved_bytes = metadata_bytes - addresses * @sizeOf(Address) - described_bytes;

/// What one received datagram carries beside its bytes. Handed over **by value**, so a caller
/// that keeps the peer address does not keep the buffer: a reply copies one cache line instead
/// of pinning a receive buffer for the life of the answer.
pub const Received = extern struct {
    /// Where the datagram came from.
    peer: Address,
    /// The address of this host it was sent to, when `flags.local`. Its `port` is 0: the kernel
    /// reports the address, and the port is the socket's.
    local: Address,
    /// The bytes of each segment when the kernel coalesced several datagrams into this one, or 0
    /// when it did not. Every segment but the last holds exactly this many bytes.
    segment_bytes: u16,
    ecn: Ecn,
    flags: Flags,
    reserved: [reserved_bytes]u8 = @splat(0),

    pub const Flags = packed struct(u8) {
        /// `local` holds an address. False means the loop has no answer, not that it is zero.
        local: bool = false,
        /// `ecn` holds a codepoint the kernel reported.
        ecn: bool = false,
        /// The datagram was longer than the buffer and the rest is gone, so `bytes` is not a
        /// whole datagram.
        truncated: bool = false,
        reserved: u5 = 0,
    };
};

/// Where a datagram goes and how. It belongs to the loop from `submit` until the operation's
/// final event (decision 5, rule 3), as `Connect.address` does.
pub const Outbound = extern struct {
    /// Where the datagram goes. A send on a connected socket names none, and clears `flags.peer`.
    peer: Address,
    /// The address of this host to send it from, when `flags.local`. A server bound to the
    /// wildcard address answers a client from the address the client wrote to.
    local: Address,
    /// Cut the buffer into datagrams of this many bytes, or 0 to send it as one. Refused by a
    /// backend whose kernel cannot segment, which is every macOS (decision 15).
    segment_bytes: u16,
    ecn: Ecn,
    flags: Flags,
    reserved: [reserved_bytes]u8 = @splat(0),

    pub const Flags = packed struct(u8) {
        peer: bool = false,
        local: bool = false,
        ecn: bool = false,
        reserved: u5 = 0,
    };

    /// The reply to `received`: back to its peer, from the address it was sent to, unmarked.
    /// This is the one call a QUIC stack makes per answer, and it copies no address twice.
    pub fn reply_to(received: *const Received) Outbound {
        return .{
            .peer = received.peer,
            .local = received.local,
            .segment_bytes = 0,
            .ecn = .not_ect,
            .flags = .{ .peer = true, .local = received.flags.local },
        };
    }
};

/// The head a datagram's buffer starts with: rotor's own name for what io_uring's multishot
/// `recvmsg` writes, which the uring backend pins to the kernel's structure field for field, and
/// which the kqueue backend fills itself. The lengths are what the kernel **used**, never where
/// the next part starts; `prefix_bytes` says that.
pub const Head = extern struct {
    name_bytes: u32,
    control_bytes: u32,
    payload_bytes: u32,
    flags: u32,
};

/// How a buffer group reserves room in front of each datagram. Chosen once, when the group is
/// registered, so that a fourth control message later costs no caller a layout change.
pub const GroupOptions = struct {
    /// Room for the peer address. 32 and not 24, so the control block that follows starts
    /// 8-aligned, which a `cmsghdr` needs on a 64-bit kernel.
    name_reserve: u32 = name_reserve_default,
    /// Room for the control messages. The default holds the three a QUIC stack asks for on IPv6
    /// and rounds the whole prefix up to a cache line, which the comptime assert below pins.
    control_reserve: u32 = control_reserve_default,
};

/// Room for the peer address: 32 and not `@sizeOf(Address)`, so the control block that follows
/// starts 8-aligned, which a `cmsghdr` needs on a 64-bit kernel.
pub const name_reserve_default: u32 = 32;

/// Room for the control messages, which is the largest the three a QUIC stack asks for can take.
/// On IPv6 that is `CMSG_SPACE` of the packet info, the traffic class and the segment size:
/// 40 + 24 + 24 = 88 on a 64-bit kernel. IPv4's two measured 56 on 2026-09-20
/// (`tools/uring_probe_datagram.zig`), which the same arithmetic gives as 32 + 24.
///
/// The value is 144 and not 88, because the prefix in front of every datagram is the head plus
/// both reserves and has to end on a cache line: 16 + 32 + 144 is 192. The 56 bytes above 88 are
/// what that rounding costs, and they leave room for a fourth control message without moving any
/// caller's payload.
pub const control_reserve_default: u32 = 144;

/// The bytes in front of every datagram in a group registered with `options`: the head, the
/// address reserve and the control reserve. The payload starts here, always, whatever the kernel
/// wrote into the head.
pub fn prefix_bytes(options: GroupOptions) u32 {
    assert(options.name_reserve >= @sizeOf(Address));
    assert(options.name_reserve % @alignOf(u64) == 0);
    assert(options.control_reserve % @alignOf(u64) == 0);
    const prefix = @sizeOf(Head) + options.name_reserve + options.control_reserve;
    assert(prefix < constants.transfer_bytes_max);
    return prefix;
}

/// The bytes of one datagram a buffer of `buffer_bytes` in such a group can hold.
pub fn payload_capacity(buffer_bytes: u32, options: GroupOptions) u32 {
    const prefix = prefix_bytes(options);
    assert(buffer_bytes > prefix);
    return buffer_bytes - prefix;
}

/// One received datagram: what it carries, and the bytes themselves.
pub const Delivery = struct { from: Received, bytes: []u8 };

comptime {
    assert(@sizeOf(Received) == metadata_bytes);
    assert(@sizeOf(Outbound) == metadata_bytes);
    // No padding: the last field ends where the struct does.
    assert(@offsetOf(Received, "reserved") + reserved_bytes == metadata_bytes);
    assert(@offsetOf(Outbound, "reserved") + reserved_bytes == metadata_bytes);
    assert(@sizeOf(Received.Flags) == 1);
    assert(@sizeOf(Outbound.Flags) == 1);
    assert(@sizeOf(Head) == 16);
    // The default reserve keeps a datagram's own bytes on a cache line when its buffer starts on
    // one, which a group's buffers do.
    assert((@sizeOf(Head) + name_reserve_default + control_reserve_default) % 64 == 0);
}

const testing = std.testing;

test "the prefix is the head and both reserves, and the payload capacity is what is left" {
    const default: GroupOptions = .{};
    try testing.expectEqual(@as(u32, 192), prefix_bytes(default));
    // The probe measured a prefix of 112 for a reserve of 32 and 64, which this reproduces.
    const probed: GroupOptions = .{ .name_reserve = 32, .control_reserve = 64 };
    try testing.expectEqual(@as(u32, 112), prefix_bytes(probed));
    try testing.expectEqual(@as(u32, 2048 - 192), payload_capacity(2048, default));
    // The default holds IPv6's three control messages, which is what the reserve is for.
    const ipv6_control = 40 + 24 + 24;
    try testing.expect(control_reserve_default >= ipv6_control);
}

test "a reply goes back to the peer, from the address the datagram was sent to" {
    const from = Address.ipv4(.{ 203, 0, 113, 7 }, 4433);
    const to = Address.ipv4(.{ 198, 51, 100, 2 }, 0);
    const received: Received = .{
        .peer = from,
        .local = to,
        .segment_bytes = 0,
        .ecn = .ect0,
        .flags = .{ .local = true, .ecn = true },
    };
    const answer = Outbound.reply_to(&received);
    try testing.expectEqual(from.port, answer.peer.port);
    try testing.expectEqualSlices(u8, &from.bytes, &answer.peer.bytes);
    try testing.expectEqualSlices(u8, &to.bytes, &answer.local.bytes);
    try testing.expect(answer.flags.peer and answer.flags.local);
    // A reply carries no codepoint of its own: the sender marks it, not the datagram it answers.
    try testing.expect(!answer.flags.ecn);
    try testing.expectEqual(Ecn.not_ect, answer.ecn);
    try testing.expectEqual(@as(u16, 0), answer.segment_bytes);
}

test "a reply to a datagram with no local address does not claim one" {
    const received: Received = .{
        .peer = Address.ipv4(.{ 127, 0, 0, 1 }, 9),
        .local = Address.ipv4(.{ 0, 0, 0, 0 }, 0),
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{},
    };
    try testing.expect(!Outbound.reply_to(&received).flags.local);
}

test "every codepoint keeps the value the IP header holds" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Ecn.not_ect));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Ecn.ect1));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Ecn.ect0));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(Ecn.ce));
}
