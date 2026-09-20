//! rotor_timers: the timer churn workload on rotor, which measures the one part of a loop that
//! touches no socket and no file.
//!
//! Run:  rotor_timers [--timers N] [--period-us U] [--seconds S]
//!
//! `timers` timers are armed at once, each for `period_us`. When one fires it is armed again, so
//! the count in flight never changes and the loop's heap is worked continuously: every fire is a
//! pop and every re-arm a push. That is the churn the workload is named for.
//!
//! Two numbers come out, and the second is the one that matters:
//!
//!   - **Throughput**: timers fired per second. A loop that batches its expiries reports more.
//!   - **Lateness**: how far past its deadline each timer actually fired, at the median, the 99th
//!     and the 999th. A timer is a promise about when, so a loop that fires more of them later is
//!     not obviously better. The percentiles are what a caller feels.
//!
//! Lateness cannot go below zero here: a loop that fires a timer early would be wrong, and the
//! measurement would catch it as a negative the clamp below turns into zero, which the report
//! names.
//!
//! It prints one line the runner reads: the result line `bench/harness/report.zig` owns, which
//! every candidate of every workload prints, so that one definition of the measurement serves all
//! of them. In this workload the percentiles carry **lateness** and not latency, and the
//! workload's name in the row is what says so.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const backend = @import("backend");
const harness = @import("harness");

const Loop = backend.Loop;
const Event = core.Event;
const Operation = core.Operation;

/// Timers armed at once, at most.
const timers_max = 16384;

/// Slots: one per timer in flight, with room to spare.
const operations = timers_max + 64;
const entries = 4096;
const events_max = 4096;

/// Lateness samples kept. A run fires more than this; the sample is the first it takes, which is
/// what every candidate of this workload does, so the comparison is of one rule.
const samples_max = 1 << 17;

var loop_memory: [
    Loop.memory_bytes(.{ .operations = operations, .entries = entries })
]u8 align(core.layout.memory_alignment) = undefined;

/// When each armed timer is due, by slot.
var due_ns: [timers_max]u64 = undefined;
var lateness_ns: [samples_max]u64 = undefined;

const Options = struct {
    timers: u32 = 1024,
    period_us: u64 = 1000,
    seconds: u64 = 3,
};

const Churn = struct {
    loop: *Loop,
    options: Options,
    period_ns: u64,
    fired: u64 = 0,
    taken: u32 = 0,
    deadline_ns: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    if (options.timers > timers_max) return error.TooManyTimers;

    var loop: Loop = undefined;
    try loop.init(&loop_memory, .{ .operations = operations, .entries = entries });
    defer loop.deinit();
    var churn: Churn = .{
        .loop = &loop,
        .options = options,
        .period_ns = options.period_us * core.constants.ns_per_us,
    };

    const span_ns = try run(&churn);
    try report(init, options, &churn, span_ns);
}

/// Arms every timer, then keeps them armed until the deadline. Returns the span measured.
fn run(churn: *Churn) !u64 {
    const started_ns = now_ns();
    churn.deadline_ns = started_ns + churn.options.seconds * core.constants.ns_per_s;

    var index: u32 = 0;
    while (index < churn.options.timers) : (index += 1) arm(churn, index);

    var events: [events_max]Event = undefined;
    var in_flight = churn.options.timers;
    while (in_flight != 0) {
        const count = try churn.loop.tick(&events, core.constants.ns_per_ms);
        const at_ns = now_ns();
        for (events[0..count]) |event| {
            _ = try event.outcome();
            const index_fired: u32 = @intCast(event.user_data);
            record(churn, index_fired, at_ns);
            if (at_ns >= churn.deadline_ns) {
                in_flight -= 1;
            } else {
                arm(churn, index_fired);
            }
        }
    }
    return now_ns() - started_ns;
}

fn arm(churn: *Churn, index: u32) void {
    due_ns[index] = now_ns() + churn.period_ns;
    const taken = churn.loop.submit(&.{.{
        .user_data = index,
        .kind = .{ .timer = .{ .after_ns = churn.period_ns } },
    }}, &.{});
    std.debug.assert(taken == 1);
}

/// One fire: how late it was, against when it was due.
fn record(churn: *Churn, index: u32, at_ns: u64) void {
    churn.fired += 1;
    if (churn.taken == samples_max) return;
    // A loop that fired early would give a negative, which this reads as zero and the report
    // names, because the workload is about lateness and not about earliness.
    lateness_ns[churn.taken] = if (at_ns > due_ns[index]) at_ns - due_ns[index] else 0;
    churn.taken += 1;
}

/// The bytes one result line needs. A line is a few hundred; this is room to spare.
const output_buffer_bytes = 1024;

/// The result line, built field by field rather than by `Result.init`, because that takes a
/// histogram and this workload keeps its samples exactly. Every candidate of this workload sorts
/// an array, so all of them are exact and none is quantised. The cross-core workload could not do
/// that, and `bench/competitors/README.md` records what it cost there.
fn report(init: std.process.Init, options: Options, churn: *Churn, span_ns: u64) !void {
    const samples = lateness_ns[0..churn.taken];
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const duration_ns = @max(span_ns, 1);

    const result: harness.Result = .{
        .workload = "timer-churn",
        .candidate = "rotor",
        .candidate_version = "this tree",
        .configuration = .{
            // This workload places no thread and opens no connection. `connections` carries the
            // timers armed at once, which is the count its rows vary, and the workload's name in
            // the row is what says which count it is.
            .cores = 0,
            .connections = options.timers,
            .payload_bytes = 0,
            .load = .even,
        },
        .duration_ns = duration_ns,
        .operations = churn.fired,
        .operations_per_second = harness.report.per_second(churn.fired, duration_ns),
        .p50_ns = percentile(samples, 500),
        .p99_ns = percentile(samples, 990),
        .p999_ns = percentile(samples, 999),
        // Nothing is clamped: a sample is kept as it was measured.
        .overflow = 0,
    };

    var buffer: [output_buffer_bytes]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try result.render_json_line(&out.interface);
    try out.interface.flush();
}

const per_mille = 1000;

/// The nearest-rank percentile of sorted `samples`, in parts per thousand.
fn percentile(samples: []const u64, parts_per_thousand: u64) u64 {
    if (samples.len == 0) return 0;
    const rank = (samples.len * parts_per_thousand + per_mille - 1) / per_mille;
    const index = @min(@max(rank, 1) - 1, samples.len - 1);
    return samples[index];
}

const now_ns = harness.clock.now_ns;

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        const name = arguments[index];
        const value = arguments[index + 1];
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
    if (options.timers == 0 or options.period_us == 0) return error.EmptyConfiguration;
    return options;
}
