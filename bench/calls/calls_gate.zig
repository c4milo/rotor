//! calls_gate: holds the kernel calls rotor's echo servers make per echo to committed ceilings, so
//! a change that adds a call per echo fails CI instead of passing unseen.
//!
//! Run:  calls_gate BASELINE ROUND [ROUND...]
//!
//! Each ROUND is what one run of `bench/calls/count_calls.sh` printed on Linux, or of
//! `bench/calls/count_calls_macos.sh` on macOS. `calls_gate_table.zig` reads the rows of its table.
//! For every cell the gate keeps the smallest value any round gave it. A change that adds a call
//! raises every round, and a burst of other work on the runner raises only some, so the smallest
//! value is the one to judge. A row whose trace lost events (`overruns` above 0), or whose client
//! completed no echo, is not used from that round.
//!
//! BASELINE holds one ceiling per line, as `bench/baseline/calls.txt` says. The gate fails when a
//! cell is over its ceiling, when a ceiling names a column the row's table does not have, or when a
//! row the baseline names has no usable round. A row the baseline does not name is printed in the
//! baseline's format and not judged, so a new candidate can be added by copying its lines.
//!
//! One column is derived, and `count_calls.sh` does not print it: `untried`, the `epoll_ctl` calls
//! per echo beyond the reads that found nothing, `ctl - max(reads - 1, 0)`. It is taken within
//! each round, before the smallest is kept, because the two counts mean something only together. A
//! readiness backend tries an operation before it registers it (decision 20), so a registration
//! follows a read that answered EAGAIN, and this stays near 0. An operation that waits without being
//! tried first adds about one per echo. On 2026-09-24 the runners read -0.05 to 0.06 for the tree,
//! on every epoll row, and 1.04 to 1.97 with E4 undone, where `ctl` alone overlapped between the two.
//!
//! A count per echo depends on the machine as well as the code: how often a receive finds its
//! bytes already there depends on how fast the client and the server run. So the ceilings come
//! from the runners this gate runs on, never from `orbstack` or `mac`, and they leave room for the
//! spread of that pool. The baseline's header says how each was set.
//!
//! Exit status: 0 when every ceiling holds, 1 when one does not or a row is missing, 2 when an
//! argument, a file or a line cannot be read.
const std = @import("std");
const table = @import("calls_gate_table.zig");

pub const columns = table.columns;
pub const Row = table.Row;
pub const ParseError = table.ParseError;
pub const rows_max = table.rows_max;
const column_index = table.column_index;
const find = table.find;

/// The most rounds one gate reads.
pub const rounds_max = 8;
/// The most baseline lines one gate reads.
pub const ceilings_max = 512;
/// The most bytes of one round's output or of the baseline.
const file_bytes_max = 1 << 20;

/// One ceiling of the baseline.
pub const Ceiling = struct {
    payload: u32,
    column: usize,
    most: f64,
    candidate: []const u8,
};

/// Reads the baseline's lines, `PAYLOAD COLUMN CEILING CANDIDATE`, into `into`. The candidate is
/// the rest of the line, because a candidate's name holds spaces. `#` starts a comment line.
pub fn read_ceilings(text: []const u8, into: []Ceiling) ParseError![]Ceiling {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        if (count == into.len) return error.TooMany;
        into[count] = try parse_ceiling(line);
        count += 1;
    }
    return into[0..count];
}

fn parse_ceiling(line: []const u8) ParseError!Ceiling {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const payload_text = fields.next() orelse return error.Malformed;
    const column_text = fields.next() orelse return error.Malformed;
    const ceiling_text = fields.next() orelse return error.Malformed;
    const candidate = std.mem.trim(u8, fields.rest(), " ");
    if (candidate.len == 0) return error.Malformed;
    return .{
        .payload = std.fmt.parseInt(u32, payload_text, 10) catch return error.Malformed,
        .column = column_index(column_text) orelse return error.UnknownColumn,
        .most = std.fmt.parseFloat(f64, ceiling_text) catch return error.Malformed,
        .candidate = candidate,
    };
}

/// Writes one line per ceiling that failed, or per row a ceiling names that no round gave, and one
/// baseline line per count of a row no ceiling names. Returns how many failed.
pub fn judge(rows: []const Row, ceilings: []const Ceiling, out: *std.Io.Writer) !u32 {
    var failed: u32 = 0;
    for (ceilings) |ceiling| {
        if (!try holds(rows, ceiling, out)) failed += 1;
    }
    for (rows) |row| {
        if (is_named(ceilings, row)) continue;
        const first = row.layout.first();
        for (columns[first..][0..row.layout.width()], first..) |column, index| {
            try out.print(
                "not gated: {d} {s} {d:.3} {s}\n",
                .{ row.payload, column, row.counts[index], row.candidate },
            );
        }
    }
    return failed;
}

/// True when the row `ceiling` names holds it. Otherwise writes the line that says why not.
fn holds(rows: []const Row, ceiling: Ceiling, out: *std.Io.Writer) !bool {
    const row = find(rows, ceiling.payload, ceiling.candidate) orelse {
        try out.print(
            "FAILED {d} {s}: no round gave this row\n",
            .{ ceiling.payload, ceiling.candidate },
        );
        return false;
    };
    const column = columns[ceiling.column];
    if (!row.layout.holds(ceiling.column)) {
        const absent = "FAILED {d} {s}: its {s} table has no column {s}\n";
        try out.print(absent, .{ row.payload, row.candidate, @tagName(row.layout), column });
        return false;
    }
    const value = row.counts[ceiling.column];
    if (value <= ceiling.most) return true;
    try out.print("FAILED {d} {s}: {s} {d:.3} per echo, over its ceiling {d:.3}\n", .{
        ceiling.payload, ceiling.candidate, column, value, ceiling.most,
    });
    return false;
}

fn is_named(ceilings: []const Ceiling, row: Row) bool {
    for (ceilings) |ceiling| {
        const same = ceiling.payload == row.payload;
        if (same and std.mem.eql(u8, ceiling.candidate, row.candidate)) return true;
    }
    return false;
}

const exit_usage = 2;

/// Bytes of standard output held before a flush.
const output_buffer_bytes = 4096;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    var buffer: [output_buffer_bytes]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    // The program's name, the baseline, then the rounds.
    const arguments_min = 3;
    if (arguments.len < arguments_min or arguments.len - 2 > rounds_max) {
        const usage = "usage: calls_gate BASELINE ROUND [ROUND...], at most {d} rounds\n";
        try out.print(usage, .{rounds_max});
        return exit_usage;
    }
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const baseline_text = cwd.readFileAlloc(init.io, arguments[1], arena, limit) catch |err| {
        try out.print("calls_gate: cannot read {s}: {s}\n", .{ arguments[1], @errorName(err) });
        return exit_usage;
    };
    var ceiling_storage: [ceilings_max]Ceiling = undefined;
    const ceilings = read_ceilings(baseline_text, &ceiling_storage) catch |err| {
        const refused = "calls_gate: {s} is not a baseline: {s}\n";
        try out.print(refused, .{ arguments[1], @errorName(err) });
        return exit_usage;
    };
    var rows: [rows_max]Row = undefined;
    var used: usize = 0;
    for (arguments[2..]) |path| {
        const text = cwd.readFileAlloc(init.io, path, arena, limit) catch |err| {
            try out.print("calls_gate: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            return exit_usage;
        };
        table.read_round(text, &rows, &used) catch |err| {
            const unread = "calls_gate: {s} holds a row that cannot be read: {s}\n";
            try out.print(unread, .{ path, @errorName(err) });
            return exit_usage;
        };
    }
    const failed = try judge(rows[0..used], ceilings, out);
    const rounds = arguments.len - 2;
    const summary = "calls_gate: {d} ceilings, {d} rows over {d} rounds, {d} failed\n";
    try out.print(summary, .{ ceilings.len, used, rounds, failed });
    return if (failed == 0) 0 else 1;
}

// Tests.

const testing = std.testing;
const examples = table.examples;
const rows_of = examples.rows_of;

test {
    _ = table;
}

test "a baseline line is payload, column, ceiling, then a candidate with spaces" {
    var storage: [4]Ceiling = undefined;
    const ceilings = try read_ceilings(
        \\# a comment, then a blank line
        \\
        \\4096 ctl 0.60 rotor on epoll (group single)
        \\65536 enter 1.25 rotor
    , &storage);
    try testing.expectEqual(@as(usize, 2), ceilings.len);
    try testing.expectEqual(@as(u32, 4096), ceilings[0].payload);
    try testing.expectEqual(column_index("ctl").?, ceilings[0].column);
    try testing.expectEqual(@as(f64, 0.60), ceilings[0].most);
    try testing.expectEqualStrings("rotor on epoll (group single)", ceilings[0].candidate);
    try testing.expectError(error.UnknownColumn, read_ceilings("4096 calls 1.0 rotor", &storage));
    try testing.expectError(error.Malformed, read_ceilings("4096 ctl 1.0", &storage));
}

fn failures_of(rows: []const Row, baseline: []const u8, out: *std.Io.Writer) !u32 {
    var storage: [8]Ceiling = undefined;
    return judge(rows, try read_ceilings(baseline, &storage), out);
}

test "a count over its ceiling fails and names the row, and one under it passes" {
    var storage: [rows_max]Row = undefined;
    const rows = try rows_of(&.{ examples.round_one, examples.round_two }, &storage);
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const baseline =
        \\4096 ctl 0.30 rotor on epoll (group single)
        \\4096 reads 1.30 rotor on epoll (group single)
        \\4096 enter 0.49 rotor
    ;
    try testing.expectEqual(@as(u32, 1), try failures_of(rows, baseline, &out));
    try testing.expectEqualStrings(
        "FAILED 4096 rotor on epoll (group single): ctl 0.364 per echo, over its ceiling 0.300\n",
        out.buffered(),
    );
}

test "a row the baseline names that no round gave fails, and one it does not name is printed" {
    var storage: [rows_max]Row = undefined;
    const rows = try rows_of(&.{examples.round_one}, &storage);
    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const baseline =
        \\65536 writes 1.05 rotor on epoll (group single)
        \\4096 writes 1.05 rotor on epoll (group single)
    ;
    try testing.expectEqual(@as(u32, 1), try failures_of(rows, baseline, &out));
    const printed = out.buffered();
    try testing.expect(std.mem.startsWith(u8, printed, "FAILED 65536 rotor on epoll (group single): no round gave this row\n"));
    try testing.expect(std.mem.indexOf(u8, printed, "not gated: 4096 enter 0.510 rotor\n") != null);
    // The row a ceiling names is judged and not printed.
    const named = "not gated: 4096 ctl 0.364 rotor on epoll (group single)";
    try testing.expect(std.mem.indexOf(u8, printed, named) == null);
    // A Linux row prints no macOS column.
    try testing.expect(std.mem.indexOf(u8, printed, " unix ") == null);
}

test "a macOS row is held to its own columns, and a ceiling on a column it lacks fails" {
    var storage: [rows_max]Row = undefined;
    const rows = try rows_of(&.{examples.macos_round}, &storage);
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const baseline =
        \\4096 unix 2.20 rotor
        \\4096 mach 0.05 rotor
        \\4096 enter 1.00 rotor
    ;
    try testing.expectEqual(@as(u32, 2), try failures_of(rows, baseline, &out));
    try testing.expectEqualStrings(
        "FAILED 4096 rotor: unix 2.273 per echo, over its ceiling 2.200\n" ++
            "FAILED 4096 rotor: its macos table has no column enter\n" ++
            "not gated: 4096 unix 3.152 rotor (accumulate)\n" ++
            "not gated: 4096 mach 0.000 rotor (accumulate)\n",
        out.buffered(),
    );
}
