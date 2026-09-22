//! The comparison of several candidates against rotor, for one workload and one configuration: a
//! piece of report.zig, which stays the entry point and re-exports what this file declares.
//!
//! The project reports the runs where rotor loses (CLAUDE.md, Performance discipline), so the mark
//! of a lost row must be impossible to miss. Three rules make it so:
//!
//! - A loss is decided on the measured integers and never on the rounded ratio, so rounding can
//!   never hide one.
//! - The verdict is the first column of the row, in bold capitals, so a reader who looks at
//!   nothing but the candidates' names still reads it.
//! - The count of candidates rotor loses to is repeated under the table, in bold capitals when it
//!   is not 0.
const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const text = @import("text.zig");
const report = @import("report.zig");
const Result = report.Result;

/// The candidate every comparison measures the others against.
pub const baseline_candidate = "rotor";

/// The most results one comparison holds: rotor, the four pinned candidates of milestone 2, and
/// room for variants of either.
pub const comparison_results_max = 16;

/// One whole, in the unit a comparison prints a throughput ratio in: thousandths.
pub const ratio_whole: u64 = 1000;

/// The words that mark a lost row, around the names of what was lost.
const losing_mark = "**ROTOR LOSES:";
const losing_mark_end = "**";

pub const comparison_header =
    "| verdict | candidate | version | operations per second | thousandths of rotor " ++
    "| p50 ns | p99 ns | p999 ns | p9999 ns | overflow | peak rss bytes |\n" ++
    "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|\n";

pub const ComparisonError = Writer.Error || error{
    /// No result is rotor's, so there is nothing to compare the others with.
    BaselineMissing,
};

/// What rotor loses to one candidate. A loss is a lower throughput or a higher latency, decided
/// on the measured integers. A tie is no loss.
pub const Losses = struct {
    throughput: bool = false,
    p50: bool = false,
    p99: bool = false,
    p999: bool = false,
    p9999: bool = false,

    pub fn of(rotor: *const Result, candidate: *const Result) Losses {
        return .{
            .throughput = rotor.operations_per_second < candidate.operations_per_second,
            .p50 = rotor.p50_ns > candidate.p50_ns,
            .p99 = rotor.p99_ns > candidate.p99_ns,
            .p999 = rotor.p999_ns > candidate.p999_ns,
            .p9999 = rotor.p9999_ns > candidate.p9999_ns,
        };
    }

    pub fn any(losses: Losses) bool {
        return losses.throughput or losses.p50 or losses.p99 or losses.p999 or losses.p9999;
    }
};

/// Prints the results of several candidates for one workload and one configuration as one table:
/// each candidate's throughput in thousandths of rotor's, the verdict of every row, and the count
/// of candidates rotor loses to. The results may come in any order; one of them must be rotor's.
pub fn render_comparison(writer: *Writer, results: []const Result) ComparisonError!void {
    assert(results.len >= 1 and results.len <= comparison_results_max);
    const rotor = find_baseline(results) orelse return error.BaselineMissing;
    const configuration = rotor.configuration;
    try writer.writeAll("Workload `");
    try text.markdown_cell(writer, rotor.workload);
    try writer.print("`: {d} cores, {d} connections, {d} payload bytes, {t} load.\n\n", .{
        configuration.cores,         configuration.connections,
        configuration.payload_bytes, configuration.load,
    });
    try writer.writeAll(comparison_header);

    var lost: u32 = 0;
    for (results) |*result| {
        // Numbers of two workloads or two configurations do not compare.
        assert(std.mem.eql(u8, result.workload, rotor.workload));
        assert(result.configuration.equals(configuration));
        try render_comparison_row(writer, rotor, result);
        // rotor against itself is a tie on every number, so its own row never counts.
        if (Losses.of(rotor, result).any()) lost += 1;
    }
    const candidates = results.len - 1;
    assert(lost <= candidates);
    if (lost == 0) return writer.print("\nrotor loses to 0 of {d} candidates.\n", .{candidates});
    try writer.print("\n**ROTOR LOSES to {d} of {d} candidates.**\n", .{ lost, candidates });
}

/// The one result whose candidate is rotor. Two of them would make the comparison ambiguous.
fn find_baseline(results: []const Result) ?*const Result {
    var found: ?*const Result = null;
    for (results) |*result| {
        if (!std.mem.eql(u8, result.candidate, baseline_candidate)) continue;
        assert(found == null);
        found = result;
    }
    return found;
}

fn render_comparison_row(
    writer: *Writer,
    rotor: *const Result,
    result: *const Result,
) Writer.Error!void {
    const losses = Losses.of(rotor, result);
    try writer.writeAll("| ");
    if (result == rotor) try writer.writeAll("baseline") else try write_verdict(writer, losses);
    try writer.writeAll(" | ");
    try report.write_cells(writer, &.{ result.candidate, result.candidate_version });
    try writer.print("{d} | ", .{result.operations_per_second});
    if (ratio_thousandths(result.operations_per_second, rotor.operations_per_second)) |ratio| {
        try writer.print("{d}", .{ratio});
    } else {
        try writer.writeAll("n/a");
    }
    try writer.print(" | {d} | {d} | {d} | {d} | {d} | {d} |\n", .{
        result.p50_ns,   result.p99_ns,   result.p999_ns,
        result.p9999_ns, result.overflow, result.peak_rss_bytes,
    });
}

/// `no loss`, or the losing mark around the names of what rotor lost, in the order of `Losses`.
fn write_verdict(writer: *Writer, losses: Losses) Writer.Error!void {
    if (!losses.any()) return writer.writeAll("no loss");
    try writer.writeAll(losing_mark);
    var separator: []const u8 = " ";
    inline for (comptime std.meta.fieldNames(Losses)) |name| {
        if (@field(losses, name)) {
            try writer.writeAll(separator);
            try writer.writeAll(name);
            separator = ", ";
        }
    }
    try writer.writeAll(losing_mark_end);
}

/// A candidate's throughput in thousandths of rotor's, rounded down: 1,250 means the candidate
/// completed 1.25 operations for each one of rotor's. Null when rotor completed none, which
/// leaves no ratio to print. The verdict never reads this number.
pub fn ratio_thousandths(candidate_per_second: u64, rotor_per_second: u64) ?u64 {
    if (rotor_per_second == 0) return null;
    const scaled = @as(u128, candidate_per_second) * ratio_whole;
    const ratio = std.math.cast(u64, scaled / rotor_per_second) orelse std.math.maxInt(u64);
    assert((ratio >= ratio_whole) == (candidate_per_second >= rotor_per_second));
    return ratio;
}

const testing = std.testing;
const echo_result = report.fixtures.echo_result;
const rotor_result = report.fixtures.rotor_result;

test "rotor loses on a lower throughput or a higher latency, and a tie is no loss" {
    try testing.expect(!Losses.of(&rotor_result, &rotor_result).any());

    const faster = echo_result("x", "1", 200_001, .{ 10_000, 20_000, 30_000, 40_000 });
    try testing.expectEqual(Losses{ .throughput = true }, Losses.of(&rotor_result, &faster));
    const slower = echo_result("x", "1", 199_999, .{ 10_001, 20_001, 30_001, 40_001 });
    try testing.expectEqual(Losses{}, Losses.of(&rotor_result, &slower));

    const low_p50 = echo_result("x", "1", 1, .{ 9_999, 20_000, 30_000, 40_000 });
    try testing.expectEqual(Losses{ .p50 = true }, Losses.of(&rotor_result, &low_p50));
    const low_p99 = echo_result("x", "1", 1, .{ 10_000, 19_999, 30_000, 40_000 });
    try testing.expectEqual(Losses{ .p99 = true }, Losses.of(&rotor_result, &low_p99));
    // Each case moves one percentile alone, so a loss names the percentile it came from.
    const low_p999 = echo_result("x", "1", 1, .{ 10_000, 20_000, 29_999, 40_000 });
    try testing.expectEqual(Losses{ .p999 = true }, Losses.of(&rotor_result, &low_p999));
    try testing.expect(Losses.of(&rotor_result, &low_p999).any());
    const low_p9999 = echo_result("x", "1", 1, .{ 10_000, 20_000, 30_000, 39_999 });
    try testing.expectEqual(Losses{ .p9999 = true }, Losses.of(&rotor_result, &low_p9999));
    try testing.expect(Losses.of(&rotor_result, &low_p9999).any());
}

test "a throughput ratio is the candidate's over rotor's, in thousandths, rounded down" {
    try testing.expectEqual(@as(?u64, 1000), ratio_thousandths(200_000, 200_000));
    try testing.expectEqual(@as(?u64, 500), ratio_thousandths(100_000, 200_000));
    try testing.expectEqual(@as(?u64, 1250), ratio_thousandths(250_000, 200_000));
    try testing.expectEqual(@as(?u64, 999), ratio_thousandths(199_999, 200_000));
    try testing.expectEqual(@as(?u64, 0), ratio_thousandths(0, 200_000));
    try testing.expectEqual(@as(?u64, null), ratio_thousandths(200_000, 0));
}

test "a comparison marks every row rotor loses, in the first column, and counts them" {
    // Three losses of four, so a count of the rows rotor does not lose would read 1 of 4. The
    // tie with std.Io.Threaded is no loss, and rotor stands in the middle of the list.
    const results = [_]Result{
        echo_result("libuv", "1.0.0", 100_000, .{ 20_000, 40_000, 29_000, 39_000 }),
        rotor_result,
        echo_result("libxev", "2.0.0", 250_000, .{ 9_000, 25_000, 28_000, 38_000 }),
        echo_result("std.Io.Threaded", "0.16.0", 200_000, .{ 10_000, 20_000, 30_000, 40_000 }),
        echo_result("std.Io.Uring", "0.16.0", 150_000, .{ 10_000, 19_999, 30_000, 40_000 }),
    };
    var buffer: [2048]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try render_comparison(&writer, &results);
    try testing.expectEqualStrings("Workload `echo`: 4 cores, 1024 connections, " ++
        "4096 payload bytes, even load.\n\n" ++
        "| verdict | candidate | version | operations per second | thousandths of rotor " ++
        "| p50 ns | p99 ns | p999 ns | p9999 ns | overflow | peak rss bytes |\n" ++
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|\n" ++
        "| **ROTOR LOSES: p999, p9999** | libuv | 1.0.0 | 100000 | 500 " ++
        "| 20000 | 40000 | 29000 | 39000 | 0 | 0 |\n" ++
        "| baseline | rotor | 0.1.0 | 200000 | 1000 | 10000 | 20000 | 30000 | 40000 | 0 | 0 |\n" ++
        "| **ROTOR LOSES: throughput, p50, p999, p9999** | libxev | 2.0.0 | 250000 | 1250 " ++
        "| 9000 | 25000 | 28000 | 38000 | 0 | 0 |\n" ++
        "| no loss | std.Io.Threaded | 0.16.0 | 200000 | 1000 " ++
        "| 10000 | 20000 | 30000 | 40000 | 0 | 0 |\n" ++
        "| **ROTOR LOSES: p99** | std.Io.Uring | 0.16.0 | 150000 | 750 " ++
        "| 10000 | 19999 | 30000 | 40000 | 0 | 0 |\n" ++
        "\n**ROTOR LOSES to 3 of 4 candidates.**\n", writer.buffered());
}

test "a comparison rotor loses no row of says so in plain letters, and the mark is absent" {
    const results = [_]Result{
        rotor_result,
        echo_result("libuv", "1.0.0", 100_000, .{ 20_000, 40_000, 60_000, 70_000 }),
    };
    var buffer: [1024]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try render_comparison(&writer, &results);
    try testing.expect(std.mem.endsWith(u8, writer.buffered(), "| no loss | libuv | 1.0.0 " ++
        "| 100000 | 500 | 20000 | 40000 | 60000 | 70000 | 0 | 0 |\n" ++
        "\nrotor loses to 0 of 1 candidates.\n"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, writer.buffered(), "LOSES"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, writer.buffered(), "**"));
}

test "a comparison without rotor is an error, and an idle rotor loses without a ratio" {
    var buffer: [1024]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    const strangers = [_]Result{echo_result("libuv", "1.0.0", 100_000, .{ 1, 2, 3, 10_003 })};
    try testing.expectError(error.BaselineMissing, render_comparison(&writer, &strangers));
    try testing.expectEqualStrings("", writer.buffered());

    const idle = [_]Result{
        echo_result("rotor", "0.1.0", 0, .{ 0, 0, 0, 10_000 }),
        echo_result("libuv", "1.0.0", 100_000, .{ 1, 2, 3, 10_003 }),
    };
    try render_comparison(&writer, &idle);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "| **ROTOR LOSES: throughput** " ++
        "| libuv | 1.0.0 | 100000 | n/a | 1 | 2 | 3 | 10003 | 0 | 0 |\n") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "| baseline | rotor | 0.1.0 " ++
        "| 0 | n/a | 0 | 0 | 0 | 10000 | 0 | 0 |\n") != null);
    try testing.expect(std.mem.endsWith(u8, writer.buffered(), "\n**ROTOR LOSES to 1 of 1 " ++
        "candidates.**\n"));
}

test "a buffer too small for a comparison is an error" {
    var buffer: [24]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try testing.expectError(error.WriteFailed, render_comparison(&writer, &.{rotor_result}));
}
