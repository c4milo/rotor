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
const constants = @import("constants.zig");
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
/// `netinet6/in6.h:478` and `:494`, behind `__APPLE_USE_RFC_3542`, which gates the header only:
/// `tools/macos_probe.zig` confirmed the kernel takes both by number on 2026-09-20.
///
/// **46 is the control message's type, not a socket option.** Setting it with `setsockopt`
/// answers EINVAL; the option that turns the report on is `ipv6_recvpktinfo`. The first version
/// of this file set 46 and silently got no packet info on IPv6 at all, which the probe found.
pub const ipv6_pktinfo = 46;
pub const ipv6_recvpktinfo = 61;
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

const InPktinfo = core.datagram.InPktinfo;
const In6Pktinfo = core.datagram.In6Pktinfo;

pub const Answer = core.datagram.Answer;

const answer_of = core.datagram.answer_of;

/// Receives one datagram into `buffer`, writing the head, the address and the control block in
/// front of it exactly as io_uring's multishot `recvmsg` would. Returns the datagram's own bytes,
/// so the caller never subtracts a prefix the uring backend has to.
pub fn receive_into(descriptor: core.Descriptor, buffer: []u8, options: GroupOptions) Answer {
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

    var retry: u32 = 0;
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        const rc = c.recvmsg(descriptor, &header, 0);
        if (rc >= 0) {
            // The head the uring backend gets from the kernel, written from what `recvmsg` said.
            const head: *Head = @ptrCast(@alignCast(buffer.ptr));
            head.* = .{
                .name_bytes = header.namelen,
                .control_bytes = @intCast(header.controllen),
                .payload_bytes = @intCast(rc),
                .flags = @intCast(@as(u32, @bitCast(header.flags))),
            };
            return Answer.done(@intCast(rc));
        }
        if (answer_of(posix.errno(rc))) |answer| return answer;
    }
    return Answer.refused(.would_block);
}

/// Sends one datagram. A segmented send is refused: macOS has no `UDP_SEGMENT` (decision 15).
pub fn send_from(descriptor: core.Descriptor, bytes: []const u8, out: *const Outbound) Answer {
    if (out.segment_bytes != 0) return Answer.refused(.unsupported);
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
    const written = write_control(&control, out) orelse return Answer.refused(.unsupported);
    if (written != 0) {
        header.control = &control;
        header.controllen = @intCast(written);
    }
    var retry: u32 = 0;
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        const rc = c.sendmsg(descriptor, &header, 0);
        if (rc >= 0) return Answer.done(@intCast(rc));
        if (answer_of(posix.errno(rc))) |answer| return answer;
    }
    return Answer.refused(.would_block);
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

/// The three option numbers one family uses, so the two families share one body.
const Names = struct { pktinfo: u32, codepoint: u32, dont_fragment: u32 };

/// Sets what a datagram socket needs, by family. macOS carries every one a QUIC stack asks for.
/// A refusal costs the caller that answer and nothing else, which is why none is checked: the
/// conformance suite reports what a host honoured rather than assuming it.
pub fn apply_options(
    socket: core.Descriptor,
    family: Address.Family,
    options: @import("kqueue_sync_socket.zig").DatagramOptions,
) void {
    switch (family) {
        .ipv4 => apply(socket, posix.IPPROTO.IP, .{
            .pktinfo = ip_pktinfo,
            .codepoint = ip_recvtos,
            .dont_fragment = ip_dontfrag,
        }, options),
        .ipv6 => apply(socket, posix.IPPROTO.IPV6, .{
            .pktinfo = ipv6_recvpktinfo,
            .codepoint = ipv6_recvtclass,
            .dont_fragment = ipv6_dontfrag,
        }, options),
    }
}

fn apply(
    socket: core.Descriptor,
    level: u32,
    names: Names,
    options: @import("kqueue_sync_socket.zig").DatagramOptions,
) void {
    const set = @import("kqueue_sync_socket.zig").set_option;
    if (options.control) {
        set(socket, @intCast(level), names.pktinfo, true) catch {};
        set(socket, @intCast(level), names.codepoint, true) catch {};
    }
    if (options.dont_fragment) set(socket, @intCast(level), names.dont_fragment, true) catch {};
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

test "EINTR makes the call again, and EAGAIN waits for readiness" {
    // A signal cannot be made to land inside a non-blocking call, so the errno is fabricated.
    try testing.expectEqual(@as(?Answer, null), answer_of(.INTR));
    try testing.expectEqual(@as(?Answer, Answer.not_ready), answer_of(.AGAIN));
}

test "a datagram call's errno carries the code core's datagram map gives it" {
    const Row = struct { errno: posix.E, code: core.Code };
    // The first two are a datagram's own. The first version of this file had its own map, which
    // answered `unexpected` to the five after them.
    const rows = [_]Row{
        .{ .errno = .MSGSIZE, .code = .message_too_long },
        .{ .errno = .DESTADDRREQ, .code = .not_connected },
        .{ .errno = .CONNRESET, .code = .connection_reset },
        .{ .errno = .PIPE, .code = .broken_pipe },
        .{ .errno = .TIMEDOUT, .code = .connection_timed_out },
        .{ .errno = .NETDOWN, .code = .network_unreachable },
        .{ .errno = .HOSTDOWN, .code = .network_unreachable },
        .{ .errno = .BADF, .code = .unexpected },
    };
    for (rows) |row| {
        const answer = answer_of(row.errno).?;
        try testing.expect(!answer.would_block);
        try testing.expectEqual(core.event.result_of(row.code), answer.result);
    }
}

/// How long the test below waits for the kernel to finish a step on loopback.
const loopback_wait_ms = 2000;

fn wait_until_ready(descriptor: core.Descriptor, events: i16) !void {
    var polled = [_]c.pollfd{.{ .fd = descriptor, .events = events, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 1), c.poll(&polled, polled.len, loopback_wait_ms));
}

test "a receive the kernel refuses with a reset carries connection_reset" {
    if (!@import("builtin").os.tag.isDarwin()) return error.SkipZigTest;
    // No datagram receive fails with ECONNRESET on demand. A stream socket whose peer reset the
    // connection does, and `receive_into` hands whatever `recvmsg` answers to the same map.
    const sockets = @import("kqueue_sync_socket.zig");
    const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const listener = try sockets.listen(&loopback, .{ .backlog = 1, .reuse_port = false });
    defer sockets.close_now(listener);
    const bound = try sockets.local_address(listener);
    const client = try sockets.open_socket(.ipv4);
    defer sockets.close_now(client);
    var storage: address_module.Storage = undefined;
    const len = address_module.to_kernel(&bound, &storage);
    const connected = c.connect(client, @ptrCast(&storage), len);
    try testing.expect(connected == 0 or posix.errno(connected) == .INPROGRESS);
    try wait_until_ready(listener, c.POLL.IN);
    const accepted = c.accept(listener, null, null);
    try testing.expect(accepted >= 0);
    // A linger of zero makes close(2) send a reset instead of a FIN.
    const abort: c.linger = .{ .onoff = 1, .linger = 0 };
    const set = c.setsockopt(accepted, c.SOL.SOCKET, c.SO.LINGER, &abort, @sizeOf(c.linger));
    try testing.expectEqual(@as(c_int, 0), set);
    sockets.close_now(accepted);

    try wait_until_ready(client, c.POLL.IN);
    const group: GroupOptions = .{};
    var buffer: [core.datagram.prefix_bytes(group) + 1]u8 align(@alignOf(Head)) = undefined;
    const answer = receive_into(client, &buffer, group);
    try testing.expect(!answer.would_block);
    try testing.expectEqual(core.event.result_of(.connection_reset), answer.result);
}

/// Opens a datagram socket of `family`, or skips when the host has no stack for it.
fn probe_socket(family: u32) !core.Descriptor {
    const rc = c.socket(family, c.SOCK.DGRAM, c.IPPROTO.UDP);
    if (rc < 0) return error.SkipZigTest;
    return rc;
}

fn option_of(socket: core.Descriptor, level: u32, name: u32) !c_int {
    var value: c_int = -1;
    var len: posix.socklen_t = @sizeOf(c_int);
    const rc = c.getsockopt(socket, @intCast(level), name, &value, &len);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(rc));
    return value;
}

test "the options a datagram socket is opened with are the ones the kernel took" {
    if (@import("builtin").os.tag == .linux) return error.SkipZigTest;
    const options: @import("kqueue_sync_socket.zig").DatagramOptions = .{};

    const four = try probe_socket(c.AF.INET);
    defer _ = c.close(four);
    apply_options(four, .ipv4, options);
    try testing.expectEqual(@as(c_int, 1), try option_of(four, posix.IPPROTO.IP, ip_pktinfo));
    try testing.expectEqual(@as(c_int, 1), try option_of(four, posix.IPPROTO.IP, ip_recvtos));

    // IPv6 is the one that drifted: 46 is a control message's type and 61 is the option that
    // turns the report on, so setting 46 answers EINVAL and reports nothing. `apply_options`
    // swallows a refusal by design, so only reading the option back can catch the wrong number.
    const six = try probe_socket(c.AF.INET6);
    defer _ = c.close(six);
    apply_options(six, .ipv6, options);
    const level = posix.IPPROTO.IPV6;
    try testing.expectEqual(@as(c_int, 1), try option_of(six, level, ipv6_recvpktinfo));
    try testing.expectEqual(@as(c_int, 1), try option_of(six, level, ipv6_recvtclass));
}
