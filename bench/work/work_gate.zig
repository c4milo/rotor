//! work_gate: the instruction gate. It counts the instructions one iteration of each workload of
//! `work.zig` runs, and holds each count to `bench/baseline/work.txt` (`work_baseline.zig`).
//!
//! Run:  work_gate BASELINE BACKEND=PROGRAM [BACKEND=PROGRAM...]
//!
//! Each program is `work` built against one backend, and BACKEND names it. The gate runs each
//! workload twice, for `short_iterations` and `long_iterations`, and divides the difference by the
//! difference: what the process does to start and to stop runs in both and cancels. It counts with
//! the counter this machine has:
//!
//! - macOS: `/usr/bin/time -l`, which reports the instructions the process retired, its own and
//!   the kernel's on its behalf. GitHub's macOS runners are virtual machines and print no count,
//!   and the gate then skips.
//! - Linux: Valgrind's cachegrind, which counts the instructions the process runs in user space,
//!   the same on every run. A machine without Valgrind skips.
//!
//! A machine is named `<os>-<arch>-<backend>`. A name the baseline has no section for is not held
//! to anything: the gate prints the section it measured, to be added, and passes, as the echo
//! baseline does for a processor it has not seen.
//!
//! Exit status: 0 when every count is within the tolerance, or the gate skipped; 1 when a count is
//! over it; 2 on a usage error or a program that failed.
const std = @import("std");
const builtin = @import("builtin");
const work_baseline = @import("work_baseline.zig");

/// One workload of `work.zig`, and how many iterations the long run adds to the short one.
const Workload = struct {
    /// As `work.zig`'s command line spells it.
    name: []const u8,
    /// Under `/usr/bin/time`, whose count holds the kernel's work for the process too and varies
    /// by about half a million instructions from one run to the next: enough iterations that this
    /// is a small fraction of a percent of the difference, and each run stays well under a second.
    time_span: u64,
    /// Under cachegrind, whose count is the same on every run, and which runs about fifty times
    /// slower than the program alone.
    cachegrind_span: u64,
};

const workloads = [_]Workload{
    .{ .name = "post", .time_span = 1_000_000, .cachegrind_span = 10_000 },
    .{ .name = "post-operation", .time_span = 500_000, .cachegrind_span = 5_000 },
    .{ .name = "timer", .time_span = 1_000_000, .cachegrind_span = 10_000 },
    .{ .name = "batch", .time_span = 50_000, .cachegrind_span = 500 },
    .{ .name = "wait", .time_span = 200_000, .cachegrind_span = 5_000 },
};

/// The iterations of the short run, which the long run repeats before its own: they warm what the
/// long run then counts.
const short_iterations: u64 = 2_000;

/// `work.zig`'s exit status for a workload its backend cannot run.
const unsupported_status: u8 = 2;

/// Programs one run may name.
const programs_max = 4;

const output_bytes_max = 1 << 16;
const file_bytes_max = 1 << 16;
const output_buffer_bytes = 4096;

const exit_failed: u8 = 1;
const exit_usage: u8 = 2;

const Counter = enum {
    time,
    cachegrind,

    fn name(counter: Counter) []const u8 {
        return switch (counter) {
            .time => "/usr/bin/time -l, user and kernel instructions",
            .cachegrind => "Valgrind's cachegrind, user instructions",
        };
    }
};

/// What one gate run holds: where it prints, and how it starts programs.
const Gate = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    counter: Counter,
    tolerance_percent: u32,
    failed: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    var buffer: [output_buffer_bytes]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    // The program's name, the baseline, then the programs.
    const arguments_min = 3;
    if (arguments.len < arguments_min or arguments.len - 2 > programs_max) {
        try out.print("usage: work_gate BASELINE BACKEND=PROGRAM [BACKEND=PROGRAM...]\n", .{});
        return exit_usage;
    }
    const text = std.Io.Dir.cwd().readFileAlloc(init.io, arguments[1], arena, .limited(file_bytes_max)) catch |err| {
        try out.print("work_gate: cannot read {s}: {s}\n", .{ arguments[1], @errorName(err) });
        return exit_usage;
    };
    var baseline: work_baseline.Baseline = undefined;
    work_baseline.parse(text, &baseline) catch |err| {
        try out.print("work_gate: {s} is not a baseline: {s}\n", .{ arguments[1], @errorName(err) });
        return exit_usage;
    };
    const counter = find_counter(arena, init.io) orelse {
        try out.print("work_gate: skipped, this machine has no instruction counter the gate can use\n", .{});
        return 0;
    };
    var gate: Gate = .{
        .arena = arena,
        .io = init.io,
        .out = out,
        .counter = counter,
        .tolerance_percent = baseline.tolerance_percent,
    };
    for (arguments[2..]) |argument| {
        const equals = std.mem.indexOfScalar(u8, argument, '=') orelse return exit_usage;
        const key = try std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{
            @tagName(builtin.os.tag), @tagName(builtin.cpu.arch), argument[0..equals],
        });
        const outcome = gate_one(&gate, key, argument[equals + 1 ..], baseline.find(key)) catch |err| {
            try out.print("work_gate: {s} failed: {s}\n", .{ key, @errorName(err) });
            return exit_usage;
        };
        if (outcome == .no_count) return 0;
    }
    return if (gate.failed) exit_failed else 0;
}

const Outcome = enum { counted, no_count };

/// Counts every workload of one program and judges it against `section`, or prints the section
/// to add when there is none.
fn gate_one(gate: *Gate, key: []const u8, program: []const u8, section: ?*const work_baseline.Section) !Outcome {
    try gate.out.print("work_gate: {s}, counted with {s}\n", .{ key, gate.counter.name() });
    if (section == null) try gate.out.print("no section for it in the baseline; add these lines:\nsection {s}\n", .{key});
    for (workloads) |workload| {
        const expected: ?u64 = if (section) |known| known.find(workload.name) else null;
        if (section != null and expected == null) continue;
        const measured = try per_iteration(gate, program, workload) orelse continue;
        if (measured == 0) {
            try gate.out.print("work_gate: skipped, this machine reports no instructions\n", .{});
            return .no_count;
        }
        const baseline = expected orelse {
            try gate.out.print("{s} {d}\n", .{ workload.name, measured });
            continue;
        };
        try judge_one(gate, workload.name, baseline, measured);
    }
    return .counted;
}

fn judge_one(gate: *Gate, workload: []const u8, baseline: u64, measured: u64) !void {
    const verdict = work_baseline.judge(baseline, measured, gate.tolerance_percent);
    const text = switch (verdict) {
        .within => "within the tolerance",
        .over => "OVER the tolerance: rotor does more work per iteration than the baseline",
        .under => "under the tolerance: lower the baseline to the measured count",
    };
    try gate.out.print("{s}: baseline {d}, measured {d}: {s}\n", .{ workload, baseline, measured, text });
    if (verdict == .over) gate.failed = true;
}

/// The instructions one iteration of `workload` runs, or null when the program cannot run it.
fn per_iteration(gate: *Gate, program: []const u8, workload: Workload) !?u64 {
    const span = switch (gate.counter) {
        .time => workload.time_span,
        .cachegrind => workload.cachegrind_span,
    };
    const short = try count(gate, program, workload.name, short_iterations) orelse return null;
    const long = try count(gate, program, workload.name, short_iterations + span) orelse return null;
    if (long < short) return error.CountShrank;
    return (long - short + span / 2) / span;
}

/// The instructions one run of `program` counted, or null when it cannot run `workload`.
fn count(gate: *Gate, program: []const u8, workload: []const u8, iterations: u64) !?u64 {
    const iterations_text = try std.fmt.allocPrint(gate.arena, "{d}", .{iterations});
    const argv: []const []const u8 = switch (gate.counter) {
        .time => &.{ "/usr/bin/time", "-l", program, workload, iterations_text },
        .cachegrind => &.{
            "valgrind", "--tool=cachegrind", "--cache-sim=no", "--cachegrind-out-file=/dev/null",
            program,    workload,            iterations_text,
        },
    };
    const run = try std.process.run(gate.arena, gate.io, .{
        .argv = argv,
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    });
    switch (run.term) {
        .exited => |code| {
            if (code == unsupported_status) return null;
            if (code != 0) return error.ProgramFailed;
        },
        else => return error.ProgramFailed,
    }
    return switch (gate.counter) {
        // A virtual Mac, such as GitHub's macOS runners, prints no line of instructions at all. It
        // counts as none, and the gate skips.
        .time => time_instructions(run.stderr) orelse 0,
        .cachegrind => cachegrind_instructions(run.stderr),
    } orelse error.NoCountInOutput;
}

/// The counter this machine has: `/usr/bin/time` on macOS, Valgrind on Linux when it runs.
fn find_counter(arena: std.mem.Allocator, io: std.Io) ?Counter {
    if (builtin.os.tag.isDarwin()) return .time;
    if (builtin.os.tag != .linux) return null;
    const run = std.process.run(arena, io, .{
        .argv = &.{ "valgrind", "--version" },
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
    }) catch return null;
    return switch (run.term) {
        .exited => |code| if (code == 0) .cachegrind else null,
        else => null,
    };
}

/// The count `/usr/bin/time -l` prints on the line that ends `instructions retired`.
fn time_instructions(output: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "instructions retired") == null) continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const number = words.next() orelse return null;
        return std.fmt.parseInt(u64, number, 10) catch null;
    }
    return null;
}

/// The count cachegrind prints after `I refs:`, whose digits it groups with commas.
fn cachegrind_instructions(output: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, " I ") == null) continue;
        const marker = std.mem.indexOf(u8, line, "refs:") orelse continue;
        return grouped_number(line[marker + "refs:".len ..]);
    }
    return null;
}

/// The number `text` starts with after any spaces, its digits grouped with commas, or null when it
/// starts with none.
fn grouped_number(text: []const u8) ?u64 {
    var total: u64 = 0;
    var digits: usize = 0;
    for (text) |character| {
        if (character == ',' or character == ' ') continue;
        if (character < '0' or character > '9') break;
        total = total * 10 + (character - '0');
        digits += 1;
    }
    return if (digits == 0) null else total;
}

test {
    _ = work_baseline;
}

const testing = std.testing;

test "a count over the tolerance fails the gate, and one within or under it does not" {
    var buffer: [output_buffer_bytes]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var gate: Gate = .{
        .arena = testing.allocator,
        .io = testing.io,
        .out = &out,
        .counter = .time,
        .tolerance_percent = 2,
    };
    try judge_one(&gate, "post", 1000, 1020);
    try judge_one(&gate, "post", 1000, 900);
    try testing.expect(!gate.failed);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "lower the baseline") != null);
    try judge_one(&gate, "timer", 1000, 1021);
    try testing.expect(gate.failed);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "timer: baseline 1000, measured 1021: OVER") != null);
}

test "the count is read from /usr/bin/time and from cachegrind as each prints it" {
    const time_output =
        \\        0.01 real         0.00 user         0.00 sys
        \\             1261568  maximum resident set size
        \\            12345678  instructions retired
        \\             9876543  cycles elapsed
    ;
    try testing.expectEqual(@as(?u64, 12345678), time_instructions(time_output));
    try testing.expectEqual(@as(?u64, null), time_instructions("0.01 real\n"));
    const cachegrind_output =
        \\==4242== Cachegrind, a high-precision tracing profiler
        \\==4242==
        \\==4242== I refs:        24,681,012
    ;
    try testing.expectEqual(@as(?u64, 24681012), cachegrind_instructions(cachegrind_output));
    try testing.expectEqual(@as(?u64, 7), cachegrind_instructions("==1== I   refs:      7\n"));
    try testing.expectEqual(@as(?u64, null), cachegrind_instructions("==1== D refs: 5\n"));
}
