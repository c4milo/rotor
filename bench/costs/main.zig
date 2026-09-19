//! The cost probes that fill docs/costs.md: one probe per row, each reporting its median and its
//! p99 in nanoseconds with how it measured (docs/costs.md, rules 2 and 5).
//!
//! Run:  zig build bench-costs                  every row this target has
//!       zig build bench-costs -- --row C6      one row; `--row` may repeat
//!
//! build/bench.zig always builds this ReleaseSafe. Per row the report prints one Markdown table
//! line, `| C6 | smallest syscall round trip, getppid | median (p99) |`, and under it one line of
//! method. Above the table it prints the machine, the OS, the Zig version, the date, the clock
//! and what was done about pinning the thread.
//!
//! A row whose median is under `measure.sanity_floor_ns` has measured nothing, because the
//! optimizer deleted the work: the report prints FAILED in place of a number. Exit status: 0 when
//! every row printed a number, 1 when a row failed, 2 on a usage error.
//!
//! The method is measure.zig, the probes are probes/, and README.md says what each probe measures
//! and what it cannot. The numbers go into docs/costs.md by hand, from a serial run on a quiet
//! machine.
const std = @import("std");
const assert = std.debug.assert;
const machine = @import("machine.zig");
const measure = @import("measure.zig");
const probes = @import("probes/probes.zig");
const Writer = std.Io.Writer;

/// The bytes of report the writer holds between flushes: several rows.
const output_buffer_bytes = 8 * 1024;

/// The most `--row` arguments: one for every row docs/costs.md could hold.
const rows_selected_max = 32;

/// Exit statuses.
const exit_failed = 1;
const exit_usage = 2;

/// Under these many nanoseconds the report prints two decimals, or one: a 0.9 ns load and a
/// 13,000 ns round trip do not share a useful precision.
const two_decimals_under_ns = 10;
const one_decimal_under_ns = 100;

const Selection = struct {
    rows: [rows_selected_max]u32 = undefined,
    count: u32 = 0,

    /// No `--row` selects every row.
    fn includes(selection: *const Selection, row: u32) bool {
        if (selection.count == 0) return true;
        return std.mem.indexOfScalar(u32, selection.rows[0..selection.count], row) != null;
    }
};

const UsageError = error{ UnknownArgument, MissingRowId, UnknownRow, TooManyRows };

fn parse_arguments(arguments: []const [:0]const u8) UsageError!Selection {
    var selection: Selection = .{};
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        if (!std.mem.eql(u8, arguments[index], "--row")) return error.UnknownArgument;
        index += 1;
        if (index == arguments.len) return error.MissingRowId;
        const probe = probes.find(arguments[index]) orelse return error.UnknownRow;
        if (selection.count == rows_selected_max) return error.TooManyRows;
        selection.rows[selection.count] = probe.row;
        selection.count += 1;
    }
    return selection;
}

fn print_usage(failure: UsageError) void {
    std.debug.print("error: {s}\nusage: costs [--row ID]...\nrows:", .{@errorName(failure)});
    for (probes.all) |probe| std.debug.print(" {c}{d}", .{ probes.id_prefix, probe.row });
    std.debug.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const selection = parse_arguments(arguments[@min(1, arguments.len)..]) catch |failure| {
        print_usage(failure);
        std.process.exit(exit_usage);
    };

    var output_buffer: [output_buffer_bytes]u8 = undefined;
    // Streaming, not positional: a positional writer overwrites earlier output when standard
    // output is a file.
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;

    // Every large array is mapped here, before any timing.
    var environment = try measure.Environment.init();
    const report: Report = .{
        .placement = measure.settle(),
        .clock_resolution_ns = measure.clock_resolution_ns(),
    };
    try report.print_header(writer);
    try writer.flush();

    var failed_rows: u32 = 0;
    for (probes.all) |probe| {
        if (!selection.includes(probe.row)) continue;
        const succeeded = try report.print_row(writer, &probe, &environment);
        if (!succeeded) failed_rows += 1;
        try writer.flush();
    }
    if (failed_rows != 0) std.process.exit(exit_failed);
}

/// What every row's method line repeats: the clock and the thread's placement.
const Report = struct {
    placement: measure.Placement,
    clock_resolution_ns: u64,

    fn print_header(report: Report, writer: *Writer) Writer.Error!void {
        try writer.writeAll("rotor cost probes, for docs/costs.md\n\n");
        try machine.print(writer);
        try writer.print("clock: {s}, smallest step seen {d} ns\n", .{
            measure.clock_name,
            report.clock_resolution_ns,
        });
        try writer.print("placement: {s}\n\n", .{report.placement.text()});
        try writer.writeAll("| id | operation | median (p99), ns |\n|---|---|---|\n");
    }

    /// Runs one probe and prints its row. Returns false when the row has no number.
    fn print_row(
        report: Report,
        writer: *Writer,
        probe: *const measure.Probe,
        environment: *measure.Environment,
    ) Writer.Error!bool {
        try writer.print("| {c}{d} | {s} | ", .{ probes.id_prefix, probe.row, probe.operation });
        const result = probe.run(environment) catch |failure| {
            try writer.print("FAILED: {s} |\n", .{@errorName(failure)});
            return false;
        };
        const summary = result.summary;
        if (summary.median_ns < measure.sanity_floor_ns) {
            try writer.print("FAILED: measured nothing, a median of {d:.3} ns is under one" ++
                " CPU cycle |\n", .{summary.median_ns});
            return false;
        }
        try print_ns(writer, summary.median_ns);
        try writer.writeAll(" (");
        try print_ns(writer, summary.p99_ns);
        try writer.writeAll(") |\n");
        try report.print_method(writer, result);
        return true;
    }

    fn print_method(report: Report, writer: *Writer, result: measure.Result) Writer.Error!void {
        const plan = result.plan;
        if (plan.batch == 1) {
            try writer.print("  method: {d} {s}, each timed alone, after {d} that were thrown" ++
                " away; the p99 is of single operations", .{
                plan.samples,
                result.unit,
                plan.warmup,
            });
        } else {
            try writer.print("  method: {d} samples, each a batch of {d} {s} timed as one and" ++
                " divided, after {d} warm-up batches; the p99 is of batch means, not of single" ++
                " operations", .{ plan.samples, plan.batch, result.unit, plan.warmup });
        }
        try writer.writeAll(if (result.is_difference)
            "; the row comes from the difference of two loops timed back to back, and its" ++
                " smallest per-sample value was "
        else
            "; smallest sample ");
        try print_ns(writer, result.summary.min_ns);
        try writer.print(" ns; {s} with {d} ns steps; {s}; {s}; {s}\n", .{
            measure.clock_name,
            report.clock_resolution_ns,
            measure.compiler_mode,
            report.placement.text(),
            result.note,
        });
    }
};

/// Nanoseconds with the precision their size deserves.
fn print_ns(writer: *Writer, nanoseconds: f64) Writer.Error!void {
    const magnitude = @abs(nanoseconds);
    if (magnitude < two_decimals_under_ns) return writer.print("{d:.2}", .{nanoseconds});
    if (magnitude < one_decimal_under_ns) return writer.print("{d:.1}", .{nanoseconds});
    return writer.print("{d:.0}", .{nanoseconds});
}

test "parse_arguments takes repeated rows and refuses the rest" {
    const testing = std.testing;
    const none = try parse_arguments(&.{});
    try testing.expect(none.includes(1));
    const two = try parse_arguments(&.{ "--row", "C1", "--row", "C6" });
    try testing.expect(two.includes(6));
    try testing.expect(!two.includes(2));
    try testing.expectError(error.UnknownRow, parse_arguments(&.{ "--row", "C99" }));
    try testing.expectError(error.MissingRowId, parse_arguments(&.{"--row"}));
    try testing.expectError(error.UnknownArgument, parse_arguments(&.{"--rows"}));
}

test "print_ns keeps two decimals under 10, one under 100, none above" {
    var buffer: [64]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    try print_ns(&writer, 0.934);
    try writer.writeAll(" ");
    try print_ns(&writer, 47.26);
    try writer.writeAll(" ");
    try print_ns(&writer, 12959.4);
    try std.testing.expectEqualStrings("0.93 47.3 12959", writer.buffered());
}
