//! The baseline a comparison is held to, and the verdict on a fresh run.
//!
//! **It records ratios and not absolute numbers.** The runner pool this project measures x86-64 on
//! hands out whichever processor it has: two runs hours apart on 2026-09-22 reported an Intel Xeon
//! Platinum 8370C and then a 8573C, and row C7 of `docs/costs.md` moved from 202 to 300 ns between
//! them. A baseline of throughputs would have fired on that and called a different machine a
//! regression. Every candidate of a comparison runs in the same run on the same machine,
//! alternating, so the ratio between two of them is what survives a machine change.
//!
//! A row says: in this workload, at this connection count and payload, this candidate reached at
//! most `ratio_max` thousandths of rotor's throughput. A fresh run that finds the candidate further
//! ahead than that, by more than `margin_thousandths`, is a regression in rotor.
//!
//! The file is line based so a person can read a diff of it:
//!
//! ```text
//! # workload connections payload candidate ratio_max
//! echo 16 4096 libuv 1005
//! echo 16 4096 libxev 900
//! ```
//!
//! A blank line and a line whose first non-blank character is `#` are ignored. A candidate's name
//! may hold spaces, so it is the fourth field onward up to the last: `rotor (accumulate)` parses.
//!
//! What it deliberately does not gate:
//!
//! - **Latency.** A percentile is a tail, and the tails of a shared runner move far more than its
//!   throughput does. They are reported in the table and read by a person.
//! - **Memory.** A fixed pool against a buffer per connection is a trade a caller makes, which
//!   `report_comparison.zig` also leaves out of what counts as a loss.
//! - **A row whose runs disagree.** `series.unreliable()` means the run could not decide anything,
//!   so gating it would fail on noise. Such a row is named in the verdict and counted apart, never
//!   silently passed.
const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const series_module = @import("series.zig");

const Series = series_module.Series;

/// Rows one baseline holds: every workload times every configuration times every candidate of the
/// comparison, with room to spare.
pub const rows_max = 128;

/// How far a candidate may move past its recorded ratio before the run is called a regression, in
/// thousandths. Fifty is 5 percent, which sits above the spread a quiet run shows and below the
/// smallest difference this project has argued from: the 64 KiB gap against libxev is 71.
pub const margin_thousandths: u64 = 50;

/// One recorded expectation.
pub const Row = struct {
    workload: []const u8,
    connections: u32,
    payload_bytes: u32,
    candidate: []const u8,
    /// The candidate's throughput as thousandths of rotor's, when the baseline was taken. 1,000 is
    /// parity; above it the candidate was ahead.
    ratio_max: u64,

    /// True when this row is about the same measurement as `other`.
    pub fn names_same(row: Row, other: Row) bool {
        return row.connections == other.connections and
            row.payload_bytes == other.payload_bytes and
            std.mem.eql(u8, row.workload, other.workload) and
            std.mem.eql(u8, row.candidate, other.candidate);
    }
};

pub const ParseError = error{
    /// A line is not four fields and a number.
    Malformed,
    /// The ratio or a count does not fit the field it belongs to.
    OutOfRange,
    /// The file holds more rows than `rows_max`.
    TooManyRows,
};

/// Every row of `text`, in the order they appear. The returned rows borrow `text`, so they live
/// exactly as long as it does. Nothing here allocates: the caller hands over the array.
pub fn parse(text: []const u8, into: []Row) ParseError![]const Row {
    var used: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (used == into.len or used == rows_max) return error.TooManyRows;
        into[used] = try parse_line(line);
        used += 1;
    }
    return into[0..used];
}

/// One row. The candidate's name is everything between the third field and the last, so a name
/// with spaces survives.
fn parse_line(line: []const u8) ParseError!Row {
    const workload, const after_workload = try field(line);
    const connections_text, const after_connections = try field(after_workload);
    const payload_text, const after_payload = try field(after_connections);
    const last = std.mem.lastIndexOfAny(u8, after_payload, " \t") orelse return error.Malformed;
    const candidate = std.mem.trim(u8, after_payload[0..last], " \t");
    const ratio_text = std.mem.trim(u8, after_payload[last..], " \t");
    if (candidate.len == 0 or ratio_text.len == 0) return error.Malformed;
    return .{
        .workload = workload,
        .connections = try count(connections_text),
        .payload_bytes = try count(payload_text),
        .candidate = candidate,
        .ratio_max = std.fmt.parseInt(u64, ratio_text, 10) catch return error.OutOfRange,
    };
}

/// The first whitespace-separated field of `rest`, and what follows it.
fn field(rest: []const u8) ParseError!struct { []const u8, []const u8 } {
    const cut = std.mem.indexOfAny(u8, rest, " \t") orelse return error.Malformed;
    const taken = rest[0..cut];
    if (taken.len == 0) return error.Malformed;
    return .{ taken, std.mem.trimStart(u8, rest[cut..], " \t") };
}

fn count(text: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, text, 10) catch error.OutOfRange;
}

/// What a fresh series says against the baseline.
pub const Verdict = enum {
    /// The candidate is no further ahead than the baseline allows.
    within,
    /// It is further ahead than the baseline plus the margin: rotor lost ground.
    regressed,
    /// The runs disagreed too much to decide, so nothing is claimed either way.
    undecided,
    /// The baseline has no row for this measurement.
    unrecorded,
};

/// Judges `candidate`'s series against the baseline, given rotor's throughput from the same run.
/// `rotor_per_second` of 0 means rotor measured nothing, which is undecided and not a pass.
pub fn judge(
    rows: []const Row,
    workload: []const u8,
    candidate: *const Series,
    rotor_per_second: u64,
) Verdict {
    if (candidate.unreliable() or rotor_per_second == 0) return .undecided;
    const first = candidate.runs[0];
    const asked: Row = .{
        .workload = workload,
        .connections = first.configuration.connections,
        .payload_bytes = first.configuration.payload_bytes,
        .candidate = first.candidate,
        .ratio_max = 0,
    };
    for (rows) |row| {
        if (!row.names_same(asked)) continue;
        const ratio = ratio_thousandths(candidate.median_per_second(), rotor_per_second);
        return if (ratio > row.ratio_max + margin_thousandths) .regressed else .within;
    }
    return .unrecorded;
}

/// `numerator` as thousandths of `denominator`, rounded down. The denominator is never 0 here:
/// `judge` refuses that case before asking.
pub fn ratio_thousandths(numerator: u64, denominator: u64) u64 {
    assert(denominator != 0);
    return numerator * thousand / denominator;
}

const thousand: u64 = 1000;

/// Writes the rows of a run in the file's own format, which is how a baseline is taken: run the
/// comparison, read this, commit it.
pub fn render_row(
    writer: *Writer,
    workload: []const u8,
    candidate: *const Series,
    rotor_per_second: u64,
) Writer.Error!void {
    assert(rotor_per_second != 0);
    const first = candidate.runs[0];
    try writer.print("{s} {d} {d} {s} {d}\n", .{
        workload,
        first.configuration.connections,
        first.configuration.payload_bytes,
        first.candidate,
        ratio_thousandths(candidate.median_per_second(), rotor_per_second),
    });
}

// Tests.

const testing = std.testing;
const report = @import("report.zig");

test "a baseline parses, ignoring blank lines and comments" {
    var rows: [8]Row = undefined;
    const parsed = try parse(
        \\# workload connections payload candidate ratio_max
        \\echo 16 4096 libuv 1005
        \\
        \\  echo 64 65536 libxev 1071
        \\   # an indented comment
        \\echo 16 4096 rotor (accumulate) 1002
    , &rows);
    try testing.expectEqual(@as(usize, 3), parsed.len);
    try testing.expectEqualStrings("echo", parsed[0].workload);
    try testing.expectEqual(@as(u32, 16), parsed[0].connections);
    try testing.expectEqual(@as(u32, 4096), parsed[0].payload_bytes);
    try testing.expectEqualStrings("libuv", parsed[0].candidate);
    try testing.expectEqual(@as(u64, 1005), parsed[0].ratio_max);
    // A name with spaces is the fields between the payload and the ratio, not the fourth alone.
    try testing.expectEqualStrings("rotor (accumulate)", parsed[2].candidate);
    try testing.expectEqual(@as(u64, 1002), parsed[2].ratio_max);
}

test "a malformed line is refused rather than read as something else" {
    var rows: [8]Row = undefined;
    try testing.expectError(error.Malformed, parse("echo 16 4096 libuv", &rows));
    try testing.expectError(error.Malformed, parse("echo", &rows));
    try testing.expectError(error.OutOfRange, parse("echo 16 4096 libuv nine", &rows));
    try testing.expectError(error.OutOfRange, parse("echo huge 4096 libuv 1000", &rows));
    var one: [1]Row = undefined;
    try testing.expectError(error.TooManyRows, parse("echo 1 1 a 1\necho 2 2 b 2", &one));
}

test "a ratio is thousandths of rotor, rounded down" {
    try testing.expectEqual(@as(u64, 1000), ratio_thousandths(200_000, 200_000));
    try testing.expectEqual(@as(u64, 1250), ratio_thousandths(250_000, 200_000));
    try testing.expectEqual(@as(u64, 999), ratio_thousandths(199_999, 200_000));
    try testing.expectEqual(@as(u64, 0), ratio_thousandths(0, 200_000));
}

/// A series of `runs` runs of `candidate`, every run at `per_second`, so the spread is 0 and the
/// series decides. `series_module.runs_min` is the fewest that decides anything.
fn steady(candidate: []const u8, per_second: u64, storage: []report.Result) !Series {
    for (storage) |*run| {
        run.* = report.fixtures.echo_result(candidate, "1", per_second, .{ 1, 2, 3, 4 });
        run.configuration.connections = 16;
        run.configuration.payload_bytes = 4096;
    }
    return Series.init(storage);
}

test "a candidate further ahead than its row, past the margin, is a regression" {
    var storage: [series_module.runs_min]report.Result = undefined;
    var rows: [4]Row = undefined;
    const recorded = try parse("echo 16 4096 libuv 1000", &rows);

    // Parity, which is the row itself: within.
    var level = try steady("libuv", 200_000, &storage);
    try testing.expectEqual(Verdict.within, judge(recorded, "echo", &level, 200_000));

    // Ahead by exactly the margin: still within, because the margin is an allowance.
    var at_margin = try steady("libuv", 210_000, &storage);
    try testing.expectEqual(Verdict.within, judge(recorded, "echo", &at_margin, 200_000));

    // Ahead by more than the margin: rotor lost ground.
    var past = try steady("libuv", 220_000, &storage);
    try testing.expectEqual(Verdict.regressed, judge(recorded, "echo", &past, 200_000));

    // rotor further ahead than the baseline is never a failure.
    var behind = try steady("libuv", 100_000, &storage);
    try testing.expectEqual(Verdict.within, judge(recorded, "echo", &behind, 200_000));
}

test "an unrecorded measurement and an idle rotor decide nothing" {
    var storage: [series_module.runs_min]report.Result = undefined;
    var rows: [4]Row = undefined;
    const recorded = try parse("echo 16 4096 libuv 1000", &rows);

    var other = try steady("libxev", 200_000, &storage);
    try testing.expectEqual(Verdict.unrecorded, judge(recorded, "echo", &other, 200_000));

    var level = try steady("libuv", 200_000, &storage);
    try testing.expectEqual(Verdict.unrecorded, judge(recorded, "storm", &level, 200_000));
    // rotor measured nothing, so no ratio exists and nothing is claimed.
    try testing.expectEqual(Verdict.undecided, judge(recorded, "echo", &level, 0));
}

test "a row written by render_row parses back to the ratio it recorded" {
    var storage: [series_module.runs_min]report.Result = undefined;
    var candidate = try steady("rotor (accumulate)", 250_000, &storage);
    var buffer: [128]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try render_row(&writer, "echo", &candidate, 200_000);
    try testing.expectEqualStrings("echo 16 4096 rotor (accumulate) 1250\n", writer.buffered());

    var rows: [2]Row = undefined;
    const parsed = try parse(writer.buffered(), &rows);
    try testing.expectEqual(@as(usize, 1), parsed.len);
    try testing.expectEqualStrings("rotor (accumulate)", parsed[0].candidate);
    try testing.expectEqual(@as(u64, 1250), parsed[0].ratio_max);
}
