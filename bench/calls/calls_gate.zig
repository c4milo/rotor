//! calls_gate: holds the kernel calls rotor's echo servers make per echo to committed ceilings, so
//! a change that adds a call per echo fails CI instead of passing unseen.
//!
//! Run:  calls_gate BASELINE ROUND [ROUND...]
//!
//! Each ROUND is what one run of `bench/calls/count_calls.sh` printed. The gate reads the rows of
//! its table, and for every cell keeps the smallest value any round gave it. A change that adds a
//! call raises every round, and a burst of other work on the runner raises only some, so the
//! smallest value is the one to judge. A row whose trace lost events (`overruns` above 0), or whose
//! client completed no echo, is not used from that round.
//!
//! BASELINE holds one ceiling per line, as `bench/baseline/calls.txt` says. The gate fails when a
//! cell is over its ceiling, or when a row the baseline names has no usable round. A row the
//! baseline does not name is printed in the baseline's format and not judged, so a new candidate
//! can be added by copying its lines.
//!
//! A count per echo depends on the machine as well as the code: how often a receive finds its
//! bytes already there depends on how fast the client and the server run. So the ceilings come
//! from the runners this gate runs on, never from `orbstack` or `mac`, and they leave room for the
//! spread of that pool. The baseline's header says how each was set.
//!
//! Exit status: 0 when every ceiling holds, 1 when one does not or a row is missing, 2 when an
//! argument, a file or a line cannot be read.
const std = @import("std");

/// The columns of `count_calls.sh`'s table that count calls, by the name a baseline line uses, in
/// the order the table prints them after `payload`, `candidate`, `echoes` and `overruns`.
pub const columns = [_][]const u8{
    "enter",
    "requests",
    "arms",
    "workers",
    "reads",
    "writes",
    "ctl",
    "waits",
    "other",
};

/// Cells before the first counted column: payload, candidate, echoes, overruns.
const leading_cells = 4;

/// The most table rows the gate keeps: every candidate at every payload, with room to spare.
pub const rows_max = 64;
/// The most rounds one gate reads.
pub const rounds_max = 8;
/// The most baseline lines one gate reads.
pub const ceilings_max = 512;
/// The most bytes of one round's output or of the baseline.
const file_bytes_max = 1 << 20;

pub const ParseError = error{ Malformed, TooMany, UnknownColumn };

/// One row of one round: its payload and candidate, and its counts per echo.
pub const Row = struct {
    payload: u32,
    candidate: []const u8,
    /// Per echo, in `columns` order. Unset until a usable round gave them.
    counts: [columns.len]f64,
    /// Rounds that gave this row usable counts.
    rounds: u32,
};

/// One ceiling of the baseline.
pub const Ceiling = struct {
    payload: u32,
    column: usize,
    most: f64,
    candidate: []const u8,
};

/// Reads the table rows of one round's output into `rows`, keeping the smaller of each cell a row
/// already holds. Lines that are not a table row of a candidate are skipped.
pub fn read_round(text: []const u8, rows: []Row, used: *usize) ParseError!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var cells: [leading_cells + columns.len + 1][]const u8 = undefined;
        const count = split_row(line, &cells) orelse continue;
        if (count < leading_cells + columns.len) continue;
        const payload = std.fmt.parseInt(u32, cells[0], 10) catch continue;
        const echoes = std.fmt.parseInt(u64, cells[2], 10) catch return error.Malformed;
        const overruns = std.fmt.parseInt(u64, cells[3], 10) catch return error.Malformed;
        if (echoes == 0 or overruns != 0) continue;
        const row = try find_or_add(rows, used, payload, cells[1]);
        try merge(row, cells[leading_cells..][0..columns.len]);
    }
}

/// Splits `| a | b | ... |` into its trimmed cells. Null for a line that is not a table row.
fn split_row(line: []const u8, cells: [][]const u8) ?usize {
    const trimmed = std.mem.trim(u8, line, " \r");
    if (trimmed.len < 2 or trimmed[0] != '|' or trimmed[trimmed.len - 1] != '|') return null;
    var parts = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], '|');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (count == cells.len) break;
        cells[count] = std.mem.trim(u8, part, " ");
        count += 1;
    }
    return count;
}

fn find_or_add(rows: []Row, used: *usize, payload: u32, candidate: []const u8) ParseError!*Row {
    for (rows[0..used.*]) |*row| {
        if (row.payload == payload and std.mem.eql(u8, row.candidate, candidate)) return row;
    }
    if (used.* == rows.len) return error.TooMany;
    rows[used.*] = .{
        .payload = payload,
        .candidate = candidate,
        .counts = undefined,
        .rounds = 0,
    };
    used.* += 1;
    return &rows[used.* - 1];
}

/// Keeps the smaller of each count this round gives `row`.
fn merge(row: *Row, cells: []const []const u8) ParseError!void {
    for (cells, 0..) |cell, index| {
        const value = std.fmt.parseFloat(f64, cell) catch return error.Malformed;
        row.counts[index] = if (row.rounds == 0) value else @min(row.counts[index], value);
    }
    row.rounds += 1;
}

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

fn column_index(name: []const u8) ?usize {
    for (columns, 0..) |column, index| {
        if (std.mem.eql(u8, column, name)) return index;
    }
    return null;
}

/// Writes one line per ceiling that failed, or per row a ceiling names that no round gave, and one
/// baseline line per count of a row no ceiling names. Returns how many failed.
pub fn judge(rows: []const Row, ceilings: []const Ceiling, out: *std.Io.Writer) !u32 {
    var failed: u32 = 0;
    for (ceilings) |ceiling| {
        const row = find(rows, ceiling.payload, ceiling.candidate) orelse {
            try out.print(
                "FAILED {d} {s}: no round gave this row\n",
                .{ ceiling.payload, ceiling.candidate },
            );
            failed += 1;
            continue;
        };
        const value = row.counts[ceiling.column];
        if (value <= ceiling.most) continue;
        try out.print("FAILED {d} {s}: {s} {d:.3} per echo, over its ceiling {d:.3}\n", .{
            ceiling.payload, ceiling.candidate, columns[ceiling.column], value, ceiling.most,
        });
        failed += 1;
    }
    for (rows) |row| {
        if (is_named(ceilings, row)) continue;
        for (columns, 0..) |column, index| {
            try out.print(
                "not gated: {d} {s} {d:.3} {s}\n",
                .{ row.payload, column, row.counts[index], row.candidate },
            );
        }
    }
    return failed;
}

fn find(rows: []const Row, payload: u32, candidate: []const u8) ?*const Row {
    for (rows) |*row| {
        if (row.payload == payload and std.mem.eql(u8, row.candidate, candidate)) return row;
    }
    return null;
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
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
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
        read_round(text, &rows, &used) catch |err| {
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

const header =
    \\| payload | candidate | echoes | overruns | io_uring_enter | io_uring requests | poll arms | io-wq jobs | reads | writes | epoll_ctl | epoll waits | other calls | requests by opcode |
    \\|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
    \\
;

const round_one = header ++
    \\| 4096 | rotor on epoll (group single) | 692161 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.206 | 1.000 | 0.364 | 0.139 | 0.000 |  |
    \\| 4096 | rotor | 197914 | 0 | 0.510 | 1.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | SEND 1.000 |
    \\
;

const round_two = header ++
    \\| 4096 | rotor on epoll (group single) | 623080 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.214 | 1.000 | 0.368 | 0.140 | 0.000 |  |
    \\| 4096 | rotor | 200000 | 0 | 0.490 | 1.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | SEND 1.000 |
    \\
;

fn rows_of(rounds: []const []const u8, into: []Row) ![]Row {
    var used: usize = 0;
    for (rounds) |round| try read_round(round, into, &used);
    return into[0..used];
}

test "each cell keeps the smallest value any round gave it" {
    var storage: [rows_max]Row = undefined;
    const rows = try rows_of(&.{ round_one, round_two }, &storage);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("rotor on epoll (group single)", rows[0].candidate);
    try testing.expectEqual(@as(u32, 2), rows[0].rounds);
    try testing.expectEqual(@as(f64, 1.206), rows[0].counts[column_index("reads").?]);
    try testing.expectEqual(@as(f64, 0.364), rows[0].counts[column_index("ctl").?]);
    try testing.expectEqual(@as(f64, 0.490), rows[1].counts[column_index("enter").?]);
}

test "a round whose trace lost events, or that completed no echo, is not used" {
    const lossy = header ++
        \\| 4096 | rotor | 200000 | 12 | 0.100 | 1.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 |  |
        \\| 65536 | rotor | 0 | 0 | no echoes |
        \\
    ;
    var storage: [rows_max]Row = undefined;
    const rows = try rows_of(&.{ lossy, round_one }, &storage);
    try testing.expectEqual(@as(usize, 2), rows.len);
    const rotor = find(rows, 4096, "rotor").?;
    try testing.expectEqual(@as(u32, 1), rotor.rounds);
    try testing.expectEqual(@as(f64, 0.510), rotor.counts[column_index("enter").?]);
    try testing.expectEqual(@as(?*const Row, null), find(rows, 65536, "rotor"));
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
    const rows = try rows_of(&.{ round_one, round_two }, &storage);
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
    const rows = try rows_of(&.{round_one}, &storage);
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
}
