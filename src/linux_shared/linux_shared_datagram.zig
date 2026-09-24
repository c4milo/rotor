//! The control blocks of a datagram on Linux, which both Linux backends write and read the same way
//! (decision 15): what a send attaches, the packet info, the codepoint and the segment size, and
//! what a receive reports, read back into `core.datagram.Received`. `uring` hands the kernel the
//! message through a ring and `epoll` calls `sendmsg` and `recvmsg` itself; the blocks are the same.
//!
//! Everything here but `apply_options` enters no kernel, so its tests run on every host.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const address_module = @import("linux_shared_address.zig");
const sync_socket = @import("linux_shared_sync_socket.zig");

const Address = core.Address;
const Ecn = core.datagram.Ecn;
const Received = core.datagram.Received;
const Outbound = core.datagram.Outbound;
const GroupOptions = core.datagram.GroupOptions;
const InPktinfo = core.datagram.InPktinfo;
const In6Pktinfo = core.datagram.In6Pktinfo;

/// The control bytes one send may attach: the packet info and the codepoint, plus the segment
/// size. Sized for IPv6, which is the wider of the two.
pub const control_bytes_max = 128;

/// `CMSG_ALIGN`: control messages are padded to a pointer on every kernel rotor runs on.
fn align_control(bytes: usize) usize {
    const unit: usize = @sizeOf(usize);
    return (bytes + unit - 1) & ~(unit - @as(usize, 1));
}

/// `CMSG_SPACE`: what one control message of `payload_bytes` occupies.
pub fn control_space(payload_bytes: usize) usize {
    return align_control(@sizeOf(linux.cmsghdr)) + align_control(payload_bytes);
}

/// Writes the control messages for `out`, and returns the bytes used, or null when they do not
/// fit. The order does not matter to the kernel; it is the order the fields are declared in.
pub fn write_control(buffer: *[control_bytes_max]u8, out: *const Outbound) ?usize {
    var used: usize = 0;
    if (out.flags.local) {
        used = switch (out.local.family) {
            .ipv4 => append(buffer, used, linux.IPPROTO.IP, linux.IP.PKTINFO, InPktinfo{
                .ifindex = out.local.scope_id,
                .spec_dst = address_module.ipv4_bits(&out.local),
                .addr = 0,
            }) orelse return null,
            .ipv6 => append(buffer, used, linux.IPPROTO.IPV6, linux.IPV6.PKTINFO, In6Pktinfo{
                .addr = out.local.bytes,
                .ifindex = out.local.scope_id,
            }) orelse return null,
        };
    }
    if (out.flags.ecn) {
        const codepoint: c_int = @intFromEnum(out.ecn);
        // Linux sends to an IPv4-mapped peer through its IPv4 path, which reads IP_TOS and ignores
        // IPV6_TCLASS, so such a peer takes IPv4's option even from an IPv6 socket.
        const ipv4 = out.peer.family == .ipv4 or is_ipv4_mapped(&out.peer);
        used = (if (ipv4)
            append(buffer, used, linux.IPPROTO.IP, linux.IP.TOS, codepoint)
        else
            append(buffer, used, linux.IPPROTO.IPV6, linux.IPV6.TCLASS, codepoint)) orelse
            return null;
    }
    if (out.segment_bytes != 0) {
        const segment: u16 = out.segment_bytes;
        used = append(buffer, used, linux.IPPROTO.UDP, linux.UDP.SEGMENT, segment) orelse
            return null;
    }
    return used;
}

/// An IPv4-mapped IPv6 address, `::ffff:a.b.c.d`, starts with this many zero bytes, then two
/// bytes of `mapped_marker`, then the IPv4 address.
const mapped_zero_bytes = 10;
const mapped_marker: u8 = 0xff;
const ipv4_mapped_prefix = [_]u8{0} ** mapped_zero_bytes ++ [_]u8{ mapped_marker, mapped_marker };

/// True for an IPv6 address that names an IPv4 peer: how the kernel names one to a socket bound to
/// `::`.
fn is_ipv4_mapped(address: *const Address) bool {
    if (address.family != .ipv6) return false;
    return std.mem.eql(u8, address.bytes[0..ipv4_mapped_prefix.len], &ipv4_mapped_prefix);
}

/// Appends one control message and returns the new length, or null when it does not fit.
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
    const header: *linux.cmsghdr = @ptrCast(@alignCast(&buffer[used]));
    header.* = .{
        .len = align_control(@sizeOf(linux.cmsghdr)) + payload_bytes,
        .level = @intCast(level),
        .type = @intCast(name),
    };
    const start = used + align_control(@sizeOf(linux.cmsghdr));
    @memcpy(buffer[start..][0..payload_bytes], std.mem.asBytes(&value));
    return used + needed;
}

/// What one completed `receive_from` carries, read out of the buffer the kernel filled. `bytes`
/// is what `Event.result` counted, so this never recomputes it.
pub fn delivery(buffer: []u8, payload_bytes: u32, options: GroupOptions) core.Delivery {
    const prefix = core.datagram.prefix_bytes(options);
    assert(buffer.len >= prefix);
    const head: *const core.datagram.Head = @ptrCast(@alignCast(buffer.ptr));
    var from: Received = .{
        .peer = .{ .family = .ipv4, .port = 0, .bytes = @splat(0) },
        .local = .{ .family = .ipv4, .port = 0, .bytes = @splat(0) },
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .truncated = head.flags & linux.MSG.TRUNC != 0 },
    };
    const name_start = @sizeOf(core.datagram.Head);
    if (head.name_bytes >= @sizeOf(linux.sockaddr)) {
        const storage: *const address_module.Storage = @ptrCast(@alignCast(&buffer[name_start]));
        if (address_module.from_kernel(storage, head.name_bytes)) |peer| from.peer = peer;
    }
    const control_start = name_start + options.name_reserve;
    read_control(buffer[control_start..][0..head.control_bytes], &from);
    return .{ .from = from, .bytes = buffer[prefix..][0..payload_bytes] };
}

/// Walks the control messages the kernel wrote and fills what rotor names. An unknown one is
/// stepped over: a kernel may attach more than was asked for.
fn read_control(control: []const u8, from: *Received) void {
    var offset: usize = 0;
    const header_bytes = align_control(@sizeOf(linux.cmsghdr));
    while (offset + header_bytes <= control.len) {
        const header: *const linux.cmsghdr = @ptrCast(@alignCast(&control[offset]));
        if (header.len < header_bytes or offset + header.len > control.len) return;
        const payload = control[offset + header_bytes ..][0 .. header.len - header_bytes];
        read_one(header.level, header.type, payload, from);
        offset += align_control(header.len);
    }
}

fn read_one(level: i32, name: i32, payload: []const u8, from: *Received) void {
    if (level == linux.IPPROTO.IP and name == linux.IP.PKTINFO) {
        if (payload.len < @sizeOf(InPktinfo)) return;
        const info: *align(1) const InPktinfo = @ptrCast(payload.ptr);
        from.local = address_module.ipv4_of(info.addr, 0);
        from.local.scope_id = info.ifindex;
        from.flags.local = true;
    } else if (level == linux.IPPROTO.IPV6 and name == linux.IPV6.PKTINFO) {
        if (payload.len < @sizeOf(In6Pktinfo)) return;
        const info: *align(1) const In6Pktinfo = @ptrCast(payload.ptr);
        from.local = Address.ipv6(info.addr, 0, info.ifindex);
        from.flags.local = true;
    } else if (is_codepoint(level, name)) {
        if (payload.len < 1) return;
        from.ecn = @enumFromInt(payload[0] & ecn_mask);
        from.flags.ecn = true;
    } else if (level == linux.IPPROTO.UDP and name == linux.UDP.GRO) {
        if (payload.len < @sizeOf(u16)) return;
        from.segment_bytes = std.mem.bytesToValue(u16, payload[0..@sizeOf(u16)]);
    }
}

/// The two congestion bits are the low two of the traffic class byte.
const ecn_mask: u8 = 0b11;

fn is_codepoint(level: i32, name: i32) bool {
    const ipv4 = level == linux.IPPROTO.IP and (name == linux.IP.TOS or name == linux.IP.RECVTOS);
    const ipv6 = level == linux.IPPROTO.IPV6 and name == linux.IPV6.TCLASS;
    return ipv4 or ipv6;
}

/// The three option numbers one family uses, so the two families share one body.
const Names = struct { pktinfo: u32, codepoint: u32, mtu_discover: u32 };

/// Sets what a datagram socket needs, by family. A refusal costs the caller that answer and
/// nothing else, which is why none is checked: the conformance suite reports what a host
/// honoured rather than assuming it.
pub fn apply_options(
    socket: core.Descriptor,
    family: Address.Family,
    options: core.sync.DatagramOptions,
) void {
    switch (family) {
        .ipv4 => apply(socket, linux.IPPROTO.IP, .{
            .pktinfo = linux.IP.PKTINFO,
            .codepoint = linux.IP.RECVTOS,
            .mtu_discover = linux.IP.MTU_DISCOVER,
        }, options),
        .ipv6 => {
            apply(socket, linux.IPPROTO.IPV6, .{
                .pktinfo = linux.IPV6.RECVPKTINFO,
                .codepoint = linux.IPV6.RECVTCLASS,
                .mtu_discover = linux.IPV6.MTU_DISCOVER,
            }, options);
            // A socket bound to `::` takes IPv4 datagrams too. The kernel reports their codepoint
            // only when IP_RECVTOS is set, in an IP_TOS message, even on an IPv6 socket.
            if (!options.control) return;
            sync_socket.set_option(socket, linux.IPPROTO.IP, linux.IP.RECVTOS, true) catch {};
        },
    }
}

/// IP_PMTUDISC_DO, which every kernel rotor runs on numbers 2: set the bit and refuse an
/// oversized datagram rather than fragmenting it.
const pmtudisc_do: c_int = 2;

fn apply(
    socket: core.Descriptor,
    level: u32,
    names: Names,
    options: core.sync.DatagramOptions,
) void {
    const set = sync_socket.set_option;
    if (options.control) {
        set(socket, @intCast(level), names.pktinfo, true) catch {};
        set(socket, @intCast(level), names.codepoint, true) catch {};
    }
    if (!options.dont_fragment) return;
    const value = pmtudisc_do;
    _ = linux.setsockopt(
        socket,
        @intCast(level),
        names.mtu_discover,
        std.mem.asBytes(&value),
        @sizeOf(c_int),
    );
}

const testing = std.testing;

test "the control space of a message is its header and its payload, each padded to a pointer" {
    const unit = @sizeOf(usize);
    const header = align_control(@sizeOf(linux.cmsghdr));
    try testing.expectEqual(header + unit, control_space(1));
    try testing.expectEqual(header + unit, control_space(unit));
    try testing.expectEqual(header + 2 * unit, control_space(unit + 1));
    // The probe measured 56 for IPv4's packet info and its codepoint on a 64-bit kernel, which
    // is the one number in this file taken from a real kernel rather than from arithmetic.
    try testing.expectEqual(@as(usize, 56), control_space(@sizeOf(InPktinfo)) + control_space(1));
}

test "a send writes one control message per thing the outbound block asks for" {
    var buffer: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const nothing: Outbound = .{
        .peer = Address.ipv4(.{ 127, 0, 0, 1 }, 1),
        .local = Address.ipv4(.{ 0, 0, 0, 0 }, 0),
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    try testing.expectEqual(@as(?usize, 0), write_control(&buffer, &nothing));

    var everything = nothing;
    everything.flags.local = true;
    everything.flags.ecn = true;
    everything.ecn = .ect0;
    everything.segment_bytes = 1200;
    const used = write_control(&buffer, &everything).?;
    const wanted = control_space(@sizeOf(InPktinfo)) + control_space(@sizeOf(c_int)) +
        control_space(@sizeOf(u16));
    try testing.expectEqual(wanted, used);
    const first: *const linux.cmsghdr = @ptrCast(@alignCast(&buffer[0]));
    try testing.expectEqual(@as(i32, @intCast(linux.IP.PKTINFO)), first.type);
}

/// The level and type of the one control message `write_control` writes to mark `peer` ECT(0).
fn codepoint_message_for(peer: Address) !struct { level: i32, kind: i32 } {
    var buffer: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const marked: Outbound = .{
        .peer = peer,
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .ect0,
        .flags = .{ .peer = true, .ecn = true },
    };
    try testing.expectEqual(@as(?usize, control_space(@sizeOf(c_int))), write_control(&buffer, &marked));
    const message: *const linux.cmsghdr = @ptrCast(@alignCast(&buffer[0]));
    return .{ .level = message.level, .kind = message.type };
}

test "an IPv4 peer is marked with IP_TOS, from an IPv6 socket too, and an IPv6 peer with TCLASS" {
    const ip_tos: i32 = @intCast(linux.IP.TOS);
    const ipv6_tclass: i32 = @intCast(linux.IPV6.TCLASS);
    const ipv4 = try codepoint_message_for(Address.ipv4(.{ 127, 0, 0, 1 }, 1));
    try testing.expectEqual(ip_tos, ipv4.kind);
    // `::ffff:127.0.0.1`, how a socket bound to `::` names an IPv4 client.
    var mapped_bytes: [Address.ipv6_bytes]u8 = @splat(0);
    mapped_bytes[10] = 0xff;
    mapped_bytes[11] = 0xff;
    mapped_bytes[12] = 127;
    mapped_bytes[15] = 1;
    const mapped = try codepoint_message_for(Address.ipv6(mapped_bytes, 1, 0));
    try testing.expectEqual(@as(i32, @intCast(linux.IPPROTO.IP)), mapped.level);
    try testing.expectEqual(ip_tos, mapped.kind);
    // `::1` shares every byte of that prefix but the two 0xff, and stays IPv6.
    var loopback_bytes: [Address.ipv6_bytes]u8 = @splat(0);
    loopback_bytes[15] = 1;
    const native = try codepoint_message_for(Address.ipv6(loopback_bytes, 1, 0));
    try testing.expectEqual(@as(i32, @intCast(linux.IPPROTO.IPV6)), native.level);
    try testing.expectEqual(ipv6_tclass, native.kind);
}

test "a datagram's codepoint and segment size are read back out of the control block" {
    var buffer: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var used: usize = 0;
    // The kernel reports the whole traffic class byte; only its low two bits are the codepoint.
    // Bit 2 is set on purpose: a mask one bit too wide reads 0b110 here, which is no codepoint
    // at all, and a mask one bit too narrow reads 0b0. Only the two low bits give `ect0`.
    const traffic_class: u8 = 0b1001_0110;
    used = append(&buffer, used, linux.IPPROTO.IP, linux.IP.RECVTOS, traffic_class).?;
    const segment: u16 = 1400;
    used = append(&buffer, used, linux.IPPROTO.UDP, linux.UDP.GRO, segment).?;

    var from: Received = std.mem.zeroes(Received);
    read_control(buffer[0..used], &from);
    try testing.expectEqual(Ecn.ect0, from.ecn);
    try testing.expect(from.flags.ecn);
    try testing.expectEqual(segment, from.segment_bytes);
    try testing.expect(!from.flags.local);
}

test "an unknown control message is stepped over and the one after it is still read" {
    var buffer: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const unknown_level = 0x7f;
    const unknown_name = 0x7e;
    var used = append(&buffer, 0, unknown_level, unknown_name, @as(u64, 0xdead)).?;
    const segment: u16 = 900;
    used = append(&buffer, used, linux.IPPROTO.UDP, linux.UDP.GRO, segment).?;
    var from: Received = std.mem.zeroes(Received);
    read_control(buffer[0..used], &from);
    try testing.expectEqual(segment, from.segment_bytes);
}

test "a control block that claims more than it holds stops the walk" {
    var buffer: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const used = append(&buffer, 0, linux.IPPROTO.UDP, linux.UDP.GRO, @as(u16, 700)).?;
    const header: *linux.cmsghdr = @ptrCast(@alignCast(&buffer[0]));
    header.len = used + control_bytes_max;
    var from: Received = std.mem.zeroes(Received);
    read_control(buffer[0..used], &from);
    try testing.expectEqual(@as(u16, 0), from.segment_bytes);
}

test "a send that asks for more control than fits is refused rather than truncated" {
    var buffer: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var used: usize = 0;
    while (used + control_space(@sizeOf(u16)) <= buffer.len) {
        used = append(&buffer, used, linux.IPPROTO.UDP, linux.UDP.GRO, @as(u16, 1)).?;
    }
    try testing.expectEqual(@as(?usize, null), append(&buffer, used, 1, 1, @as(u64, 0)));
}
