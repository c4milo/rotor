//! The checks of uring_probe.zig that run an operation, because the kernel lists no feature bit
//! and no opcode for them: multishot accept, provided buffer rings (IORING_REGISTER_PBUF_RING)
//! and multishot receive. A kernel without one answers EINVAL.
//!
//! They run the path the backend will run. A listener on 127.0.0.1 arms one multishot accept and
//! two clients connect. One accepted connection then arms one multishot receive that takes its
//! buffers from the provided buffer ring, and its client sends two messages. Each operation is
//! armed before its first event arrives, so every completion comes by the kernel's internal poll
//! and not at submission. "Present" means one submission produced every completion, the first of
//! them flagged IORING_CQE_F_MORE, and the provided buffers hold the bytes that were sent.

const std = @import("std");
const probe = @import("uring_probe.zig");

const linux = probe.linux;
const IoUring = probe.IoUring;
const Report = probe.Report;
const Feature = probe.Feature;
const assert = std.debug.assert;

const multishot_accept: Feature = .{ .name = "multishot accept" };
const pbuf_ring: Feature = .{ .name = "IORING_REGISTER_PBUF_RING" };
const multishot_receive: Feature = .{ .name = "multishot receive" };

/// 127.0.0.1 as `sockaddr.in` holds it, in network byte order.
const loopback_address = std.mem.nativeToBig(u32, 0x7f00_0001);

/// The connections the probe opens, and so the completions one multishot accept must produce.
const connections = 2;

/// Entries of the provided buffer ring. The kernel requires a power of two.
const buffer_ring_entries = 4;

/// Bytes of each provided buffer: more than either of `messages`.
const buffer_bytes = 64;

/// The group the buffer ring is registered under. Any value a u16 holds would do.
const buffer_group = 7;

/// What the client sends. Each is sent after the one before it was reaped, so one multishot
/// receive must complete once per message.
const messages = [_][]const u8{ "first", "second" };

/// The user_data of the multishot accept, which every one of its completions must carry.
const user_data_accept = 0xacce;

/// The user_data of the multishot receive.
const user_data_receive = 0x4ecf;

/// The provided buffer ring. The kernel requires a page-aligned address, and `page_size_max` is
/// aligned for every page size the architecture allows.
var buffer_ring_memory: [buffer_ring_entries]linux.io_uring_buf align(std.heap.page_size_max) =
    std.mem.zeroes([buffer_ring_entries]linux.io_uring_buf);

/// The buffers the ring hands to the multishot receive.
var receive_buffers: [buffer_ring_entries][buffer_bytes]u8 = undefined;

/// Runs the three checks on `ring` in the order of decision 2's table.
pub fn check(report: *Report, ring: *IoUring) !void {
    const connection = try check_multishot_accept(report, ring);
    const buffers_ready = try check_buffer_ring(report, ring);
    try check_multishot_receive(report, ring, connection, buffers_ready);
}

/// One end each of a loopback TCP connection: `client` connected and the kernel `accepted`.
const Connection = struct { client: linux.fd_t, accepted: linux.fd_t };

fn open_socket() !linux.fd_t {
    const flags = linux.SOCK.STREAM | linux.SOCK.CLOEXEC;
    return @intCast(try probe.check("socket", linux.socket(linux.AF.INET, flags, 0)));
}

/// Arms one multishot accept, then opens `connections` connections to it.
fn check_multishot_accept(report: *Report, ring: *IoUring) !?Connection {
    const listener = try open_socket();
    var address: linux.sockaddr.in = .{ .port = 0, .addr = loopback_address };
    var address_bytes: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = try probe.check("bind", linux.bind(listener, @ptrCast(&address), address_bytes));
    _ = try probe.check("listen", linux.listen(listener, connections));
    const named = linux.getsockname(listener, @ptrCast(&address), &address_bytes);
    _ = try probe.check("getsockname", named);
    assert(address.port != 0);

    const sqe = try ring.get_sqe();
    sqe.prep_multishot_accept(listener, null, null, 0);
    sqe.user_data = user_data_accept;
    _ = try ring.submit();

    var clients: [connections]linux.fd_t = undefined;
    for (&clients) |*client| {
        client.* = try open_socket();
        _ = try probe.check("connect", linux.connect(client.*, &address, address_bytes));
    }
    var cqes: [connections]linux.io_uring_cqe = undefined;
    const count = try probe.reap(ring, &cqes, connections);
    const outcome = judge(cqes[0..count], user_data_accept, connections);
    try report_outcome(report, multishot_accept, "accepts", outcome, connections);
    if (outcome != .present) return null;
    // The accept queue is first in, first out, so the first completion is the first client's.
    return .{ .client = clients[0], .accepted = cqes[0].res };
}

/// What the completions of one multishot submission show.
const Outcome = union(enum) {
    present,
    /// A completion carried this errno.
    refused: linux.E,
    /// The first completion lacks IORING_CQE_F_MORE, so the kernel ran the operation once.
    ran_once,
    /// Only this many completions arrived before the wait ran out.
    short: usize,
};

fn judge(cqes: []const linux.io_uring_cqe, user_data: u64, wanted: usize) Outcome {
    assert(wanted > 0);
    assert(cqes.len <= wanted);
    for (cqes) |cqe| {
        assert(cqe.user_data == user_data);
        if (cqe.err() != .SUCCESS) return .{ .refused = cqe.err() };
    }
    if (cqes.len == 0) return .{ .short = 0 };
    if (cqes[0].flags & linux.IORING_CQE_F_MORE == 0) return .ran_once;
    if (cqes.len < wanted) return .{ .short = cqes.len };
    return .present;
}

fn report_outcome(
    report: *Report,
    feature: Feature,
    comptime noun: []const u8,
    outcome: Outcome,
    wanted: usize,
) !void {
    switch (outcome) {
        .present => try report.verdict(feature, .present, ", {d} " ++ noun ++
            " from 1 submission, the first with IORING_CQE_F_MORE", .{wanted}),
        .refused => |errno| try report.refused(feature, "the completion", errno),
        .ran_once => try report.verdict(feature, .missing, ", the first completion lacks" ++
            " IORING_CQE_F_MORE, so the kernel ran the operation once", .{}),
        .short => |count| try report.verdict(feature, .missing, ", {d} of {d} " ++ noun ++
            " arrived within {d} s", .{ count, wanted, probe.wait_seconds }),
    }
}

/// Registers the provided buffer ring and hands the kernel every buffer.
fn check_buffer_ring(report: *Report, ring: *IoUring) !bool {
    const buffer_ring: *linux.io_uring_buf_ring = @ptrCast(&buffer_ring_memory);
    const registration: linux.io_uring_buf_reg = .{
        .ring_addr = @intFromPtr(buffer_ring),
        .ring_entries = buffer_ring_entries,
        .bgid = buffer_group,
        .flags = .{ .inc = false },
        .resv = @splat(0),
    };
    const result = linux.io_uring_register(ring.fd, .REGISTER_PBUF_RING, &registration, 1);
    if (linux.errno(result) != .SUCCESS) {
        try report.refused(pbuf_ring, "io_uring_register", linux.errno(result));
        return false;
    }
    IoUring.buf_ring_init(buffer_ring);
    const mask = IoUring.buf_ring_mask(buffer_ring_entries);
    for (&receive_buffers, 0..) |*buffer, index| {
        IoUring.buf_ring_add(buffer_ring, buffer, @intCast(index), mask, @intCast(index));
    }
    IoUring.buf_ring_advance(buffer_ring, buffer_ring_entries);
    const detail = ", {d} buffers registered as group {d}";
    try report.verdict(pbuf_ring, .present, detail, .{ buffer_ring_entries, buffer_group });
    return true;
}

/// Arms one multishot receive that takes its buffers from the ring, then sends `messages`.
fn check_multishot_receive(
    report: *Report,
    ring: *IoUring,
    connection: ?Connection,
    buffers_ready: bool,
) !void {
    const feature = multishot_receive;
    const peer = connection orelse {
        return report.verdict(feature, .not_tried, ", it needs multishot accept", .{});
    };
    if (!buffers_ready) {
        return report.verdict(feature, .not_tried, ", it needs {s}", .{pbuf_ring.name});
    }
    const sqe = try ring.get_sqe();
    sqe.prep_rw(.RECV, peer.accepted, 0, 0, 0);
    sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
    sqe.flags |= linux.IOSQE_BUFFER_SELECT;
    sqe.buf_index = buffer_group;
    sqe.user_data = user_data_receive;
    _ = try ring.submit();

    var cqes: [messages.len]linux.io_uring_cqe = undefined;
    var count: usize = 0;
    for (messages) |message| {
        _ = try probe.check("write", linux.write(peer.client, message.ptr, message.len));
        if (try probe.reap(ring, cqes[count..][0..1], 1) == 0) break;
        count += 1;
        if (cqes[count - 1].err() != .SUCCESS) break;
    }
    const outcome = judge(cqes[0..count], user_data_receive, messages.len);
    if (outcome == .present and !buffers_hold_messages(&cqes)) {
        const detail = ", a completion's buffer does not hold the bytes that were sent";
        return report.verdict(feature, .missing, detail, .{});
    }
    const noun = "receives into provided buffers";
    try report_outcome(report, feature, noun, outcome, messages.len);
}

fn buffers_hold_messages(cqes: *const [messages.len]linux.io_uring_cqe) bool {
    for (cqes, messages) |cqe, message| {
        const buffer_id = cqe.buffer_id() catch return false;
        if (buffer_id >= buffer_ring_entries or cqe.res != message.len) return false;
        if (!std.mem.eql(u8, receive_buffers[buffer_id][0..message.len], message)) return false;
    }
    return true;
}
