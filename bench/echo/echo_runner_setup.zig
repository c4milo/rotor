//! What the echo runner is asked to do: the candidate table, the options, the defaults, and the
//! question "does this candidate run here". `echo_runner.zig` owns the measuring.
//!
//! Split from it on 2026-09-22, when the two together passed the 500-line limit of CLAUDE.md.
const std = @import("std");
const harness = @import("harness");
const testing = std.testing;

const Result = harness.report.Result;

/// The workloads this runner drives. Both use the same servers, so a candidate needs no line per
/// workload: the storm opens and closes connections where echo keeps them.
pub const Workload = enum { echo, storm };

pub const Candidate = struct {
    name: []const u8,
    program: []const u8,
    version: []const u8,
    /// Arguments after the port.
    arguments: []const []const u8 = &.{},
    /// True for a candidate whose backend only exists on Linux: `std.Io.Uring` is the one.
    linux_only: bool = false,
    /// Why this candidate cannot run at all, or null when it can. `std.Io.Uring` carries one: it
    /// does not compile on the pinned Zig, which `uring_compiles` in its own program and
    /// `bench/alternatives/README.md` also record, and all three change together. Without this the
    /// runner started a program that exits at once, once per round per configuration.
    blocked: ?[]const u8 = null,
    /// Why this candidate does not run the accept storm, or null when it does. The accumulate
    /// shape carries one: it echoes when it holds a whole message, and the storm's message is one
    /// probe byte against a 4 KiB buffer, so the server never replies and the run stalls. Six runs
    /// died that way on 2026-09-22 before this field existed. The storm measures what an accept
    /// costs, which both rotor shapes pay the same way, so the row carried nothing either.
    storm_blocked: ?[]const u8 = null,
    /// True when the server takes `--buffer-bytes`, which the runner sets to the payload. rotor
    /// picks a buffer from a pool, so its buffer is a choice; libuv, libxev and `std.Io` each
    /// hold 64 KiB per connection and have nothing to set. A comparison of a rotor sized for
    /// 8 KiB against candidates holding 64 KiB measured the sizing and not the loops: the
    /// 64 KiB rows halved, and `bench/alternatives/README.md` records it.
    takes_buffer_bytes: bool = false,
};

pub const candidates = [_]Candidate{
    .{
        .name = "rotor",
        .program = "rotor_echo",
        .version = "this tree",
        .takes_buffer_bytes = true,
    },
    // rotor's second shape, which `rotor_echo.zig` calls the experiment: a receive into this
    // connection's own buffer, re-armed until a whole message has arrived, then one send. The
    // default shape takes a whole buffer of a provided group per completion, so a message TCP
    // delivers in pieces is echoed with one send per piece. libuv, libxev and `std.Io` each hold a
    // buffer per connection and accumulate, so this is the shape that compares like for like, and
    // the pair says whether the 64 KiB rows are the loop or the reads.
    .{
        .name = "rotor (accumulate)",
        .program = "rotor_echo",
        .version = "this tree",
        .arguments = &.{ "--shape", "accumulate" },
        .takes_buffer_bytes = true,
        .storm_blocked = "it echoes a whole message, and the storm's message is one byte",
    },
    .{
        .name = "libuv",
        .program = "libuv_echo",
        .version = "v1.52.1",
        .arguments = &.{ "--buffers", "one" },
    },
    .{ .name = "libxev", .program = "libxev_echo", .version = "9ce8e8e" },
    .{
        .name = "std.Io.Threaded",
        .program = "std_io_echo",
        .version = "0.16.0",
        .arguments = &.{ "--backend", "threaded" },
    },
    .{
        .name = "std.Io.Uring",
        .blocked = "it does not compile on the pinned Zig",
        .program = "std_io_echo",
        .version = "0.16.0",
        .arguments = &.{ "--backend", "uring" },
        .linux_only = true,
    },
};

/// Runs of each candidate per configuration. `harness.series` needs at least `runs_min`.
pub const rounds_default: u32 = 3;
pub const rounds_max: u32 = harness.series.runs_max;

pub const seconds_default: u64 = 4;
pub const warmup_seconds_default: u64 = 1;

/// The first port, which `--port-base` moves. Every run takes the next one, so a socket left in
/// TIME_WAIT by one run never collides with the next. The gate of `zig build test` is given a
/// base of its own, so a comparison a person is running by hand and the gate cannot meet on a
/// port.
pub const port_first_default: u16 = 20000;

/// How long a server is given to print its ready line before the runner gives up on it.
pub const ready_wait_ns: u64 = 5 * std.time.ns_per_s;

/// Where the servers are, under the install prefix.
pub const directory_default = "zig-out/bin";

pub const connections_default = [_]u32{ 16, 64 };
/// The one entry the storm uses, because its message is one byte.
pub const payloads_storm = [_]u32{4096};
/// The payload sizes a comparison walks by default. Four, so a regression baseline sees the shape
/// of the curve and not two points on it: rotor leads at 4 KiB and trails libxev at 64 KiB
/// (`bench/alternatives/README.md`), and 8 and 16 KiB are where that crossover has to live.
pub const payloads_default = [_]u32{ 4096, 8192, 16384, 65536 };

/// Configurations and candidates together, which bounds every array below.
pub const configurations_max = 8;
pub const results_max = rounds_max * candidates.len;

pub const Options = struct {
    /// The baseline to hold this run to, or null to report and gate nothing.
    baseline_path: ?[]const u8 = null,
    /// Print each row in the baseline's own format instead of gating, which is how one is taken.
    write_baseline: bool = false,
    rounds: u32 = rounds_default,
    seconds: u64 = seconds_default,
    warmup_seconds: u64 = warmup_seconds_default,
    /// When set, only the candidates named here run. `zig build test`'s smoke run names rotor
    /// alone, so the gate needs no pinned alternative.
    only: []const u8 = "",
    port_base: u16 = port_first_default,
    workload: Workload = .echo,
    directory: []const u8 = directory_default,
    connections: []const u32 = &connections_default,
    payloads: []const u32 = &payloads_default,
};

pub var results: [results_max]Result = undefined;
pub var connections_buffer: [configurations_max]u32 = undefined;
pub var payloads_buffer: [configurations_max]u32 = undefined;

var path_buffer: [candidates.len][std.fs.max_path_bytes]u8 = undefined;

pub fn program_path(options: Options, candidate: Candidate, slot: usize) ![]const u8 {
    const buffer = &path_buffer[slot];
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ options.directory, candidate.program });
}

var present_candidates: [candidates.len]bool = @splat(false);

pub fn installed(options: Options, index: usize) bool {
    if (!present_candidates[index]) return false;
    return wanted(options, candidates[index].name);
}

/// True when `--candidates` was not given, or names this candidate.
pub fn wanted(options: Options, name: []const u8) bool {
    if (options.only.len == 0) return true;
    var pieces = std.mem.splitScalar(u8, options.only, ',');
    while (pieces.next()) |piece| {
        if (std.mem.eql(u8, piece, name)) return true;
    }
    return false;
}

/// Why this candidate does not run `workload`, or null when it runs it. Both reasons print the
/// same line, because a reader of the table needs the same thing from either: the row is absent
/// and this is why.
pub fn unavailable(candidate: Candidate, workload: Workload) ?[]const u8 {
    if (candidate.blocked) |reason| return reason;
    if (workload == .storm) return candidate.storm_blocked;
    return null;
}

/// Marks every candidate whose program is on disk, names the ones that are not, and returns how
/// many are there.
pub fn found(init: std.process.Init, options: Options, writer: *std.Io.Writer) !u32 {
    var count: u32 = 0;
    for (candidates, 0..) |candidate, index| {
        if (!wanted(options, candidate.name)) {
            present_candidates[index] = false;
            continue;
        }
        if (candidate.linux_only and @import("builtin").os.tag != .linux) {
            present_candidates[index] = false;
            try writer.print("echo_runner: {s} runs on Linux alone, skipping it\n", .{
                candidate.name,
            });
            continue;
        }
        if (unavailable(candidate, options.workload)) |reason| {
            present_candidates[index] = false;
            try writer.print("echo_runner: {s} is not run: {s}\n", .{ candidate.name, reason });
            continue;
        }
        const path = try program_path(options, candidate, index);
        const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch {
            present_candidates[index] = false;
            try writer.print(
                "echo_runner: {s} is not installed at {s}, skipping it\n",
                .{ candidate.name, path },
            );
            continue;
        };
        file.close(init.io);
        present_candidates[index] = true;
        count += 1;
    }
    return count;
}

/// Reads a comma-separated list of counts into `buffer`.
pub fn candidate_named(name: []const u8) ?Candidate {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

test "the accumulate shape runs echo and not the storm, and the default shape runs both" {
    const accumulate = candidate_named("rotor (accumulate)") orelse return error.NoCandidate;
    try testing.expect(unavailable(accumulate, .echo) == null);
    // Without this the storm stalls: the shape waits for a whole message and gets one byte.
    try testing.expect(unavailable(accumulate, .storm) != null);

    // The storm still has a rotor row, so removing the one above loses no workload.
    const default_shape = candidate_named("rotor") orelse return error.NoCandidate;
    try testing.expect(unavailable(default_shape, .echo) == null);
    try testing.expect(unavailable(default_shape, .storm) == null);
}

test "a candidate blocked outright is blocked in every workload" {
    const blocked = candidate_named("std.Io.Uring") orelse return error.NoCandidate;
    try testing.expect(blocked.blocked != null);
    try testing.expect(unavailable(blocked, .echo) != null);
    try testing.expect(unavailable(blocked, .storm) != null);
}
