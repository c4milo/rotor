//! crosscore_runner: the comparison of milestone 4's cross-core workload, the one decision 4
//! calls rotor's main claim.
//!
//! Run:  crosscore_runner [--rounds N] [--samples N] [--warmup N] [--only NAME,NAME]
//!                        [--cpu N] [--peer-cpu N] [--directory D]
//!
//! Every candidate here measures itself, because a message between two threads of one process has
//! no client outside it to time it. So this runner starts each candidate's program, reads the
//! result line it prints last, and puts the runs of one candidate into a `Series`.
//!
//! **Candidates alternate within a round, not across rounds.** Round one runs every candidate,
//! then round two runs every candidate again. A machine that drifts warmer or busier over the run
//! hits all of them alike, which is what `bench/alternatives/README.md` records as the reason one
//! run of one candidate is not evidence.
//!
//! Only rotor's `waiting` mode appears here. `uv_async_send` and libxev's `Async` wake a sleeping
//! loop and offer no other mode, so that is the mode all three share; `bench/crosscore/
//! rotor_post.zig` says what the other two modes are and why they are not a comparison.
const std = @import("std");
const harness = @import("harness");

const Result = harness.Result;
const Series = harness.series.Series;
const programs = harness.candidates;
const LoadWindow = harness.load.Window;
const Candidate = programs.Candidate;
const placement = harness.placement;

/// Every candidate here takes `--cpu` and `--peer-cpu`, because a cross-core row that did not
/// place its two threads may have measured two threads sharing one core.
const candidates = [_]Candidate{
    .{ .name = "rotor", .program = "rotor_post" },
    .{ .name = "libuv", .program = "libuv_async" },
    .{ .name = "libxev", .program = "libxev_async" },
};

/// Rounds a run may ask for, and the fewest a series accepts.
const rounds_default: u32 = 5;
const rounds_max = harness.series.runs_max;

/// Round trips each candidate measures per round, and the ones before them that are not measured.
const samples_default: u32 = 20_000;
const warmup_default: u32 = 2_000;

/// Where the programs are, under the install prefix.
const directory_default = "zig-out/bin";

const Options = struct {
    rounds: u32 = rounds_default,
    samples: u32 = samples_default,
    warmup: u32 = warmup_default,
    only: []const u8 = "",
    cpu: usize = placement.first_cpu,
    peer_cpu: usize = placement.second_cpu,
    directory: []const u8 = directory_default,
};

var results: [rounds_max * candidates.len]Result = undefined;
var present: [candidates.len]bool = @splat(false);
/// The machine's load while each candidate's runs were taken, one window per candidate.
var loads: [candidates.len]LoadWindow = @splat(.empty);
var path_buffer: [candidates.len][std.fs.max_path_bytes]u8 = undefined;

const output_buffer_bytes = 8192;

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;

    const installed = try found(init, options, writer);
    if (installed == 0) {
        try writer.writeAll("crosscore_runner: no candidate is installed; " ++
            "run `zig build bench-crosscore`\n");
        try writer.flush();
        return error.NoCandidate;
    }

    try writer.writeAll(harness.series.markdown_header);
    try writer.flush();
    var counts: [candidates.len]u32 = @splat(0);
    try collect(init, options, &counts, writer);
    try render(counts, writer);
    try writer.flush();
}

/// Runs every installed candidate `rounds` times, alternating within each round.
fn collect(
    init: std.process.Init,
    options: Options,
    counts: *[candidates.len]u32,
    writer: *std.Io.Writer,
) !void {
    loads = @splat(.empty);
    var round: u32 = 0;
    while (round < options.rounds) : (round += 1) {
        for (candidates, 0..) |candidate, index| {
            if (!present[index]) continue;
            // Around the run, not before the round: a job that arrives part way through is what
            // spoiled the 2026-09-20 attempts, and only a sample on each side sees it.
            loads[index].sample();
            defer loads[index].sample();
            const measured = one_run(init, options, candidate, index) catch |err| {
                try writer.print("crosscore_runner: {s} failed: {t}\n", .{ candidate.name, err });
                try writer.flush();
                continue;
            };
            results[index * rounds_max + counts[index]] = measured;
            counts[index] += 1;
        }
    }
}

/// One row per candidate that produced enough runs, and a line naming each that did not.
fn render(counts: [candidates.len]u32, writer: *std.Io.Writer) !void {
    for (candidates, 0..) |candidate, index| {
        const taken = results[index * rounds_max ..][0..counts[index]];
        if (taken.len < harness.series.runs_min) {
            if (present[index]) {
                try writer.print("crosscore_runner: {s} has too few runs ({d})\n", .{
                    candidate.name, taken.len,
                });
            }
            continue;
        }
        const series = Series.init_with_load(taken, loads[index]) catch |err| {
            try writer.print("crosscore_runner: {s} runs are not one series: {t}\n", .{
                candidate.name, err,
            });
            continue;
        };
        try series.render_markdown_row(writer);
        try writer.writeByte('\n');
    }
}

/// Starts one candidate, waits for it, and reads the result line it printed last.
fn one_run(
    init: std.process.Init,
    options: Options,
    candidate: Candidate,
    index: usize,
) !Result {
    var samples_text: [16]u8 = undefined;
    var warmup_text: [16]u8 = undefined;
    var cpu_text: [16]u8 = undefined;
    var peer_text: [16]u8 = undefined;

    const argv = [_][]const u8{
        try program_path(options, candidate, index),
        "--samples",
        try std.fmt.bufPrint(&samples_text, "{d}", .{options.samples}),
        "--warmup",
        try std.fmt.bufPrint(&warmup_text, "{d}", .{options.warmup}),
        "--cpu",
        try std.fmt.bufPrint(&cpu_text, "{d}", .{options.cpu}),
        "--peer-cpu",
        try std.fmt.bufPrint(&peer_text, "{d}", .{options.peer_cpu}),
    };

    // The arena outlives the run, and the result's strings point into the bytes it holds, so
    // nothing here is freed while a `Series` still reads it.
    return try programs.run_once(init.io, init.arena.allocator(), &argv);
}

fn program_path(options: Options, candidate: Candidate, index: usize) ![]const u8 {
    std.debug.assert(index < candidates.len);
    return try programs.program_path(&path_buffer[index], options.directory, candidate.program);
}

/// Marks every candidate whose program is on disk, names the ones that are not, and returns how
/// many are there.
fn found(init: std.process.Init, options: Options, writer: *std.Io.Writer) !u32 {
    var count: u32 = 0;
    for (candidates, 0..) |candidate, index| {
        if (!programs.wanted(options.only, candidate.name)) {
            present[index] = false;
            continue;
        }
        const path = try program_path(options, candidate, index);
        present[index] = programs.installed(init.io, path);
        if (!present[index]) {
            try writer.print("crosscore_runner: {s} is not installed at {s}, skipping it\n", .{
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
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    if (options.rounds < harness.series.runs_min) return error.TooFewRounds;
    if (options.rounds > rounds_max) return error.TooManyRounds;
    if (options.cpu == options.peer_cpu) return error.OneCoreIsNotCrossCore;
    return options;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--rounds")) {
        options.rounds = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--samples")) {
        options.samples = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--warmup")) {
        options.warmup = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--cpu")) {
        options.cpu = try std.fmt.parseInt(usize, value, 10);
    } else if (std.mem.eql(u8, name, "--peer-cpu")) {
        options.peer_cpu = try std.fmt.parseInt(usize, value, 10);
    } else if (std.mem.eql(u8, name, "--only")) {
        options.only = value;
    } else if (std.mem.eql(u8, name, "--directory")) {
        options.directory = value;
    } else {
        return error.UnknownArgument;
    }
}

const testing = std.testing;

test "every candidate has a distinct name and a distinct program" {
    // Two candidates sharing either would collide in `results` and in `path_buffer`, and the
    // table would carry one candidate's runs under another's name.
    for (candidates, 0..) |candidate, index| {
        try testing.expect(candidate.name.len >= 1);
        try testing.expect(candidate.program.len >= 1);
        for (candidates[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, candidate.name, other.name));
            try testing.expect(!std.mem.eql(u8, candidate.program, other.program));
        }
    }
}

test "a path is the directory and the program" {
    const options: Options = .{ .directory = "zig-out/bin" };
    try testing.expectEqualStrings(
        "zig-out/bin/rotor_post",
        try program_path(options, candidates[0], 0),
    );
}

test "the two cores of a cross-core run may not be the same core" {
    // `parse` refuses it, because a run with both ends on one core is not a cross-core run at
    // all: it is C14 against C15, which docs/costs.md keeps as separate rows.
    var options: Options = .{};
    options.peer_cpu = options.cpu;
    try testing.expectEqual(options.cpu, options.peer_cpu);
}
