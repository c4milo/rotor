//! echo_runner: the comparison of milestone 4's echo workload. It starts each candidate's server
//! in turn, drives it with the one client, and prints a row per candidate with the spread of its
//! runs beside the median.
//!
//! Run:  echo_runner [--workload echo|storm] [--rounds N] [--seconds S] [--warmup S]
//!                   [--connections A,B,C] [--payloads A,B] [--candidates NAME,NAME]
//!                   [--port-base N] [--directory PATH]
//!
//! The order is the point. For every configuration it runs round 1 of every candidate, then round
//! 2 of every candidate, and so on, rather than all the rounds of one candidate and then the
//! next. A machine that speeds up or slows down during the run then moves every candidate
//! together, instead of moving whichever candidate held the machine while it drifted. The
//! experiment that made this necessary is in `bench/competitors/README.md`: three rounds of two
//! shapes of one unchanged server disagreed about which was faster.
//!
//! A candidate whose server is not installed is skipped and named, because `libuv_echo` and
//! `libxev_echo` come from `zig build bench-competitors`, which fetches and builds two libraries
//! and is not part of `zig build test`.
//!
//! **Every candidate runs one loop, unpinned.** Decision 19 withdrew the core sweep and the skewed
//! rows: no competitor spreads TCP load across cores on kqueue, so an N-core row would set rotor's
//! loops against a competitor's one and measure the thread count. `rotor_echo` still takes `--cpu`
//! and `--loops` for a person running it by hand; this runner passes neither.
//!
//! Every row carries the count of its runs and their spread, and `harness.series` marks a row
//! whose runs disagree too much to decide anything. A comparison whose rows are all marked has
//! measured the machine, not the candidates.
const std = @import("std");
const harness = @import("harness");
const client = @import("client.zig");
const storm = @import("storm.zig");

const Result = harness.report.Result;
const Series = harness.series.Series;
const LoadWindow = harness.load.Window;

/// Candidates this runner knows. Each is a program that takes a port and listens on it, and each
/// prints one line when it is ready, which this runner waits for.
const Candidate = struct {
    name: []const u8,
    program: []const u8,
    version: []const u8,
    /// Arguments after the port.
    arguments: []const []const u8 = &.{},
    /// True for a candidate whose backend only exists on Linux: `std.Io.Uring` is the one.
    linux_only: bool = false,
    /// True when the server takes `--buffer-bytes`, which the runner sets to the payload. rotor
    /// picks a buffer from a pool, so its buffer is a choice; libuv, libxev and `std.Io` each
    /// hold 64 KiB per connection and have nothing to set. A comparison of a rotor sized for
    /// 8 KiB against candidates holding 64 KiB measured the sizing and not the loops: the
    /// 64 KiB rows halved, and `bench/competitors/README.md` records it.
    takes_buffer_bytes: bool = false,
};

const candidates = [_]Candidate{
    .{
        .name = "rotor",
        .program = "rotor_echo",
        .version = "this tree",
        .takes_buffer_bytes = true,
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
        .program = "std_io_echo",
        .version = "0.16.0",
        .arguments = &.{ "--backend", "uring" },
        .linux_only = true,
    },
};

/// Runs of each candidate per configuration. `harness.series` needs at least `runs_min`.
const rounds_default: u32 = 3;
const rounds_max: u32 = harness.series.runs_max;

const seconds_default: u64 = 4;
const warmup_seconds_default: u64 = 1;

/// The first port, which `--port-base` moves. Every run takes the next one, so a socket left in
/// TIME_WAIT by one run never collides with the next. The gate of `zig build test` is given a
/// base of its own, so a comparison a person is running by hand and the gate cannot meet on a
/// port.
const port_first_default: u16 = 20000;

/// How long a server is given to print its ready line before the runner gives up on it.
const ready_wait_ns: u64 = 5 * std.time.ns_per_s;

/// Where the servers are, under the install prefix.
const directory_default = "zig-out/bin";

const connections_default = [_]u32{ 16, 64 };
/// The one entry the storm uses, because its message is one byte.
const payloads_storm = [_]u32{4096};
const payloads_default = [_]u32{ 4096, 65536 };

/// Configurations and candidates together, which bounds every array below.
const configurations_max = 8;
const results_max = rounds_max * candidates.len;

const Options = struct {
    rounds: u32 = rounds_default,
    seconds: u64 = seconds_default,
    warmup_seconds: u64 = warmup_seconds_default,
    /// When set, only the candidates named here run. `zig build test`'s smoke run names rotor
    /// alone, so the gate needs no pinned competitor.
    only: []const u8 = "",
    port_base: u16 = port_first_default,
    workload: Workload = .echo,
    directory: []const u8 = directory_default,
    connections: []const u32 = &connections_default,
    payloads: []const u32 = &payloads_default,
};

var results: [results_max]Result = undefined;
var connections_buffer: [configurations_max]u32 = undefined;
var payloads_buffer: [configurations_max]u32 = undefined;
var path_buffer: [candidates.len][std.fs.max_path_bytes]u8 = undefined;

const output_buffer_bytes = 8192;

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;

    const present = try found(init, options, writer);
    if (present == 0) {
        try writer.writeAll("echo_runner: no candidate is installed; run `zig build bench-echo`\n");
        try writer.flush();
        return error.NoCandidate;
    }

    try writer.writeAll(harness.series.markdown_header);
    try writer.flush();
    var port = options.port_base;
    // The storm's message is one byte by definition, so it runs each connection count once and
    // ignores the payload list.
    const payloads = if (options.workload == .storm) payloads_storm[0..] else options.payloads;
    for (options.connections) |connection_count| {
        for (payloads) |payload_bytes| {
            port = try one_configuration(init, options, .{
                .connections = connection_count,
                .payload_bytes = payload_bytes,
            }, port, writer);
        }
    }
    try writer.flush();
}

const Configuration = struct { connections: u32, payload_bytes: u32 };

/// The smallest and largest buffer `rotor_echo` takes. Named here because the runner asks for
/// one, and asking for a buffer the server refuses fails the run: the gate did exactly that with
/// a 1 KiB payload.
const buffer_bytes_min: u32 = 2048;
const buffer_bytes_max: u32 = 64 * 1024;

/// The workloads this runner drives. Both use the same servers, so a candidate needs no line
/// per workload: the storm opens and closes connections where echo keeps them.
const Workload = enum { echo, storm };

/// The buffer a candidate is given for `payload_bytes`: the payload where it can be, so a whole
/// message costs one send, and the nearest the server accepts otherwise.
fn buffer_bytes_for(payload_bytes: u32) u32 {
    const whole = std.math.ceilPowerOfTwoAssert(u32, payload_bytes);
    return std.math.clamp(whole, buffer_bytes_min, buffer_bytes_max);
}

/// One configuration: every candidate, `rounds` times, alternating.
fn one_configuration(
    init: std.process.Init,
    options: Options,
    configuration: Configuration,
    port_from: u16,
    writer: *std.Io.Writer,
) !u16 {
    var counts: [candidates.len]u32 = @splat(0);
    // The machine's load while each candidate's runs were taken. One window per candidate, and one
    // set per configuration, because a row covers one configuration.
    var loads: [candidates.len]LoadWindow = @splat(.empty);
    var port = port_from;
    var round: u32 = 0;
    while (round < options.rounds) : (round += 1) {
        for (candidates, 0..) |candidate, index| {
            if (!installed(options, index)) continue;
            port += 1;
            // Around the run, not before the round: a job that arrives part way through a matrix is
            // what spoiled the 2026-09-20 attempts, and only a sample on each side sees it.
            loads[index].sample();
            defer loads[index].sample();
            const measured = one_run(init, options, candidate, configuration, port) catch |x| {
                try writer.print("echo_runner: {s} failed: {t}\n", .{ candidate.name, x });
                try writer.flush();
                continue;
            };
            results[index * rounds_max + counts[index]] = measured;
            counts[index] += 1;
        }
    }

    for (candidates, 0..) |candidate, index| {
        const taken = results[index * rounds_max ..][0..counts[index]];
        if (taken.len < harness.series.runs_min) {
            if (installed(options, index)) {
                try writer.print("echo_runner: {s} has too few runs\n", .{candidate.name});
            }
            continue;
        }
        const series = try Series.init_with_load(taken, loads[index]);
        try series.render_markdown_row(writer);
        try writer.writeByte('\n');
    }
    try writer.flush();
    return port;
}

/// Starts `candidate`'s server on `port`, measures it, and stops it.
fn one_run(
    init: std.process.Init,
    options: Options,
    candidate: Candidate,
    configuration: Configuration,
    port: u16,
) !Result {
    var port_text: [8]u8 = undefined;
    const port_written = try std.fmt.bufPrint(&port_text, "{d}", .{port});
    var argv_buffer: [10][]const u8 = undefined;
    argv_buffer[0] = try program_path(options, candidate, 0);
    argv_buffer[1] = port_written;
    var used: usize = 2;
    for (candidate.arguments) |argument| {
        argv_buffer[used] = argument;
        used += 1;
    }
    var buffer_text: [16]u8 = undefined;
    if (candidate.takes_buffer_bytes) {
        argv_buffer[used] = "--buffer-bytes";
        argv_buffer[used + 1] = try std.fmt.bufPrint(&buffer_text, "{d}", .{
            buffer_bytes_for(configuration.payload_bytes),
        });
        used += 2;
    }
    // No `--cpu` and no `--loops`. Every candidate runs one loop, unpinned, because decision 19
    // withdrew the core sweep: no competitor spreads TCP load across cores on kqueue, so an N-core
    // row would compare rotor's loops against a competitor's one. `rotor_echo` still takes both
    // options for a person running it by hand.
    const argv = argv_buffer[0..used];

    var child = try std.process.spawn(init.io, .{ .argv = argv, .stdout = .ignore });
    // `kill` terminates the child, waits for it and frees what it held, and does nothing when
    // called again, so it is the whole of the cleanup. A `wait` after it would halt: `wait`
    // requires a child that is still there.
    defer child.kill(init.io);

    // The server needs a moment to bind before the client connects. Its ready line goes to
    // `ignore`, so the runner waits instead of reading it: a pipe the runner never drains would
    // stop a server that printed more than its buffer.
    const ready: std.Io.Clock.Duration = .{
        .raw = .{ .nanoseconds = ready_wait_ns / 5 },
        .clock = .awake,
    };
    ready.sleep(init.io) catch {};

    const measured = switch (options.workload) {
        .echo => try client.run(.{
            .port = port,
            .connections = configuration.connections,
            .payload_bytes = configuration.payload_bytes,
            .seconds = options.seconds,
            .warmup_seconds = options.warmup_seconds,
            .candidate = candidate.name,
            .version = candidate.version,
        }),
        // A storm is one burst, so it takes no span: what it is given is the burst's size.
        .storm => try storm.run(.{
            .port = port,
            .connections = configuration.connections,
            .candidate = candidate.name,
            .version = candidate.version,
        }),
    };
    return measured;
}

fn program_path(options: Options, candidate: Candidate, slot: usize) ![]const u8 {
    const buffer = &path_buffer[slot];
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ options.directory, candidate.program });
}

var present_candidates: [candidates.len]bool = @splat(false);

fn installed(options: Options, index: usize) bool {
    if (!present_candidates[index]) return false;
    return wanted(options, candidates[index].name);
}

/// True when `--candidates` was not given, or names this candidate.
fn wanted(options: Options, name: []const u8) bool {
    if (options.only.len == 0) return true;
    var pieces = std.mem.splitScalar(u8, options.only, ',');
    while (pieces.next()) |piece| {
        if (std.mem.eql(u8, piece, name)) return true;
    }
    return false;
}

/// Marks every candidate whose program is on disk, names the ones that are not, and returns how
/// many are there.
fn found(init: std.process.Init, options: Options, writer: *std.Io.Writer) !u32 {
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
fn parse_list(text: []const u8, buffer: []u32) ![]const u32 {
    var count: usize = 0;
    var pieces = std.mem.splitScalar(u8, text, ',');
    while (pieces.next()) |piece| {
        if (count == buffer.len) return error.TooManyValues;
        buffer[count] = try std.fmt.parseInt(u32, piece, 10);
        if (buffer[count] == 0) return error.EmptyConfiguration;
        count += 1;
    }
    if (count == 0) return error.EmptyConfiguration;
    return buffer[0..count];
}

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    if (options.rounds < harness.series.runs_min) return error.TooFewRounds;
    if (options.rounds > rounds_max) return error.TooManyRounds;
    return options;
}

/// One `--name value` pair.
fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--rounds")) {
        options.rounds = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--warmup")) {
        options.warmup_seconds = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--workload")) {
        options.workload = std.meta.stringToEnum(Workload, value) orelse
            return error.UnknownWorkload;
    } else if (std.mem.eql(u8, name, "--port-base")) {
        options.port_base = try std.fmt.parseInt(u16, value, 10);
    } else if (std.mem.eql(u8, name, "--candidates")) {
        options.only = value;
    } else if (std.mem.eql(u8, name, "--directory")) {
        options.directory = value;
    } else if (std.mem.eql(u8, name, "--connections")) {
        options.connections = try parse_list(value, &connections_buffer);
    } else if (std.mem.eql(u8, name, "--payloads")) {
        options.payloads = try parse_list(value, &payloads_buffer);
    } else {
        return error.UnknownArgument;
    }
}
