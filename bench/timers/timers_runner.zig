//! timers_runner: the comparison of milestone 4's timer churn workload, the one part of a loop
//! that touches no socket and no file.
//!
//! Run:  timers_runner [--rounds N] [--timers N,N] [--period-us U] [--seconds S]
//!                     [--only NAME,NAME] [--directory D]
//!
//! Every candidate measures itself, because a timer has no client to time it from: the loop that
//! arms the timer is the only thing that knows when it fired. So this runner starts each
//! candidate's program once per round, reads the result line it printed last, and puts the runs
//! of one candidate into a `Series`.
//!
//! **The percentiles are lateness, not latency.** Each candidate reports how far past its deadline
//! each timer actually fired. A loop that fires more timers later is not obviously better, so the
//! throughput column and the percentile columns have to be read together.
//!
//! **libuv timers are whole milliseconds.** `uv_timer_start` takes its timeout in milliseconds, so
//! `bench/alternatives/libuv_timers.c` refuses a period it cannot state exactly, and this runner's
//! default period is one it can. A period under 1,000 microseconds compares rotor against a libuv
//! that was asked for something else, so the runner refuses it too rather than printing a row that
//! looks like a comparison.
//!
//! **`std.Io` has no timer, and that is why its row is here.** It has `sleep`, and a task that
//! sleeps, so N timers is N tasks; under `std.Io.Threaded` a sleeping task holds the worker thread
//! it runs on, so N timers is N threads. `bench/alternatives/std_io_timers.zig` writes it that way
//! because nothing else the interface offers arms a timer, and this row is what the shape costs.
//!
//! **A candidate here is a program and its arguments, not a program.** Two candidates share
//! `std_io_timers`, which takes `--backend`, the way `bench/files/reads_runner.zig` has two
//! candidates per program. `std.Io.Uring` is Linux-only, and it does not compile on the pinned Zig
//! at all, which `bench/alternatives/README.md` records.
const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");

const Result = harness.Result;
const Series = harness.series.Series;
const programs = harness.candidates;
const LoadWindow = harness.load.Window;

/// One candidate: the name a row carries, the program to start, and the arguments that make it
/// this candidate rather than another of the same program. The version is not here, because a
/// candidate reports its own.
const Candidate = struct {
    name: []const u8,
    program: []const u8,
    arguments: []const []const u8 = &.{},
    /// True for a candidate that only exists on Linux. `std.Io.Uring` is the one.
    linux_only: bool = false,
};

const candidates = [_]Candidate{
    .{ .name = "rotor", .program = "rotor_timers" },
    .{ .name = "libuv", .program = "libuv_timers" },
    .{ .name = "libxev", .program = "libxev_timers" },
    .{
        .name = "std.Io.Threaded",
        .program = "std_io_timers",
        .arguments = &.{ "--backend", "threaded" },
    },
    .{
        .name = "std.Io.Uring",
        .program = "std_io_timers",
        .arguments = &.{ "--backend", "uring" },
        .linux_only = true,
    },
};

const rounds_default: u32 = 5;
const rounds_max = harness.series.runs_max;

/// Timer counts a run sweeps, one row per count per candidate. The small one fits any loop's
/// structure in cache; the large one does not, which is what the workload is for.
const timers_default = [_]u32{ 256, 4096 };

/// The period every timer is armed for, in microseconds, and the fewest a run may ask for. The
/// floor is libuv's: one whole millisecond.
const period_us_default: u64 = 1000;
const period_us_min: u64 = 1000;

/// How long one round runs.
const seconds_default: u64 = 3;

/// Counts one run may sweep, which bounds the buffer the list is read into.
const configurations_max = 8;

const directory_default = "zig-out/bin";

const Options = struct {
    rounds: u32 = rounds_default,
    timers: []const u32 = &timers_default,
    period_us: u64 = period_us_default,
    seconds: u64 = seconds_default,
    only: []const u8 = "",
    directory: []const u8 = directory_default,
};

var results: [rounds_max * candidates.len]Result = undefined;
var present: [candidates.len]bool = @splat(false);
/// The machine's load while each candidate's runs were taken, one window per candidate. `collect`
/// empties them: a window belongs to one configuration, as `counts` does.
var loads: [candidates.len]LoadWindow = @splat(.empty);
var path_buffer: [candidates.len][std.fs.max_path_bytes]u8 = undefined;
var timers_buffer: [configurations_max]u32 = undefined;

const output_buffer_bytes = 8192;

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;

    const installed = try found(init, options, writer);
    if (installed == 0) {
        try writer.writeAll("timers_runner: no candidate is installed; " ++
            "run `zig build bench-echo` and `zig build bench-alternatives`\n");
        try writer.flush();
        return error.NoCandidate;
    }

    try writer.writeAll(harness.series.markdown_header);
    try writer.flush();
    for (options.timers) |count| {
        var counts: [candidates.len]u32 = @splat(0);
        try collect(init, options, count, &counts, writer);
        try render(counts, writer);
        try writer.flush();
    }
}

/// Runs every installed candidate `rounds` times at `timers`, alternating within each round so a
/// machine that drifts over the run hits all of them alike.
fn collect(
    init: std.process.Init,
    options: Options,
    timers: u32,
    counts: *[candidates.len]u32,
    writer: *std.Io.Writer,
) !void {
    loads = @splat(.empty);
    var round: u32 = 0;
    while (round < options.rounds) : (round += 1) {
        for (candidates, 0..) |candidate, index| {
            if (!present[index]) continue;
            // Around the run, not before the round: a job that arrives part way through a matrix is
            // what spoiled the 2026-09-20 attempts, and only a sample on each side sees it.
            loads[index].sample();
            defer loads[index].sample();
            const measured = one_run(init, options, candidate, index, timers) catch |err| {
                try writer.print("timers_runner: {s} failed at {d} timers: {t}\n", .{
                    candidate.name, timers, err,
                });
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
                try writer.print("timers_runner: {s} has too few runs ({d})\n", .{
                    candidate.name, taken.len,
                });
            }
            continue;
        }
        const series = Series.init_with_load(taken, loads[index]) catch |err| {
            try writer.print("timers_runner: {s} runs are not one series: {t}\n", .{
                candidate.name, err,
            });
            continue;
        };
        try series.render_markdown_row(writer);
        try writer.writeByte('\n');
    }
}

/// The most arguments one run passes: the program, three name-value pairs, and the candidate's
/// own. A test holds it at or above what the longest candidate needs.
const argv_max = 12;

fn one_run(
    init: std.process.Init,
    options: Options,
    candidate: Candidate,
    index: usize,
    timers: u32,
) !Result {
    var timers_text: [16]u8 = undefined;
    var period_text: [16]u8 = undefined;
    var seconds_text: [16]u8 = undefined;

    var argv: [argv_max][]const u8 = undefined;
    argv[0] = try program_path(options, candidate, index);
    argv[1] = "--timers";
    argv[2] = try std.fmt.bufPrint(&timers_text, "{d}", .{timers});
    argv[3] = "--period-us";
    argv[4] = try std.fmt.bufPrint(&period_text, "{d}", .{options.period_us});
    argv[5] = "--seconds";
    argv[6] = try std.fmt.bufPrint(&seconds_text, "{d}", .{options.seconds});
    const used = try append_arguments(&argv, 7, candidate.arguments);

    // The arena outlives the run, and the result's strings point into the bytes it holds.
    return try programs.run_once(init.io, init.arena.allocator(), argv[0..used]);
}

/// Writes `extra` into `argv` after the `used` entries already there, and returns how many
/// entries the run passes. It is a function of its own so a test can reach it: a candidate whose
/// arguments were dropped would run another candidate's configuration and print another
/// candidate's name, which no other check here would notice.
fn append_arguments(
    argv: *[argv_max][]const u8,
    used: usize,
    extra: []const []const u8,
) !usize {
    std.debug.assert(used <= argv_max);
    var count = used;
    for (extra) |argument| {
        if (count == argv_max) return error.TooManyArguments;
        argv[count] = argument;
        count += 1;
    }
    return count;
}

fn program_path(options: Options, candidate: Candidate, index: usize) ![]const u8 {
    std.debug.assert(index < candidates.len);
    return try programs.program_path(&path_buffer[index], options.directory, candidate.program);
}

/// True when this host can run a candidate at all. `std.Io.Uring` exists on Linux alone, and a
/// row for it on any other host would name a candidate that never ran. The host is a parameter so
/// a test reaches both answers on either machine.
fn runnable(candidate: Candidate, os_tag: std.Target.Os.Tag) bool {
    return !candidate.linux_only or os_tag == .linux;
}

fn found(init: std.process.Init, options: Options, writer: *std.Io.Writer) !u32 {
    var count: u32 = 0;
    for (candidates, 0..) |candidate, index| {
        present[index] = false;
        if (!programs.wanted(options.only, candidate.name)) continue;
        if (!runnable(candidate, builtin.os.tag)) {
            try writer.print("timers_runner: {s} runs on Linux alone, skipping it\n", .{
                candidate.name,
            });
            continue;
        }
        const path = try program_path(options, candidate, index);
        present[index] = programs.installed(init.io, path);
        if (!present[index]) {
            try writer.print("timers_runner: {s} is not installed at {s}, skipping it\n", .{
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
    try check_period(options.period_us);
    return options;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--rounds")) {
        options.rounds = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--timers")) {
        options.timers = try parse_list(value, &timers_buffer);
    } else if (std.mem.eql(u8, name, "--period-us")) {
        options.period_us = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--only")) {
        options.only = value;
    } else if (std.mem.eql(u8, name, "--directory")) {
        options.directory = value;
    } else {
        return error.UnknownArgument;
    }
}

/// Refuses a period the alternatives cannot state exactly. libuv and libxev both take their
/// timeout as whole milliseconds, so a period under one, or one that is not a whole number of
/// them, would compare rotor against an alternative that was asked for something else. It is a
/// function of its own so a test can reach it: the check was inside `parse` first, and deleting
/// it there failed no test.
fn check_period(period_us: u64) !void {
    if (period_us < period_us_min) return error.PeriodBelowLibuvFloor;
    if (period_us % period_us_min != 0) return error.PeriodNotWholeMilliseconds;
}

/// Reads a comma-separated list of counts into `buffer`.
///
/// An empty list refuses itself: `splitScalar` yields one empty piece for the empty string, and
/// `parseInt` refuses that as `InvalidCharacter`. So the count is never 0 on return, and a guard
/// for it would be a branch nothing can reach. `bench/echo/echo_runner.zig` carries such a guard.
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

test "a period libuv cannot state exactly is refused, not rounded" {
    // Comparing rotor at 1,500 microseconds against a libuv that was asked for 1,000 would
    // measure the rounding, so no such row is printed at all.
    try testing.expectError(error.PeriodBelowLibuvFloor, check_period(0));
    try testing.expectError(error.PeriodBelowLibuvFloor, check_period(1));
    try testing.expectError(error.PeriodBelowLibuvFloor, check_period(999));
    try testing.expectError(error.PeriodNotWholeMilliseconds, check_period(1001));
    try testing.expectError(error.PeriodNotWholeMilliseconds, check_period(1500));

    try check_period(1000);
    try check_period(2000);
    try check_period(1_000_000);
}

test "a timer list is read, and an empty or oversized one is refused" {
    var buffer: [configurations_max]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 16, 256 }, try parse_list("16,256", &buffer));
    try testing.expectEqualSlices(u32, &.{64}, try parse_list("64", &buffer));

    // The empty list is refused as a bad number and not as an empty configuration: the split
    // yields one empty piece, and `parseInt` refuses that first.
    try testing.expectError(error.InvalidCharacter, parse_list("", &buffer));
    try testing.expectError(error.EmptyConfiguration, parse_list("16,0", &buffer));
    try testing.expectError(error.EmptyConfiguration, parse_list("0", &buffer));
    try testing.expectError(error.InvalidCharacter, parse_list("16,many", &buffer));
    try testing.expectError(error.InvalidCharacter, parse_list("16,", &buffer));

    var small: [1]u32 = undefined;
    try testing.expectError(error.TooManyValues, parse_list("16,256", &small));
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

test "the two std.Io candidates share one program and differ only in the backend" {
    // `std.Io` is an interface, and the two are implementations of it. They have to be two
    // candidates and not two runs of one, or a `Series` would average them into a number that
    // describes neither.
    const threaded = candidates[3];
    const uring = candidates[4];
    try testing.expectEqualStrings("std.Io.Threaded", threaded.name);
    try testing.expectEqualStrings("std.Io.Uring", uring.name);
    try testing.expectEqualStrings(threaded.program, uring.program);
    try testing.expectEqualStrings("--backend", threaded.arguments[0]);
    try testing.expectEqualStrings("threaded", threaded.arguments[1]);
    try testing.expectEqualStrings("--backend", uring.arguments[0]);
    try testing.expectEqualStrings("uring", uring.arguments[1]);
}

test "only std.Io.Uring is Linux-only, and off Linux it is not runnable" {
    for (candidates) |candidate| {
        const is_uring = std.mem.eql(u8, candidate.name, "std.Io.Uring");
        try testing.expectEqual(is_uring, candidate.linux_only);
        // Both answers, on whichever host this test runs on.
        try testing.expectEqual(!is_uring, runnable(candidate, .macos));
        try testing.expect(runnable(candidate, .linux));
    }
}

test "a candidate's own arguments are appended, and a full buffer is an error" {
    var argv: [argv_max][]const u8 = undefined;
    argv[0] = "std_io_timers";

    try testing.expectEqual(@as(usize, 1), try append_arguments(&argv, 1, &.{}));
    try testing.expectEqual(
        @as(usize, 3),
        try append_arguments(&argv, 1, &.{ "--backend", "threaded" }),
    );
    try testing.expectEqualStrings("--backend", argv[1]);
    try testing.expectEqualStrings("threaded", argv[2]);

    try testing.expectError(
        error.TooManyArguments,
        append_arguments(&argv, argv_max, &.{"--backend"}),
    );
    try testing.expectError(
        error.TooManyArguments,
        append_arguments(&argv, argv_max - 1, &.{ "--backend", "threaded" }),
    );
}

test "one run's arguments fit the buffer, with the longest candidate's own" {
    var longest: usize = 0;
    for (candidates) |candidate| longest = @max(longest, candidate.arguments.len);
    // 7 fixed: the program and three name-value pairs.
    try testing.expect(7 + longest <= argv_max);
}

test "the default period is one libuv can state, and the default sweep is not empty" {
    const options: Options = .{};
    try testing.expect(options.period_us >= period_us_min);
    try testing.expectEqual(@as(u64, 0), options.period_us % period_us_min);
    try testing.expect(options.timers.len >= 1);
    try testing.expect(options.timers.len <= configurations_max);
}
