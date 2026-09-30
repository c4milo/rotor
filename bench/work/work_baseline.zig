//! The baseline of the instruction gate, `bench/baseline/work.txt`, and the verdict on one count.
//!
//! The file holds `tolerance_percent N` once, then one section per machine: `section KEY`, where
//! KEY is `<os>-<arch>-<backend>` as `work_gate` names the machine it runs on, followed by one
//! `WORKLOAD COUNT` line per workload, the instructions one iteration ran when the section was
//! taken. A line that starts with `#` is a comment, and blank lines are skipped.
//!
//! A count above its baseline by more than the tolerance fails. A count below it by more than the
//! tolerance passes, and the gate asks for the baseline to be lowered, so a gain is kept.
const std = @import("std");

/// Sections one file may hold: every operating system, processor and backend the gate runs on.
pub const sections_max = 16;

/// Workloads one section may hold.
pub const entries_max = 8;

/// The most a tolerance may be, in percent. A larger one would let a real regression through.
pub const tolerance_percent_max = 20;

pub const Entry = struct {
    workload: []const u8,
    count: u64,
};

pub const Section = struct {
    key: []const u8,
    entries: [entries_max]Entry = undefined,
    used: usize = 0,

    pub fn find(section: *const Section, workload: []const u8) ?u64 {
        for (section.entries[0..section.used]) |entry| {
            if (std.mem.eql(u8, entry.workload, workload)) return entry.count;
        }
        return null;
    }
};

pub const Baseline = struct {
    tolerance_percent: u32 = 0,
    sections: [sections_max]Section = undefined,
    used: usize = 0,

    pub fn find(baseline: *const Baseline, key: []const u8) ?*const Section {
        for (baseline.sections[0..baseline.used]) |*section| {
            if (std.mem.eql(u8, section.key, key)) return section;
        }
        return null;
    }
};

pub const ParseError = error{
    NoTolerance,
    ToleranceTooLarge,
    EntryBeforeSection,
    TooManySections,
    TooManyEntries,
    MalformedLine,
    DuplicateSection,
    DuplicateEntry,
};

/// Reads a baseline. The slices it holds point into `text`.
pub fn parse(text: []const u8, baseline: *Baseline) !void {
    baseline.* = .{};
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var have_tolerance = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (try parse_line(baseline, line)) have_tolerance = true;
    }
    if (!have_tolerance) return error.NoTolerance;
}

/// Reads one line that is not a comment. True when it was the tolerance.
fn parse_line(baseline: *Baseline, line: []const u8) ParseError!bool {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const first = words.next() orelse return error.MalformedLine;
    const second = words.next() orelse return error.MalformedLine;
    if (words.next() != null) return error.MalformedLine;
    if (std.mem.eql(u8, first, "tolerance_percent")) {
        baseline.tolerance_percent = std.fmt.parseInt(u32, second, 10) catch return error.MalformedLine;
        if (baseline.tolerance_percent > tolerance_percent_max) return error.ToleranceTooLarge;
        return true;
    }
    if (std.mem.eql(u8, first, "section")) {
        try add_section(baseline, second);
    } else {
        try add_entry(baseline, first, second);
    }
    return false;
}

fn add_section(baseline: *Baseline, key: []const u8) ParseError!void {
    if (baseline.find(key) != null) return error.DuplicateSection;
    if (baseline.used == sections_max) return error.TooManySections;
    baseline.sections[baseline.used] = .{ .key = key };
    baseline.used += 1;
}

fn add_entry(baseline: *Baseline, workload: []const u8, count_text: []const u8) ParseError!void {
    if (baseline.used == 0) return error.EntryBeforeSection;
    const section = &baseline.sections[baseline.used - 1];
    if (section.find(workload) != null) return error.DuplicateEntry;
    if (section.used == entries_max) return error.TooManyEntries;
    const count = std.fmt.parseInt(u64, count_text, 10) catch return error.MalformedLine;
    section.entries[section.used] = .{ .workload = workload, .count = count };
    section.used += 1;
}

pub const Verdict = enum {
    /// Within the tolerance of the baseline, either way.
    within,
    /// Above the baseline by more than the tolerance: the gate fails.
    over,
    /// Below the baseline by more than the tolerance: the gate passes and asks for a lower one.
    under,
};

/// The verdict on `measured` against `baseline`, both in instructions per iteration.
pub fn judge(baseline: u64, measured: u64, tolerance_percent: u32) Verdict {
    std.debug.assert(tolerance_percent <= tolerance_percent_max);
    const percent = 100;
    if (measured * percent > baseline * (percent + tolerance_percent)) return .over;
    if (measured * percent < baseline * (percent - tolerance_percent)) return .under;
    return .within;
}

const testing = std.testing;

const example =
    \\# a comment
    \\tolerance_percent 2
    \\
    \\section macos-aarch64-kqueue
    \\post 1236
    \\timer 400
    \\section linux-x86_64-uring
    \\post 1500
    \\
;

test "a baseline reads its tolerance, its sections and their counts" {
    var baseline: Baseline = undefined;
    try parse(example, &baseline);
    try testing.expectEqual(@as(u32, 2), baseline.tolerance_percent);
    try testing.expectEqual(@as(usize, 2), baseline.used);
    const mac = baseline.find("macos-aarch64-kqueue").?;
    try testing.expectEqual(@as(?u64, 1236), mac.find("post"));
    try testing.expectEqual(@as(?u64, 400), mac.find("timer"));
    try testing.expectEqual(@as(?u64, null), mac.find("batch"));
    try testing.expectEqual(@as(?u64, 1500), baseline.find("linux-x86_64-uring").?.find("post"));
    try testing.expect(baseline.find("linux-aarch64-epoll") == null);
}

test "a baseline refuses what it cannot read" {
    var baseline: Baseline = undefined;
    try testing.expectError(error.NoTolerance, parse("section a\npost 1\n", &baseline));
    try testing.expectError(error.ToleranceTooLarge, parse("tolerance_percent 21\n", &baseline));
    try testing.expectError(error.EntryBeforeSection, parse("tolerance_percent 2\npost 1\n", &baseline));
    try testing.expectError(error.MalformedLine, parse("tolerance_percent 2\nsection a\npost x\n", &baseline));
    try testing.expectError(error.MalformedLine, parse("tolerance_percent 2\nsection a b\n", &baseline));
    try testing.expectError(error.DuplicateSection, parse("tolerance_percent 2\nsection a\nsection a\n", &baseline));
    try testing.expectError(error.DuplicateEntry, parse("tolerance_percent 2\nsection a\npost 1\npost 2\n", &baseline));
}

test "a count fails above the tolerance, passes within it, and asks for a lower baseline below it" {
    try testing.expectEqual(Verdict.within, judge(1000, 1000, 2));
    try testing.expectEqual(Verdict.within, judge(1000, 1020, 2));
    try testing.expectEqual(Verdict.over, judge(1000, 1021, 2));
    try testing.expectEqual(Verdict.within, judge(1000, 980, 2));
    try testing.expectEqual(Verdict.under, judge(1000, 979, 2));
}
