//! The rounds `calls_gate` reads: the table rows of what one run of a count script printed. Split
//! from `calls_gate.zig` for the 500-line limit, which keeps the baseline and the judgment.
//!
//! A round holds one of two tables, and its header row says which:
//!
//! - `count_calls.sh`'s, on Linux: payload, candidate, echoes and overruns, then nine counts from
//!   the kernel's tracepoints. The gate derives a tenth, `untried`.
//! - `count_calls_macos.sh`'s, on macOS: payload, candidate and echoes, then the Unix system calls
//!   and the Mach traps per echo, from the kernel's counts for the process.
const std = @import("std");

/// The columns a baseline line may name. The first ten are the Linux table's: its nine counts in
/// the order it prints them, then `untried`, which the gate derives from them. The last two are
/// the macOS table's.
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
    "untried",
    "unix",
    "mach",
};

/// The table a round holds.
pub const Layout = enum {
    linux,
    macos,

    /// The header cell that names the table.
    fn marker(layout: Layout) []const u8 {
        return switch (layout) {
            .linux => "io_uring_enter",
            .macos => "unix calls",
        };
    }

    /// Cells before the first count: payload, candidate, echoes, and on Linux the overruns.
    fn leading_cells(layout: Layout) usize {
        return switch (layout) {
            .linux => linux_leading_cells,
            .macos => macos_leading_cells,
        };
    }

    /// The index in `columns` of the table's first count.
    pub fn first(layout: Layout) usize {
        return switch (layout) {
            .linux => column_index("enter").?,
            .macos => column_index("unix").?,
        };
    }

    /// The counts the table prints. On Linux `untried` follows them, derived.
    fn printed(layout: Layout) usize {
        return switch (layout) {
            .linux => column_index("untried").? - layout.first(),
            .macos => columns.len - layout.first(),
        };
    }

    /// The columns a row of this table has: what it prints and what the gate derives.
    pub fn width(layout: Layout) usize {
        return switch (layout) {
            .linux => layout.printed() + 1,
            .macos => layout.printed(),
        };
    }

    /// True when `index` in `columns` is a column of this table.
    pub fn holds(layout: Layout, index: usize) bool {
        return index >= layout.first() and index < layout.first() + layout.width();
    }
};

const linux_leading_cells = 4;
const macos_leading_cells = 3;

/// The most cells a row has: the Linux table's leading cells, its counts, and its opcodes.
const cells_max = linux_leading_cells + columns.len;

/// The most table rows the gate keeps: every candidate at every payload, with room to spare.
pub const rows_max = 64;

pub const ParseError = error{ Malformed, TooMany, UnknownColumn };

/// One row of one round: its payload and candidate, its table, and its counts per echo.
pub const Row = struct {
    payload: u32,
    candidate: []const u8,
    layout: Layout,
    /// Per echo, in `columns` order. Only the columns of `layout` are set, once a usable round
    /// gave them.
    counts: [columns.len]f64,
    /// Rounds that gave this row usable counts.
    rounds: u32,
};

/// Reads the table rows of one round's output into `rows`, keeping the smaller of each cell a row
/// already holds. Lines that are not a table row of a candidate are skipped. A row before any
/// header is read as the Linux table's.
pub fn read_round(text: []const u8, rows: []Row, used: *usize) ParseError!void {
    var layout: Layout = .linux;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (header_layout(line)) |named| {
            layout = named;
            continue;
        }
        try read_row(line, layout, rows, used);
    }
}

/// Reads one line of a table of `layout` into `rows`. A line that is no row of a candidate, a row
/// that completed no echo, and a Linux row whose trace lost events change nothing.
fn read_row(line: []const u8, layout: Layout, rows: []Row, used: *usize) ParseError!void {
    var cells: [cells_max][]const u8 = undefined;
    const count = split_row(line, &cells) orelse return;
    const leading = layout.leading_cells();
    if (count < leading + layout.printed()) return;
    const payload = std.fmt.parseInt(u32, cells[0], 10) catch return;
    const echoes = std.fmt.parseInt(u64, cells[2], 10) catch return error.Malformed;
    if (echoes == 0) return;
    if (layout == .linux) {
        const overruns = std.fmt.parseInt(u64, cells[3], 10) catch return error.Malformed;
        if (overruns != 0) return;
    }
    const row = try find_or_add(rows, used, payload, cells[1], layout);
    merge(row, try counts_of(layout, cells[leading..][0..layout.printed()]));
}

/// The table a header row names, or null for a line that is no header.
fn header_layout(line: []const u8) ?Layout {
    inline for (comptime std.enums.values(Layout)) |layout| {
        const marked = "| " ++ comptime layout.marker() ++ " |";
        if (std.mem.indexOf(u8, line, marked) != null) return layout;
    }
    return null;
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

fn find_or_add(
    rows: []Row,
    used: *usize,
    payload: u32,
    candidate: []const u8,
    layout: Layout,
) ParseError!*Row {
    for (rows[0..used.*]) |*row| {
        if (row.payload != payload or !std.mem.eql(u8, row.candidate, candidate)) continue;
        // One gate reads the rounds of one system, so a row cannot change its table.
        if (row.layout != layout) return error.Malformed;
        return row;
    }
    if (used.* == rows.len) return error.TooMany;
    rows[used.*] = .{
        .payload = payload,
        .candidate = candidate,
        .layout = layout,
        .counts = @splat(0),
        .rounds = 0,
    };
    used.* += 1;
    return &rows[used.* - 1];
}

/// One round's counts of one row: the table's, then on Linux the derived `untried`.
fn counts_of(layout: Layout, cells: []const []const u8) ParseError![columns.len]f64 {
    var counts: [columns.len]f64 = @splat(0);
    for (cells, layout.first()..) |cell, index| {
        counts[index] = std.fmt.parseFloat(f64, cell) catch return error.Malformed;
    }
    if (layout == .linux) {
        const reads = counts[column_index("reads").?];
        const ctl = counts[column_index("ctl").?];
        counts[column_index("untried").?] = ctl - @max(reads - 1, 0);
    }
    return counts;
}

/// Keeps the smaller of each count this round gives `row`.
fn merge(row: *Row, counts: [columns.len]f64) void {
    for (counts, 0..) |value, index| {
        row.counts[index] = if (row.rounds == 0) value else @min(row.counts[index], value);
    }
    row.rounds += 1;
}

pub fn column_index(name: []const u8) ?usize {
    for (columns, 0..) |column, index| {
        if (std.mem.eql(u8, column, name)) return index;
    }
    return null;
}

pub fn find(rows: []const Row, payload: u32, candidate: []const u8) ?*const Row {
    for (rows) |*row| {
        if (row.payload == payload and std.mem.eql(u8, row.candidate, candidate)) return row;
    }
    return null;
}

/// Rounds the tests of this file and of `calls_gate.zig` read.
pub const examples = struct {
    pub const header =
        \\| payload | candidate | echoes | overruns | io_uring_enter | io_uring requests | poll arms | io-wq jobs | reads | writes | epoll_ctl | epoll waits | other calls | requests by opcode |
        \\|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
        \\
    ;

    pub const round_one = header ++
        \\| 4096 | rotor on epoll (group single) | 692161 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.206 | 1.000 | 0.364 | 0.139 | 0.000 |  |
        \\| 4096 | rotor | 197914 | 0 | 0.510 | 1.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | SEND 1.000 |
        \\
    ;

    pub const round_two = header ++
        \\| 4096 | rotor on epoll (group single) | 623080 | 0 | 0.000 | 0.000 | 0.000 | 0.000 | 1.214 | 1.000 | 0.368 | 0.140 | 0.000 |  |
        \\| 4096 | rotor | 200000 | 0 | 0.490 | 1.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | SEND 1.000 |
        \\
    ;

    pub const macos_header =
        \\| payload | candidate | echoes | unix calls | mach traps |
        \\|---:|---|---:|---:|---:|
        \\
    ;

    pub const macos_round = macos_header ++
        \\| 4096 | rotor | 10773 | 2.273 | 0.000 |
        \\| 4096 | rotor (accumulate) | 6364 | 3.152 | 0.000 |
        \\| 65536 | rotor | 0 | no echoes |
        \\
    ;

    pub fn rows_of(rounds: []const []const u8, into: []Row) ![]Row {
        var used: usize = 0;
        for (rounds) |round| try read_round(round, into, &used);
        return into[0..used];
    }
};

const testing = std.testing;
const rows_of = examples.rows_of;

test "each cell keeps the smallest value any round gave it" {
    var storage: [rows_max]Row = undefined;
    const rows = try rows_of(&.{ examples.round_one, examples.round_two }, &storage);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("rotor on epoll (group single)", rows[0].candidate);
    try testing.expectEqual(@as(u32, 2), rows[0].rounds);
    try testing.expectEqual(Layout.linux, rows[0].layout);
    try testing.expectEqual(@as(f64, 1.206), rows[0].counts[column_index("reads").?]);
    try testing.expectEqual(@as(f64, 0.364), rows[0].counts[column_index("ctl").?]);
    try testing.expectEqual(@as(f64, 0.490), rows[1].counts[column_index("enter").?]);
}

test "untried is epoll_ctl beyond the reads that found nothing, taken within each round" {
    // Round one tried and registered 0.9 of its receives, round two 0.2. Taken across the rounds
    // cell by cell, the smallest ctl and the smallest reads would come from different rounds.
    const tried = examples.header ++
        \\| 4096 | rotor on epoll (group single) | 1000 | 0 | 0 | 0 | 0 | 0 | 1.900 | 1 | 0.900 | 0.5 | 0 |  |
        \\| 4096 | rotor | 1000 | 0 | 0.5 | 1 | 0 | 0 | 0.000 | 0 | 0.000 | 0 | 0 |  |
        \\
    ;
    const partly = examples.header ++
        \\| 4096 | rotor on epoll (group single) | 1000 | 0 | 0 | 0 | 0 | 0 | 1.200 | 1 | 0.300 | 0.5 | 0 |  |
        \\
    ;
    const untried = column_index("untried").?;
    var storage: [rows_max]Row = undefined;
    const rows = try rows_of(&.{ tried, partly }, &storage);
    try testing.expectApproxEqAbs(@as(f64, 0.0), rows[0].counts[untried], 1e-9);
    // io_uring reads nothing, so none of its registrations is counted.
    try testing.expectEqual(@as(f64, 0.0), rows[1].counts[untried]);

    // Every receive registered with no read before it: one untried call per echo.
    const waited = examples.header ++
        \\| 4096 | rotor on epoll (group single) | 1000 | 0 | 0 | 0 | 0 | 0 | 1.000 | 1 | 1.300 | 0.5 | 0 |  |
        \\
    ;
    const alone = try rows_of(&.{waited}, &storage);
    try testing.expectApproxEqAbs(@as(f64, 1.3), alone[0].counts[untried], 1e-9);
}

test "a round whose trace lost events, or that completed no echo, is not used" {
    const lossy = examples.header ++
        \\| 4096 | rotor | 200000 | 12 | 0.100 | 1.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 |  |
        \\| 65536 | rotor | 0 | 0 | no echoes |
        \\
    ;
    var storage: [rows_max]Row = undefined;
    const rows = try rows_of(&.{ lossy, examples.round_one }, &storage);
    try testing.expectEqual(@as(usize, 2), rows.len);
    const rotor = find(rows, 4096, "rotor").?;
    try testing.expectEqual(@as(u32, 1), rotor.rounds);
    try testing.expectEqual(@as(f64, 0.510), rotor.counts[column_index("enter").?]);
    try testing.expectEqual(@as(?*const Row, null), find(rows, 65536, "rotor"));
}

test "a macOS round's header names its table, and its rows hold the Unix and Mach counts" {
    const second = examples.macos_header ++
        \\| 4096 | rotor | 9000 | 2.199 | 0.010 |
        \\
    ;
    var storage: [rows_max]Row = undefined;
    const rows = try rows_of(&.{ examples.macos_round, second }, &storage);
    // The row that completed no echo is not used.
    try testing.expectEqual(@as(usize, 2), rows.len);
    const rotor = find(rows, 4096, "rotor").?;
    try testing.expectEqual(Layout.macos, rotor.layout);
    try testing.expectEqual(@as(u32, 2), rotor.rounds);
    try testing.expectEqual(@as(f64, 2.199), rotor.counts[column_index("unix").?]);
    try testing.expectEqual(@as(f64, 0.0), rotor.counts[column_index("mach").?]);
    try testing.expect(rotor.layout.holds(column_index("mach").?));
    try testing.expect(!rotor.layout.holds(column_index("untried").?));
    try testing.expect(!Layout.linux.holds(column_index("unix").?));
}

test "a row whose table changes from one round to the next is refused" {
    var storage: [rows_max]Row = undefined;
    const mixed = &.{ examples.round_one, examples.macos_round };
    try testing.expectError(error.Malformed, rows_of(mixed, &storage));
}
