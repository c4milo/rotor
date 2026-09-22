//! libxev_timers: the timer churn workload on libxev, the same measurement rotor_timers makes.
//!
//! Run:  libxev_timers [--timers N] [--period-us U] [--seconds S]
//!
//! `timers` timers are armed at once for `period_us`, and each is armed again as it fires, so the
//! count in flight never changes and the loop's timer structure is worked continuously.
//!
//! It prints the result line every candidate of every workload prints, which
//! `bench/harness/report.zig` owns. In this workload the percentiles carry **lateness** and not
//! latency: how far past its deadline each timer actually fired.
//!
//! **libxev timers are whole milliseconds**, as libuv's are: `xev.Timer.run` takes `next_ms`. So
//! this program refuses a period it cannot state exactly, rather than rounding one down and
//! reporting a row that looks like a comparison. rotor's timer takes nanoseconds, and that is a
//! difference in what the three can be asked for and not only in what they do.
//!
//! Each timer re-arms by calling `run` again from its own callback rather than returning `.rearm`,
//! so the deadline this program sets is visible in one place and no timer outlives the run.
const std = @import("std");
const xev = @import("xev");
const harness = @import("harness");

const Result = harness.Result;
const now_ns = harness.clock.now_ns;

/// The pinned commit of libxev, which `bench/alternatives/README.md` records.
const version = "9ce8e8e";

/// Timers armed at once, at most. The same limit rotor_timers and libuv_timers carry.
const timers_max = 16384;

/// Lateness samples kept. A run fires more than this; the sample is the first it takes, which is
/// what every candidate of this workload does, so the comparison is of one rule.
const samples_max = 1 << 17;

const ns_per_us: u64 = 1000;
const ns_per_ms: u64 = 1_000_000;
const us_per_ms: u64 = 1000;
const per_mille: u64 = 1000;

const Options = struct {
    timers: u32 = 1024,
    period_us: u64 = 1000,
    seconds: u64 = 3,
};

/// One armed timer: libxev needs a completion per timer in flight, and this holds the deadline
/// the lateness is measured against.
const Armed = struct {
    timer: xev.Timer = undefined,
    completion: xev.Completion = .{},
    due_ns: u64 = 0,
};

var armed: [timers_max]Armed = undefined;
var lateness_ns: [samples_max]u64 = undefined;

var period_ns: u64 = 0;
var next_ms: u64 = 0;
var deadline_ns: u64 = 0;
var fired: u64 = 0;
var taken: u32 = 0;

/// Records one firing and arms the timer again, unless the run is over.
fn on_timer(
    userdata: ?*Armed,
    loop: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    result catch return .disarm;
    const state = userdata.?;
    const at_ns = now_ns();
    fired += 1;
    if (taken < samples_max) {
        // A timer that fired early would be wrong, and the clamp turns that into a zero the
        // report names rather than into a negative the subtraction cannot hold.
        lateness_ns[taken] = if (at_ns > state.due_ns) at_ns - state.due_ns else 0;
        taken += 1;
    }
    if (at_ns >= deadline_ns) return .disarm;
    state.due_ns = at_ns + period_ns;
    state.timer.run(loop, &state.completion, next_ms, Armed, state, on_timer);
    return .disarm;
}

fn percentile(sorted: []const u64, parts_per_thousand: u64) u64 {
    if (sorted.len == 0) return 0;
    const rank = (sorted.len * parts_per_thousand + per_mille - 1) / per_mille;
    const index = @min(@max(rank, 1) - 1, sorted.len - 1);
    return sorted[index];
}

fn report(init: std.process.Init, options: Options, span_ns: u64) !void {
    const samples = lateness_ns[0..taken];
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const duration_ns = @max(span_ns, 1);

    const result: Result = .{
        .workload = "timer-churn",
        .candidate = "libxev",
        .candidate_version = version,
        .configuration = .{
            .cores = 0,
            .connections = options.timers,
            .payload_bytes = 0,
            .load = .even,
        },
        .duration_ns = duration_ns,
        .operations = fired,
        .operations_per_second = harness.report.per_second(fired, duration_ns),
        .p50_ns = percentile(samples, 500),
        .p99_ns = percentile(samples, 990),
        .p999_ns = percentile(samples, 999),
        .overflow = 0,
    };

    var buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try result.render_json_line(&out.interface);
    try out.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    if (options.timers > timers_max) return error.TooManyTimers;

    period_ns = options.period_us * ns_per_us;
    next_ms = options.period_us / us_per_ms;
    std.debug.assert(next_ms >= 1);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const started_ns = now_ns();
    deadline_ns = started_ns + options.seconds * std.time.ns_per_s;
    for (armed[0..options.timers]) |*state| {
        state.* = .{ .timer = try xev.Timer.init(), .due_ns = started_ns + period_ns };
        state.timer.run(&loop, &state.completion, next_ms, Armed, state, on_timer);
    }

    try loop.run(.until_done);
    const span_ns = now_ns() - started_ns;
    for (armed[0..options.timers]) |*state| state.timer.deinit();

    try report(init, options, span_ns);
}

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    if (options.timers == 0 or options.seconds == 0) return error.EmptyConfiguration;
    // libxev takes whole milliseconds, so a period it cannot state exactly is refused here and
    // not rounded: a rounded row would compare rotor against a libxev asked for something else.
    if (options.period_us < us_per_ms) return error.PeriodBelowMillisecond;
    if (options.period_us % us_per_ms != 0) return error.PeriodNotWholeMilliseconds;
    return options;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--timers")) {
        options.timers = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--period-us")) {
        options.period_us = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else {
        return error.UnknownArgument;
    }
}
