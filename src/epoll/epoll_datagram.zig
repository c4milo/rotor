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
const address_module = @import("linux_shared").address;
const shared = @import("linux_shared").datagram;
const socket_calls = @import("epoll_sync_socket.zig");

const Address = core.Address;
const Ecn = core.datagram.Ecn;
const Head = core.datagram.Head;
const Received = core.datagram.Received;
const Outbound = core.datagram.Outbound;
const GroupOptions = core.datagram.GroupOptions;

/// The control blocks are `linux_shared_datagram.zig`'s, shared with the other Linux backend.
pub const control_bytes_max = shared.control_bytes_max;
pub const control_space = shared.control_space;
pub const delivery = shared.delivery;
const write_control = shared.write_control;

pub const Answer = core.datagram.Answer;

const answer_of = core.datagram.answer_of;

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
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        const rc = linux.recvmsg(descriptor, &header, 0);
        const errno = linux.errno(rc);
        if (errno == .SUCCESS) {
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
        if (answer_of(errno)) |answer| return answer;
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
    while (retry <= core.constants.interrupt_retries_max) : (retry += 1) {
        const rc = linux.sendmsg(descriptor, &header, linux.MSG.NOSIGNAL);
        const errno = linux.errno(rc);
        if (errno == .SUCCESS) return Answer.done(@intCast(rc));
        if (answer_of(errno)) |answer| return answer;
    }
    return Answer.refused(.would_block);
}

const testing = std.testing;

test "EINTR makes the call again, EAGAIN waits for readiness, and any other errno is refused" {
    // A signal cannot be made to land inside a non-blocking call, so the errno is fabricated.
    try testing.expectEqual(@as(?Answer, null), answer_of(.INTR));
    try testing.expectEqual(@as(?Answer, Answer.not_ready), answer_of(.AGAIN));
    const refused = answer_of(.MSGSIZE).?;
    try testing.expect(!refused.would_block);
    try testing.expectEqual(core.event.result_of(.message_too_long), refused.result);
}

/// One byte more than the 16-bit length field of a UDP header can state.
const oversized: [std.math.maxInt(u16) + 1]u8 = @splat(0);

test "a datagram longer than UDP can carry ends with message_too_long" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    // Linux refuses the send with EMSGSIZE before it copies a byte. `core.errno.code_of` has no arm
    // for EMSGSIZE, so this fails if the send stops asking the datagram map.
    const socket = try socket_calls.open_datagram(.ipv4, null, .{});
    defer socket_calls.close_now(socket);
    const out: Outbound = .{
        .peer = Address.ipv4(.{ 127, 0, 0, 1 }, 9),
        .local = undefined,
        .segment_bytes = 0,
        .ecn = .not_ect,
        .flags = .{ .peer = true },
    };
    const answer = send_from(socket, &oversized, &out);
    try testing.expect(!answer.would_block);
    try testing.expectEqual(core.event.result_of(.message_too_long), answer.result);
}
