//! The tests of `rotor_reads.zig`. They live beside it rather than inside it because the program
//! is at the 500-line limit CLAUDE.md sets, and a program plus its tests is what that limit counts.
//! Its own `test` block imports this file, so `zig build test-bench-programs` runs them.
const std = @import("std");
const core = @import("core");
const reads = @import("rotor_reads.zig");

const Options = reads.Options;
const write_suffix = reads.write_suffix;
const testing = std.testing;

test "a write run writes its own file, and a read run the one it was given" {
    // A write overwrites whole blocks. If it used the path it was handed, pointing this program at
    // anything valuable would destroy 256 MiB of it.
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const read_options: Options = .{ .path = "/tmp/scratch", .transfer = .read };
    try testing.expectEqualStrings("/tmp/scratch", try reads.path_of(read_options, &buffer));

    const write_options: Options = .{ .path = "/tmp/scratch", .transfer = .write };
    const written = try reads.path_of(write_options, &buffer);
    try testing.expectEqualStrings("/tmp/scratch" ++ write_suffix, written);
    try testing.expect(!std.mem.eql(u8, written, write_options.path));
    // Zero-terminated, because `open_file` takes a C string.
    try testing.expectEqual(@as(u8, 0), written.ptr[written.len]);
}

test "a path with no room for the suffix is an error, not a truncated path" {
    var small: [8]u8 = undefined;
    const options: Options = .{ .path = "/tmp/scratch", .transfer = .write };
    try testing.expectError(error.NoSpaceLeft, reads.path_of(options, &small));
}

test "each direction and pattern names its own workload, and no two share a name" {
    const names = [_][]const u8{
        reads.workload_of(.read, .seq),
        reads.workload_of(.read, .random),
        reads.workload_of(.write, .seq),
        reads.workload_of(.write, .random),
    };
    try testing.expectEqualStrings("file-read-seq", names[0]);
    try testing.expectEqualStrings("file-read-random", names[1]);
    try testing.expectEqualStrings("file-write-seq", names[2]);
    try testing.expectEqualStrings("file-write-random", names[3]);

    // Four distinct names, so a `Series` can never mix two of these workloads into one row.
    for (names, 0..) |name, index| {
        for (names[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, name, other));
        }
    }
}

test "a candidate's name carries the buffer choice and the policy, not the direction" {
    // The direction is the workload's, because a read row and a write row are different
    // measurements. The candidate is the same rotor either way.
    try testing.expectEqualStrings("rotor (registered)", reads.candidate_of(true, .blocking));
    try testing.expectEqualStrings("rotor", reads.candidate_of(false, .blocking));
    try testing.expectEqualStrings("rotor (registered, offload)", reads.candidate_of(true, .offload));
    try testing.expectEqualStrings("rotor (offload)", reads.candidate_of(false, .offload));
}

test "a configuration the device or the buffers cannot carry is refused" {
    const sound: Options = .{ .path = "/tmp/scratch" };
    try reads.check(sound);

    var bad = sound;
    bad.depth = 0;
    try testing.expectError(error.DepthOutOfRange, reads.check(bad));
    bad = sound;
    bad.block_bytes = 512;
    try testing.expectError(error.BlockTooSmall, reads.check(bad));
    bad = sound;
    bad.block_bytes = 4096 + 1;
    try testing.expectError(error.BlockNotAligned, reads.check(bad));
    bad = sound;
    bad.seconds = 0;
    try testing.expectError(error.EmptyConfiguration, reads.check(bad));
    bad = sound;
    bad.file_bytes = 1024;
    try testing.expectError(error.FileTooSmall, reads.check(bad));
}

test "a write request becomes a write, and a read request a read" {
    // The direction is chosen in one place. A write submitted as a read would measure the wrong
    // direction under a row named for the right one, and the run would look perfectly healthy.
    var bytes: [4096]u8 = undefined;
    const common = .{
        .user_data = 7,
        .file = 3,
        .buffer = bytes[0..],
        .registered = null,
        .offset = 8192,
    };

    const read = reads.operation_of(.{
        .transfer = .read,
        .user_data = common.user_data,
        .file = common.file,
        .buffer = common.buffer,
        .registered = common.registered,
        .offset = common.offset,
    });
    try testing.expectEqual(core.Operation.Code.read, read.code());
    try testing.expectEqual(@as(u64, 7), read.user_data);
    try testing.expectEqual(@as(u64, 8192), read.kind.read.offset);
    try testing.expectEqual(@as(core.Descriptor, 3), read.kind.read.file);

    const write = reads.operation_of(.{
        .transfer = .write,
        .user_data = common.user_data,
        .file = common.file,
        .buffer = common.buffer,
        .registered = common.registered,
        .offset = common.offset,
    });
    try testing.expectEqual(core.Operation.Code.write, write.code());
    try testing.expectEqual(@as(u64, 8192), write.kind.write.offset);
    try testing.expectEqual(@as(core.Descriptor, 3), write.kind.write.file);
}

test "a registered buffer index reaches the operation in both directions" {
    var bytes: [4096]u8 = undefined;
    const read = reads.operation_of(.{
        .transfer = .read,
        .user_data = 0,
        .file = 3,
        .buffer = bytes[0..],
        .registered = 5,
        .offset = 0,
    });
    try testing.expectEqual(@as(?u16, 5), read.kind.read.buffer.registered);

    const write = reads.operation_of(.{
        .transfer = .write,
        .user_data = 0,
        .file = 3,
        .buffer = bytes[0..],
        .registered = 5,
        .offset = 0,
    });
    try testing.expectEqual(@as(?u16, 5), write.kind.write.buffer.registered);
}
