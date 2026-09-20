//! `Series`: the several runs of one candidate on one workload and one configuration, and the row
//! they make together.
//!
//! One run is not evidence. The experiment that settled this is in
//! `bench/competitors/README.md`: three alternating rounds of two shapes of the same server
//! disagreed about which was faster, because the spread inside one shape was wider than the gap
//! between the shapes. A single number from a single run would have reported either shape as the
//! winner, with equal confidence and no warning.
//!
//! So a row here carries three things and not one: the median of the runs, the spread between the
//! fastest and the slowest, and whether that spread is wide enough that the row cannot decide
//! anything. `render_markdown_row` prints the spread beside the median, always, so a reader
//! cannot take a number without seeing how firm it is.
//!
//! Nothing here allocates. A series holds its runs in a fixed array, and a caller that wants more
//! than `runs_max` is refused rather than silently given a summary of some of them.
const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const report = @import("report.zig");
const text = @import("text.zig");

const Result = report.Result;

/// Runs one series holds. A comparison that repeats a candidate more than this many times is
/// measuring something this file was not built for.
pub const runs_max = 32;

/// The fewest runs a series needs before it reports anything: one run has no spread, and two
/// cannot tell a spread from a single outlier.
pub const runs_min = 3;

/// A spread at or above this many parts per hundred of the median means the runs disagree by more
/// than a candidate comparison can see through. The threshold is the harness's own rule and not a
/// measured constant; the experiment in `bench/competitors/README.md` saw 20 parts per hundred
/// between runs of one unchanged program, so a row that wide decides nothing.
pub const spread_unreliable_percent: u64 = 10;

const percent_whole: u64 = 100;

pub const SeriesError = error{
    /// Fewer than `runs_min`, or more than `runs_max`.
    RunCountOutOfRange,
    /// Two runs of one series named different workloads, candidates or configurations.
    RunsDisagree,
};

pub const Series = struct {
    /// The runs, oldest first, all of one workload, candidate and configuration.
    runs: []const Result,

    /// Fails when the runs are too few, too many, or not of one thing.
    pub fn init(runs: []const Result) SeriesError!Series {
        if (runs.len < runs_min or runs.len > runs_max) return error.RunCountOutOfRange;
        const first = runs[0];
        for (runs[1..]) |run| {
            if (!std.mem.eql(u8, run.workload, first.workload)) return error.RunsDisagree;
            if (!std.mem.eql(u8, run.candidate, first.candidate)) return error.RunsDisagree;
            if (!run.configuration.equals(first.configuration)) return error.RunsDisagree;
        }
        return .{ .runs = runs };
    }

    /// The middle run's throughput. The median and not the mean, because one run that hit a
    /// scheduler stall moves a mean and does not move a median.
    pub fn median_per_second(series: Series) u64 {
        var values: [runs_max]u64 = undefined;
        for (series.runs, values[0..series.runs.len]) |run, *value| {
            value.* = run.operations_per_second;
        }
        return median_of(values[0..series.runs.len]);
    }

    /// The middle run's p50, p99 and p999, each taken across the runs on its own.
    pub fn median_p50_ns(series: Series) u64 {
        return series.median_latency(latency_p50);
    }

    pub fn median_p99_ns(series: Series) u64 {
        return series.median_latency(latency_p99);
    }

    pub fn median_p999_ns(series: Series) u64 {
        return series.median_latency(latency_p999);
    }

    /// The fastest run's throughput, and the slowest run's.
    pub fn fastest_per_second(series: Series) u64 {
        var highest: u64 = 0;
        for (series.runs) |run| highest = @max(highest, run.operations_per_second);
        return highest;
    }

    pub fn slowest_per_second(series: Series) u64 {
        var lowest: u64 = std.math.maxInt(u64);
        for (series.runs) |run| lowest = @min(lowest, run.operations_per_second);
        return lowest;
    }

    /// How far the runs disagree, in parts per hundred of the median: the fastest minus the
    /// slowest, over the median. 0 when the median is 0, which is a series that measured nothing.
    pub fn spread_percent(series: Series) u64 {
        const median = series.median_per_second();
        if (median == 0) return 0;
        const span = series.fastest_per_second() - series.slowest_per_second();
        return span * percent_whole / median;
    }

    /// True when the runs disagree by more than a comparison can see through. A row this wide
    /// reports its numbers and decides nothing.
    pub fn unreliable(series: Series) bool {
        return series.spread_percent() >= spread_unreliable_percent;
    }

    fn median_latency(series: Series, comptime field: []const u8) u64 {
        var values: [runs_max]u64 = undefined;
        for (series.runs, values[0..series.runs.len]) |run, *value| {
            value.* = @field(run, field);
        }
        return median_of(values[0..series.runs.len]);
    }

    /// One row: the medians, then the spread, then the mark when the spread is too wide.
    pub fn render_markdown_row(series: Series, writer: *Writer) Writer.Error!void {
        const first = series.runs[0];
        try writer.writeAll("| ");
        try text.markdown_cell(writer, first.workload);
        try writer.writeAll(" | ");
        try text.markdown_cell(writer, first.candidate);
        try writer.writeAll(" | ");
        try text.markdown_cell(writer, first.candidate_version);
        try writer.print(" | {d} | {d} | {d} | {t} | {d} | {d} | {d} | {d} | {d} | {s} |", .{
            first.configuration.cores,
            first.configuration.connections,
            first.configuration.payload_bytes,
            first.configuration.load,
            series.runs.len,
            series.median_per_second(),
            series.median_p50_ns(),
            series.median_p99_ns(),
            series.spread_percent(),
            if (series.unreliable()) unreliable_mark else "",
        });
    }
};

const latency_p50 = "p50_ns";
const latency_p99 = "p99_ns";
const latency_p999 = "p999_ns";

/// What a row says when its runs disagree too much to decide anything. Capitals, as
/// report_comparison's loss mark is, so a reader who skims cannot miss it.
pub const unreliable_mark = "**RUNS DISAGREE**";

pub const markdown_header =
    "| workload | candidate | version | cores | connections | payload bytes | load " ++
    "| runs | median per second | median p50 ns | median p99 ns | spread percent | verdict |\n" ++
    "|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---|\n";

/// Sorts `values` in place and returns the middle one. An even count takes the lower of the two
/// middle values, so the answer is always a run that happened.
fn median_of(values: []u64) u64 {
    assert(values.len >= 1);
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[(values.len - 1) / 2];
}

const testing = std.testing;

fn measured(operations_per_second: u64, p50_ns: u64) Result {
    return .{
        .workload = "echo",
        .candidate = "libuv",
        .candidate_version = "v1.52.1",
        .configuration = .{
            .cores = 1,
            .connections = 16,
            .payload_bytes = 4096,
            .load = .even,
        },
        .duration_ns = 4 * std.time.ns_per_s,
        .operations = operations_per_second * 4,
        .operations_per_second = operations_per_second,
        .p50_ns = p50_ns,
        .p99_ns = p50_ns * 2,
        .p999_ns = p50_ns * 4,
        .overflow = 0,
    };
}

test "a series needs enough runs, and every run must be of one thing" {
    const runs = [_]Result{ measured(10, 1), measured(20, 2), measured(30, 3) };
    _ = try Series.init(&runs);
    try testing.expectError(error.RunCountOutOfRange, Series.init(runs[0..2]));
    try testing.expectError(error.RunCountOutOfRange, Series.init(&.{}));

    // The upper bound is a bound too: a caller with more runs than this is refused, and not
    // handed a summary of some of them.
    var many: [runs_max + 1]Result = undefined;
    for (&many, 0..) |*one, index| one.* = measured(index + 1, 1);
    _ = try Series.init(many[0..runs_max]);
    try testing.expectError(error.RunCountOutOfRange, Series.init(&many));

    var other = runs;
    other[1].candidate = "libxev";
    try testing.expectError(error.RunsDisagree, Series.init(&other));
    other = runs;
    other[2].configuration.connections = 32;
    try testing.expectError(error.RunsDisagree, Series.init(&other));
    other = runs;
    other[0].workload = "accept storm";
    try testing.expectError(error.RunsDisagree, Series.init(&other));
}

test "the median is a run that happened, and an outlier does not move it" {
    const runs = [_]Result{ measured(100, 10), measured(900, 90), measured(110, 11) };
    const series = try Series.init(&runs);
    try testing.expectEqual(@as(u64, 110), series.median_per_second());
    try testing.expectEqual(@as(u64, 11), series.median_p50_ns());
    try testing.expectEqual(@as(u64, 22), series.median_p99_ns());
    try testing.expectEqual(@as(u64, 44), series.median_p999_ns());
    try testing.expectEqual(@as(u64, 900), series.fastest_per_second());
    try testing.expectEqual(@as(u64, 100), series.slowest_per_second());

    // An even count takes the lower middle, so the answer is one of the runs.
    const four = [_]Result{ measured(100, 1), measured(200, 2), measured(300, 3), measured(400, 4) };
    try testing.expectEqual(@as(u64, 200), (try Series.init(&four)).median_per_second());
}

test "a series says when its runs disagree by more than a comparison can see through" {
    // The three rounds of bench/competitors/README.md, the `two` shape: 78236, 82826, 93952.
    const rounds = [_]Result{ measured(78236, 1), measured(82826, 1), measured(93952, 1) };
    const series = try Series.init(&rounds);
    try testing.expectEqual(@as(u64, 82826), series.median_per_second());
    try testing.expectEqual(@as(u64, 18), series.spread_percent());
    try testing.expect(series.unreliable());

    const steady = [_]Result{ measured(1000, 1), measured(1010, 1), measured(1020, 1) };
    const firm = try Series.init(&steady);
    try testing.expectEqual(@as(u64, 1), firm.spread_percent());
    try testing.expect(!firm.unreliable());

    // Exactly at the threshold is unreliable: the rule is "at or above".
    const edge = [_]Result{ measured(100, 1), measured(100, 1), measured(110, 1) };
    try testing.expectEqual(spread_unreliable_percent, (try Series.init(&edge)).spread_percent());
    try testing.expect((try Series.init(&edge)).unreliable());
}

test "a row prints the spread beside the median, and marks the rows that decide nothing" {
    var buffer: [512]u8 = undefined;
    const wide = [_]Result{ measured(78236, 100), measured(82826, 110), measured(93952, 120) };
    var writer = Writer.fixed(&buffer);
    try (try Series.init(&wide)).render_markdown_row(&writer);
    const row = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, row, "| 82826 |") != null);
    try testing.expect(std.mem.indexOf(u8, row, "| 18 |") != null);
    try testing.expect(std.mem.indexOf(u8, row, unreliable_mark) != null);
    try testing.expect(std.mem.indexOf(u8, row, "| 3 |") != null);

    const steady = [_]Result{ measured(1000, 10), measured(1010, 10), measured(1020, 10) };
    var second: [512]u8 = undefined;
    var steady_writer = Writer.fixed(&second);
    try (try Series.init(&steady)).render_markdown_row(&steady_writer);
    try testing.expect(std.mem.indexOf(u8, steady_writer.buffered(), unreliable_mark) == null);
}
