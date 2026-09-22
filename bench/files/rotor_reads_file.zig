//! The file `bench/files/rotor_reads.zig` measures: which path it uses, and making sure the file
//! holds real data before a run.
//!
//! **The fill is not optional.** `set_file_size` calls `fallocate` and `ftruncate`, which allocate
//! blocks and write none. An O_DIRECT read of an unwritten extent on ext4 or XFS is answered by the
//! filesystem with zeros and never reaches the device, so a read row would measure an extent flag
//! and not an NVMe read. A write to an unwritten extent is an allocating write, slower than an
//! overwrite, so a write run's first pass would measure allocation. Before 2026-09-22 this program
//! filled nothing, and `bench/alternatives/README.md` records what that cost.
//!
//! `bench/alternatives/libuv_reads.c` fills with the same byte and samples the same way, so the two
//! programs read and overwrite the same content whichever of them created the file.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const backend = @import("backend");

const sync = backend.sync;

/// Which direction a run measures. Two workloads, not two runs of one: a read row and a write row
/// must never share a `Series`, which `rotor_reads.zig` enforces by naming them apart.
pub const Transfer = enum { read, write };

/// What a write run appends to the path it was given, so it writes its own file and can never
/// overwrite one the caller named.
pub const write_suffix = ".rotor_write";

/// The byte every block of the file holds before a run. libuv's program writes the same one.
pub const fill_byte: u8 = 0x5a;

/// Blocks one file may hold, which bounds the fill loop. 256 MiB of 4 KiB blocks is 65,536.
pub const blocks_max: u64 = 1 << 22;

/// What the setup needs to know about the run.
pub const Setup = struct {
    path: [:0]const u8,
    transfer: Transfer,
    file_bytes: u64,
};

/// The path a run uses: the one it was given for a read, and that path plus `write_suffix` for a
/// write. A write overwrites whole blocks, so it writes a file of its own and never the caller's.
pub fn path_of(setup: Setup, buffer: []u8) ![:0]const u8 {
    if (setup.transfer == .read) return setup.path;
    return std.fmt.bufPrintZ(buffer, "{s}" ++ write_suffix, .{setup.path});
}

/// Opens the file, growing it and filling it when it is short or unwritten, with the nearest thing
/// the host has to O_DIRECT. `block` is an aligned scratch block the fill writes and samples with.
pub fn open_and_fill(setup: Setup, block: []u8) !core.Descriptor {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try path_of(setup, &buffer);
    const direct: sync.OpenOptions = .{ .create = false, .direct = true };
    if (sync.open_file(path, direct)) |file| {
        errdefer sync.close_now(file);
        const have = try sync.file_size(file);
        if (have < setup.file_bytes) try sync.set_file_size(file, setup.file_bytes);
        // A file of the right size may still be unwritten: `truncate -s 256M` makes one, and so did
        // this program before 2026-09-22.
        try fill_if_needed(file, setup, block);
        return file;
    } else |failure| switch (failure) {
        error.FileNotFound => {},
        else => return failure,
    }
    const created = try sync.open_file(path, .{ .create = true, .direct = true });
    errdefer sync.close_now(created);
    try sync.set_file_size(created, setup.file_bytes);
    try fill_if_needed(created, setup, block);
    return created;
}

/// Writes `fill_byte` over every block, unless the file already holds it.
///
/// **Without this the file is allocated and never written.** `set_file_size` calls `fallocate` and
/// `ftruncate`, which leave unwritten extents. An O_DIRECT read of an unwritten extent on ext4 or
/// XFS is answered by the filesystem with zeros and never reaches the device, so a read row would
/// measure an extent flag and not an NVMe read. A write to an unwritten extent is an allocating
/// write, slower than an overwrite, so a write run's first pass would measure allocation.
///
/// It samples the last block rather than filling every time: a sweep starts this program about a
/// hundred times, and filling 256 MiB on each would cost minutes and the drive's write endurance.
/// The last block is the one an interrupted fill leaves unwritten, so sampling it is enough.
pub fn fill_if_needed(file: core.Descriptor, setup: Setup, block: []u8) !void {
    if (try already_filled(file, setup, block)) return;

    @memset(block, fill_byte);
    const blocks = setup.file_bytes / block.len;
    assert(blocks >= 1);
    assert(blocks <= blocks_max);
    var written: u64 = 0;
    while (written < blocks) : (written += 1) {
        const offset: i64 = @intCast(written * block.len);
        const count = std.c.pwrite(file, block.ptr, block.len, offset);
        if (count != block.len) return error.FillFailed;
    }
}

/// True when the file's last block already holds `fill_byte`, so the fill can be skipped.
pub fn already_filled(file: core.Descriptor, setup: Setup, block: []u8) !bool {
    const last: i64 = @intCast(setup.file_bytes - block.len);
    const count = std.c.pread(file, block.ptr, block.len, last);
    if (count != block.len) return false;
    for (block) |byte| {
        if (byte != fill_byte) return false;
    }
    return true;
}
