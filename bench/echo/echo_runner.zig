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
const baseline = harness.baseline;

/// Candidates this runner knows. Each is a program that takes a port and listens on it, and each
/// prints one line when it is ready, which this runner waits for.
const output_buffer_bytes = 8192;

pub fn main(init: std.process.Init) !void {
    var options = try parse(init);
    var buffer: [output_buffer_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;

    // A baseline holds one processor's ratios per section, because ratios move with the processor.
    const machine = harness.Machine.collect(init.io);
    const processor = machine.cpu_model.slice();
    var baseline_rows: [baseline.rows_max]baseline.Row = undefined;
    const recorded = try read_baseline(init, options, processor, &baseline_rows, writer);
    // A run the baseline cannot judge prints its ratios instead, so its processor can be added.
    if (options.baseline_path != null and !recorded.found) options.write_baseline = true;
    if (options.write_baseline) try baseline.render_processor(writer, processor);

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
    var regressed: u32 = 0;
    // The storm's message is one byte by definition, so it runs each connection count once and
    // ignores the payload list.
    const payloads = if (options.workload == .storm) payloads_storm[0..] else options.payloads;
    for (options.connections) |connection_count| {
        for (payloads) |payload_bytes| {
            port = try one_configuration(init, options, .{
                .connections = connection_count,
                .payload_bytes = payload_bytes,
            }, port, writer, &rowless, recorded.rows, &regressed);
        }
    }
    if (recorded.found) {
        try writer.print("echo_runner: {d} row(s) fell behind the baseline\n", .{regressed});
    }
    try writer.flush();
    if (rowless != 0) return error.CandidateProducedNoRow;
    if (regressed != 0) return error.BehindBaseline;
}

/// The baseline file's rows for `processor`, and nothing when no `--baseline` was given. The text is
/// read into a buffer this function owns, and the rows borrow it, so both live as long as the
/// process: a run reads its baseline once and holds it.
var baseline_text: [baseline_bytes_max]u8 = undefined;

/// The most bytes a baseline file may hold. `rows_max` rows of a line each, with room to spare.
const baseline_bytes_max = 16 * 1024;

fn read_baseline(
    init: std.process.Init,
    options: Options,
    processor: []const u8,
    into: []baseline.Row,
    writer: *std.Io.Writer,
) !baseline.Section {
    const path = options.baseline_path orelse return .{ .rows = &.{}, .found = false };
    if (processor.len == 0) return error.ProcessorUnknown;
    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var reader = file.reader(init.io, &.{});
    const read = try reader.interface.readSliceShort(&baseline_text);
    if (read == baseline_text.len) return error.BaselineTooLarge;
    const section = try baseline.parse(baseline_text[0..read], processor, into);
    if (!section.found) {
        try writer.print("echo_runner: the baseline holds no rows for {s}, so nothing is gated; " ++
            "the rows below, from `processor` on, are this run's ratios in its format\n", .{processor});
    }
    return section;
}

const Configuration = setup.Configuration;

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
    /// The baseline this run is held to, empty when there is none.
    recorded: []const baseline.Row,
    /// Rises once per row that fell further behind than the baseline allows.
    regressed: *u32,
) !u16 {
    var counts: [candidates.len]u32 = @splat(0);
    // The other work on the machine while each candidate's runs were taken. One window per candidate, and one
    // set per configuration, because a row covers one configuration.
    var other_work: [candidates.len]OtherWork = @splat(.empty);
    var port = port_from;
    var round: u32 = 0;
    while (round < options.rounds) : (round += 1) {
        for (candidates, 0..) |candidate, index| {
            if (!installed(index)) continue;
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

    var built: [candidates.len]?Series = @splat(null);
    try build_series(&counts, &other_work, &built, writer, rowless);
    try render_rows(options, &built, writer, recorded, regressed);
    try writer.flush();
    return port;
}

/// One series per candidate that produced enough runs, and a line naming each that did not. Built
/// before any row is written, because a verdict needs rotor's throughput from this same run and
/// rotor is not always the first candidate the table walks.
fn build_series(
    counts: *const [candidates.len]u32,
    other_work: *const [candidates.len]OtherWork,
    built: *[candidates.len]?Series,
    writer: *std.Io.Writer,
    rowless: *u32,
) !void {
    for (candidates, 0..) |candidate, index| {
        const taken = setup.results[index * rounds_max ..][0..counts[index]];
        if (taken.len < harness.series.runs_min) {
            if (installed(index)) {
                try writer.print("echo_runner: {s} has too few runs\n", .{candidate.name});
                rowless.* += 1;
            }
            continue;
        }
        built[index] = try Series.init_with_other_work(taken, other_work[index]);
    }
}

/// One table row per series, then whatever the baseline has to say about it.
fn render_rows(
    options: Options,
    built: *const [candidates.len]?Series,
    writer: *std.Io.Writer,
    recorded: []const baseline.Row,
    regressed: *u32,
) !void {
    const rotor_per_second = rotor_throughput(built);
    for (built) |maybe| {
        const series = maybe orelse continue;
        try series.render_markdown_row(writer);
        try writer.writeByte('\n');
        if (options.write_baseline and rotor_per_second != 0) {
            try baseline.render_row(writer, @tagName(options.workload), &series, rotor_per_second);
        }
        if (recorded.len != 0) {
            try report_verdict(writer, options, recorded, &series, rotor_per_second, regressed);
        }
    }
}

/// rotor's own throughput from this configuration, which every ratio is taken against, or 0 when
/// rotor produced no row. The default shape is the baseline and not the accumulate one: two rotor
/// rows would otherwise each be measured against whichever came first.
fn rotor_throughput(built: *const [candidates.len]?Series) u64 {
    for (candidates, 0..) |candidate, index| {
        if (!std.mem.eql(u8, candidate.name, rotor_candidate_name)) continue;
        const series = built[index] orelse return 0;
        return series.median_per_second();
    }
    return 0;
}

/// The candidate every ratio is measured against.
const rotor_candidate_name = "rotor";

/// Names this row's standing against the baseline, and counts it when rotor fell behind. A row the
/// baseline does not hold, or one whose runs disagreed, is named and not counted: neither decides
/// anything, and a silent pass would read as one.
fn report_verdict(
    writer: *std.Io.Writer,
    options: Options,
    recorded: []const baseline.Row,
    series: *const Series,
    rotor_per_second: u64,
    regressed: *u32,
) !void {
    const workload = @tagName(options.workload);
    const verdict = baseline.judge(recorded, workload, series, rotor_per_second);
    const name = series.runs[0].candidate;
    switch (verdict) {
        .within => {},
        .regressed => {
            regressed.* += 1;
            try writer.print("echo_runner: **{s} GAINED ON ROTOR** past the baseline\n", .{name});
        },
        .undecided => try writer.print(
            "echo_runner: {s} decides nothing against the baseline: the runs disagreed\n",
            .{name},
        ),
        .unrecorded => try writer.print(
            "echo_runner: {s} is not in the baseline for this configuration\n",
            .{name},
        ),
    }
}

/// Starts `candidate`'s server on `port`, measures it, and stops it.
fn one_run(
    init: std.process.Init,
    options: Options,
    candidate: Candidate,
    configuration: Configuration,
    port: u16,
) !Result {
    var command: setup.ServerCommand = undefined;
    const program = try program_path(options, candidate, 0);
    const argv = try command.fill(program, candidate, configuration, port);

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
        options.connections = try harness.candidates.parse_list(value, &setup.connections_buffer);
    } else if (std.mem.eql(u8, name, "--payloads")) {
        options.payloads = try harness.candidates.parse_list(value, &setup.payloads_buffer);
    } else if (std.mem.eql(u8, name, "--baseline")) {
        options.baseline_path = value;
    } else if (std.mem.eql(u8, name, "--write-baseline")) {
        // A value is taken and ignored, because every option here is a pair.
        options.write_baseline = std.mem.eql(u8, value, "yes");
    } else {
        return error.UnknownArgument;
    }
}

// Tests. `build/bench.zig` names this file in `tested`, so these run under `zig build test`.

const testing = std.testing;
