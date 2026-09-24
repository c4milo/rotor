//! The macOS probe decision 15 asks for. rotor had none: every claim about what this kernel does
//! came from reading the SDK's headers, and a header says what a symbol is named, not what the
//! kernel honours.
//!
//! It matters more here than on Linux, because the IPv6 options rotor uses sit behind
//! `__APPLE_USE_RFC_3542` in `netinet6/in6.h` and Zig defines no such macro. rotor names them by
//! their numbers instead, on the argument that the macro gates the header and not the kernel.
//! **This program is what turns that argument into a measurement.** It also states plainly what
//! macOS does not have, so no later reader has to rediscover it.
//!
//! It runs natively in `zig build test` and needs no container: unlike the io_uring probe, the
//! kernel it asks about is the one running it.
//!
//! Exit status is 0 when every required check passed. A check marked optional may fail and says
//! so; nothing here is required to run rotor today, because macOS is a development platform
//! (decision 2).
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

/// The option numbers rotor names by value, each read from the SDK on 2026-09-20 and each cited
/// where `src/kqueue/kqueue_datagram.zig` declares it.
const ip_pktinfo = 26;
const ip_recvtos = 27;
const ip_dontfrag = 28;
const ip_tos = 3;
const ipv6_recvtclass = 35;
const ipv6_tclass = 36;
const ipv6_pktinfo = 46;
const ipv6_recvpktinfo = 61;
const ipv6_dontfrag = 62;
/// `netinet/udp.h` defines exactly one option, and this is it. There is no `UDP_SEGMENT` and no
/// `UDP_GRO` to name.
const udp_nocksum = 1;

const line_prefix = "macos_probe: ";

/// The bytes a datagram of this probe carries, and the codepoint it is marked with.
const payload = "rotor macos probe";
/// `ect0` in the low two bits, with a DSCP above them, so the report says whether the kernel
/// dropped the codepoint alone or the whole type-of-service byte.
const marked_codepoint: c_int = 0x28 | 2;

/// The two congestion bits of the traffic class byte.
const ecn_mask: u8 = 0b11;

const Report = struct {
    out: *std.Io.Writer,
    failed: ?[]const u8 = null,

    fn line(report: *Report, comptime format: []const u8, arguments: anytype) !void {
        try report.out.print(line_prefix ++ format ++ "\n", arguments);
        try report.out.flush();
    }

    /// One check's verdict. `required` false means a "no" is recorded and not a failure.
    fn verdict(
        report: *Report,
        name: []const u8,
        passed: bool,
        required: bool,
        comptime detail: []const u8,
        arguments: anytype,
    ) !void {
        const state = if (passed) "present" else if (required) "MISSING" else "absent";
        try report.out.print(line_prefix ++ "{s}: {s}", .{ name, state });
        try report.out.print(detail ++ "\n", arguments);
        try report.out.flush();
        if (passed or !required) return;
        if (report.failed == null) report.failed = name;
    }
};

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    var report: Report = .{ .out = &out.interface };

    if (builtin.os.tag == .linux) {
        try report.line("this probe asks about macOS and is running on Linux; nothing was run", .{});
        return;
    }
    try report.line("darwin {s}", .{@tagName(builtin.os.tag)});

    try check_options(&report);
    try check_source_selection(&report);
    try check_codepoint(&report);
    try check_absent(&report);

    if (report.failed) |name| {
        try report.line("{s} is required and was not present", .{name});
        return error.FeatureMissing;
    }
    try report.line("every required feature is present", .{});
}

/// Every option rotor sets on a datagram socket, by the number it names it with. A kernel that
/// does not honour one answers ENOPROTOOPT, which is the whole question about RFC 3542.
fn check_options(report: *Report) !void {
    const four = try open_datagram(c.AF.INET);
    defer _ = c.close(four);
    try option(report, "IP_PKTINFO", four, c.IPPROTO.IP, ip_pktinfo, true);
    try option(report, "IP_RECVTOS", four, c.IPPROTO.IP, ip_recvtos, true);
    try option(report, "IP_DONTFRAG", four, c.IPPROTO.IP, ip_dontfrag, true);

    const six = open_datagram(c.AF.INET6) catch {
        return report.line("no IPv6 stack on this host; its options were not tried", .{});
    };
    defer _ = c.close(six);
    // These four are the ones behind `__APPLE_USE_RFC_3542`. If the macro gated the kernel and
    // not only the header, each would answer ENOPROTOOPT here.
    try option(report, "IPV6_RECVTCLASS", six, c.IPPROTO.IPV6, ipv6_recvtclass, true);
    try option(report, "IPV6_TCLASS", six, c.IPPROTO.IPV6, ipv6_tclass, true);
    // 61 enables the report; 46 is the cmsg type the report arrives as. Asking with 46 gets
    // EINVAL, which the first version of this probe did and which the tree copied.
    try option(report, "IPV6_RECVPKTINFO", six, c.IPPROTO.IPV6, ipv6_recvpktinfo, true);
    try option(report, "IPV6_PKTINFO as an option", six, c.IPPROTO.IPV6, ipv6_pktinfo, false);
    try option(report, "IPV6_DONTFRAG (RFC 3542)", six, c.IPPROTO.IPV6, ipv6_dontfrag, true);
}

fn option(
    report: *Report,
    name: []const u8,
    socket: c.fd_t,
    level: u32,
    number: u32,
    required: bool,
) !void {
    const enabled: c_int = 1;
    const rc = c.setsockopt(socket, @intCast(level), number, &enabled, @sizeOf(c_int));
    const errno = posix.errno(rc);
    if (errno != .SUCCESS) {
        return report.verdict(name, false, required, ", setsockopt answered E{s}", .{
            @tagName(errno),
        });
    }
    try report.verdict(name, true, required, ", option {d} took it", .{number});
}

/// The claim that matters most: `IP_PKTINFO` selects the **source address** of an outgoing
/// datagram, which is what a QUIC server on a wildcard address needs to answer from the address
/// a client wrote to. The SDK says so; this makes the kernel say so.
fn check_source_selection(report: *Report) !void {
    const receiver = try open_datagram(c.AF.INET);
    defer _ = c.close(receiver);
    const enabled: c_int = 1;
    _ = c.setsockopt(receiver, c.IPPROTO.IP, ip_pktinfo, &enabled, @sizeOf(c_int));
    // The wildcard address, so the kernel picks a source unless the sender names one.
    var bound: posix.sockaddr.in = .{ .port = 0, .addr = 0 };
    if (c.bind(receiver, @ptrCast(&bound), @sizeOf(posix.sockaddr.in)) < 0) {
        return report.verdict("IP_PKTINFO source selection", false, true, ", bind failed", .{});
    }
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    _ = c.getsockname(receiver, @ptrCast(&bound), &len);

    const sender = try open_datagram(c.AF.INET);
    defer _ = c.close(sender);
    var to: posix.sockaddr.in = .{ .port = bound.port, .addr = loopback_bits };
    const sent = c.sendto(
        sender,
        payload,
        payload.len,
        0,
        @ptrCast(&to),
        @sizeOf(posix.sockaddr.in),
    );
    if (sent != payload.len) {
        return report.verdict("IP_PKTINFO source selection", false, true, ", sendto failed", .{});
    }
    try read_back(report, receiver);
}

/// Reads the datagram and reports whether the kernel told the receiver which of this host's
/// addresses it was sent to.
fn read_back(report: *Report, receiver: c.fd_t) !void {
    var bytes: [64]u8 = undefined;
    var control: [128]u8 align(@alignOf(c.cmsghdr)) = undefined;
    var name: posix.sockaddr.in = undefined;
    var vector: posix.iovec = .{ .base = &bytes, .len = bytes.len };
    var header = std.mem.zeroes(c.msghdr);
    header.name = @ptrCast(&name);
    header.namelen = @sizeOf(posix.sockaddr.in);
    header.iov = @ptrCast(&vector);
    header.iovlen = 1;
    header.control = &control;
    header.controllen = control.len;
    const count = c.recvmsg(receiver, &header, 0);
    if (count != payload.len) {
        return report.verdict("IP_PKTINFO source selection", false, true, ", recvmsg gave {d}", .{
            count,
        });
    }
    const found = find_control(control[0..@intCast(header.controllen)], c.IPPROTO.IP, ip_pktinfo);
    try report.verdict(
        "IP_PKTINFO source selection",
        found != null,
        true,
        ", the receiver was told the destination address: {}",
        .{found != null},
    );
}

/// The codepoint both ways: marked on a send with `IP_TOS`, reported on a receive with
/// `IP_RECVTOS`. QUIC's congestion control reads it, so a kernel that drops it silently would
/// leave rotor reporting `not_ect` for every datagram.
fn check_codepoint(report: *Report) !void {
    const receiver = try open_datagram(c.AF.INET);
    defer _ = c.close(receiver);
    const enabled: c_int = 1;
    _ = c.setsockopt(receiver, c.IPPROTO.IP, ip_recvtos, &enabled, @sizeOf(c_int));
    var bound: posix.sockaddr.in = .{ .port = 0, .addr = loopback_bits };
    if (c.bind(receiver, @ptrCast(&bound), @sizeOf(posix.sockaddr.in)) < 0) return;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    _ = c.getsockname(receiver, @ptrCast(&bound), &len);

    const sender = try open_datagram(c.AF.INET);
    defer _ = c.close(sender);
    _ = c.setsockopt(sender, c.IPPROTO.IP, ip_tos, &marked_codepoint, @sizeOf(c_int));
    var to: posix.sockaddr.in = .{ .port = bound.port, .addr = loopback_bits };
    _ = c.sendto(sender, payload, payload.len, 0, @ptrCast(&to), @sizeOf(posix.sockaddr.in));

    var bytes: [64]u8 = undefined;
    var control: [128]u8 align(@alignOf(c.cmsghdr)) = undefined;
    var vector: posix.iovec = .{ .base = &bytes, .len = bytes.len };
    var header = std.mem.zeroes(c.msghdr);
    header.iov = @ptrCast(&vector);
    header.iovlen = 1;
    header.control = &control;
    header.controllen = control.len;
    if (c.recvmsg(receiver, &header, 0) != payload.len) return;

    const written = control[0..@intCast(header.controllen)];
    const carried = find_control(written, c.IPPROTO.IP, ip_recvtos) orelse
        find_control(written, c.IPPROTO.IP, ip_tos);
    const whole: ?u8 = if (carried) |slice| slice[0] else null;
    const codepoint: ?u8 = if (whole) |byte| byte & ecn_mask else null;
    // The mark is a whole type-of-service byte, and the codepoint is its low two bits. Until
    // 2026-09-23 this compared the codepoint with the whole byte, so it could never pass.
    const sent_codepoint = @as(u8, @intCast(marked_codepoint)) & ecn_mask;
    const kept = codepoint != null and codepoint.? == sent_codepoint;
    try report.verdict(
        "IP_TOS and IP_RECVTOS carry the codepoint",
        kept,
        false,
        ", sent TOS {d}; the receiver read TOS {?d}, codepoint {?d}",
        .{ marked_codepoint, whole, codepoint },
    );
    if (!kept) {
        try report.line(
            "  the codepoint did not survive; a QUIC stack on this host runs without ECN",
            .{},
        );
    }
}

/// What macOS does not have, stated rather than assumed. A later kernel that gains one of these
/// makes this probe say so, which is the only way the tree would find out.
fn check_absent(report: *Report) !void {
    const socket = try open_datagram(c.AF.INET);
    defer _ = c.close(socket);
    // Linux numbers these 103 and 104. macOS numbers nothing there, so asking is the check.
    const linux_udp_segment = 103;
    const linux_udp_gro = 104;
    try absent(report, "UDP segmentation (Linux UDP_SEGMENT)", socket, linux_udp_segment);
    try absent(report, "UDP coalescing (Linux UDP_GRO)", socket, linux_udp_gro);
    // The one UDP option macOS does define, as a control: this probe asks the kernel correctly.
    try option(report, "UDP_NOCKSUM", socket, c.IPPROTO.UDP, udp_nocksum, true);
}

/// A check that passes when the kernel **refuses** the option: decision 15 refuses a segmented
/// send on macOS, and this is the evidence for that refusal rather than an assumption.
fn absent(report: *Report, name: []const u8, socket: c.fd_t, number: u32) !void {
    const value: c_int = 1;
    const rc = c.setsockopt(socket, c.IPPROTO.UDP, number, &value, @sizeOf(c_int));
    const refused = posix.errno(rc) != .SUCCESS;
    try report.verdict(name, !refused, false, ", option {d} was {s}", .{
        number,
        if (refused) "refused, as decision 15 says" else "TAKEN, which this tree does not expect",
    });
}

const loopback_bits: u32 = std.mem.nativeToBig(u32, 0x7f00_0001);

/// The payload of the first control message with this level and type, or null.
fn find_control(control: []const u8, level: u32, number: u32) ?[]const u8 {
    const unit = @alignOf(u32);
    const header_bytes = (@sizeOf(c.cmsghdr) + unit - 1) & ~(unit - @as(usize, 1));
    var offset: usize = 0;
    while (offset + header_bytes <= control.len) {
        const header: *const c.cmsghdr = @ptrCast(@alignCast(&control[offset]));
        const len: usize = @intCast(header.len);
        if (len < header_bytes or offset + len > control.len) return null;
        if (header.level == @as(i32, @intCast(level)) and header.type == @as(i32, @intCast(number))) {
            return control[offset + header_bytes ..][0 .. len - header_bytes];
        }
        offset += (len + unit - 1) & ~(unit - @as(usize, 1));
    }
    return null;
}

fn open_datagram(family: u32) !c.fd_t {
    const rc = c.socket(family, c.SOCK.DGRAM, c.IPPROTO.UDP);
    if (rc < 0) return error.SocketFailed;
    return rc;
}
