//! The datagram paths of the uring backend (decision 15): what a `receive_from` and a `send_to`
//! put in a submission entry, and what a completed receive's buffer holds.
//!
//! **The layout is measured, not recalled.** `tools/uring_probe_datagram.zig` ran it on
//! `orbstack`, Linux 7.0.14, on 2026-09-20. A multishot `recvmsg` writes, into one provided
//! buffer: an `io_uring_recvmsg_out`, the peer address, the control messages, then the datagram.
//! The kernel lays the payload out after the space the submission **reserved** and reports the
//! bytes it **used** in the head, so the two differ whenever the address or the control block is
//! shorter than its reserve — a `sockaddr.in` reports 16 against a reserve of 32. An offset taken
//! from the written lengths lands inside the control block.
//!
//! So the payload sits at a constant offset the group fixes, and `cqe.res` less that constant is
//! the datagram's own bytes. That is the one subtract `uring_reap` makes, with no load into the
//! buffer.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");
const address_module = @import("uring_address.zig");
const ring_module = @import("uring_ring.zig");

const Address = core.Address;
const Ecn = core.datagram.Ecn;
const Received = core.datagram.Received;
const Outbound = core.datagram.Outbound;
const GroupOptions = core.datagram.GroupOptions;

/// The scratch one submission entry needs, which the slot cannot hold: the kernel reads the
/// `msghdr` and its vector while `io_uring_enter` runs, so both live until it returns, exactly
/// as `uring_submit.Extra.address` does.
pub const Message = extern struct {
    header: linux.msghdr,
    vector: std.posix.iovec,
    name: address_module.Storage,
    /// The control messages a `send_to` asks the kernel to attach. Read by the protocol when the
    /// send runs, which can be after `enter` returns, so a send keeps it alive to its final
    /// event under decision 5, rule 3 — the same rule its buffer travels under.
    control: [control_bytes_max]u8 align(@alignOf(linux.cmsghdr)),
};

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

const InPktinfo = core.datagram.InPktinfo;
const In6Pktinfo = core.datagram.In6Pktinfo;

/// Fills `message` for a receive and points `sqe` at it. Only the two lengths are read by the
/// kernel: it writes the name and the control block into the provided buffer, not through these.
pub fn prepare_receive(
    sqe: *linux.io_uring_sqe,
    message: *Message,
    slot: *const core.Slot,
    options: GroupOptions,
) void {
    message.header = std.mem.zeroes(linux.msghdr);
    message.header.namelen = options.name_reserve;
    message.header.controllen = options.control_reserve;
    ring_module.set_opcode(sqe, .RECVMSG);
    sqe.addr = @intFromPtr(&message.header);
    sqe.len = 1;
    if (slot.flags.multishot) {
        assert(slot.flags.buffer_group);
        sqe.ioprio = linux.IORING_RECV_MULTISHOT;
    }
    if (slot.flags.buffer_group) {
        sqe.flags |= linux.IOSQE_BUFFER_SELECT;
        sqe.buf_index = slot.buffer_index;
    }
}

/// Fills `message` for a send and points `sqe` at it, writing the control messages `out` asks
/// for. Returns false when they do not fit, which `assert_send_to` has already made impossible
/// for the kinds rotor offers and which a future control message could reach.
pub fn prepare_send(
    sqe: *linux.io_uring_sqe,
    message: *Message,
    slot: *const core.Slot,
    out: *const Outbound,
) bool {
    message.header = std.mem.zeroes(linux.msghdr);
    message.vector = .{ .base = @ptrFromInt(slot.buffer), .len = slot.len };
    message.header.iov = @ptrCast(&message.vector);
    message.header.iovlen = 1;
    if (out.flags.peer) {
        const len = address_module.to_kernel(&out.peer, &message.name);
        message.header.name = @ptrCast(&message.name);
        message.header.namelen = len;
    }
    const written = write_control(&message.control, out) orelse return false;
    if (written != 0) {
        message.header.control = &message.control;
        message.header.controllen = written;
    }
    ring_module.set_opcode(sqe, .SENDMSG);
    sqe.addr = @intFromPtr(&message.header);
    sqe.len = 1;
    // Without it, a send to a peer that closed raises SIGPIPE and ends the process.
    sqe.rw_flags = linux.MSG.NOSIGNAL;
    return true;
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
    options: @import("uring_sync_socket.zig").DatagramOptions,
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
    options: @import("uring_sync_socket.zig").DatagramOptions,
) void {
    const set = @import("uring_sync_socket.zig").set_option;
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
