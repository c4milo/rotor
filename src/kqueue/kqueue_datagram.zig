//! The datagram paths of the kqueue backend (decision 15). macOS has no io_uring, so nothing
//! here mirrors a kernel structure: this file **writes** the same head the uring backend receives,
//! so `core.datagram` reads either kernel's buffer with one accessor and the conformance suite
//! asserts the same things on both.
//!
//! **What macOS cannot do.** `netinet/udp.h` defines exactly one option, `UDP_NOCKSUM`: there is
//! no segmentation and no coalescing. A send that asks for `segment_bytes` is answered
//! `unsupported`, which the owner ruled on 2026-09-20. Everything else a QUIC stack needs is
//! here: `IP_PKTINFO` selects the source address on a wildcard socket, and the traffic class
//! carries the codepoint both ways.
//!
//! The option numbers are named here because Zig's `std.c` does not carry them for Darwin, and
//! the IPv6 ones sit behind `__APPLE_USE_RFC_3542` in the SDK, which gates the header and not the
//! kernel. Each was read from the SDK on 2026-09-20 and each is cited where it is declared.
const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const core = @import("core");
const address_module = @import("kqueue_address.zig");

const Address = core.Address;
const Received = core.datagram.Received;
const Outbound = core.datagram.Outbound;
const GroupOptions = core.datagram.GroupOptions;
const Head = core.datagram.Head;

/// `netinet/in.h:433`: "get pktinfo on recv socket, set src on sent dgram".
pub const ip_pktinfo = 26;
/// `netinet/in.h:435`: receive the type of service with the datagram.
pub const ip_recvtos = 27;
/// `netinet/in.h:436`: do not fragment, which path MTU discovery needs.
pub const ip_dontfrag = 28;
/// `netinet/in.h:407`: the type of service, whose low two bits are the codepoint.
pub const ip_tos = 1;
/// `netinet6/in6.h:438` and `:439`, both unconditional in the SDK.
pub const ipv6_recvtclass = 35;
pub const ipv6_tclass = 36;
/// `netinet6/in6.h:478` and `:494`, behind `__APPLE_USE_RFC_3542`, which gates the header only.
pub const ipv6_pktinfo = 46;
pub const ipv6_dontfrag = 62;

/// The control bytes one datagram may carry. Darwin's `cmsghdr` is smaller than Linux's, so this
/// is generous for the three messages rotor asks for.
pub const control_bytes_max = 128;

/// `CMSG_ALIGN` on Darwin, which pads to `u32` and not to a pointer.
fn align_control(bytes: usize) usize {
    const unit = @alignOf(u32);
    return (bytes + unit - 1) & ~(unit - @as(usize, 1));
}

pub fn control_space(payload_bytes: usize) usize {
    return align_control(@sizeOf(c.cmsghdr)) + align_control(payload_bytes);
}

/// Darwin's `in_pktinfo`, `netinet/in.h:616`. The two addresses are not interchangeable and the
/// direction picks which one: a **send** sets `spec_dst`, the source to send from, and a
/// **receive** reports the header's destination in `addr`. Writing one and reading the other is
/// silent, because both are four zeroed bytes when unset.
const InPktinfo = extern struct { ifindex: u32, spec_dst: u32, addr: u32 };

/// Darwin's `in6_pktinfo`.
const In6Pktinfo = extern struct { addr: [Address.ipv6_bytes]u8, ifindex: u32 };

/// What one `recvmsg` needs and fills, laid out so the head, the name and the control block land
/// where `core.datagram` expects them: at the front of the caller's buffer.
pub const Receive = struct {
    /// The bytes received, or the code the kernel refused with.
    result: i32,
    would_block: bool,
};

/// Receives one datagram into `buffer`, writing the head, the address and the control block in
/// front of it exactly as io_uring's multishot `recvmsg` would. Returns the datagram's own bytes,
/// so the caller never subtracts a prefix the uring backend has to.
pub fn receive_into(descriptor: core.Descriptor, buffer: []u8, options: GroupOptions) Receive {
    const prefix = core.datagram.prefix_bytes(options);
    assert(buffer.len > prefix);
    const name_start = @sizeOf(Head);
    const control_start = name_start + options.name_reserve;

    var vector: posix.iovec = .{
        .base = buffer.ptr + prefix,
        .len = buffer.len - prefix,
    };
    var header = std.mem.zeroes(c.msghdr);
    header.name = @ptrCast(@alignCast(buffer.ptr + name_start));
    header.namelen = options.name_reserve;
    header.iov = @ptrCast(&vector);
    header.iovlen = 1;
    header.control = buffer.ptr + control_start;
    header.controllen = @intCast(options.control_reserve);

    const rc = c.recvmsg(descriptor, &header, 0);
    if (rc < 0) {
        const errno = posix.errno(rc);
        if (errno == .AGAIN) return .{ .result = 0, .would_block = true };
        return .{ .result = core.event.result_of(code_of(errno)), .would_block = false };
    }
    // The head the uring backend gets from the kernel, written here from what `recvmsg` reported.
    const head: *Head = @ptrCast(@alignCast(buffer.ptr));
    head.* = .{
        .name_bytes = header.namelen,
        .control_bytes = @intCast(header.controllen),
        .payload_bytes = @intCast(rc),
        .flags = @intCast(@as(u32, @bitCast(header.flags))),
    };
    return .{ .result = @intCast(rc), .would_block = false };
}

/// Sends one datagram. A segmented send is refused: macOS has no `UDP_SEGMENT` (decision 15).
pub fn send_from(descriptor: core.Descriptor, bytes: []const u8, out: *const Outbound) Receive {
    if (out.segment_bytes != 0) {
        return .{ .result = core.event.result_of(.unsupported), .would_block = false };
    }
    var name: address_module.Storage = undefined;
    var control: [control_bytes_max]u8 align(@alignOf(c.cmsghdr)) = undefined;
    var vector: posix.iovec_const = .{ .base = bytes.ptr, .len = bytes.len };
    var header = std.mem.zeroes(c.msghdr_const);
    header.iov = @ptrCast(&vector);
    header.iovlen = 1;
    if (out.flags.peer) {
        header.namelen = address_module.to_kernel(&out.peer, &name);
        header.name = @ptrCast(@alignCast(&name));
    }
    const written = write_control(&control, out) orelse {
        return .{ .result = core.event.result_of(.unsupported), .would_block = false };
    };
    if (written != 0) {
        header.control = &control;
        header.controllen = @intCast(written);
    }
    const rc = c.sendmsg(descriptor, &header, 0);
    if (rc < 0) {
        const errno = posix.errno(rc);
        if (errno == .AGAIN) return .{ .result = 0, .would_block = true };
        return .{ .result = core.event.result_of(code_of(errno)), .would_block = false };
    }
    return .{ .result = @intCast(rc), .would_block = false };
}

/// EMSGSIZE has its own code, because a QUIC stack answers it by lowering its packet size.
fn code_of(errno: posix.E) core.Code {
    return switch (errno) {
        .MSGSIZE => .message_too_long,
        .NOBUFS, .NOMEM => .system_resources,
        .CONNREFUSED => .connection_refused,
        .HOSTUNREACH, .NETUNREACH => .network_unreachable,
        .DESTADDRREQ, .NOTCONN => .not_connected,
        else => .unexpected,
    };
}

fn write_control(buffer: *[control_bytes_max]u8, out: *const Outbound) ?usize {
    var used: usize = 0;
    if (out.flags.local) {
        used = switch (out.local.family) {
            .ipv4 => append(buffer, used, posix.IPPROTO.IP, ip_pktinfo, InPktinfo{
                .ifindex = out.local.scope_id,
                .spec_dst = address_module.ipv4_bits(&out.local),
                .addr = 0,
            }),
            .ipv6 => append(buffer, used, posix.IPPROTO.IPV6, ipv6_pktinfo, In6Pktinfo{
                .addr = out.local.bytes,
                .ifindex = out.local.scope_id,
            }),
        } orelse return null;
    }
    if (out.flags.ecn) {
        const codepoint: c_int = @intFromEnum(out.ecn);
        used = switch (out.peer.family) {
            .ipv4 => append(buffer, used, posix.IPPROTO.IP, ip_tos, codepoint),
            .ipv6 => append(buffer, used, posix.IPPROTO.IPV6, ipv6_tclass, codepoint),
        } orelse return null;
    }
    return used;
}

fn append(
    buffer: *[control_bytes_max]u8,
    used: usize,
    level: u32,
    name: u32,
    value: anytype,
) ?usize {
    const payload_bytes = @sizeOf(@TypeOf(value));
    const needed = control_space(payload_bytes);
    if (used + needed > buffer.len) return null;
    const header: *c.cmsghdr = @ptrCast(@alignCast(&buffer[used]));
    header.* = .{
        .len = @intCast(align_control(@sizeOf(c.cmsghdr)) + payload_bytes),
        .level = @intCast(level),
        .type = @intCast(name),
    };
    const start = used + align_control(@sizeOf(c.cmsghdr));
    @memcpy(buffer[start..][0..payload_bytes], std.mem.asBytes(&value));
    return used + needed;
}

/// What one received datagram carries, read from the head and control block this file wrote.
pub fn delivery(buffer: []u8, payload_bytes: u32, options: GroupOptions) core.Delivery {
    const prefix = core.datagram.prefix_bytes(options);
    assert(buffer.len >= prefix);
    const head: *const Head = @ptrCast(@alignCast(buffer.ptr));
    var from: Received = std.mem.zeroes(Received);
    from.flags.truncated = head.flags & @as(u32, @intCast(c.MSG.TRUNC)) != 0;
    const name_start = @sizeOf(Head);
    if (head.name_bytes >= @sizeOf(c.sockaddr)) {
        const storage: *const address_module.Storage = @ptrCast(@alignCast(&buffer[name_start]));
        if (address_module.from_kernel(storage, @intCast(head.name_bytes))) |peer| {
            from.peer = peer;
        }
    }
    const control_start = name_start + options.name_reserve;
    read_control(buffer[control_start..][0..head.control_bytes], &from);
    return .{ .from = from, .bytes = buffer[prefix..][0..payload_bytes] };
}

fn read_control(control: []const u8, from: *Received) void {
    var offset: usize = 0;
    const header_bytes = align_control(@sizeOf(c.cmsghdr));
    while (offset + header_bytes <= control.len) {
        const header: *const c.cmsghdr = @ptrCast(@alignCast(&control[offset]));
        const len: usize = @intCast(header.len);
        if (len < header_bytes or offset + len > control.len) return;
        read_one(header.level, header.type, control[offset + header_bytes ..][0 .. len -
            header_bytes], from);
        offset += align_control(len);
    }
}

fn read_one(level: i32, name: i32, payload: []const u8, from: *Received) void {
    if (level == posix.IPPROTO.IP and name == ip_pktinfo) {
        if (payload.len < @sizeOf(InPktinfo)) return;
        const info: *align(1) const InPktinfo = @ptrCast(payload.ptr);
        from.local = address_module.ipv4_of(info.addr, 0);
        from.local.scope_id = info.ifindex;
        from.flags.local = true;
    } else if (level == posix.IPPROTO.IPV6 and name == ipv6_pktinfo) {
        if (payload.len < @sizeOf(In6Pktinfo)) return;
        const info: *align(1) const In6Pktinfo = @ptrCast(payload.ptr);
        from.local = Address.ipv6(info.addr, 0, info.ifindex);
        from.flags.local = true;
    } else if (is_codepoint(level, name)) {
        if (payload.len < 1) return;
        from.ecn = @enumFromInt(payload[0] & ecn_mask);
        from.flags.ecn = true;
    }
}

/// The two congestion bits are the low two of the traffic class byte.
const ecn_mask: u8 = 0b11;

fn is_codepoint(level: i32, name: i32) bool {
    const ipv4 = level == posix.IPPROTO.IP and (name == ip_tos or name == ip_recvtos);
    const ipv6 = level == posix.IPPROTO.IPV6 and name == ipv6_tclass;
    return ipv4 or ipv6;
}

const testing = std.testing;

test "a segmented send is refused, because macOS has no UDP segmentation" {
    const out: Outbound = .{
        .peer = Address.ipv4(.{ 127, 0, 0, 1 }, 1),
        .local = Address.ipv4(.{ 0, 0, 0, 0 }, 0),
        .segment_bytes = 1200,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    // The descriptor is never used: the refusal comes before any system call.
    const answer = send_from(-1, "bytes", &out);
    try testing.expect(!answer.would_block);
    try testing.expectEqual(core.event.result_of(.unsupported), answer.result);
}

test "the control block macOS writes is read back by the same rules the uring one is" {
    var buffer: [control_bytes_max]u8 align(@alignOf(c.cmsghdr)) = undefined;
    const traffic_class: u8 = 0b1110_0010;
    const used = append(&buffer, 0, posix.IPPROTO.IP, ip_recvtos, traffic_class).?;
    var from: Received = std.mem.zeroes(Received);
    read_control(buffer[0..used], &from);
    try testing.expectEqual(core.datagram.Ecn.ect0, from.ecn);
    try testing.expect(from.flags.ecn);
}

test "the packet info macOS reports names the address the datagram was sent to" {
    var buffer: [control_bytes_max]u8 align(@alignOf(c.cmsghdr)) = undefined;
    const wanted = Address.ipv4(.{ 198, 51, 100, 4 }, 0);
    // A receive reports the header's destination in `addr`; `spec_dst` is the send side's.
    const info: InPktinfo = .{
        .ifindex = 3,
        .spec_dst = 0,
        .addr = address_module.ipv4_bits(&wanted),
    };
    const used = append(&buffer, 0, posix.IPPROTO.IP, ip_pktinfo, info).?;
    var from: Received = std.mem.zeroes(Received);
    read_control(buffer[0..used], &from);
    try testing.expect(from.flags.local);
    try testing.expectEqualSlices(u8, &wanted.bytes, &from.local.bytes);
    try testing.expectEqual(@as(u32, 3), from.local.scope_id);
}

test "EMSGSIZE has its own code, because a QUIC stack acts on it" {
    try testing.expectEqual(core.Code.message_too_long, code_of(.MSGSIZE));
    try testing.expectEqual(core.Code.not_connected, code_of(.DESTADDRREQ));
    try testing.expectEqual(core.Code.unexpected, code_of(.BADF));
}
