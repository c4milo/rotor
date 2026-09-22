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
//! experiment that made this necessary is in `bench/alternatives/README.md`: three rounds of two
//! shapes of one unchanged server disagreed about which was faster.
//!
//! A candidate whose server is not installed is skipped and named, because `libuv_echo` and
//! `libxev_echo` come from `zig build bench-alternatives`, which fetches and builds two libraries
//! and is not part of `zig build test`.
//!
//! **Every candidate runs one loop, unpinned.** Decision 19 withdrew the core sweep and the skewed
//! rows: neither libuv nor libxev spreads TCP load across cores on kqueue, so an N-core row would set rotor's
//! loops against an alternative's one and measure the thread count. `rotor_echo` still takes `--cpu`
//! and `--loops` for a person running it by hand; this runner passes neither.
//!
//! Every row carries the count of its runs and their spread, and `harness.series` marks a row
//! whose runs disagree too much to decide anything. A comparison whose rows are all marked has
//! measured the machine, not the candidates.
const std = @import("std");
const harness = @import("harness");
const client = @import("client.zig");
const storm = @import("storm.zig");
const setup = @import("echo_runner_setup.zig");

const Candidate = setup.Candidate;
const candidates = setup.candidates;
const Options = setup.Options;
const Workload = setup.Workload;
const found = setup.found;
const installed = setup.installed;
const program_path = setup.program_path;
const payloads_storm = setup.payloads_storm;
const ready_wait_ns = setup.ready_wait_ns;
const rounds_max = setup.rounds_max;

const Result = harness.report.Result;
const Series = harness.series.Series;
const OtherWork = harness.other_work.Window;

/// Candidates this runner knows. Each is a program that takes a port and listens on it, and each
/// prints one line when it is ready, which this runner waits for.
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
    var rowless: u32 = 0;
    // The storm's message is one byte by definition, so it runs each connection count once and
    // ignores the payload list.
    const payloads = if (options.workload == .storm) payloads_storm[0..] else options.payloads;
    for (options.connections) |connection_count| {
        for (payloads) |payload_bytes| {
            port = try one_configuration(init, options, .{
                .connections = connection_count,
                .payload_bytes = payload_bytes,
            }, port, writer, &rowless);
        }
    }
    try writer.flush();
    if (rowless != 0) return error.CandidateProducedNoRow;
}

const Configuration = struct { connections: u32, payload_bytes: u32 };

/// The smallest and largest buffer `rotor_echo` takes. Named here because the runner asks for
/// one, and asking for a buffer the server refuses fails the run: the gate did exactly that with
/// a 1 KiB payload.
const buffer_bytes_min: u32 = 2048;
const buffer_bytes_max: u32 = 64 * 1024;

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
    /// Rises once per candidate this configuration selected and could not produce a row for. A run
    /// that measured nothing must not exit 0: the smoke gate would pass on a runner that failed
    /// every run, which is what it exists to catch.
    rowless: *u32,
) !u16 {
    var counts: [candidates.len]u32 = @splat(0);
    // The other work on the machine while each candidate's runs were taken. One window per candidate, and one
    // set per configuration, because a row covers one configuration.
    var other_work: [candidates.len]OtherWork = @splat(.empty);
    var port = port_from;
    var round: u32 = 0;
    while (round < options.rounds) : (round += 1) {
        for (candidates, 0..) |candidate, index| {
            if (!installed(options, index)) continue;
            port += 1;
            // Around the run, not before the round: a job that arrives part way through a matrix is
            // what spoiled the 2026-09-20 attempts, and only a reading on each side sees it.
            other_work[index].begin_run(init.io);
            defer other_work[index].end_run(init.io);
            const measured = one_run(init, options, candidate, configuration, port) catch |x| {
                try writer.print("echo_runner: {s} failed: {t}\n", .{ candidate.name, x });
                try writer.flush();
                continue;
            };
            setup.results[index * rounds_max + counts[index]] = measured;
            counts[index] += 1;
        }
    }

    for (candidates, 0..) |candidate, index| {
        const taken = setup.results[index * rounds_max ..][0..counts[index]];
        if (taken.len < harness.series.runs_min) {
            if (installed(options, index)) {
                try writer.print("echo_runner: {s} has too few runs\n", .{candidate.name});
                rowless.* += 1;
            }
            continue;
        }
        const series = try Series.init_with_other_work(taken, other_work[index]);
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
    // withdrew the core sweep: neither libuv nor libxev spreads TCP load across cores on kqueue, so an N-core
    // row would compare rotor's loops against an alternative's one. `rotor_echo` still takes both
    // options for a person running it by hand.
    const argv = argv_buffer[0..used];

    var child = try std.process.spawn(init.io, .{
        .argv = argv,
        .stdout = .ignore,
        // The peak memory of the candidate's own process, which `wait4` reports when the child is
        // reaped. Without this the memory column has nothing to read.
        .request_resource_usage_statistics = true,
    });
    // `kill` terminates the child, waits for it and frees what it held, and does nothing when
    // called again, so it is the whole of the cleanup. A `wait` after it would halt: `wait`
    // requires a child that is still there. The success path kills the child itself, because the
    // memory it used is only readable once it has been reaped; this covers every other path.
    var reaped = false;
    defer if (!reaped) child.kill(init.io);

    // The server needs a moment to bind before the client connects. Its ready line goes to
    // `ignore`, so the runner waits instead of reading it: a pipe the runner never drains would
    // stop a server that printed more than its buffer.
    const ready: std.Io.Clock.Duration = .{
        .raw = .{ .nanoseconds = ready_wait_ns / 5 },
        .clock = .awake,
    };
    ready.sleep(init.io) catch {};

    var measured = switch (options.workload) {
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

    // Reaped here and not in the defer, so the peak memory is readable before this returns.
    //
    // Signalled and then waited for, rather than through `kill`: `kill` reaps the child without
    // collecting its resource usage, so the memory column read 0 for every candidate when it was
    // written that way (2026-09-22). `wait` collects it, and every server here documents SIGTERM
    // as its stop and installs no handler for it. A host that reports nothing leaves the field 0,
    // which the table prints as it is: a number nobody measured is not worth inventing.
    if (child.id) |id| std.posix.kill(id, std.posix.SIG.TERM) catch {};
    _ = child.wait(init.io) catch {};
    reaped = true;
    const reported = child.resource_usage_statistics.getMaxRss();
    // The standard library fills this from `wait4` on both targets this harness runs on, so a null
    // here is the runner asking wrong and not the host declining. It asked wrong until 2026-09-22,
    // reaping with `kill`, and every memory cell read 0; refusing is what makes the smoke gate
    // notice if that comes back.
    if (memory_reported_here and reported == null) return error.MemoryNotReported;
    measured.peak_rss_bytes = reported orelse 0;
    return measured;
}

/// Whether this host reports a child's peak memory. Both targets of this harness do, through
/// `wait4`; a host that does not leaves every memory cell 0 rather than failing a run.
const memory_reported_here = switch (@import("builtin").os.tag) {
    .linux, .macos => true,
    else => false,
};

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
        options.connections = try parse_list(value, &setup.connections_buffer);
    } else if (std.mem.eql(u8, name, "--payloads")) {
        options.payloads = try parse_list(value, &setup.payloads_buffer);
    } else {
        return error.UnknownArgument;
    }
}

// Tests. `build/bench.zig` names this file in `tested`, so these run under `zig build test`.

const testing = std.testing;
