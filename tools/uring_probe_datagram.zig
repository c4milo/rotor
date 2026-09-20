//! The datagram checks decision 15 blocks itself on. Every layout that record states is recalled,
//! and these run the path the backend would run and report what the kernel actually did.
//!
//! Three questions, and the second is the one that decides the design:
//!
//!   1. Does a multishot `recvmsg` from a provided buffer ring work at all?
//!   2. **Does `cqe.res` count the payload, or everything the datagram occupies in its buffer?**
//!      Decision 15 says `Event.result` is the datagram's own bytes, so the backend subtracts the
//!      difference. This says what there is to subtract, and whether the head, the name and the
//!      control block are inside the count or beside it.
//!   3. Are `UDP_SEGMENT` and `UDP_GRO` accepted, and do `IP_PKTINFO` and `IP_RECVTOS` deliver?
//!
//! A kernel without any of it is not a fault here: the checks are optional, because decision 2's
//! floor is Linux 6.1 and none of this is required to run rotor today. What they must not do is
//! disagree silently with the record.
const std = @import("std");
const probe = @import("uring_probe.zig");

const linux = probe.linux;
const IoUring = probe.IoUring;
const Report = probe.Report;
const Feature = probe.Feature;
const assert = std.debug.assert;

const multishot_recvmsg: Feature = .{ .name = "multishot recvmsg", .need = .optional };
const recvmsg_layout: Feature = .{ .name = "io_uring_recvmsg_out layout", .need = .optional };
const udp_segment: Feature = .{ .name = "UDP_SEGMENT", .need = .optional };
const udp_gro: Feature = .{ .name = "UDP_GRO", .need = .optional };
const datagram_control: Feature = .{ .name = "IP_PKTINFO and IP_RECVTOS", .need = .optional };

const loopback_address = std.mem.nativeToBig(u32, 0x7f00_0001);

/// Buffers in the ring, and their size. One datagram is sent, so one buffer is enough; four
/// leaves room for the ring's power-of-two requirement.
const buffer_ring_entries = 4;
const buffer_bytes = 512;
const buffer_group = 11;

/// The datagram sent, whose length the report compares `cqe.res` against.
const payload = "rotor datagram probe";

const user_data_receive = 0xda7a;

/// The control block the kernel is asked for: `IP_PKTINFO` and `IP_RECVTOS`. 64 bytes is more
/// than the two need, so a kernel that adds a third has room to show it.
const control_bytes = 64;

/// The name the kernel writes: `sockaddr.in` is 16 bytes, and 32 is what decision 15 reserves so
/// that the control block that follows starts 8-aligned.
const name_bytes = 32;

pub fn check(report: *Report, ring: *IoUring) !void {
    try check_options(report);
    try check_receive(report, ring);
}

/// The socket options, which need no ring: a kernel either takes them or answers ENOPROTOOPT.
fn check_options(report: *Report) !void {
    const socket = try open_datagram();
    defer _ = linux.close(socket);

    const segment: c_int = 1200;
    try option_verdict(report, udp_segment, socket, linux.IPPROTO.UDP, linux.UDP.SEGMENT, segment);
    const enabled: c_int = 1;
    try option_verdict(report, udp_gro, socket, linux.IPPROTO.UDP, linux.UDP.GRO, enabled);

    const pktinfo = set_option(socket, linux.IPPROTO.IP, linux.IP.PKTINFO, enabled);
    const recvtos = set_option(socket, linux.IPPROTO.IP, linux.IP.RECVTOS, enabled);
    if (pktinfo != .SUCCESS) return report.refused(datagram_control, "IP_PKTINFO", pktinfo);
    if (recvtos != .SUCCESS) return report.refused(datagram_control, "IP_RECVTOS", recvtos);
    try report.verdict(datagram_control, .present, ", both set", .{});
}

fn option_verdict(
    report: *Report,
    feature: Feature,
    socket: i32,
    level: u32,
    name: u32,
    value: c_int,
) !void {
    const errno = set_option(socket, level, name, value);
    if (errno != .SUCCESS) return report.refused(feature, "setsockopt", errno);
    try report.verdict(feature, .present, ", setsockopt took it", .{});
}

/// Arms one multishot `recvmsg` from a provided buffer ring, sends one datagram to it, and
/// reports what the kernel wrote and what it counted.
fn check_receive(report: *Report, ring: *IoUring) !void {
    const receiver = try open_datagram();
    defer _ = linux.close(receiver);
    const enabled: c_int = 1;
    _ = set_option(receiver, linux.IPPROTO.IP, linux.IP.PKTINFO, enabled);
    _ = set_option(receiver, linux.IPPROTO.IP, linux.IP.RECVTOS, enabled);

    var bound: linux.sockaddr.in = .{ .port = 0, .addr = loopback_address };
    const bind_rc = linux.bind(receiver, @ptrCast(&bound), @sizeOf(linux.sockaddr.in));
    if (linux.errno(bind_rc) != .SUCCESS) {
        return report.refused(multishot_recvmsg, "bind", linux.errno(bind_rc));
    }
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = linux.getsockname(receiver, @ptrCast(&bound), &len);

    var buffers: [buffer_ring_entries * buffer_bytes]u8 align(4096) = undefined;
    var ring_memory: [buffer_ring_entries * @sizeOf(linux.io_uring_buf)]u8 align(4096) = undefined;
    const buffer_ring = register_ring(ring, &ring_memory) catch |failure| {
        try report.verdict(multishot_recvmsg, .missing, ", the buffer ring was refused", .{});
        return failure;
    };
    provide(buffer_ring, &buffers);

    // Only `namelen` and `controllen` are read: the kernel takes the sizes from here and writes
    // the name and the control block into the provided buffer, not through these pointers.
    var header = std.mem.zeroes(linux.msghdr);
    header.namelen = name_bytes;
    header.controllen = control_bytes;

    const sqe = try ring.get_sqe();
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    sqe.opcode = .RECVMSG;
    sqe.fd = receiver;
    sqe.addr = @intFromPtr(&header);
    sqe.len = 1;
    sqe.ioprio = linux.IORING_RECV_MULTISHOT;
    sqe.flags |= linux.IOSQE_BUFFER_SELECT;
    sqe.buf_index = buffer_group;
    sqe.user_data = user_data_receive;
    _ = try ring.submit();

    try send_one(&bound);
    const cqe = try ring.copy_cqe();
    if (cqe.res < 0) {
        const errno: linux.E = @enumFromInt(@as(u32, @intCast(-cqe.res)));
        return report.refused(multishot_recvmsg, "the completion", errno);
    }
    try report_result(report, cqe, &buffers);
}

/// What the kernel wrote, and what it counted. This is the whole point of the probe.
fn report_result(report: *Report, cqe: linux.io_uring_cqe, buffers: []u8) !void {
    const more = cqe.flags & linux.IORING_CQE_F_MORE != 0;
    const selected = cqe.flags & linux.IORING_CQE_F_BUFFER != 0;
    if (!selected) {
        return report.verdict(multishot_recvmsg, .missing, ", no buffer was selected", .{});
    }
    const id = cqe.flags >> linux.IORING_CQE_BUFFER_SHIFT;
    const buffer = buffers[id * buffer_bytes ..][0..buffer_bytes];
    const head: *const linux.io_uring_recvmsg_out = @ptrCast(@alignCast(buffer.ptr));
    try report.verdict(multishot_recvmsg, .present, ", more={}, buffer id {d}", .{ more, id });

    const head_bytes = @sizeOf(linux.io_uring_recvmsg_out);
    try report.line(
        "  recvmsg_out: namelen {d}, controllen {d}, payloadlen {d}, flags 0x{x}",
        .{ head.namelen, head.controllen, head.payloadlen, head.flags },
    );

    // The kernel lays the payload out after the space the submission ASKED for, and writes the
    // bytes it actually used into the head. The two differ whenever the peer address is shorter
    // than the reserve or the control messages are: here `namelen` comes back 16 for a
    // `sockaddr.in` although 32 was reserved. An offset computed from the written lengths lands
    // short of the payload and reads the tail of the control block, which is what the first
    // version of this probe did.
    const prefix = head_bytes + name_bytes + control_bytes;
    const reported = head_bytes + head.namelen + head.controllen;
    try report.line(
        "  prefix asked {d} (head {d} + name {d} + control {d}); prefix written {d}",
        .{ prefix, head_bytes, name_bytes, control_bytes, reported },
    );
    try report.line(
        "  cqe.res {d}; payload sent {d}; cqe.res - prefix {d}",
        .{ cqe.res, payload.len, @as(i32, @intCast(cqe.res)) - @as(i32, prefix) },
    );

    // The question decision 15 turns on: what a backend subtracts to report payload bytes. A
    // constant per buffer group is the cheap answer, because the group fixes the reserve.
    const by_subtraction = @as(i64, cqe.res) - @as(i64, prefix) == @as(i64, head.payloadlen);
    const verdict_text = if (by_subtraction)
        "cqe.res - prefix == payloadlen; ONE SUBTRACT OF A GROUP CONSTANT"
    else
        "cqe.res - prefix does NOT equal payloadlen; the head must be read";
    try report.line("  VERDICT: {s}", .{verdict_text});

    const got = buffer[prefix..][0..@min(head.payloadlen, payload.len)];
    const matched = std.mem.eql(u8, got, payload[0..got.len]) and by_subtraction;
    try report.verdict(
        recvmsg_layout,
        if (matched) .present else .missing,
        ", payload starts at {d} and the bytes {s}",
        .{ prefix, if (std.mem.eql(u8, got, payload[0..got.len])) "match" else "DO NOT MATCH" },
    );
}

fn send_one(to: *const linux.sockaddr.in) !void {
    const sender = try open_datagram();
    defer _ = linux.close(sender);
    const rc = linux.sendto(
        sender,
        payload,
        payload.len,
        0,
        @ptrCast(to),
        @sizeOf(linux.sockaddr.in),
    );
    _ = try probe.check("sendto", rc);
}

fn open_datagram() !i32 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    return @intCast(try probe.check("socket", rc));
}

fn set_option(socket: i32, level: u32, name: u32, value: c_int) linux.E {
    const rc = linux.setsockopt(
        socket,
        @intCast(level),
        name,
        std.mem.asBytes(&value),
        @sizeOf(c_int),
    );
    return linux.errno(rc);
}

fn register_ring(ring: *IoUring, memory: []align(4096) u8) ![*]linux.io_uring_buf {
    var registration = std.mem.zeroes(linux.io_uring_buf_reg);
    registration.ring_addr = @intFromPtr(memory.ptr);
    registration.ring_entries = buffer_ring_entries;
    registration.bgid = buffer_group;
    const rc = linux.io_uring_register(
        ring.fd,
        .REGISTER_PBUF_RING,
        @ptrCast(&registration),
        1,
    );
    _ = try probe.check("io_uring_register(REGISTER_PBUF_RING)", rc);
    return @ptrCast(memory.ptr);
}

/// Writes every buffer into the ring and publishes them, as `uring_buffers.provide` does.
fn provide(buffer_ring: [*]linux.io_uring_buf, buffers: []u8) void {
    const mask: u16 = buffer_ring_entries - 1;
    for (0..buffer_ring_entries) |index| {
        const entry = &buffer_ring[(index) & mask];
        entry.addr = @intFromPtr(buffers.ptr) + index * buffer_bytes;
        entry.len = buffer_bytes;
        entry.bid = @intCast(index);
    }
    const tail: *volatile u16 = @ptrCast(@alignCast(&buffer_ring[0].resv));
    @atomicStore(u16, tail, buffer_ring_entries, .release);
}
