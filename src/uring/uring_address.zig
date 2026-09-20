//! `core.Address` to and from the kernel's socket address structures, `sockaddr_in` and
//! `sockaddr_in6`. The surface names no kernel type (decision 1), so every address crosses here on
//! its way into a `bind` or a `connect` and on its way out of a `getsockname`.
//!
//! This file enters no kernel. It reads `std.os.linux` for types and constants alone, so its
//! tests run on every host.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const core = @import("core");

const Address = core.Address;

/// Room for either family's socket address, aligned for both.
pub const Storage = extern union { in: linux.sockaddr.in, in6: linux.sockaddr.in6 };

/// Writes `address` into `storage` in the kernel's form (port and address in network byte order)
/// and returns the length the kernel expects for that family. Every byte of `storage` past that
/// length is zero.
///
/// `address` has the form `Address.ipv4` and `Address.ipv6` build, in which an IPv4 address
/// carries no scope id and no octet past its fourth. So every address this function accepts comes
/// back from `from_kernel` byte for byte.
pub fn to_kernel(address: *const Address, storage: *Storage) linux.socklen_t {
    assert(address.reserved == 0);
    storage.* = std.mem.zeroes(Storage);
    const port = std.mem.nativeToBig(u16, address.port);
    switch (address.family) {
        .ipv4 => {
            // Both are IPv6's alone, and `sockaddr_in` has no field that could carry them.
            assert(address.scope_id == 0);
            assert(std.mem.allEqual(u8, address.bytes[Address.ipv4_bytes..], 0));
            storage.in = .{
                .family = linux.AF.INET,
                .port = port,
                // `bytes` and `addr` both hold network byte order, so the octets move as they are.
                .addr = @bitCast(address.bytes[0..Address.ipv4_bytes].*),
            };
            return @sizeOf(linux.sockaddr.in);
        },
        .ipv6 => {
            storage.in6 = .{
                .family = linux.AF.INET6,
                .port = port,
                .flowinfo = 0,
                .addr = address.bytes,
                // An interface index, which the kernel keeps in host byte order.
                .scope_id = address.scope_id,
            };
            return @sizeOf(linux.sockaddr.in6);
        },
    }
}

/// The `core.Address` a kernel socket address holds, or null for a family rotor does not carry.
/// `len` is the length the kernel reported for `storage`.
///
/// The length picks the structure, and the family must agree with it. Any other length means
/// another family, an address the kernel cut short, or none written, and then no field is read.
pub fn from_kernel(storage: *const Storage, len: linux.socklen_t) ?Address {
    // The kernel reports no length past `sockaddr_storage`, whatever the family.
    assert(len <= @sizeOf(linux.sockaddr.storage));
    switch (len) {
        @sizeOf(linux.sockaddr.in) => {
            if (storage.in.family != linux.AF.INET) return null;
            const octets: [Address.ipv4_bytes]u8 = @bitCast(storage.in.addr);
            return Address.ipv4(octets, std.mem.bigToNative(u16, storage.in.port));
        },
        @sizeOf(linux.sockaddr.in6) => {
            if (storage.in6.family != linux.AF.INET6) return null;
            const port = std.mem.bigToNative(u16, storage.in6.port);
            return Address.ipv6(storage.in6.addr, port, storage.in6.scope_id);
        },
        else => return null,
    }
}

/// The four octets of an IPv4 address as the kernel's `in_addr` holds them: network byte order
/// in both, so they move as they are. A control message carries a bare address with no port
/// (decision 15), which neither `to_kernel` nor `from_kernel` can express.
pub fn ipv4_bits(address: *const Address) u32 {
    assert(address.family == .ipv4);
    return @bitCast(address.bytes[0..Address.ipv4_bytes].*);
}

/// The `core.Address` those four octets name, with `port`.
pub fn ipv4_of(bits: u32, port: u16) Address {
    const octets: [Address.ipv4_bytes]u8 = @bitCast(bits);
    return Address.ipv4(octets, port);
}

test "an IPv4 address round-trips through the bare form a control message carries" {
    const address = Address.ipv4(.{ 198, 51, 100, 9 }, 443);
    const back = ipv4_of(ipv4_bits(&address), 0);
    try std.testing.expectEqualSlices(u8, &address.bytes, &back.bytes);
    try std.testing.expectEqual(@as(u16, 0), back.port);
}

comptime {
    // `Storage` has the size of the larger structure and the alignment both need, 4 bytes.
    assert(@sizeOf(Storage) == @sizeOf(linux.sockaddr.in6));
    assert(@sizeOf(linux.sockaddr.in) == 16);
    assert(@sizeOf(linux.sockaddr.in6) == 28);
    assert(@alignOf(Storage) == @alignOf(u32));
    // `from_kernel` tells the two structures apart by their lengths.
    assert(@sizeOf(linux.sockaddr.in) != @sizeOf(linux.sockaddr.in6));
    // The octets of a `core.Address` fill the kernel's address fields exactly.
    assert(@sizeOf(@FieldType(linux.sockaddr.in, "addr")) == Address.ipv4_bytes);
    assert(@sizeOf(@FieldType(linux.sockaddr.in6, "addr")) == Address.ipv6_bytes);
}

const testing = std.testing;

fn expect_same(expected: Address, actual: ?Address) !void {
    try testing.expect(actual != null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&actual.?));
}

test "an IPv4 address round-trips and its kernel form is in network byte order" {
    const address = Address.ipv4(.{ 192, 168, 7, 9 }, 0x1F90);
    var storage: Storage = undefined;
    const len = to_kernel(&address, &storage);
    try testing.expectEqual(@as(linux.socklen_t, @sizeOf(linux.sockaddr.in)), len);
    try testing.expectEqual(@as(linux.sa_family_t, linux.AF.INET), storage.in.family);

    // The two bytes of the port, as the kernel reads them, whatever the host's byte order.
    const kernel_bytes = std.mem.asBytes(&storage.in);
    const port_offset = @offsetOf(linux.sockaddr.in, "port");
    try testing.expectEqualSlices(u8, &.{ 0x1F, 0x90 }, kernel_bytes[port_offset..][0..2]);
    const addr_offset = @offsetOf(linux.sockaddr.in, "addr");
    try testing.expectEqualSlices(u8, &.{ 192, 168, 7, 9 }, kernel_bytes[addr_offset..][0..4]);
    try testing.expect(std.mem.allEqual(u8, &storage.in.zero, 0));
    try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&storage)[len..], 0));

    try expect_same(address, from_kernel(&storage, len));
}

test "an IPv6 address round-trips, keeps its scope id and holds its port big-endian" {
    var octets: [Address.ipv6_bytes]u8 = undefined;
    for (&octets, 0..) |*octet, index| octet.* = @intCast(0xF0 + index);
    const address = Address.ipv6(octets, 0x01BB, 0x0A0B0C0D);
    var storage: Storage = undefined;
    const len = to_kernel(&address, &storage);
    try testing.expectEqual(@as(linux.socklen_t, @sizeOf(linux.sockaddr.in6)), len);
    try testing.expectEqual(@as(linux.sa_family_t, linux.AF.INET6), storage.in6.family);

    const kernel_bytes = std.mem.asBytes(&storage.in6);
    const port_offset = @offsetOf(linux.sockaddr.in6, "port");
    try testing.expectEqualSlices(u8, &.{ 0x01, 0xBB }, kernel_bytes[port_offset..][0..2]);
    try testing.expectEqualSlices(u8, &octets, &storage.in6.addr);
    try testing.expectEqual(@as(u32, 0x0A0B0C0D), storage.in6.scope_id);
    try testing.expectEqual(@as(u32, 0), storage.in6.flowinfo);

    const back = from_kernel(&storage, len);
    try expect_same(address, back);
    try testing.expectEqual(@as(u32, 0x0A0B0C0D), back.?.scope_id);
}

test "a family rotor does not carry yields null, whatever length comes with it" {
    var storage = std.mem.zeroes(Storage);
    const families = [_]linux.sa_family_t{ linux.AF.UNSPEC, linux.AF.UNIX, linux.AF.NETLINK };
    for (families) |family| {
        storage.in.family = family;
        for ([_]linux.socklen_t{ 2, 12, 16, 28, 110 }) |len| {
            try testing.expectEqual(@as(?Address, null), from_kernel(&storage, len));
        }
    }
}

test "a length that is not the family's own yields null" {
    const loopback = Address.ipv4(.{ 127, 0, 0, 1 }, 80);
    var storage: Storage = undefined;
    const len = to_kernel(&loopback, &storage);
    try expect_same(loopback, from_kernel(&storage, len));
    for ([_]linux.socklen_t{ 0, 1, 2, len - 1, len + 1, @sizeOf(Storage) }) |wrong| {
        try testing.expectEqual(@as(?Address, null), from_kernel(&storage, wrong));
    }

    const loopback6 = Address.ipv6(@splat(0), 80, 0);
    const len6 = to_kernel(&loopback6, &storage);
    try expect_same(loopback6, from_kernel(&storage, len6));
    for ([_]linux.socklen_t{ 0, 1, 2, @sizeOf(linux.sockaddr.in), len6 - 1, len6 + 1 }) |wrong| {
        try testing.expectEqual(@as(?Address, null), from_kernel(&storage, wrong));
    }
}

test "random addresses of both families round-trip, under a named seed" {
    const seed: u64 = 0x5EED_ADD7;
    var random = core.random.Random.init(seed);
    for (0..1024) |round| {
        var octets: [Address.ipv6_bytes]u8 = undefined;
        std.mem.writeInt(u64, octets[0..8], random.next(), .little);
        std.mem.writeInt(u64, octets[8..16], random.next(), .little);
        const port: u16 = @truncate(random.next());
        const address = if (random.chance(1, 2))
            Address.ipv4(octets[0..Address.ipv4_bytes].*, port)
        else
            Address.ipv6(octets, port, @truncate(random.next()));
        var storage: Storage = undefined;
        const len = to_kernel(&address, &storage);
        expect_same(address, from_kernel(&storage, len)) catch |err| {
            std.debug.print("seed 0x{X} failed at round {d}\n", .{ seed, round });
            return err;
        };
    }
}
