//! Starting a candidate's program, and reading back the result line it printed.
//!
//! Three workloads measure themselves rather than being measured by a client: the cross-core
//! message, timer churn and the O_DIRECT reads. None of them has anything outside the program to
//! time it, so each candidate times itself and prints one line, and a runner collects the lines.
//! This file is what those runners share, so the fiddly parts — spawning, exit codes, path
//! buffers, reading the last line — have one definition and not one per workload.
//!
//! What a runner keeps for itself is its candidate list, the arguments it gives a run, and the
//! configurations it sweeps. Those are what a workload actually differs in.
const std = @import("std");
const assert = std.debug.assert;
const report = @import("report.zig");
const report_parse = @import("report_parse.zig");
const Result = report.Result;

/// One candidate program: the name a row carries and the file to start. The version is not here,
/// because a candidate reports its own: only the program knows which libuv it was linked against.
pub const Candidate = struct {
    name: []const u8,
    program: []const u8,
};

/// Why a run produced no result.
pub const RunError = error{
    /// The program exited non-zero. Whatever it printed, it measured nothing.
    CandidateFailed,
    /// A signal, a stop, or an end the host could not name. A run the machine cut short printed
    /// whatever it had reached, and that is not a measurement.
    CandidateKilled,
    /// The program printed nothing at all.
    NoResultLine,
    /// The program named itself something other than the candidate the runner asked for, so the
    /// row would carry a name for a configuration that never ran.
    CandidateMismatch,
};

/// The most bytes one candidate may print. A result line is a few hundred; this leaves room for a
/// header, a Markdown row and a warning beside them.
pub const output_bytes_max: usize = 64 * 1024;

/// Runs `argv` to completion and returns the result line it printed last.
///
/// The strings of the returned `Result` point into memory `allocator` holds, so the caller passes
/// an allocator that outlives every use of the result. A runner passes its arena, which lives as
/// long as the run does.
/// `expected` is the name the runner's table gives this candidate, which the program must print as
/// its own. A mismatch is a run that is not the candidate it was asked for: an argument was dropped,
/// or a program ignored a flag that picks its mode, and the row would then carry a name for
/// something that never ran. It is a parameter and not an optional check, so no runner can forget it.
pub fn run_once(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    expected: []const u8,
) !Result {
    assert(argv.len >= 1);
    assert(argv[0].len >= 1);
    assert(expected.len >= 1);
    const run = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });
    try check_exit(run.term);
    const line = report_parse.last_line(run.stdout) orelse return error.NoResultLine;
    const result = try report_parse.parse_line(line);
    try expect_candidate(result.candidate, expected);
    return result;
}

/// Halts a run whose program named itself something else. A function of its own so a test can reach
/// it: the comparison is what stops a mislabelled row, and a row that lies about which candidate or
/// which mode it measured is worse than a row that is missing.
pub fn expect_candidate(reported: []const u8, expected: []const u8) RunError!void {
    if (!std.mem.eql(u8, reported, expected)) return error.CandidateMismatch;
}

/// A candidate that did not exit cleanly measured nothing, whatever it printed.
pub fn check_exit(term: std.process.Child.Term) RunError!void {
    switch (term) {
        .exited => |code| if (code != 0) return error.CandidateFailed,
        else => return error.CandidateKilled,
    }
}

/// `directory`/`program`, written into `buffer`.
pub fn program_path(
    buffer: []u8,
    directory: []const u8,
    program: []const u8,
) ![]const u8 {
    assert(program.len >= 1);
    assert(buffer.len >= 1);
    return try std.fmt.bufPrint(buffer, "{s}/{s}", .{ directory, program });
}

/// True when `only` is empty, or names `name` exactly. A name that merely contains a candidate's
/// name is a different candidate.
pub fn wanted(only: []const u8, name: []const u8) bool {
    if (only.len == 0) return true;
    var pieces = std.mem.splitScalar(u8, only, ',');
    while (pieces.next()) |piece| {
        if (std.mem.eql(u8, piece, name)) return true;
    }
    return false;
}

/// True when a program is on disk at `path`.
pub fn installed(io: std.Io, path: []const u8) bool {
    assert(path.len >= 1);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

const testing = std.testing;

test "a program that names itself something else does not become a row" {
    try expect_candidate("rotor", "rotor");
    try expect_candidate("rotor (repeating)", "rotor (repeating)");
    // A mode flag a program ignored: it runs the plain mode and prints the plain name, and the
    // table's name would otherwise label it as the mode that never ran.
    try testing.expectError(error.CandidateMismatch, expect_candidate("libuv", "libuv (repeating)"));
    try testing.expectError(error.CandidateMismatch, expect_candidate("libuv (repeating)", "libuv"));
    try testing.expectError(error.CandidateMismatch, expect_candidate("", "rotor"));
    try testing.expectError(error.CandidateMismatch, expect_candidate("rotor ", "rotor"));
    // Two names of one length: a comparison of lengths alone would pass this, and the row would
    // carry the wrong library.
    try testing.expectError(error.CandidateMismatch, expect_candidate("rotor", "libuv"));
}

test "a candidate that did not exit cleanly measured nothing" {
    try check_exit(.{ .exited = 0 });
    try testing.expectError(error.CandidateFailed, check_exit(.{ .exited = 1 }));
    try testing.expectError(error.CandidateFailed, check_exit(.{ .exited = 255 }));
    try testing.expectError(error.CandidateKilled, check_exit(.{ .signal = .KILL }));
    try testing.expectError(error.CandidateKilled, check_exit(.{ .stopped = .STOP }));
    try testing.expectError(error.CandidateKilled, check_exit(.{ .unknown = 0 }));
}

test "an empty only-list names everything, and a list names its members alone" {
    try testing.expect(wanted("", "rotor"));
    try testing.expect(wanted("", "libuv"));

    try testing.expect(wanted("rotor,libxev", "rotor"));
    try testing.expect(wanted("rotor,libxev", "libxev"));
    try testing.expect(!wanted("rotor,libxev", "libuv"));

    // A name that contains a candidate's name is not that candidate, in either direction.
    try testing.expect(!wanted("rotorx", "rotor"));
    try testing.expect(!wanted("roto", "rotor"));
    try testing.expect(!wanted("rotor", "rotorx"));
}

test "a path is the directory and the program, and a full buffer is an error" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "zig-out/bin/rotor_post",
        try program_path(&buffer, "zig-out/bin", "rotor_post"),
    );

    var small: [4]u8 = undefined;
    try testing.expectError(
        error.NoSpaceLeft,
        program_path(&small, "zig-out/bin", "rotor_post"),
    );
}
