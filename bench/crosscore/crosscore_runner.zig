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
//! hits all of them alike, which is what `bench/competitors/README.md` records as the reason one
//! run of one candidate is not evidence.
//!
//! Only rotor's `waiting` mode appears here. `uv_async_send` and libxev's `Async` wake a sleeping
//! loop and offer no other mode, so that is the mode all three share; `bench/crosscore/
//! rotor_post.zig` says what the other two modes are and why they are not a comparison.
const std = @import("std");
const harness = @import("harness");

const Result = harness.Result;
const Series = harness.series.Series;
const parse_line = harness.report_parse.parse_line;
const last_line = harness.report_parse.last_line;
const placement = harness.placement;

/// Candidates this runner knows. Each is a program that measures one cross-core message and
/// prints a result line last.
const Candidate = struct {
    name: []const u8,
    program: []const u8,
    /// True when the program takes `--cpu` and `--peer-cpu`. All three do, because a cross-core
    /// row that did not place its two threads may have measured two threads on one core.
    takes_cpu: bool = true,
};

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

/// The most bytes one candidate may print. A result line is a few hundred; this is room for a
/// header, a Markdown row and a warning beside it.
const output_bytes_max: usize = 64 * 1024;

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
    var round: u32 = 0;
    while (round < options.rounds) : (round += 1) {
        for (candidates, 0..) |candidate, index| {
            if (!present[index]) continue;
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
        const series = Series.init(taken) catch |err| {
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

    var argv_buffer: [10][]const u8 = undefined;
    argv_buffer[0] = try program_path(options, candidate, index);
    argv_buffer[1] = "--samples";
    argv_buffer[2] = try std.fmt.bufPrint(&samples_text, "{d}", .{options.samples});
    argv_buffer[3] = "--warmup";
    argv_buffer[4] = try std.fmt.bufPrint(&warmup_text, "{d}", .{options.warmup});
    var used: usize = 5;
    if (candidate.takes_cpu) {
        argv_buffer[used] = "--cpu";
        argv_buffer[used + 1] = try std.fmt.bufPrint(&cpu_text, "{d}", .{options.cpu});
        argv_buffer[used + 2] = "--peer-cpu";
        argv_buffer[used + 3] = try std.fmt.bufPrint(&peer_text, "{d}", .{options.peer_cpu});
        used += 4;
    }

    // The arena outlives the run, and the result's strings point into the bytes it holds, so
    // nothing here is freed while a `Series` still reads it.
    const run = try std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv_buffer[0..used],
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });
    try check_exit(run.term);
    const line = last_line(run.stdout) orelse return error.NoResultLine;
    return try parse_line(line);
}

/// A candidate that did not exit cleanly measured nothing, whatever it printed.
fn check_exit(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code != 0) return error.CandidateFailed,
        else => return error.CandidateKilled,
    }
}

fn program_path(options: Options, candidate: Candidate, index: usize) ![]const u8 {
    std.debug.assert(index < candidates.len);
    std.debug.assert(candidate.program.len >= 1);
    return try std.fmt.bufPrint(&path_buffer[index], "{s}/{s}", .{
        options.directory, candidate.program,
    });
}

/// True when `--only` was not given, or names this candidate.
fn wanted(options: Options, name: []const u8) bool {
    if (options.only.len == 0) return true;
    var pieces = std.mem.splitScalar(u8, options.only, ',');
    while (pieces.next()) |piece| {
        if (std.mem.eql(u8, piece, name)) return true;
    }
    return false;
}

/// Marks every candidate whose program is on disk, names the ones that are not, and returns how
/// many are there.
fn found(init: std.process.Init, options: Options, writer: *std.Io.Writer) !u32 {
    var count: u32 = 0;
    for (candidates, 0..) |candidate, index| {
        if (!wanted(options, candidate.name)) {
            present[index] = false;
            continue;
        }
        const path = try program_path(options, candidate, index);
        const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch {
            present[index] = false;
            try writer.print("crosscore_runner: {s} is not installed at {s}, skipping it\n", .{
                candidate.name, path,
            });
            continue;
        };
        file.close(init.io);
        present[index] = true;
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

test "only names the candidates it lists, and an empty list names them all" {
    const all: Options = .{};
    for (candidates) |candidate| try testing.expect(wanted(all, candidate.name));

    const two: Options = .{ .only = "rotor,libxev" };
    try testing.expect(wanted(two, "rotor"));
    try testing.expect(wanted(two, "libxev"));
    try testing.expect(!wanted(two, "libuv"));

    const one: Options = .{ .only = "libuv" };
    try testing.expect(!wanted(one, "rotor"));
    try testing.expect(wanted(one, "libuv"));
    // A name that merely contains a candidate's name is not that candidate.
    try testing.expect(!wanted(.{ .only = "rotorx" }, "rotor"));
}

test "a candidate that did not exit cleanly measured nothing" {
    try check_exit(.{ .exited = 0 });
    try testing.expectError(error.CandidateFailed, check_exit(.{ .exited = 1 }));
    try testing.expectError(error.CandidateFailed, check_exit(.{ .exited = 255 }));
    // A killed candidate is the case that matters: a run cut short by the machine printed
    // whatever it had reached, and that line is not a measurement of anything.
    try testing.expectError(error.CandidateKilled, check_exit(.{ .signal = .KILL }));
    try testing.expectError(error.CandidateKilled, check_exit(.{ .stopped = .STOP }));
    try testing.expectError(error.CandidateKilled, check_exit(.{ .unknown = 0 }));
}

test "every candidate's program has a distinct name and path" {
    for (candidates, 0..) |candidate, index| {
        try testing.expect(candidate.program.len >= 1);
        for (candidates[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, candidate.name, other.name));
            try testing.expect(!std.mem.eql(u8, candidate.program, other.program));
        }
    }
}

test "a path is the directory and the program, and it fits the buffer" {
    const options: Options = .{ .directory = "zig-out/bin" };
    const path = try program_path(options, candidates[0], 0);
    try testing.expectEqualStrings("zig-out/bin/rotor_post", path);
}
