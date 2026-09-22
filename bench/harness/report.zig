//! `Result`, what one run of one candidate on one workload measured, and how results print: a
//! Markdown table for a person, and one JSON object per line for a file that results append to
//! and that diffs cleanly. report_comparison.zig prints several candidates against rotor and
//! marks the rows rotor loses; this file is the entry point and re-exports it.
//!
//! Every renderer writes to the `std.Io.Writer` the caller backs with its own buffer, so nothing
//! here allocates, and a buffer that is too small is an error and never a cut line. Every number
//! prints as an integer: throughput in whole operations per second, rounded down, and latency in
//! nanoseconds. No locale and no floating point take part.
const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const text = @import("text.zig");
const histogram_module = @import("histogram.zig");
const Histogram = histogram_module.Histogram;

pub const comparison = @import("report_comparison.zig");
pub const Losses = comparison.Losses;
pub const ComparisonError = comparison.ComparisonError;
pub const render_comparison = comparison.render_comparison;
pub const ratio_thousandths = comparison.ratio_thousandths;

/// Nanoseconds in one second.
const ns_per_s: u64 = 1_000_000_000;

/// How a run spread its load over its cores. One value, because every run spreads it evenly:
/// decision 19 withdrew the skewed rows, since no competitor spreads TCP load across cores on
/// kqueue and `SO_REUSEPORT` cannot aim a skew at a chosen loop on either kernel.
///
/// The field stays so a published row keeps its column and its key order. A line naming any other
/// load is refused by `report_parse.zig`, which is the point: a row may not claim a load the
/// harness cannot produce.
pub const Load = enum { even };

pub const Configuration = struct {
    cores: u32,
    connections: u32,
    payload_bytes: u32,
    load: Load,

    /// Field by field, so a field added later is compared without a change here.
    pub fn equals(configuration: Configuration, other: Configuration) bool {
        return std.meta.eql(configuration, other);
    }
};

/// What a workload knows when a run ends. The three names are slices the caller keeps alive: the
/// harness names its workloads and candidates with string literals.
pub const Run = struct {
    workload: []const u8,
    candidate: []const u8,
    /// The pinned version of the candidate: a number means nothing without it.
    candidate_version: []const u8,
    configuration: Configuration,
    /// The measured span, warm-up excluded.
    duration_ns: u64,
    /// Operations completed inside the span. A workload that samples its latencies completes
    /// more operations than its histogram holds values, so the two are counted apart.
    operations: u64,
};

pub const Result = struct {
    workload: []const u8,
    candidate: []const u8,
    candidate_version: []const u8,
    configuration: Configuration,
    duration_ns: u64,
    operations: u64,
    operations_per_second: u64,
    p50_ns: u64,
    p99_ns: u64,
    p999_ns: u64,
    /// Latencies above the histogram's range. When this is not 0 the tail was clamped, and the
    /// row says so.
    overflow: u64,

    /// The result of `run`: its throughput from the operations and the span, and its percentiles
    /// and overflow from `latencies`, the merged histogram of the run's threads.
    pub fn init(run: Run, latencies: *const Histogram) Result {
        assert(run.duration_ns >= 1);
        assert(run.workload.len >= 1 and run.candidate.len >= 1);
        return .{
            .workload = run.workload,
            .candidate = run.candidate,
            .candidate_version = run.candidate_version,
            .configuration = run.configuration,
            .duration_ns = run.duration_ns,
            .operations = run.operations,
            .operations_per_second = per_second(run.operations, run.duration_ns),
            .p50_ns = latencies.percentile(histogram_module.p50),
            .p99_ns = latencies.percentile(histogram_module.p99),
            .p999_ns = latencies.percentile(histogram_module.p999),
            .overflow = latencies.overflow,
        };
    }

    /// One row under `markdown_header`.
    pub fn render_markdown_row(result: *const Result, writer: *Writer) Writer.Error!void {
        assert(result.workload.len >= 1 and result.candidate.len >= 1);
        try writer.writeAll("| ");
        try write_cells(writer, &.{ result.workload, result.candidate, result.candidate_version });
        const configuration = result.configuration;
        try writer.print("{d} | {d} | {d} | {t} | ", .{
            configuration.cores,         configuration.connections,
            configuration.payload_bytes, configuration.load,
        });
        try writer.print("{d} | {d} | {d} | ", .{
            result.duration_ns, result.operations, result.operations_per_second,
        });
        try writer.print("{d} | {d} | {d} | {d} |\n", .{
            result.p50_ns, result.p99_ns, result.p999_ns, result.overflow,
        });
    }

    /// The result as one JSON object on one line, with its keys always in this order.
    pub fn render_json_line(result: *const Result, writer: *Writer) Writer.Error!void {
        assert(result.workload.len >= 1 and result.candidate.len >= 1);
        try writer.writeAll("{\"workload\":");
        try text.json_string(writer, result.workload);
        try writer.writeAll(",\"candidate\":");
        try text.json_string(writer, result.candidate);
        try writer.writeAll(",\"version\":");
        try text.json_string(writer, result.candidate_version);
        const configuration = result.configuration;
        try writer.print(",\"cores\":{d},\"connections\":{d},\"payload_bytes\":{d}", .{
            configuration.cores, configuration.connections, configuration.payload_bytes,
        });
        try writer.print(",\"load\":\"{t}\",\"duration_ns\":{d},\"operations\":{d}", .{
            configuration.load, result.duration_ns, result.operations,
        });
        try writer.print(",\"operations_per_second\":{d},\"p50_ns\":{d},\"p99_ns\":{d}", .{
            result.operations_per_second, result.p50_ns, result.p99_ns,
        });
        try writer.print(",\"p999_ns\":{d},\"overflow\":{d}}}\n", .{
            result.p999_ns, result.overflow,
        });
    }
};

/// The header `Result.render_markdown_row` prints rows under. The numbers align right.
pub const markdown_header =
    "| workload | candidate | version | cores | connections | payload bytes | load " ++
    "| duration ns | operations | operations per second " ++
    "| p50 ns | p99 ns | p999 ns | overflow |\n" ++
    "|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|\n";

/// The two header lines of a table of results.
pub fn render_markdown_header(writer: *Writer) Writer.Error!void {
    try writer.writeAll(markdown_header);
}

/// Whole operations per second, rounded down, in integers: `operations × 10^9 / duration_ns`.
pub fn per_second(operations: u64, duration_ns: u64) u64 {
    assert(duration_ns >= 1);
    const scaled = @as(u128, operations) * ns_per_s;
    const rate = std.math.cast(u64, scaled / duration_ns) orelse std.math.maxInt(u64);
    assert(rate <= operations or duration_ns < ns_per_s);
    return rate;
}

/// Each cell escaped, with the separator that follows it.
pub fn write_cells(writer: *Writer, cells: []const []const u8) Writer.Error!void {
    for (cells) |cell| {
        try text.markdown_cell(writer, cell);
        try writer.writeAll(" | ");
    }
}

/// The results the tests of this file and of report_comparison.zig are built from. Nothing
/// outside a test names it, so no harness build holds it.
pub const fixtures = struct {
    /// The numbers the results share: the `echo` configuration, the span of every run in
    /// seconds, and rotor's own result, which every other candidate's numbers are chosen around.
    const echo_cores = 4;
    const echo_connections = 1024;
    const echo_payload_bytes = 4096;
    const span_seconds = 10;
    const rotor_rate = 200_000;
    const rotor_p50_ns = 10_000;
    const rotor_p99_ns = 20_000;
    const rotor_p999_ns = 30_000;

    pub const echo: Configuration = .{
        .cores = echo_cores,
        .connections = echo_connections,
        .payload_bytes = echo_payload_bytes,
        .load = .even,
    };

    /// p50, p99 and p999, in nanoseconds.
    pub const Latencies = struct { u64, u64, u64 };

    /// A result of the `echo` configuration: a candidate, its throughput and its latencies.
    pub fn echo_result(
        candidate: []const u8,
        version: []const u8,
        rate: u64,
        latencies: Latencies,
    ) Result {
        const p50_ns, const p99_ns, const p999_ns = latencies;
        return .{
            .workload = "echo",
            .candidate = candidate,
            .candidate_version = version,
            .configuration = echo,
            .duration_ns = span_seconds * ns_per_s,
            .operations = span_seconds * rate,
            .operations_per_second = rate,
            .p50_ns = p50_ns,
            .p99_ns = p99_ns,
            .p999_ns = p999_ns,
            .overflow = 0,
        };
    }

    const rotor_latencies: Latencies = .{ rotor_p50_ns, rotor_p99_ns, rotor_p999_ns };
    pub const rotor_result = echo_result("rotor", "0.1.0", rotor_rate, rotor_latencies);
};

const testing = std.testing;
const rotor_result = fixtures.rotor_result;

test "init computes whole operations per second and reads the percentiles and the overflow" {
    var latencies: Histogram = .empty;
    for (1..100) |value| latencies.record(value);
    latencies.record(histogram_module.value_ns_max + 1);
    const result = Result.init(.{
        .workload = "echo",
        .candidate = "rotor",
        .candidate_version = "0.1.0",
        .configuration = fixtures.echo,
        .duration_ns = 10 * ns_per_s,
        .operations = 1_234_567,
    }, &latencies);
    // 123,456.7 rounds down.
    try testing.expectEqual(@as(u64, 123_456), result.operations_per_second);
    try testing.expectEqual(@as(u64, 50), result.p50_ns);
    try testing.expectEqual(@as(u64, 99), result.p99_ns);
    try testing.expectEqual(histogram_module.value_ns_max + 1, result.p999_ns);
    try testing.expectEqual(@as(u64, 1), result.overflow);
    try testing.expectEqual(@as(u64, 1_234_567), result.operations);
    try testing.expectEqualStrings("rotor", result.candidate);
    try testing.expect(result.configuration.equals(fixtures.echo));
}

test "per_second rounds down, scales a short span up and saturates" {
    try testing.expectEqual(@as(u64, 0), per_second(0, ns_per_s));
    try testing.expectEqual(@as(u64, 1), per_second(3, 2 * ns_per_s));
    try testing.expectEqual(@as(u64, 2_000), per_second(1, ns_per_s / 2_000));
    try testing.expectEqual(@as(u64, 250_000), per_second(15_000_000, 60 * ns_per_s));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), per_second(std.math.maxInt(u64), 1));
}

test "a row can name one load, and only the one the harness produces" {
    // Decision 19 withdrew the skewed rows. This holds the enum to that: adding a value back is a
    // change to what a row may claim, and it should fail here before it reaches a table.
    const values = @typeInfo(Load).@"enum".fields;
    try testing.expectEqual(@as(usize, 1), values.len);
    try testing.expectEqualStrings("even", values[0].name);
}

test "two configurations are equal only when every field is" {
    const echo = fixtures.echo;
    var other = echo;
    try testing.expect(echo.equals(other));
    // `load` is not varied here: it has one value since decision 19, so no two configurations can
    // differ in it. Every field that can differ is varied below.
    other.cores += 1;
    try testing.expect(!echo.equals(other));
    other = echo;
    other.connections += 1;
    try testing.expect(!echo.equals(other));
    other = echo;
    other.payload_bytes += 1;
    try testing.expect(!echo.equals(other));
    other = echo;
    other.cores += 1;
    try testing.expect(!echo.equals(other));
    other = echo;
    other.connections += 1;
    try testing.expect(!echo.equals(other));
}

test "the Markdown header and a row, as exact text" {
    var buffer: [1024]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try render_markdown_header(&writer);
    try rotor_result.render_markdown_row(&writer);
    try testing.expectEqualStrings("| workload | candidate | version | cores | connections " ++
        "| payload bytes | load | duration ns | operations | operations per second " ++
        "| p50 ns | p99 ns | p999 ns | overflow |\n" ++
        "|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|\n" ++
        "| echo | rotor | 0.1.0 | 4 | 1024 | 4096 | even | 10000000000 | 2000000 | 200000 " ++
        "| 10000 | 20000 | 30000 | 0 |\n", writer.buffered());
}

test "a JSON line, as exact text, with its names escaped" {
    var buffer: [1024]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    var result = rotor_result;
    result.configuration.load = .even;
    result.overflow = 7;
    try result.render_json_line(&writer);
    try testing.expectEqualStrings("{\"workload\":\"echo\",\"candidate\":\"rotor\"," ++
        "\"version\":\"0.1.0\",\"cores\":4,\"connections\":1024,\"payload_bytes\":4096," ++
        "\"load\":\"even\",\"duration_ns\":10000000000,\"operations\":2000000," ++
        "\"operations_per_second\":200000,\"p50_ns\":10000,\"p99_ns\":20000," ++
        "\"p999_ns\":30000,\"overflow\":7}\n", writer.buffered());

    var escaped: Writer = .fixed(&buffer);
    result.workload = "echo \"4 KiB\"";
    result.candidate = "lib|uv";
    try result.render_json_line(&escaped);
    try testing.expect(std.mem.startsWith(u8, escaped.buffered(), "{\"workload\":" ++
        "\"echo \\\"4 KiB\\\"\",\"candidate\":\"lib|uv\","));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, escaped.buffered(), "\n"));

    var row: Writer = .fixed(&buffer);
    try result.render_markdown_row(&row);
    try testing.expect(std.mem.startsWith(u8, row.buffered(), "| echo \"4 KiB\" | lib\\|uv | "));
}

test "a buffer too small for a rendering is an error" {
    var buffer: [24]u8 = undefined;
    var first: Writer = .fixed(&buffer);
    try testing.expectError(error.WriteFailed, rotor_result.render_markdown_row(&first));
    var second: Writer = .fixed(&buffer);
    try testing.expectError(error.WriteFailed, rotor_result.render_json_line(&second));
    var third: Writer = .fixed(&buffer);
    try testing.expectError(error.WriteFailed, render_markdown_header(&third));
}
