//! Reading back what `report.render_json_line` wrote: one `Result` from one JSON line.
//!
//! A runner whose candidate measures itself in its own process gets the numbers the only way a
//! separate process can hand them over, on standard output. The echo runner needs none of this,
//! because its client runs inside the runner and returns a `Result` directly. The cross-core and
//! timer workloads do need it: neither has a client, so each candidate times itself and prints
//! one line, and the runner collects the lines.
//!
//! **It reads exactly what the writer writes, field for field, in that order.** Writer and reader
//! live in one tree, and the round-trip test at the end of this file pins them together, so a
//! field added to `Result` without a change here fails that test instead of quietly parsing into
//! the wrong number. A general JSON reader would accept orders the writer never produces and hide
//! that break, which is the one failure this file exists to make loud.
//!
//! Nothing here allocates. Every string in the returned `Result` is a slice of the line the caller
//! passed in, and lives exactly as long as that line does.
const std = @import("std");
const assert = std.debug.assert;
const report = @import("report.zig");
const Result = report.Result;
const Configuration = report.Configuration;
const Load = report.Load;

/// Why a line is not a result. Every one of these is a caller's or a child's mistake, not a
/// programmer's, so they are errors and not assertions (CLAUDE.md, Conventions).
pub const ParseError = error{
    /// The line is not what the writer produces: a missing field, a wrong order, a short line, or
    /// bytes after the closing brace.
    Malformed,
    /// A JSON string with an escape in it. The harness names its workloads and candidates with
    /// literals that need none, and returning a slice with escapes still in it would be wrong.
    EscapedString,
    /// The `load` field names something `Load` does not have.
    UnknownLoad,
    /// A number too large for the field it belongs to.
    NumberTooLarge,
};

/// The bytes a line may carry at either end, which a child's `writeByte('\n')` puts there.
const blank = " \t\r\n";

/// The base every number in the line is written in.
const base = 10;

/// One pass over one line, left to right. It holds no copy of the line: every string it returns
/// points into it.
const Scanner = struct {
    line: []const u8,
    index: usize = 0,

    /// Consumes `literal` or refuses the line. This is how every field name and every separator
    /// is read, which is what makes the order part of the format.
    fn expect(scanner: *Scanner, literal: []const u8) ParseError!void {
        assert(literal.len >= 1);
        assert(scanner.index <= scanner.line.len);
        const end = scanner.index + literal.len;
        if (end > scanner.line.len) return error.Malformed;
        if (!std.mem.eql(u8, scanner.line[scanner.index..end], literal)) return error.Malformed;
        scanner.index = end;
    }

    /// The content of one JSON string, without its quotes, as a slice of the line.
    fn string(scanner: *Scanner) ParseError![]const u8 {
        try scanner.expect("\"");
        const from = scanner.index;
        while (scanner.index < scanner.line.len) : (scanner.index += 1) {
            switch (scanner.line[scanner.index]) {
                '\\' => return error.EscapedString,
                '"' => {
                    const value = scanner.line[from..scanner.index];
                    scanner.index += 1;
                    assert(scanner.index <= scanner.line.len);
                    return value;
                },
                else => {},
            }
        }
        return error.Malformed;
    }

    /// One unsigned number. The writer prints every number as a whole number of its unit, so a
    /// sign or a point is a malformed line and not a number this reads.
    fn number(scanner: *Scanner) ParseError!u64 {
        const from = scanner.index;
        while (scanner.index < scanner.line.len and
            std.ascii.isDigit(scanner.line[scanner.index])) : (scanner.index += 1)
        {}
        if (scanner.index == from) return error.Malformed;
        assert(scanner.index > from);
        return std.fmt.parseInt(u64, scanner.line[from..scanner.index], base) catch
            error.NumberTooLarge;
    }

    /// One number that belongs in a 32-bit field. A value above that range is refused rather than
    /// truncated: a count that does not fit is not a count.
    fn number_32(scanner: *Scanner) ParseError!u32 {
        const value = try scanner.number();
        if (value > std.math.maxInt(u32)) return error.NumberTooLarge;
        return @intCast(value);
    }
};

/// The numbers of one result, read in the order the writer prints them. It exists so that
/// `parse_line` reads three groups and not fourteen fields, and stays inside the complexity limit.
const Measurements = struct {
    duration_ns: u64,
    operations: u64,
    operations_per_second: u64,
    p50_ns: u64,
    p99_ns: u64,
    p999_ns: u64,
    p9999_ns: u64,
    overflow: u64,
    peak_rss_bytes: u64,
};

/// One `Result` from one line, with every string pointing into `line`.
pub fn parse_line(line: []const u8) ParseError!Result {
    var scanner: Scanner = .{ .line = std.mem.trim(u8, line, blank) };
    assert(scanner.index == 0);

    try scanner.expect("{\"workload\":");
    const workload = try scanner.string();
    try scanner.expect(",\"candidate\":");
    const candidate = try scanner.string();
    try scanner.expect(",\"version\":");
    const version = try scanner.string();
    const configuration = try parse_configuration(&scanner);
    const measured = try parse_measurements(&scanner);
    try scanner.expect("}");
    if (scanner.index != scanner.line.len) return error.Malformed;

    assert(workload.len <= scanner.line.len);
    return .{
        .workload = workload,
        .candidate = candidate,
        .candidate_version = version,
        .configuration = configuration,
        .duration_ns = measured.duration_ns,
        .operations = measured.operations,
        .operations_per_second = measured.operations_per_second,
        .p50_ns = measured.p50_ns,
        .p99_ns = measured.p99_ns,
        .p999_ns = measured.p999_ns,
        .p9999_ns = measured.p9999_ns,
        .overflow = measured.overflow,
        .peak_rss_bytes = measured.peak_rss_bytes,
    };
}

fn parse_configuration(scanner: *Scanner) ParseError!Configuration {
    assert(scanner.index >= 1);
    try scanner.expect(",\"cores\":");
    const cores = try scanner.number_32();
    try scanner.expect(",\"connections\":");
    const connections = try scanner.number_32();
    try scanner.expect(",\"payload_bytes\":");
    const payload_bytes = try scanner.number_32();
    try scanner.expect(",\"load\":");
    const load_name = try scanner.string();
    const load = std.meta.stringToEnum(Load, load_name) orelse return error.UnknownLoad;
    assert(scanner.index <= scanner.line.len);
    return .{
        .cores = cores,
        .connections = connections,
        .payload_bytes = payload_bytes,
        .load = load,
    };
}

fn parse_measurements(scanner: *Scanner) ParseError!Measurements {
    assert(scanner.index >= 1);
    try scanner.expect(",\"duration_ns\":");
    const duration_ns = try scanner.number();
    try scanner.expect(",\"operations\":");
    const operations = try scanner.number();
    try scanner.expect(",\"operations_per_second\":");
    const operations_per_second = try scanner.number();
    try scanner.expect(",\"p50_ns\":");
    const p50_ns = try scanner.number();
    try scanner.expect(",\"p99_ns\":");
    const p99_ns = try scanner.number();
    try scanner.expect(",\"p999_ns\":");
    const p999_ns = try scanner.number();
    try scanner.expect(",\"p9999_ns\":");
    const p9999_ns = try scanner.number();
    try scanner.expect(",\"overflow\":");
    const overflow = try scanner.number();
    try scanner.expect(",\"peak_rss_bytes\":");
    const peak_rss_bytes = try scanner.number();
    assert(scanner.index <= scanner.line.len);
    return .{
        .duration_ns = duration_ns,
        .operations = operations,
        .operations_per_second = operations_per_second,
        .p50_ns = p50_ns,
        .p99_ns = p99_ns,
        .p999_ns = p999_ns,
        .p9999_ns = p9999_ns,
        .overflow = overflow,
        .peak_rss_bytes = peak_rss_bytes,
    };
}

/// The last line of `text` that is not blank, which is where a child's result is: a candidate may
/// print a ready line or a warning first, and the result is what it prints last.
pub fn last_line(text: []const u8) ?[]const u8 {
    var rest = std.mem.trim(u8, text, blank);
    if (rest.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, rest, '\n')) |cut| rest = rest[cut + 1 ..];
    assert(rest.len >= 1);
    return rest;
}

const testing = std.testing;

/// The buffer a rendered line is written into. One result's line is far shorter than this.
const line_bytes_max = 1024;

fn render(result: *const Result, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try result.render_json_line(&writer);
    return writer.buffered();
}

const sample: Result = .{
    .workload = "cross-core",
    .candidate = "std.Io.Threaded",
    .candidate_version = "0.16.0",
    .configuration = .{
        .cores = 2,
        .connections = 64,
        .payload_bytes = 65536,
        .load = .even,
    },
    .duration_ns = 1_000_000_007,
    .operations = 4_000_000,
    .operations_per_second = 3_999_999,
    .p50_ns = 101,
    .p99_ns = 16_300,
    .p999_ns = 90_000,
    .p9999_ns = 250_000,
    .overflow = 3,
    .peak_rss_bytes = 67_108_864,
};

test "a rendered result parses back field for field" {
    var buffer: [line_bytes_max]u8 = undefined;
    const line = try render(&sample, &buffer);
    const read = try parse_line(line);

    try testing.expectEqualStrings(sample.workload, read.workload);
    try testing.expectEqualStrings(sample.candidate, read.candidate);
    try testing.expectEqualStrings(sample.candidate_version, read.candidate_version);
    try testing.expect(sample.configuration.equals(read.configuration));
    try testing.expectEqual(sample.duration_ns, read.duration_ns);
    try testing.expectEqual(sample.operations, read.operations);
    try testing.expectEqual(sample.operations_per_second, read.operations_per_second);
    try testing.expectEqual(sample.p50_ns, read.p50_ns);
    try testing.expectEqual(sample.p99_ns, read.p99_ns);
    try testing.expectEqual(sample.p999_ns, read.p999_ns);
    try testing.expectEqual(sample.overflow, read.overflow);
}

test "the trailing newline the writer prints is not part of the line" {
    var buffer: [line_bytes_max]u8 = undefined;
    const line = try render(&sample, &buffer);
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
    const read = try parse_line(line);
    try testing.expectEqualStrings(sample.candidate, read.candidate);
}

test "every prefix of a good line short of the whole is refused" {
    var buffer: [line_bytes_max]u8 = undefined;
    const line = std.mem.trim(u8, try render(&sample, &buffer), blank);
    var length: usize = 0;
    while (length < line.len) : (length += 1) {
        try testing.expectError(error.Malformed, parse_line(line[0..length]));
    }
    _ = try parse_line(line);
}

test "bytes after the closing brace are refused" {
    var buffer: [line_bytes_max]u8 = undefined;
    const line = std.mem.trim(u8, try render(&sample, &buffer), blank);
    var longer: [line_bytes_max]u8 = undefined;
    @memcpy(longer[0..line.len], line);
    longer[line.len] = '}';
    try testing.expectError(error.Malformed, parse_line(longer[0 .. line.len + 1]));
}

test "a field out of the writer's order is refused rather than read" {
    const swapped = "{\"workload\":\"w\",\"version\":\"v\",\"candidate\":\"c\"," ++
        "\"cores\":1,\"connections\":1,\"payload_bytes\":1,\"load\":\"even\"," ++
        "\"duration_ns\":1,\"operations\":1,\"operations_per_second\":1," ++
        "\"p50_ns\":1,\"p99_ns\":1,\"p999_ns\":1,\"p9999_ns\":1,\"overflow\":0}";
    try testing.expectError(error.Malformed, parse_line(swapped));
}

test "a load the enum does not have is refused, and both that it has are read" {
    var buffer: [line_bytes_max]u8 = undefined;
    var result = sample;
    for ([_]Load{.even}) |load| {
        result.configuration.load = load;
        const line = try render(&result, &buffer);
        try testing.expectEqual(load, (try parse_line(line)).configuration.load);
    }

    const unknown = "{\"workload\":\"w\",\"candidate\":\"c\",\"version\":\"v\"," ++
        "\"cores\":1,\"connections\":1,\"payload_bytes\":1,\"load\":\"lopsided\"," ++
        "\"duration_ns\":1,\"operations\":1,\"operations_per_second\":1," ++
        "\"p50_ns\":1,\"p99_ns\":1,\"p999_ns\":1,\"p9999_ns\":1,\"overflow\":0}";
    try testing.expectError(error.UnknownLoad, parse_line(unknown));
}

test "an escaped string is refused rather than returned with its escapes" {
    var buffer: [line_bytes_max]u8 = undefined;
    var result = sample;
    result.candidate = "say \"hi\"";
    const line = try render(&result, &buffer);
    try testing.expectError(error.EscapedString, parse_line(line));
}

test "a number past its field's range is refused rather than truncated" {
    const wide = "{\"workload\":\"w\",\"candidate\":\"c\",\"version\":\"v\"," ++
        "\"cores\":4294967296,\"connections\":1,\"payload_bytes\":1,\"load\":\"even\"," ++
        "\"duration_ns\":1,\"operations\":1,\"operations_per_second\":1," ++
        "\"p50_ns\":1,\"p99_ns\":1,\"p999_ns\":1,\"p9999_ns\":1,\"overflow\":0}";
    try testing.expectError(error.NumberTooLarge, parse_line(wide));

    const huge = "{\"workload\":\"w\",\"candidate\":\"c\",\"version\":\"v\"," ++
        "\"cores\":1,\"connections\":1,\"payload_bytes\":1,\"load\":\"even\"," ++
        "\"duration_ns\":18446744073709551616,\"operations\":1," ++
        "\"operations_per_second\":1,\"p50_ns\":1,\"p99_ns\":1,\"p999_ns\":1,\"p9999_ns\":1,\"overflow\":0}";
    try testing.expectError(error.NumberTooLarge, parse_line(huge));
}

test "a field with no digits where a number belongs is refused" {
    const empty = "{\"workload\":\"w\",\"candidate\":\"c\",\"version\":\"v\"," ++
        "\"cores\":,\"connections\":1,\"payload_bytes\":1,\"load\":\"even\"," ++
        "\"duration_ns\":1,\"operations\":1,\"operations_per_second\":1," ++
        "\"p50_ns\":1,\"p99_ns\":1,\"p999_ns\":1,\"p9999_ns\":1,\"overflow\":0}";
    try testing.expectError(error.Malformed, parse_line(empty));
}

test "the last line is the result, whatever a candidate printed before it" {
    var buffer: [line_bytes_max]u8 = undefined;
    const line = try render(&sample, &buffer);
    var together: [line_bytes_max]u8 = undefined;
    const noisy = try std.fmt.bufPrint(&together, "ready on 20001\nwarning: pin refused\n{s}", .{
        line,
    });
    const last = last_line(noisy).?;
    try testing.expectEqualStrings(sample.candidate, (try parse_line(last)).candidate);

    try testing.expectEqual(@as(?[]const u8, null), last_line(""));
    try testing.expectEqual(@as(?[]const u8, null), last_line("  \n\t\r\n "));
    try testing.expectEqualStrings("only", last_line("only").?);
}
