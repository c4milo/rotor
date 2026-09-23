//! The datagram paths of the epoll backend (decision 15). It is two files' halves put together:
//!
//! - **kqueue's shape.** epoll reports readiness and completes nothing, so the loop makes the
//!   `recvmsg` and the `sendmsg` itself, and this file **writes** the head io_uring's multishot
//!   `recvmsg` would have written, in front of the datagram. `core.datagram` then reads any
//!   backend's buffer with one accessor, and the conformance suite asserts the same things on all.
//! - **uring's names.** The option numbers, the control messages and their alignment are Linux's,
//!   read from `std.os.linux`, and so is what Linux can do that macOS cannot: a send with
//!   `segment_bytes` carries `UDP_SEGMENT` and the kernel cuts the datagram up, where the kqueue
//!   backend answers `unsupported`.
//!
//! Every function here but `receive_into`, `send_from` and `apply_options` enters no kernel, so
//! their tests run on every host.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const constants = @import("constants.zig");
const address_module = @import("epoll_address.zig");
const socket_calls = @import("epoll_sync_socket.zig");

const Address = core.Address;
const Ecn = core.datagram.Ecn;
const Head = core.datagram.Head;
const Received = core.datagram.Received;
const Outbound = core.datagram.Outbound;
const GroupOptions = core.datagram.GroupOptions;

/// The control bytes one send may attach: the packet info, the codepoint and the segment size.
/// Sized for IPv6, which is the wider of the two families.
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

/// The kernel's in_pktinfo. The two addresses are not interchangeable and the direction picks
/// which one: a **send** sets `spec_dst`, the source to send from, and a **receive** reports the
/// header's destination in `addr`. Writing one and reading the other is silent, because both are
/// four zeroed bytes when unset.
const InPktinfo = extern struct { ifindex: u32, spec_dst: u32, addr: u32 };

/// The kernel's in6_pktinfo.
const In6Pktinfo = extern struct { addr: [Address.ipv6_bytes]u8, ifindex: u32 };

/// What one `recvmsg` or `sendmsg` came to: a result, or the answer that the socket is not ready.
pub const Answer = struct {
    /// The datagram's own bytes, or the negation of the code the kernel refused with.
    result: i32,
    would_block: bool,

    const not_ready: Answer = .{ .result = 0, .would_block = true };

    fn done(result: i32) Answer {
        return .{ .result = result, .would_block = false };
    }

    fn refused(code: core.Code) Answer {
        return done(core.event.result_of(code));
    }
};

/// Receives one datagram into `buffer`, writing the head, the address and the control block in
/// front of it exactly as io_uring's multishot `recvmsg` would. Returns the datagram's own bytes,
/// so the caller never subtracts a prefix.
pub fn receive_into(descriptor: core.Descriptor, buffer: []u8, options: GroupOptions) Answer {
    const prefix = core.datagram.prefix_bytes(options);
    assert(buffer.len > prefix);
    const name_start = @sizeOf(Head);
    const control_start = name_start + options.name_reserve;

    var vector: std.posix.iovec = .{ .base = buffer.ptr + prefix, .len = buffer.len - prefix };
    var header = std.mem.zeroes(linux.msghdr);
    header.name = @ptrCast(@alignCast(buffer.ptr + name_start));
    header.namelen = options.name_reserve;
    header.iov = @ptrCast(&vector);
    header.iovlen = 1;
    header.control = buffer.ptr + control_start;
    header.controllen = @intCast(options.control_reserve);

    var retry: u32 = 0;
    while (retry <= constants.interrupt_retries_max) : (retry += 1) {
        const rc = linux.recvmsg(descriptor, &header, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            .AGAIN => return Answer.not_ready,
            else => |errno| return Answer.refused(code_of(errno)),
        }
        // The head the uring backend gets from the kernel, written here from what `recvmsg`
        // reported: the bytes of each part it used, and its flags, `MSG_TRUNC` among them.
        const head: *Head = @ptrCast(@alignCast(buffer.ptr));
        head.* = .{
            .name_bytes = header.namelen,
            .control_bytes = @intCast(header.controllen),
            .payload_bytes = @intCast(rc),
            .flags = @bitCast(header.flags),
        };
        return Answer.done(@intCast(rc));
    }
    return Answer.refused(.would_block);
}

/// Sends one datagram, with the control messages `out` asks for. `MSG_NOSIGNAL` keeps a send on a
/// socket whose peer went away from raising SIGPIPE, as the uring backend's `sendmsg` does.
pub fn send_from(descriptor: core.Descriptor, bytes: []const u8, out: *const Outbound) Answer {
    var name: address_module.Storage = undefined;
    var control: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var vector: std.posix.iovec_const = .{ .base = bytes.ptr, .len = bytes.len };
    var header = std.mem.zeroes(linux.msghdr_const);
    header.iov = @ptrCast(&vector);
    header.iovlen = 1;
    if (out.flags.peer) {
        header.namelen = address_module.to_kernel(&out.peer, &name);
        header.name = @ptrCast(&name);
    }
    const written = write_control(&control, out) orelse return Answer.refused(.unsupported);
    if (written != 0) {
        header.control = &control;
        header.controllen = @intCast(written);
    }
    var retry: u32 = 0;
    while (retry <= constants.interrupt_retries_max) : (retry += 1) {
        const rc = linux.sendmsg(descriptor, &header, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => return Answer.done(@intCast(rc)),
            .INTR => continue,
            .AGAIN => return Answer.not_ready,
            else => |errno| return Answer.refused(code_of(errno)),
        }
    }
    return Answer.refused(.would_block);
}

/// EMSGSIZE has its own code, because a QUIC stack answers it by lowering its packet size. The
/// rest are what `core/errno.zig` says for any call, so they are asked of it.
fn code_of(errno: linux.E) core.Code {
    return switch (errno) {
        .MSGSIZE => .message_too_long,
        .DESTADDRREQ => .not_connected,
        else => core.errno.code_of(errno),
    };
}

/// Writes the control messages for `out`, and returns the bytes used, or null when they do not
/// fit. The order does not matter to the kernel; it is the order the fields are declared in.
fn write_control(buffer: *[control_bytes_max]u8, out: *const Outbound) ?usize {
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
        used = switch (out.peer.family) {
            .ipv4 => append(buffer, used, linux.IPPROTO.IP, linux.IP.TOS, codepoint),
            .ipv6 => append(buffer, used, linux.IPPROTO.IPV6, linux.IPV6.TCLASS, codepoint),
        } orelse return null;
    }
    if (out.segment_bytes != 0) {
        const segment: u16 = out.segment_bytes;
        used = append(buffer, used, linux.IPPROTO.UDP, linux.UDP.SEGMENT, segment) orelse
            return null;
    }
    return used;
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

/// What one received datagram carries, read from the head and control block `receive_into`
/// wrote. `payload_bytes` is what `Event.result` counted, so this never recomputes it.
pub fn delivery(buffer: []u8, payload_bytes: u32, options: GroupOptions) core.Delivery {
    const prefix = core.datagram.prefix_bytes(options);
    assert(buffer.len >= prefix);
    const head: *const Head = @ptrCast(@alignCast(buffer.ptr));
    var from: Received = .{
        .peer = .{ .family = .ipv4, .port = 0, .bytes = @splat(0) },
        .local = .{ .family = .ipv4, .port = 0, .bytes = @splat(0) },
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .truncated = head.flags & linux.MSG.TRUNC != 0 },
    };
    const name_start = @sizeOf(Head);
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
    options: socket_calls.DatagramOptions,
) void {
    switch (family) {
        .ipv4 => apply(socket, linux.IPPROTO.IP, .{
            .pktinfo = linux.IP.PKTINFO,
            .codepoint = linux.IP.RECVTOS,
            .mtu_discover = linux.IP.MTU_DISCOVER,
        }, options),
        .ipv6 => apply(socket, linux.IPPROTO.IPV6, .{
            .pktinfo = linux.IPV6.RECVPKTINFO,
            .codepoint = linux.IPV6.RECVTCLASS,
            .mtu_discover = linux.IPV6.MTU_DISCOVER,
        }, options),
    }
}

/// IP_PMTUDISC_DO, which every kernel rotor runs on numbers 2: set the bit and refuse an
/// oversized datagram rather than fragmenting it.
const pmtudisc_do: c_int = 2;

fn apply(
    socket: core.Descriptor,
    level: u32,
    names: Names,
    options: socket_calls.DatagramOptions,
) void {
    if (options.control) {
        socket_calls.set_option(socket, @intCast(level), names.pktinfo, true) catch {};
        socket_calls.set_option(socket, @intCast(level), names.codepoint, true) catch {};
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
    // The segment size is the last message, and it is what makes the kernel cut the datagram up:
    // the one thing this backend carries that the kqueue backend refuses.
    const segment_at = used - control_space(@sizeOf(u16));
    const last: *const linux.cmsghdr = @ptrCast(@alignCast(&buffer[segment_at]));
    try testing.expectEqual(@as(i32, @intCast(linux.UDP.SEGMENT)), last.type);
}

test "a datagram's codepoint and segment size are read back out of the control block" {
    var buffer: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var used: usize = 0;
    // The kernel reports the whole traffic class byte; only its low two bits are the codepoint.
    // Bit 2 is set on purpose: a mask one bit too wide reads 0b110, and one too narrow reads 0b0.
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

test "a control block that claims more than it holds stops the walk" {
    var buffer: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const used = append(&buffer, 0, linux.IPPROTO.UDP, linux.UDP.GRO, @as(u16, 700)).?;
    const header: *linux.cmsghdr = @ptrCast(@alignCast(&buffer[0]));
    header.len = used + control_bytes_max;
    var from: Received = std.mem.zeroes(Received);
    read_control(buffer[0..used], &from);
    try testing.expectEqual(@as(u16, 0), from.segment_bytes);
}

test "a refusal a datagram can meet has its own code, and the rest are the shared map's" {
    try testing.expectEqual(core.Code.message_too_long, code_of(.MSGSIZE));
    try testing.expectEqual(core.Code.not_connected, code_of(.DESTADDRREQ));
    try testing.expectEqual(core.Code.connection_refused, code_of(.CONNREFUSED));
    try testing.expectEqual(core.Code.network_unreachable, code_of(.HOSTUNREACH));
    try testing.expectEqual(core.Code.system_resources, code_of(.NOBUFS));
    try testing.expectEqual(core.Code.unexpected, code_of(.BADF));
}
