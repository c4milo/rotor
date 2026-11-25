//! A test of `linux_shared_sync_socket.zig` in a file of its own, so that one stays at or under
//! 500 lines (CLAUDE.md, Conventions). `linux_shared.zig` names this file so it runs.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const core = @import("core");
const sync_socket = @import("linux_shared_sync_socket.zig");

const Address = core.Address;
const testing = std.testing;
const open_datagram = sync_socket.open_datagram;
const local_address = sync_socket.local_address;
const close_now = sync_socket.close_now;

/// The type flags of the `uring` backend's sockets; the option does not depend on them.
const flags: u32 = linux.SOCK.CLOEXEC;

test "datagram sockets share a port only when each asks for reuse_port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 0);
    const first = try open_datagram(.ipv4, &loopback, .{ .reuse_port = true }, flags);
    defer close_now(first);
    const shared = try local_address(first);
    const second = try open_datagram(.ipv4, &shared, .{ .reuse_port = true }, flags);
    defer close_now(second);
    try testing.expectEqual(shared.port, (try local_address(second)).port);
    // A socket that does not ask cannot join the group.
    try testing.expectError(error.AddressInUse, open_datagram(.ipv4, &shared, .{}, flags));
    // A socket that asks cannot join one that did not.
    const alone = try open_datagram(.ipv4, &loopback, .{}, flags);
    defer close_now(alone);
    const alone_address = try local_address(alone);
    try testing.expectError(error.AddressInUse, open_datagram(.ipv4, &alone_address, .{ .reuse_port = true }, flags));
}
