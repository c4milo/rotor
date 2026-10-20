//! The `memset` that every program under bench/ links on Linux (build/bench_memset.zig). It
//! replaces compiler_rt's `memset`, which stores one byte at a time in Zig 0.16. On Linux,
//! compiler_rt's `memset` serves every `memset` call in a program, with or without libc. This
//! includes the 0xAA fill that ReleaseSafe gives an `undefined` local of more than about 512
//! bytes. It also includes each `@memset` whose length is known only at run time.
//!
//! rotor's measured functions call no `memset`. Some libraries of the other candidates do, for
//! example `std.Io.Threaded` in `concurrent` and `netSendPosix`. Thus every candidate links this
//! `memset`, and all candidates fill memory with the same code. pepegrillo's
//! `docs/performance/performance_zig.md`, section "Copies and fills", has the recipe and its
//! measurements.
//!
//! Only programs link this file. A library that exports `memset` collides with the program of its
//! caller, because that program owns the symbol. The guard limits the export to Linux and Zig 0.16.
//! Zig's master writes compiler_rt's `memset` with vector stores, so the upgrade after 0.16
//! deletes this file.
const std = @import("std");
const builtin = @import("builtin");

comptime {
    const zig_0_16 = builtin.zig_version.major == 0 and builtin.zig_version.minor == 16;
    if (builtin.os.tag == .linux and zig_0_16) @export(&memset, .{ .name = "memset" });
}

/// Bytes one vector store writes.
const chunk_bytes = 32;

fn memset(dest: ?[*]u8, c: u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    const d = dest orelse return dest;
    const fill: @Vector(chunk_bytes, u8) = @splat(c);
    if (len < chunk_bytes) {
        for (0..len) |i| {
            d[i] = c;
            // Without the barrier LLVM turns the loop into a call to `memset`, which is this
            // function.
            std.mem.doNotOptimizeAway(d);
        }
        return dest;
    }
    for (0..len / chunk_bytes) |chunk| {
        d[chunk * chunk_bytes ..][0..chunk_bytes].* = fill;
        std.mem.doNotOptimizeAway(d);
    }
    // Write the last chunk. It overlaps the chunk before it when 32 does not divide the length.
    d[len - chunk_bytes ..][0..chunk_bytes].* = fill;
    return dest;
}

const testing = std.testing;

/// Bytes in the test buffer. The test fills every length below this number once.
const test_buffer_bytes = 300;

/// Bytes before the fill and after the longest fill. The fill must not change these bytes.
const test_margin_bytes = 8;

/// Sets each byte of `buffer` to `value`, one byte at a time. Thus the test does not use the
/// `memset` that it checks.
fn set_bytewise(buffer: []u8, value: u8) void {
    for (buffer) |*byte| {
        byte.* = value;
        std.mem.doNotOptimizeAway(byte);
    }
}

test "memset fills every byte it is given and none around them, at every length" {
    var buffer: [test_buffer_bytes]u8 = undefined;
    const start = buffer[test_margin_bytes..];
    for (0..test_buffer_bytes - 2 * test_margin_bytes) |len| {
        set_bytewise(&buffer, 0x11);
        try testing.expectEqual(@as(?[*]u8, start.ptr), memset(start.ptr, 0x5a, len));
        for (buffer[0..test_margin_bytes]) |byte| try testing.expectEqual(@as(u8, 0x11), byte);
        for (start[0..len]) |byte| try testing.expectEqual(@as(u8, 0x5a), byte);
        for (start[len..]) |byte| try testing.expectEqual(@as(u8, 0x11), byte);
    }
}

test "memset of a null destination returns it and writes nothing" {
    try testing.expectEqual(@as(?[*]u8, null), memset(null, 0x5a, 0));
}
