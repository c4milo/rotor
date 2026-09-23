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
    /// True when the server takes `--group-buffers`, which the runner sets from the connections
    /// with `group_buffers_for`. rotor's group shape draws from a pool, and on io_uring the pool's
    /// size is what it cycles through: the whole 64 MiB made every echo land in cold memory, and
    /// halved the shape's rate on `orbstack` (`bench/alternatives/README.md`). The other candidates
    /// hold a buffer per connection, so the pool is sized per connection too.
    takes_group_buffers: bool = false,
};

/// One configuration of a comparison: how many connections, and how large a message.
pub const Configuration = struct { connections: u32, payload_bytes: u32 };

/// The smallest and largest buffer `rotor_echo` takes. Named here because the runner asks for
/// one, and asking for a buffer the server refuses fails the run: the gate did exactly that with
/// a 1 KiB payload.
const buffer_bytes_min: u32 = 2048;
const buffer_bytes_max: u32 = 64 * 1024;

/// The buffer a candidate is given for `payload_bytes`: the payload where it can be, so a whole
/// message costs one send, and the nearest the server accepts otherwise.
pub fn buffer_bytes_for(payload_bytes: u32) u32 {
    const whole = std.math.ceilPowerOfTwoAssert(u32, payload_bytes);
    return std.math.clamp(whole, buffer_bytes_min, buffer_bytes_max);
}

/// The most arguments a server is started with: the program, the port, a candidate's own two, and
/// two pairs the runner sets.
const server_arguments_max = 10;

/// A server's command line, with the numbers it prints held beside it so they live as long as it.
///
/// No `--cpu` and no `--loops`. Every candidate runs one loop, unpinned, because decision 19
/// withdrew the core sweep: neither libuv nor libxev spreads TCP load across cores on kqueue, so
/// an N-core row would compare rotor's loops against an alternative's one. `rotor_echo` still
/// takes both options for a person running it by hand.
pub const ServerCommand = struct {
    argv: [server_arguments_max][]const u8,
    port_text: [8]u8,
    buffer_text: [16]u8,
    group_text: [16]u8,

    /// The command line of `candidate`'s server at `program`, on `port`, for `configuration`.
    pub fn fill(
        command: *ServerCommand,
        program: []const u8,
        candidate: Candidate,
        configuration: Configuration,
        port: u16,
    ) ![]const []const u8 {
        std.debug.assert(candidate.arguments.len + 6 <= server_arguments_max);
        command.argv[0] = program;
        command.argv[1] = try std.fmt.bufPrint(&command.port_text, "{d}", .{port});
        var used: usize = 2;
        for (candidate.arguments) |argument| {
            command.argv[used] = argument;
            used += 1;
        }
        if (candidate.takes_buffer_bytes) {
            command.argv[used] = "--buffer-bytes";
            command.argv[used + 1] = try std.fmt.bufPrint(&command.buffer_text, "{d}", .{
                buffer_bytes_for(configuration.payload_bytes),
            });
            used += 2;
        }
        if (candidate.takes_group_buffers) {
            command.argv[used] = "--group-buffers";
            command.argv[used + 1] = try std.fmt.bufPrint(&command.group_text, "{d}", .{
                group_buffers_for(configuration.connections),
            });
            used += 2;
        }
        return command.argv[0..used];
    }
};

/// Buffers per connection in rotor's group: a message TCP delivers in two pieces holds two buffers
/// until both sends complete, and a connection has one message in flight.
pub const group_buffers_per_connection: u32 = 2;

/// The fewest buffers a group is given, so a run with a handful of connections still has room for
/// a burst. At 64 KiB they are 2 MiB, which stayed warm on `orbstack`.
pub const group_buffers_min: u32 = 32;

/// The buffers rotor's group gets for `connections`: two per connection, rounded up to the power of
/// two a buffer ring's size must be, and never fewer than `group_buffers_min`.
pub fn group_buffers_for(connections: u32) u32 {
    std.debug.assert(connections >= 1);
    const needed = @max(connections * group_buffers_per_connection, group_buffers_min);
    return std.math.ceilPowerOfTwoAssert(u32, needed);
}

pub const candidates = [_]Candidate{
    .{
        .name = "rotor",
        .program = "rotor_echo",
        .version = "this tree",
        .takes_buffer_bytes = true,
        .takes_group_buffers = true,
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

test "rotor's group is sized per connection, a power of two, and never below its floor" {
    try testing.expectEqual(@as(u32, 32), group_buffers_for(1));
    try testing.expectEqual(@as(u32, 32), group_buffers_for(16));
    try testing.expectEqual(@as(u32, 128), group_buffers_for(64));
    try testing.expectEqual(@as(u32, 512), group_buffers_for(256));
    // Not a power of two after doubling: rounded up, never down, so no connection goes short.
    try testing.expectEqual(@as(u32, 64), group_buffers_for(17));
    // Only the group shape draws from the group; the accumulate shape holds its own buffers.
    const group_shape = candidate_named("rotor") orelse return error.NoCandidate;
    try testing.expect(group_shape.takes_group_buffers);
    const accumulate = candidate_named("rotor (accumulate)") orelse return error.NoCandidate;
    try testing.expect(!accumulate.takes_group_buffers);
}

test "rotor's server is started with its group sized by the connections, and libxev's is not" {
    const configuration: Configuration = .{ .connections = 64, .payload_bytes = 65536 };
    var command: ServerCommand = undefined;
    const group_shape = candidate_named("rotor") orelse return error.NoCandidate;
    const rotor_argv = try command.fill("rotor_echo", group_shape, configuration, 31001);
    const expected = [_][]const u8{
        "rotor_echo", "31001", "--buffer-bytes", "65536", "--group-buffers", "128",
    };
    try testing.expectEqual(expected.len, rotor_argv.len);
    for (expected, rotor_argv) |want, got| try testing.expectEqualStrings(want, got);

    const libxev = candidate_named("libxev") orelse return error.NoCandidate;
    const libxev_argv = try command.fill("libxev_echo", libxev, configuration, 31002);
    try testing.expectEqual(@as(usize, 2), libxev_argv.len);
    try testing.expectEqualStrings("31002", libxev_argv[1]);
}

test "a candidate blocked outright is blocked in every workload" {
    const blocked = candidate_named("std.Io.Uring") orelse return error.NoCandidate;
    try testing.expect(blocked.blocked != null);
    try testing.expect(unavailable(blocked, .echo) != null);
    try testing.expect(unavailable(blocked, .storm) != null);
}
