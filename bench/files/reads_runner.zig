//! reads_runner: the comparison of milestone 4's O_DIRECT read workload, sequential and random.
//!
//! Run:  reads_runner PATH [--rounds N] [--depths N,N] [--blocks B,B] [--seconds S]
//!                    [--only NAME,NAME] [--directory D]
//!
//! Every candidate measures itself, as the timer and cross-core candidates do: a read has no
//! client outside the program that issued it.
//!
//! **A candidate here is a program and its arguments, not a program.** The other two runners have
//! one program per candidate. This workload compares five things across two programs: rotor with
//! registered buffers and without, which is decision 3's first speed source measured as an A
//! against a B, rotor with its reads offloaded to a thread pool (decision 18), and libuv on its
//! thread pool and on its io_uring ring.
//!
//! rotor's offload candidate runs on macOS only. io_uring reads a file without a thread, so the
//! policy changes nothing there and the row would repeat `rotor-registered` under another name.
//!
//! **libuv's io_uring path needs two things, and this runner supplies one of them.**
//! `bench/alternatives/libuv_reads.c` calls `uv_loop_configure(UV_LOOP_USE_IO_URING_SQPOLL)` under
//! `--backend uring`; libuv also requires `UV_USE_IO_URING` to be a positive number in the
//! environment, and a kernel of at least 5.10.186. This runner sets that variable for itself, and
//! children inherit it. Setting it changes nothing for the other candidates: libuv creates the
//! ring only when the loop flag is set too, so the thread-pool candidate stays on the pool.
//!
//! **Sequential and random are different workloads, not different rows of one, and so are reads and
//! writes.** Each candidate names its direction and its pattern in the workload column, so a
//! `Series` can never mix them.
//!
//! **A write run writes a file of its own.** Both programs append `.rotor_write` to the path and
//! create that file, so a write row never overwrites the file the read rows use, or anything else
//! the caller named. Neither program issues an `fdatasync`, so a write row is the write path's
//! latency and says nothing about durability.
const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");

const Result = harness.Result;
const programs = harness.candidates;
const OtherWork = harness.other_work.Window;

/// A candidate: a program and the arguments that make it this candidate. The name a row carries
/// comes from the program itself, because only the program knows which libuv it linked.
pub const Candidate = struct {
    name: []const u8,
    program: []const u8,
    arguments: []const []const u8,
    /// True for a candidate that only exists on Linux. libuv's io_uring path is the one.
    linux_only: bool = false,
    /// True for a candidate that only exists on macOS. rotor's offload is the one: io_uring reads a
    /// file without a thread, so there is nothing to offload there (decision 18).
    kqueue_only: bool = false,
};

pub const candidates = [_]Candidate{
    .{
        .name = "rotor-registered",
        .program = "rotor_reads",
        .arguments = &.{ "--registered", "yes" },
    },
    .{
        .name = "rotor-plain",
        .program = "rotor_reads",
        .arguments = &.{ "--registered", "no" },
    },
    .{
        .name = "rotor-offload",
        .program = "rotor_reads",
        .arguments = &.{ "--registered", "yes", "--file-policy", "offload" },
        .kqueue_only = true,
    },
    .{
        .name = "libuv-threadpool",
        .program = "libuv_reads",
        .arguments = &.{ "--backend", "threadpool" },
    },
    .{
        .name = "libuv-uring",
        .program = "libuv_reads",
        .arguments = &.{ "--backend", "uring" },
        .linux_only = true,
    },
};

pub const patterns = [_][]const u8{ "seq", "random" };

/// The directions a run sweeps. Each is its own workload, named apart by the candidates, so a read
/// row and a write row can never land in one `Series`.
pub const transfers = [_][]const u8{ "read", "write" };

/// Whether a write is followed by an `fdatasync`. A read has nothing to flush, so the sweep pairs
/// `yes` with the write direction alone.
///
/// The two rows answer different questions. Unsynced is the write path: what the loop costs. Synced
/// is what a journal pays, and on an NVMe drive with power-loss protection the two nearly coincide,
/// because the drive reports no volatile write cache and the flush is almost free. On a consumer
/// drive the flush dominates everything the loop does. The pair says which drive this is.
pub const syncs = [_][]const u8{ "no", "yes" };

/// Block sizes a run sweeps. 4 KiB is the NVMe page and the size rows C12 and C13 of
/// `docs/costs.md` name; 16 KiB is one command carrying four of them, which is how a caller batches
/// without a vectored write. rotor's `write` takes one buffer, so a larger command is a larger
/// block and there is no other way to ask for one.
const blocks_default = [_]u32{ 4096, 16384 };

const rounds_default: u32 = 5;
const rounds_max = harness.series.runs_max;

/// Queue depths a run sweeps. Depth 1 is row C12 of `docs/costs.md` and above it is C13.
const depths_default = [_]u32{ 1, 32 };

const seconds_default: u64 = 3;
const file_bytes_default: u64 = 256 << 20;

pub const configurations_max = 8;
const directory_default = "zig-out/bin";

pub const Options = struct {
    path: []const u8,
    rounds: u32 = rounds_default,
    depths: []const u32 = &depths_default,
    blocks: []const u32 = &blocks_default,
    seconds: u64 = seconds_default,
    file_bytes: u64 = file_bytes_default,
    only: []const u8 = "",
    directory: []const u8 = directory_default,
};

var results: [rounds_max * candidates.len]Result = undefined;
var present: [candidates.len]bool = @splat(false);
/// The other work on the machine while each candidate's runs were taken, one window per candidate. `collect`
/// empties them: a window belongs to one configuration, as `counts` does.
var other_work: [candidates.len]OtherWork = @splat(.empty);
var path_buffer: [candidates.len][std.fs.max_path_bytes]u8 = undefined;
var depths_buffer: [configurations_max]u32 = undefined;
var blocks_buffer: [configurations_max]u32 = undefined;

const output_buffer_bytes = 8192;

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;

    const found_count = try found(init, options, writer);
    if (found_count == 0) {
        try writer.writeAll("reads_runner: no candidate is installed; " ++
            "run `zig build bench-echo` and `zig build bench-alternatives`\n");
        try writer.flush();
        return error.NoCandidate;
    }

    try writer.writeAll(harness.series.markdown_header);
    try writer.flush();
    var rowless: u32 = 0;
    for (transfers) |transfer| {
        for (syncs_for(transfer)) |sync_choice| {
            rowless += try sweep(init, options, transfer, sync_choice, writer);
        }
    }
    if (rowless != 0) return error.CandidateProducedNoRow;
}

/// One configuration a row covers: the direction, the pattern and the queue depth.
pub const Configuration = struct {
    transfer: []const u8,
    pattern: []const u8,
    depth: u32,
    block_bytes: u32,
    sync: []const u8,
};

/// The flush policies one direction is swept at. A read has nothing to flush, so it takes the
/// unsynced value alone: asking a read program for `--sync yes` makes it refuse the run, and the
/// table would carry a failure line where a row should be.
pub fn syncs_for(transfer: []const u8) []const []const u8 {
    if (std.mem.eql(u8, transfer, "write")) return syncs[0..];
    return syncs[0..1];
}

/// Every pattern, block size and depth of one direction and one flush policy, each its own row. It
/// is a function of its own because the sweep has five dimensions now, and `main` was over the
/// cognitive-complexity limit with all of them nested in it. Returns how many installed candidates
/// got no row.
fn sweep(
    init: std.process.Init,
    options: Options,
    transfer: []const u8,
    sync_choice: []const u8,
    writer: *std.Io.Writer,
) !u32 {
    var rowless: u32 = 0;
    for (patterns) |pattern| {
        for (options.blocks) |block_bytes| {
            for (options.depths) |depth| {
                var counts: [candidates.len]u32 = @splat(0);
                try collect(init, options, .{
                    .transfer = transfer,
                    .pattern = pattern,
                    .depth = depth,
                    .block_bytes = block_bytes,
                    .sync = sync_choice,
                }, &counts, writer);
                rowless += try render(counts, writer);
                try writer.flush();
            }
        }
    }
    return rowless;
}

fn collect(
    init: std.process.Init,
    options: Options,
    configuration: Configuration,
    counts: *[candidates.len]u32,
    writer: *std.Io.Writer,
) !void {
    other_work = @splat(.empty);
    var round: u32 = 0;
    while (round < options.rounds) : (round += 1) {
        for (candidates, 0..) |candidate, index| {
            if (!present[index]) continue;
            // Around the run, not before the round: a job that arrives part way through a matrix is
            // what spoiled the 2026-09-20 attempts, and only a reading on each side sees it.
            other_work[index].begin_run(init.io);
            defer other_work[index].end_run(init.io);
            const measured = one_run(init, options, candidate, index, configuration) catch |err| {
                try writer.print(
                    "reads_runner: {s} failed at {s} {s} sync {s} block {d} depth {d}: {t}\n",
                    .{
                        candidate.name,            configuration.transfer,
                        configuration.pattern,     configuration.sync,
                        configuration.block_bytes, configuration.depth,
                        err,
                    },
                );
                try writer.flush();
                continue;
            };
            results[index * rounds_max + counts[index]] = measured;
            counts[index] += 1;
        }
    }
}

/// One row per installed candidate that produced enough runs of one series, and a line naming each
/// that did not. Returns how many installed candidates got no row.
fn render(counts: [candidates.len]u32, writer: *std.Io.Writer) !u32 {
    var rowless: u32 = 0;
    for (candidates, 0..) |candidate, index| {
        if (!present[index]) continue;
        const taken = results[index * rounds_max ..][0..counts[index]];
        const window = other_work[index];
        if (!try programs.render_row(writer, "reads_runner", candidate.name, taken, window)) {
            rowless += 1;
        }
    }
    return rowless;
}

/// The most arguments one run passes: the program, the path, six pairs, and the candidate's own.
pub const argv_max = 22;

fn one_run(
    init: std.process.Init,
    options: Options,
    candidate: Candidate,
    index: usize,
    configuration: Configuration,
) !Result {
    var numbers: Numbers = undefined;
    var argv: [argv_max][]const u8 = undefined;
    const program = try program_path(options, candidate, index);
    const used = try fill_argv(&argv, &numbers, program, options, configuration, candidate);
    return try programs.run_once(init.io, init.arena.allocator(), argv[0..used], candidate.name);
}

/// The buffers the numeric arguments are printed into. They outlive `fill_argv`, because the argv it
/// returns points into them.
pub const Numbers = struct {
    depth: [16]u8 = undefined,
    block: [16]u8 = undefined,
    seconds: [16]u8 = undefined,
    file: [24]u8 = undefined,
};

/// Writes one run's whole argument list and returns how many entries it holds.
///
/// It is a function of its own so a test can read what a run is actually asked for. An argument the
/// runner stopped passing would leave the candidate on its own default, and the row would carry the
/// name of the configuration it was meant to run rather than the one it ran.
pub fn fill_argv(
    argv: *[argv_max][]const u8,
    numbers: *Numbers,
    program: []const u8,
    options: Options,
    configuration: Configuration,
    candidate: Candidate,
) !usize {
    argv[0] = program;
    argv[1] = options.path;
    argv[2] = "--pattern";
    argv[3] = configuration.pattern;
    argv[4] = "--depth";
    argv[5] = try std.fmt.bufPrint(&numbers.depth, "{d}", .{configuration.depth});
    argv[6] = "--block-bytes";
    argv[7] = try std.fmt.bufPrint(&numbers.block, "{d}", .{configuration.block_bytes});
    argv[8] = "--seconds";
    argv[9] = try std.fmt.bufPrint(&numbers.seconds, "{d}", .{options.seconds});
    argv[10] = "--file-bytes";
    argv[11] = try std.fmt.bufPrint(&numbers.file, "{d}", .{options.file_bytes});
    argv[12] = "--transfer";
    argv[13] = configuration.transfer;
    argv[14] = "--sync";
    argv[15] = configuration.sync;
    var used: usize = 16;
    for (candidate.arguments) |argument| {
        if (used == argv_max) return error.TooManyArguments;
        argv[used] = argument;
        used += 1;
    }
    return used;
}

fn program_path(options: Options, candidate: Candidate, index: usize) ![]const u8 {
    std.debug.assert(index < candidates.len);
    return try programs.program_path(&path_buffer[index], options.directory, candidate.program);
}

fn found(init: std.process.Init, options: Options, writer: *std.Io.Writer) !u32 {
    var count: u32 = 0;
    for (candidates, 0..) |candidate, index| {
        present[index] = false;
        if (!programs.wanted(options.only, candidate.name)) continue;
        if (candidate.linux_only and builtin.os.tag != .linux) {
            try writer.print("reads_runner: {s} runs on Linux alone, skipping it\n", .{
                candidate.name,
            });
            continue;
        }
        if (candidate.kqueue_only and builtin.os.tag == .linux) {
            try writer.print("reads_runner: {s} runs on macOS alone, skipping it\n", .{
                candidate.name,
            });
            continue;
        }
        const path = try program_path(options, candidate, index);
        present[index] = programs.installed(init.io, path);
        if (!present[index]) {
            try writer.print("reads_runner: {s} is not installed at {s}, skipping it\n", .{
                candidate.name, path,
            });
            continue;
        }
        count += 1;
    }
    return count;
}

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return error.MissingPath;
    var options: Options = .{ .path = arguments[1] };
    var index: usize = 2;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    if (options.rounds < harness.series.runs_min) return error.TooFewRounds;
    if (options.rounds > rounds_max) return error.TooManyRounds;
    for (options.blocks) |block_bytes| try check_block_bytes(block_bytes);
    return options;
}

/// O_DIRECT refuses a length that is not a multiple of the device's block size, so a block size
/// that is not a power of two at or above 512 cannot be read at all. It is a function of its own
/// so a test can reach it.
pub fn check_block_bytes(block_bytes: u32) !void {
    if (block_bytes < 512) return error.BlockTooSmall;
    if (!std.math.isPowerOfTwo(block_bytes)) return error.BlockNotPowerOfTwo;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--rounds")) {
        options.rounds = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--depths")) {
        options.depths = try harness.candidates.parse_list(value, &depths_buffer);
    } else if (std.mem.eql(u8, name, "--blocks")) {
        options.blocks = try harness.candidates.parse_list(value, &blocks_buffer);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--file-bytes")) {
        options.file_bytes = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--only")) {
        options.only = value;
    } else if (std.mem.eql(u8, name, "--directory")) {
        options.directory = value;
    } else {
        return error.UnknownArgument;
    }
}

test {
    _ = @import("reads_runner_test.zig");
}
