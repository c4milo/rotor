//! `core.Address` to and from the kernel's socket address structures. It enters no kernel, so
//! its tests run on every host. It names `std.posix.sockaddr`, the structures of the target the
//! module is built for: on Darwin each starts with its own length, which Linux's do not have.
const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const core = @import("core");

const Address = core.Address;

/// Room for either family's socket address, aligned for both.
pub const Storage = extern union { in: posix.sockaddr.in, in6: posix.sockaddr.in6 };

/// Writes `address` into `storage` in the kernel's form, port and address in network byte order,
/// and returns the length the kernel expects for that family.
pub fn to_kernel(address: *const Address, storage: *Storage) posix.socklen_t {
    switch (address.family) {
        .ipv4 => {
            storage.in = std.mem.zeroes(posix.sockaddr.in);
            if (@hasField(posix.sockaddr.in, "len")) storage.in.len = @sizeOf(posix.sockaddr.in);
            storage.in.family = posix.AF.INET;
            storage.in.port = std.mem.nativeToBig(u16, address.port);
            storage.in.addr = @bitCast(address.bytes[0..Address.ipv4_bytes].*);
            return @sizeOf(posix.sockaddr.in);
        },
        .ipv6 => {
            storage.in6 = std.mem.zeroes(posix.sockaddr.in6);
            if (@hasField(posix.sockaddr.in6, "len")) storage.in6.len = @sizeOf(posix.sockaddr.in6);
            storage.in6.family = posix.AF.INET6;
            storage.in6.port = std.mem.nativeToBig(u16, address.port);
            storage.in6.addr = address.bytes;
            storage.in6.scope_id = address.scope_id;
            return @sizeOf(posix.sockaddr.in6);
        },
    }
}

/// The `core.Address` a kernel socket address holds, or null for a family rotor does not carry
/// or a length too short for its family.
pub fn from_kernel(storage: *const Storage, len: posix.socklen_t) ?Address {
    if (len < @sizeOf(posix.sockaddr.in)) return null;
    if (storage.in.family == posix.AF.INET) {
        const octets: [Address.ipv4_bytes]u8 = @bitCast(storage.in.addr);
        return Address.ipv4(octets, std.mem.bigToNative(u16, storage.in.port));
    }
    if (storage.in.family != posix.AF.INET6) return null;
    if (len < @sizeOf(posix.sockaddr.in6)) return null;
    const port = std.mem.bigToNative(u16, storage.in6.port);
    return Address.ipv6(storage.in6.addr, port, storage.in6.scope_id);
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

const testing = std.testing;

test "an IPv4 address round-trips through the bare form a control message carries" {
    const address = Address.ipv4(.{ 203, 0, 113, 5 }, 8443);
    const back = ipv4_of(ipv4_bits(&address), 0);
    try testing.expectEqualSlices(u8, &address.bytes, &back.bytes);
    try testing.expectEqual(@as(u16, 0), back.port);
}

test "an IPv4 address round-trips, with its port in network byte order" {
    const address = Address.ipv4(.{ 127, 0, 0, 1 }, 0x1F90);
    var storage: Storage = undefined;
    const len = to_kernel(&address, &storage);
    try testing.expectEqual(@as(posix.socklen_t, @sizeOf(posix.sockaddr.in)), len);
    const port_bytes = std.mem.asBytes(&storage.in.port);
    try testing.expectEqualSlices(u8, &.{ 0x1F, 0x90 }, port_bytes);
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, std.mem.asBytes(&storage.in.addr));
    const back = from_kernel(&storage, len).?;
    try testing.expectEqual(Address.Family.ipv4, back.family);
    try testing.expectEqual(@as(u16, 0x1F90), back.port);
    try testing.expectEqualSlices(u8, &address.bytes, &back.bytes);
}

test "an IPv6 address round-trips with its scope id" {
    var octets: [Address.ipv6_bytes]u8 = @splat(0);
    octets[0] = 0xFE;
    octets[1] = 0x80;
    octets[Address.ipv6_bytes - 1] = 1;
    const address = Address.ipv6(octets, 443, 7);
    var storage: Storage = undefined;
    const len = to_kernel(&address, &storage);
    try testing.expectEqual(@as(posix.socklen_t, @sizeOf(posix.sockaddr.in6)), len);
    const back = from_kernel(&storage, len).?;
    try testing.expectEqual(Address.Family.ipv6, back.family);
    try testing.expectEqual(@as(u16, 443), back.port);
    try testing.expectEqual(@as(u32, 7), back.scope_id);
    try testing.expectEqualSlices(u8, &octets, &back.bytes);
}

test "a family rotor does not carry, or a length too short, yields null" {
    const address = Address.ipv4(.{ 10, 0, 0, 1 }, 80);
    var storage: Storage = undefined;
    const len = to_kernel(&address, &storage);
    try testing.expectEqual(@as(?Address, null), from_kernel(&storage, len - 1));
    storage.in.family = posix.AF.UNIX;
    try testing.expectEqual(@as(?Address, null), from_kernel(&storage, len));
    var six: Storage = undefined;
    const six_len = to_kernel(&Address.ipv6(@splat(0), 1, 0), &six);
    try testing.expectEqual(@as(?Address, null), from_kernel(&six, six_len - 1));
    // A family rotor does not carry is refused even when the length would fit an IPv6 address.
    six.in6.family = posix.AF.UNIX;
    try testing.expectEqual(@as(?Address, null), from_kernel(&six, six_len));
}
