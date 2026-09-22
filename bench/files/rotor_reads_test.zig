//! The tests of `rotor_reads.zig`. They live beside it rather than inside it because the program
//! is at the 500-line limit CLAUDE.md sets, and a program plus its tests is what that limit counts.
//! Its own `test` block imports this file, so `zig build test-bench-programs` runs them.
const std = @import("std");
const core = @import("core");
const backend = @import("backend");
const reads = @import("rotor_reads.zig");
const file_module = @import("rotor_reads_file.zig");

const Options = reads.Options;
const write_suffix = file_module.write_suffix;
const testing = std.testing;

test "a write run writes its own file, and a read run the one it was given" {
    // A write overwrites whole blocks. If it used the path it was handed, pointing this program at
    // anything valuable would destroy 256 MiB of it.
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const read_setup: file_module.Setup =
        .{ .path = "/tmp/scratch", .transfer = .read, .file_bytes = 1 << 20 };
    try testing.expectEqualStrings("/tmp/scratch", try file_module.path_of(read_setup, &buffer));

    const write_setup: file_module.Setup =
        .{ .path = "/tmp/scratch", .transfer = .write, .file_bytes = 1 << 20 };
    const written = try file_module.path_of(write_setup, &buffer);
    try testing.expectEqualStrings("/tmp/scratch" ++ write_suffix, written);
    try testing.expect(!std.mem.eql(u8, written, write_setup.path));
    // Zero-terminated, because `open_file` takes a C string.
    try testing.expectEqual(@as(u8, 0), written.ptr[written.len]);
}

test "a path with no room for the suffix is an error, not a truncated path" {
    var small: [8]u8 = undefined;
    const setup: file_module.Setup =
        .{ .path = "/tmp/scratch", .transfer = .write, .file_bytes = 1 << 20 };
    try testing.expectError(error.NoSpaceLeft, file_module.path_of(setup, &small));
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

test "a file that is the right size but unwritten is not treated as filled" {
    // The defect this catches, found on 2026-09-22: `set_file_size` calls fallocate and ftruncate,
    // which allocate blocks and write none, and the old check accepted any file of the right size.
    // Both programs then read unwritten extents, which ext4 and XFS answer with zeros and no device
    // I/O at all, so the read rows would have measured an extent flag.
    var block: [4096]u8 align(4096) = @splat(0);
    const setup: file_module.Setup =
        .{ .path = "unused", .transfer = .read, .file_bytes = 4096 };

    // A closed descriptor cannot be read, so the sample fails and the file counts as unfilled. The
    // safe direction: an unreadable file is filled, never assumed good.
    try testing.expect(!try file_module.already_filled(-1, setup, &block));
}

test "a real file's last block decides whether it is filled" {
    // The byte check itself, on a file that exists. Without this, `already_filled` could return true
    // for a hole and the fill would never run: the defect of 2026-09-22 all over again.
    var name: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&name, "{s}/rotor_fill_{d}", .{
        backend.testing.directory, backend.testing.process_id(),
    });
    // Not O_DIRECT: this test is about the byte check, not about alignment, and a temporary file on
    // /tmp may sit on a filesystem that refuses O_DIRECT.
    const file = try backend.sync.open_file(path, .{ .create = true, .direct = false });
    defer {
        backend.sync.close_now(file);
        backend.testing.remove_file(path);
    }

    const block_bytes = 4096;
    try backend.sync.set_file_size(file, 2 * block_bytes);
    const setup: file_module.Setup =
        .{ .path = "unused", .transfer = .read, .file_bytes = 2 * block_bytes };

    var block: [block_bytes]u8 align(block_bytes) = undefined;
    // A file of the right size whose blocks were never written: zeros, so not filled.
    try testing.expect(!try file_module.already_filled(file, setup, &block));

    // Fill it and ask again.
    try file_module.fill_if_needed(file, setup, &block);
    try testing.expect(try file_module.already_filled(file, setup, &block));

    // The first block too, not only the sampled last one.
    var read_back: [block_bytes]u8 = undefined;
    const count = std.c.pread(file, &read_back, read_back.len, 0);
    try testing.expectEqual(@as(isize, block_bytes), count);
    for (read_back) |byte| try testing.expectEqual(file_module.fill_byte, byte);
}

test "the fill byte is the one libuv writes" {
    // bench/alternatives/libuv_reads.c defines FILL_BYTE as 0x5a. If the two disagree, whichever
    // program runs second refills the whole file on every invocation of a sweep, and each row pays
    // for a 256 MiB write it did not need.
    try testing.expectEqual(@as(u8, 0x5a), file_module.fill_byte);
}

test "a file that is not a whole number of blocks is refused" {
    // The fill writes whole blocks and samples the last one, and O_DIRECT refuses an offset that is
    // not a multiple of the block size.
    var bad: Options = .{ .path = "/tmp/scratch" };
    bad.file_bytes = (256 << 20) + 1;
    try testing.expectError(error.FileNotWholeBlocks, reads.check(bad));

    var sound: Options = .{ .path = "/tmp/scratch" };
    sound.file_bytes = 256 << 20;
    try reads.check(sound);
}
