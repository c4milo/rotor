//! reads_runner: the comparison of milestone 4's O_DIRECT read workload, sequential and random.
//!
//! Run:  reads_runner PATH [--rounds N] [--depths N,N] [--block-bytes B] [--seconds S]
//!                    [--only NAME,NAME] [--directory D]
//!
//! Every candidate measures itself, as the timer and cross-core candidates do: a read has no
//! client outside the program that issued it.
//!
//! **A candidate here is a program and its arguments, not a program.** The other two runners have
//! one program per candidate. This workload compares four things across two programs: rotor with
//! registered buffers and without, which is decision 3's first speed source measured as an A
//! against a B, and libuv on its thread pool and on its io_uring ring.
//!
//! **libuv's io_uring path needs two things, and this runner supplies one of them.**
//! `bench/competitors/libuv_reads.c` calls `uv_loop_configure(UV_LOOP_USE_IO_URING_SQPOLL)` under
//! `--backend uring`; libuv also requires `UV_USE_IO_URING` to be a positive number in the
//! environment, and a kernel of at least 5.10.186. This runner sets that variable for itself, and
//! children inherit it. Setting it changes nothing for the other candidates: libuv creates the
//! ring only when the loop flag is set too, so the thread-pool candidate stays on the pool.
//!
//! **Sequential and random are different workloads, not different rows of one.** Each candidate
//! names its pattern in the workload column, so a `Series` can never mix them.
const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");

const Result = harness.Result;
const Series = harness.series.Series;
const programs = harness.candidates;

/// A candidate: a program and the arguments that make it this candidate. The name a row carries
/// comes from the program itself, because only the program knows which libuv it linked.
const Candidate = struct {
    name: []const u8,
    program: []const u8,
    arguments: []const []const u8,
    /// True for a candidate that only exists on Linux. libuv's io_uring path is the one.
    linux_only: bool = false,
};

const candidates = [_]Candidate{
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

const patterns = [_][]const u8{ "seq", "random" };

const rounds_default: u32 = 5;
const rounds_max = harness.series.runs_max;

/// Queue depths a run sweeps. Depth 1 is row C12 of `docs/costs.md` and above it is C13.
const depths_default = [_]u32{ 1, 32 };

const block_bytes_default: u32 = 4096;
const seconds_default: u64 = 3;
const file_bytes_default: u64 = 256 << 20;

const configurations_max = 8;
const directory_default = "zig-out/bin";

/// The variable libuv reads, and the value it wants.
const uring_variable = "UV_USE_IO_URING";
const uring_value = "1";

const Options = struct {
    path: []const u8,
    rounds: u32 = rounds_default,
    depths: []const u32 = &depths_default,
    block_bytes: u32 = block_bytes_default,
    seconds: u64 = seconds_default,
    file_bytes: u64 = file_bytes_default,
    only: []const u8 = "",
    directory: []const u8 = directory_default,
};

var results: [rounds_max * candidates.len]Result = undefined;
var present: [candidates.len]bool = @splat(false);
var path_buffer: [candidates.len][std.fs.max_path_bytes]u8 = undefined;
var depths_buffer: [configurations_max]u32 = undefined;

const output_buffer_bytes = 8192;

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;

    enable_libuv_uring();

    const found_count = try found(init, options, writer);
    if (found_count == 0) {
        try writer.writeAll("reads_runner: no candidate is installed; " ++
            "run `zig build bench-echo` and `zig build bench-competitors`\n");
        try writer.flush();
        return error.NoCandidate;
    }

    try writer.writeAll(harness.series.markdown_header);
    try writer.flush();
    for (patterns) |pattern| {
        for (options.depths) |depth| {
            var counts: [candidates.len]u32 = @splat(0);
            try collect(init, options, pattern, depth, &counts, writer);
            try render(counts, writer);
            try writer.flush();
        }
    }
}

/// Sets `UV_USE_IO_URING` for this process, which children inherit. It is half of what libuv's
/// io_uring path needs; the other half is the loop option, which only the `uring` candidate's
/// program sets, so this changes nothing for anybody else.
fn enable_libuv_uring() void {
    if (builtin.os.tag != .linux) return;
    _ = std.c.setenv(uring_variable, uring_value, 1);
}

fn collect(
    init: std.process.Init,
    options: Options,
    pattern: []const u8,
    depth: u32,
    counts: *[candidates.len]u32,
    writer: *std.Io.Writer,
) !void {
    var round: u32 = 0;
    while (round < options.rounds) : (round += 1) {
        for (candidates, 0..) |candidate, index| {
            if (!present[index]) continue;
            const measured = one_run(init, options, candidate, index, pattern, depth) catch |err| {
                try writer.print("reads_runner: {s} failed at {s} depth {d}: {t}\n", .{
                    candidate.name, pattern, depth, err,
                });
                try writer.flush();
                continue;
            };
            results[index * rounds_max + counts[index]] = measured;
            counts[index] += 1;
        }
    }
}

fn render(counts: [candidates.len]u32, writer: *std.Io.Writer) !void {
    for (candidates, 0..) |candidate, index| {
        const taken = results[index * rounds_max ..][0..counts[index]];
        if (taken.len < harness.series.runs_min) {
            if (present[index]) {
                try writer.print("reads_runner: {s} has too few runs ({d})\n", .{
                    candidate.name, taken.len,
                });
            }
            continue;
        }
        const series = Series.init(taken) catch |err| {
            try writer.print("reads_runner: {s} runs are not one series: {t}\n", .{
                candidate.name, err,
            });
            continue;
        };
        try series.render_markdown_row(writer);
        try writer.writeByte('\n');
    }
}

/// The most arguments one run passes: the program, the path, five pairs, and the candidate's own.
const argv_max = 16;

fn one_run(
    init: std.process.Init,
    options: Options,
    candidate: Candidate,
    index: usize,
    pattern: []const u8,
    depth: u32,
) !Result {
    var depth_text: [16]u8 = undefined;
    var block_text: [16]u8 = undefined;
    var seconds_text: [16]u8 = undefined;
    var file_text: [24]u8 = undefined;

    var argv: [argv_max][]const u8 = undefined;
    argv[0] = try program_path(options, candidate, index);
    argv[1] = options.path;
    argv[2] = "--pattern";
    argv[3] = pattern;
    argv[4] = "--depth";
    argv[5] = try std.fmt.bufPrint(&depth_text, "{d}", .{depth});
    argv[6] = "--block-bytes";
    argv[7] = try std.fmt.bufPrint(&block_text, "{d}", .{options.block_bytes});
    argv[8] = "--seconds";
    argv[9] = try std.fmt.bufPrint(&seconds_text, "{d}", .{options.seconds});
    argv[10] = "--file-bytes";
    argv[11] = try std.fmt.bufPrint(&file_text, "{d}", .{options.file_bytes});
    var used: usize = 12;
    for (candidate.arguments) |argument| {
        if (used == argv_max) return error.TooManyArguments;
        argv[used] = argument;
        used += 1;
    }

    return try programs.run_once(init.io, init.arena.allocator(), argv[0..used]);
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
    try check_block_bytes(options.block_bytes);
    return options;
}

/// O_DIRECT refuses a length that is not a multiple of the device's block size, so a block size
/// that is not a power of two at or above 512 cannot be read at all. It is a function of its own
/// so a test can reach it.
fn check_block_bytes(block_bytes: u32) !void {
    if (block_bytes < 512) return error.BlockTooSmall;
    if (!std.math.isPowerOfTwo(block_bytes)) return error.BlockNotPowerOfTwo;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--rounds")) {
        options.rounds = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--depths")) {
        options.depths = try parse_list(value, &depths_buffer);
    } else if (std.mem.eql(u8, name, "--block-bytes")) {
        options.block_bytes = try std.fmt.parseInt(u32, value, 10);
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

/// Reads a comma-separated list of counts into `buffer`. The empty list refuses itself: the split
/// yields one empty piece and `parseInt` refuses that.
fn parse_list(text: []const u8, buffer: []u32) ![]const u32 {
    var count: usize = 0;
    var pieces = std.mem.splitScalar(u8, text, ',');
    while (pieces.next()) |piece| {
        if (count == buffer.len) return error.TooManyValues;
        buffer[count] = try std.fmt.parseInt(u32, piece, 10);
        if (buffer[count] == 0) return error.EmptyConfiguration;
        count += 1;
    }
    std.debug.assert(count >= 1);
    return buffer[0..count];
}

const testing = std.testing;

test "a block size O_DIRECT cannot use is refused" {
    try testing.expectError(error.BlockTooSmall, check_block_bytes(0));
    try testing.expectError(error.BlockTooSmall, check_block_bytes(511));
    try testing.expectError(error.BlockNotPowerOfTwo, check_block_bytes(4095));
    try testing.expectError(error.BlockNotPowerOfTwo, check_block_bytes(6144));

    try check_block_bytes(512);
    try check_block_bytes(4096);
    try check_block_bytes(65536);
}

test "a depth list is read, and an empty or oversized one is refused" {
    var buffer: [configurations_max]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 1, 32 }, try parse_list("1,32", &buffer));
    try testing.expectError(error.InvalidCharacter, parse_list("", &buffer));
    try testing.expectError(error.EmptyConfiguration, parse_list("1,0", &buffer));

    var small: [1]u32 = undefined;
    try testing.expectError(error.TooManyValues, parse_list("1,32", &small));
}

test "the two rotor candidates differ only in registration, and both name it" {
    // The A and the B of decision 3's first speed source have to be two candidates and not two
    // runs of one, or a `Series` would average them into a number that describes neither.
    const registered = candidates[0];
    const plain = candidates[1];
    try testing.expectEqualStrings(registered.program, plain.program);
    try testing.expect(!std.mem.eql(u8, registered.name, plain.name));
    try testing.expectEqualStrings("yes", registered.arguments[1]);
    try testing.expectEqualStrings("no", plain.arguments[1]);
}

test "every candidate has a distinct name, and its arguments come in pairs" {
    for (candidates, 0..) |candidate, index| {
        try testing.expect(candidate.name.len >= 1);
        try testing.expect(candidate.program.len >= 1);
        try testing.expectEqual(@as(usize, 0), candidate.arguments.len % 2);
        for (candidates[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, candidate.name, other.name));
        }
    }
}

test "one run's arguments fit the buffer, with the longest candidate's own" {
    var longest: usize = 0;
    for (candidates) |candidate| longest = @max(longest, candidate.arguments.len);
    // 12 fixed: the program, the path, and five name-value pairs.
    try testing.expect(12 + longest <= argv_max);
}

test "only libuv's io_uring candidate is Linux-only" {
    for (candidates) |candidate| {
        const is_uring = std.mem.eql(u8, candidate.name, "libuv-uring");
        try testing.expectEqual(is_uring, candidate.linux_only);
    }
}
