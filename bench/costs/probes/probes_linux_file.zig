//! Rows C12 and C13: a 4 KiB O_DIRECT read from NVMe, at queue depth 1 and at queue depth 32.
//! The rows decision 3's source 1 divides its registration claim by.
//!
//!   - C12: one read submitted and waited for, the device's own latency plus the ring's.
//!   - C13: `depth` reads in flight, per operation. At depth the device overlaps them, so this
//!     is a throughput number wearing a latency's units, and it is the one that says whether the
//!     CPU per operation matters.
//!
//! The probe writes its own file under /tmp and removes it. It
//! reads at offsets it picks with the seeded generator, spread over the file, so the device sees
//! a random pattern and not a readahead-friendly one. The file is larger than this machine's page
//! cache would hold usefully, and O_DIRECT bypasses that cache anyway; a filesystem that refuses
//! O_DIRECT fails the probe rather than reporting a cached number.
//!
//! What it cannot show: a number from a container. Docker's virtual machine puts a host
//! filesystem under the file, so a reading taken there describes the virtual machine
//! (docs/costs.md, the machines table).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const measure = @import("../measure.zig");
const sys = @import("../sys.zig");
const shared = @import("probes_linux.zig");

const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;
const Ring = shared.Ring;

pub const probes = [_]measure.Probe{
    .{
        .row = 12,
        .operation = "4 KiB O_DIRECT NVMe read, queue depth 1, submit to completion",
        .run = run_depth_one,
    },
    .{
        .row = 13,
        .operation = "4 KiB O_DIRECT NVMe read, queue depth 32, per operation",
        .run = run_depth_many,
    },
};

/// Where the probe writes its file. The Linux gate runs a container whose /tmp is the
/// container's own filesystem, as `src/uring/uring_testing.zig` says of the suite's files.
const directory = "/tmp";

/// The transfer size every row names, and the alignment O_DIRECT needs.
const block_bytes = 4096;

/// Reads in flight for C13.
const depth = 32;

/// The file the probe reads, in blocks: 256 MiB, larger than a drive's own cache is likely to
/// hold, so a repeated offset is unlikely to be served from it.
const file_blocks = 65536;

/// The multiplier of a 64-bit splitmix64 step, which picks the offsets. The pattern must be the
/// same on every run of the probe, so the number is fixed and no clock is read.
const step_odd: u64 = 0x9E37_79B9_7F4A_7C15;
const mix_shift_first = 30;
const mix_shift_second = 27;
const mix_shift_third = 31;
const mix_first: u64 = 0xBF58_476D_1CE4_E5B9;
const mix_second: u64 = 0x94D0_49BB_1331_11EB;

const depth_one_plan: Plan = .{ .warmup = 16, .samples = 500, .batch = 16 };
const depth_many_plan: Plan = .{ .warmup = 8, .samples = 200, .batch = depth * 4 };

/// splitmix64, as `src/core/random.zig` runs it: the offsets are a function of the seed alone.
fn next_offset(state: *u64) u64 {
    state.* +%= step_odd;
    var z = state.*;
    z = (z ^ (z >> mix_shift_first)) *% mix_first;
    z = (z ^ (z >> mix_shift_second)) *% mix_second;
    z = z ^ (z >> mix_shift_third);
    return (z % file_blocks) * block_bytes;
}

/// The file the reads go to, and the aligned buffer they land in.
const File = struct {
    fd: sys.fd_t,
    path: [path_bytes_max:0]u8,
    buffers: []align(block_bytes) u8,

    const path_bytes_max = 128;

    fn open(buffers: []align(block_bytes) u8) Error!File {
        var file: File = .{ .fd = -1, .path = undefined, .buffers = buffers };
        const written = std.fmt.bufPrintZ(&file.path, "{s}/rotor_costs_{d}", .{
            directory,
            linux.getpid(),
        }) catch return error.UnexpectedResult;
        assert(written.len < path_bytes_max);

        const flags: linux.O = .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
            .DIRECT = true,
        };
        const rc = linux.open(&file.path, flags, 0o600);
        if (linux.errno(rc) != .SUCCESS) return error.SystemCallFailed;
        file.fd = @intCast(rc);
        errdefer file.deinit();
        try file.fill();
        return file;
    }

    /// Writes the whole file with O_DIRECT, so every block the reads touch exists on the device.
    fn fill(file: *File) Error!void {
        @memset(file.buffers, 0xA5);
        const block = file.buffers[0..block_bytes];
        var written: u64 = 0;
        while (written < file_blocks) : (written += 1) {
            const offset = written * block_bytes;
            const rc = linux.pwrite(file.fd, block.ptr, block.len, @intCast(offset));
            if (linux.errno(rc) != .SUCCESS or rc != block_bytes) return error.SystemCallFailed;
        }
        if (linux.errno(linux.fsync(file.fd)) != .SUCCESS) return error.SystemCallFailed;
    }

    fn deinit(file: *File) void {
        if (file.fd >= 0) sys.close(file.fd);
        _ = linux.unlink(&file.path);
    }

    fn block_at(file: *File, index: u32) []align(block_bytes) u8 {
        const start = @as(usize, index) * block_bytes;
        return @alignCast(file.buffers[start..][0..block_bytes]);
    }
};

/// Queues one read of `block_bytes` at a random offset.
fn queue_read(ring: *Ring, file: *File, state: *u64, buffer_index: u32) Error!void {
    const sqe = ring.io.get_sqe() catch return error.UnexpectedResult;
    sqe.* = std.mem.zeroes(linux.io_uring_sqe);
    sqe.opcode = .READ;
    sqe.fd = file.fd;
    sqe.addr = @intFromPtr(file.block_at(buffer_index).ptr);
    sqe.len = block_bytes;
    sqe.off = next_offset(state);
    sqe.user_data = buffer_index;
}

/// Waits for `count` completions and checks each moved a whole block.
fn wait_for(ring: *Ring, count: u32) Error!void {
    var taken: u32 = 0;
    while (taken < count) : (taken += 1) {
        const cqe = ring.io.copy_cqe() catch return error.SystemCallFailed;
        if (cqe.res != block_bytes) return error.UnexpectedResult;
    }
}

const Reads = struct {
    ring: Ring,
    file: File,
    state: u64 = 0,
    in_flight: u32,

    pub fn run_batch(context: *Reads, reads: u32) Error!void {
        assert(reads % context.in_flight == 0);
        var remaining = reads;
        while (remaining != 0) : (remaining -= context.in_flight) {
            var queued: u32 = 0;
            while (queued < context.in_flight) : (queued += 1) {
                try queue_read(&context.ring, &context.file, &context.state, queued);
            }
            const submitted = context.ring.io.submit_and_wait(context.in_flight) catch {
                return error.SystemCallFailed;
            };
            if (submitted != context.in_flight) return error.UnexpectedResult;
            try wait_for(&context.ring, context.in_flight);
        }
    }
};

fn run_reads(environment: *Environment, in_flight: u32, plan: Plan, note: []const u8) Error!Result {
    const buffer_bytes = @as(usize, in_flight) * block_bytes;
    if (environment.arena.len < buffer_bytes) return error.UnexpectedResult;
    const buffers: []align(block_bytes) u8 = @alignCast(environment.arena[0..buffer_bytes]);

    var context: Reads = .{
        .ring = try Ring.init(2 * depth),
        .file = try File.open(buffers),
        .in_flight = in_flight,
    };
    defer context.ring.deinit();
    defer context.file.deinit();

    const summary = try measure.sample(Reads, &context, plan, environment.values[0]);
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "reads",
        .note = note,
    };
}

fn run_depth_one(environment: *Environment) Error!Result {
    return run_reads(environment, 1, depth_one_plan, "O_DIRECT, 4 KiB, offsets drawn by" ++
        " splitmix64 over a 256 MiB file this probe writes and removes; one read in flight," ++
        " submitted and waited for, so this is the device's latency plus the ring's");
}

fn run_depth_many(environment: *Environment) Error!Result {
    return run_reads(environment, depth, depth_many_plan, "O_DIRECT, 4 KiB, offsets drawn by" ++
        " splitmix64 over a 256 MiB file this probe writes and removes; 32 reads in flight per" ++
        " call, so the device overlaps them and this is throughput in a latency's units");
}
