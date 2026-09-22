//! What one run of `bench/files/rotor_reads.zig` is before it starts: the options it was given, the
//! limits those are checked against, and the file it measures.
//!
//! The program itself is the measurement — the loop, the operations and the result. This is
//! everything settled before the first submission, which is one thing and keeps that file under the
//! 500-line limit CLAUDE.md sets.
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
const builtin = @import("builtin");
const assert = std.debug.assert;
const core = @import("core");
const backend = @import("backend");
const pool_module = @import("reads_pool.zig");

const sync = backend.sync;

/// Which direction a run measures. Two workloads, not two runs of one: a read row and a write row
/// must never share a `Series`, which `rotor_reads.zig` enforces by naming them apart.
pub const Transfer = enum { read, write };

/// What a write run appends to the path it was given, so it writes its own file and can never
/// overwrite one the caller named.
pub const write_suffix = ".rotor_write";

/// Blocks one file may hold, which bounds the fill loop. 256 MiB of 4 KiB blocks is 65,536.
pub const blocks_max: u64 = 1 << 22;

pub const depth_max = 128;

pub const operations = depth_max + 64;
pub const entries = 256;
pub const events_max = 256;

/// The block a read moves, at most. Every offset and length is a multiple of the block asked for,
/// and O_DIRECT refuses anything else.
pub const block_bytes_max = 1 << 20;

/// The alignment every O_DIRECT buffer needs. A page is at least the logical block of every
/// device rotor runs on, and aligning to it costs nothing here.
pub const buffer_alignment = 4096;

/// The bytes the program's buffer pool holds: one buffer of the largest block per read in flight.
/// `check` refuses a configuration that would not fit, and `rotor_reads.zig` sizes its array by it.
pub const buffer_bytes_total: usize = depth_max * block_bytes_max;

/// The byte every block of the file holds before a run. `bench/alternatives/libuv_reads.c` writes
/// the same one, so both programs read and overwrite the same content.
pub const fill_byte: u8 = 0x5a;

/// Set in an operation's `user_data` when it is the `fdatasync` half of a durable write, so one
/// completion handler can tell the two apart. A slot index is far below this.
pub const sync_bit: u64 = 1 << 32;
pub const index_mask: u64 = sync_bit - 1;

pub const Pattern = enum { seq, random };

pub const Options = struct {
    path: [:0]const u8,
    pattern: Pattern = .seq,
    depth: u32 = 16,
    block_bytes: u32 = 4096,
    registered: bool = true,
    transfer: Transfer = .read,
    /// Follow every write with an `fdatasync`, so one operation is one durable write. Only a write
    /// run may set it (decision 18's `fdatasync` is the call, and a read has nothing to flush).
    sync: bool = false,
    seconds: u64 = 3,
    file_bytes: u64 = 256 << 20,
    /// What the loop does with a read it cannot perform without blocking (decision 18). On
    /// io_uring it changes nothing; on kqueue it is the difference this workload's newest row
    /// measures. `refuse` is not offered: a run that refused every read would measure nothing.
    policy: Policy = .blocking,
};

/// The policies this workload runs, which are decision 18's two that perform the read.
pub const Policy = enum { blocking, offload };

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
        // Spelled twice: Linux is built without libc here, and `std.posix` has no pwrite.
        const count = if (builtin.os.tag == .linux)
            std.os.linux.pwrite(file, block.ptr, block.len, offset)
        else
            std.c.pwrite(file, block.ptr, block.len, offset);
        if (count != block.len) return error.FillFailed;
    }
}

/// True when the file's last block already holds `fill_byte`, so the fill can be skipped.
pub fn already_filled(file: core.Descriptor, setup: Setup, block: []u8) !bool {
    const last: i64 = @intCast(setup.file_bytes - block.len);
    const count = if (builtin.os.tag == .linux)
        std.os.linux.pread(file, block.ptr, block.len, last)
    else
        std.c.pread(file, block.ptr, block.len, last);
    if (count != block.len) return false;
    for (block) |byte| {
        if (byte != fill_byte) return false;
    }
    return true;
}

pub fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingPath;
    var options: Options = .{ .path = arguments[1] };
    var index: usize = 2;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    try check(options);
    return options;
}

pub fn check(options: Options) !void {
    // A depth above the pool's queue would make `Pool.submit` block the loop thread, which is the
    // stall the offload removes. Refused here rather than found part way through a run.
    if (options.policy == .offload and options.depth > pool_module.queue_max) {
        return error.DepthAboveOffloadQueue;
    }
    if (options.depth == 0 or options.depth > depth_max) return error.DepthOutOfRange;
    if (options.block_bytes < buffer_alignment) return error.BlockTooSmall;
    if (options.block_bytes > block_bytes_max) return error.BlockTooLarge;
    if (options.block_bytes % buffer_alignment != 0) return error.BlockNotAligned;
    if (options.depth * options.block_bytes > buffer_bytes_total) return error.BuffersTooLarge;
    if (options.file_bytes < options.depth * options.block_bytes) return error.FileTooSmall;
    // The fill writes whole blocks and samples the last one, and O_DIRECT refuses an offset that is
    // not a multiple of the block size. A file that is not a whole number of blocks has neither.
    if (options.file_bytes % options.block_bytes != 0) return error.FileNotWholeBlocks;
    // A read has nothing to flush, so `--sync yes` with a read would name a workload nobody ran.
    if (options.sync and options.transfer != .write) return error.SyncNeedsWrite;
    if (options.seconds == 0) return error.EmptyConfiguration;
    // `register_buffers` takes at most this many, and one per read in flight is what it is given.
    if (options.registered and options.depth > core.constants.registered_buffers_max) {
        return error.TooManyRegistered;
    }
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--pattern")) {
        options.pattern = std.meta.stringToEnum(Pattern, value) orelse return error.UnknownPattern;
    } else if (std.mem.eql(u8, name, "--depth")) {
        options.depth = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--block-bytes")) {
        options.block_bytes = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--registered")) {
        options.registered = try yes_or_no(value);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--file-bytes")) {
        options.file_bytes = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--sync")) {
        options.sync = try yes_or_no(value);
    } else if (std.mem.eql(u8, name, "--transfer")) {
        options.transfer = std.meta.stringToEnum(Transfer, value) orelse
            return error.UnknownTransfer;
    } else if (std.mem.eql(u8, name, "--file-policy")) {
        options.policy = std.meta.stringToEnum(Policy, value) orelse return error.UnknownPolicy;
    } else {
        return error.UnknownArgument;
    }
}

fn yes_or_no(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "yes")) return true;
    if (std.mem.eql(u8, value, "no")) return false;
    return error.NotYesOrNo;
}
