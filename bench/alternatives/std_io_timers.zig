//! std_io_timers: the timer churn workload on `std.Io`, the standard library's own I/O interface,
//! which is the fourth candidate of this comparison.
//!
//! Run:  std_io_timers [--timers N] [--period-us U] [--seconds S] [--backend uring|threaded]
//!
//! It makes the measurement `bench/timers/rotor_timers.zig` makes: keep `timers` timers armed for
//! `period_us`, arm each again as it fires, and report fires per second and how far past its
//! deadline each fire was. The percentiles are **lateness** and not latency.
//!
//! The shape is what this row measures. `std.Io` has no timer. It has `sleep`, and a task that
//! sleeps, so N timers is N tasks, each sleeping and sleeping again. Under `std.Io.Threaded` a
//! sleeping task holds the worker thread it runs on, because `sleep` there is `clock_nanosleep` on
//! that thread. So N timers is N threads, each with a default thread stack, against one 64-byte
//! slot per timer in rotor. Nothing else the interface offers arms a timer, so this is the cost of
//! the shape and not a defect.
//!
//! The tasks are started with `Group.concurrent` and not `Group.async`, for the reason
//! `bench/alternatives/std_io_echo.zig` gives at its own call: `async` is allowed to run a task on
//! the calling thread, and a task here never returns until the run is over, so the first timer
//! would be the only timer. `concurrent` is the call that promises a task runs beside this one.
//!
//! **A host that refuses the threads fails the run.** `Group.concurrent` answers
//! `error.ConcurrencyUnavailable` when it cannot spawn, and this program turns that into
//! `error.ThreadPerTimerRefused` and exits non-zero rather than arming fewer timers than the row
//! would claim. A missing row at a large count is the same finding stated more sharply, and
//! `bench/timers/timers_runner.zig` names the candidate and the count when it happens.
//!
//! **This candidate has no whole-millisecond floor.** `Io.sleep` takes a `Duration` in
//! nanoseconds, as rotor's timer does, so nothing here refuses a period libuv and libxev cannot
//! state. The floor in the runner is theirs.
//!
//! One program serves both implementations of the interface, as `std_io_echo` does:
//!
//!   - `threaded`: `std.Io.Threaded`, a thread pool with a blocking call per operation.
//!   - `uring`: `std.Io.Uring`, fibers over io_uring. It does not compile on the pinned Zig, which
//!     `uring_compiles` and `bench/alternatives/README.md` both record.
//!
//! It prints the one result line `bench/harness/report.zig` owns, which every candidate of every
//! workload prints.
const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
/// One definition of a percentile for every candidate of a workload, so two of them
/// cannot disagree about what p99 means. This file carried a copy until 2026-09-22.
const percentile = harness.percentile;

const Io = std.Io;
const Result = harness.Result;
const now_ns = harness.clock.now_ns;

/// The pinned Zig, which `bench/alternatives/README.md` records. `std.Io` is the compiler's own, so
/// the version of this candidate is the compiler's version and nothing is fetched for it.
const version = "0.16.0";

/// Timers armed at once, at most. The same limit rotor_timers and libuv_timers carry.
const timers_max = 16384;

/// Lateness samples kept. A run fires more than this; the sample is the first it takes, which is
/// what every candidate of this workload does, so the comparison is of one rule. Here the fires
/// come from many threads, so which fires are first is whatever the counter below hands out, and
/// the count is the same.
const samples_max = 1 << 17;

const ns_per_us: u64 = 1000;

/// False while `std.Io.Uring` does not compile, which on Zig 0.16.0 is always: `dirOpen` returns
/// an error its own `Dir.OpenError` does not name, and naming the type is enough to reach it.
/// `bench/alternatives/std_io_echo.zig` prints the compiler's message, and
/// `bench/alternatives/README.md` holds the record of it. Set this to true when a Zig that builds
/// it is pinned, and the candidate returns with no other change.
const uring_compiles = false;

/// Memory `std.Io.Threaded` takes for the tasks it holds. A task is small and one is created per
/// timer, never reused, so this is room to spare at `timers_max`.
const backing_bytes = 4 * 1024 * 1024;

var backing: [backing_bytes]u8 = undefined;

var lateness_ns: [samples_max]u64 = undefined;

/// Fires, and the slot each fire takes. One counter serves both because every fire samples: the
/// slot a fire is handed is the count of fires before it. Fires past `samples_max` keep counting
/// and store nothing, so the count is exact and the sample is bounded.
///
/// It is atomic because every fire happens on its own thread. `Group.await` makes the stores
/// visible to the thread that sorts them: a task's completion releases and the await acquires.
var fired: std.atomic.Value(u64) = .init(0);

const Backend = enum { uring, threaded };

const Options = struct {
    timers: u32 = 1024,
    period_us: u64 = 1000,
    seconds: u64 = 3,
    backend: Backend = .threaded,
};

pub fn main(init: std.process.Init) !void {
    const options = try parse(init);
    var arena = std.heap.FixedBufferAllocator.init(&backing);
    // The threadsafe interface: a task is created on this thread and destroyed on the worker
    // thread that ran it, so the allocator is reached from both. The plain one would race.
    const gpa = arena.threadSafeAllocator();

    switch (options.backend) {
        .threaded => {
            var threaded: std.Io.Threaded = .init(gpa, .{});
            defer threaded.deinit();
            try churn(init, threaded.io(), options);
        },
        .uring => {
            if (!uring_compiles) return error.UringDoesNotCompile;
            if (builtin.os.tag != .linux) return error.UringNeedsLinux;
            var evented: std.Io.Uring = undefined;
            try evented.init(gpa, .{});
            defer evented.deinit();
            try churn(init, evented.io(), options);
        },
    }
}

/// Starts one task per timer, waits for every one of them to reach the deadline, and reports.
fn churn(init: std.process.Init, io: Io, options: Options) !void {
    const period_ns = options.period_us * ns_per_us;
    const started_ns = now_ns();
    const deadline_ns = started_ns + options.seconds * std.time.ns_per_s;

    var group: Io.Group = .init;
    defer group.cancel(io);
    var started: u32 = 0;
    while (started < options.timers) : (started += 1) {
        // The host refused a thread, because one task per timer is one thread per timer here.
        // The run fails: a row for fewer timers than were asked for would misname itself.
        group.concurrent(io, one_timer, .{ io, period_ns, deadline_ns }) catch {
            return error.ThreadPerTimerRefused;
        };
    }
    try group.await(io);

    const span_ns = now_ns() - started_ns;
    try report(init, options, span_ns);
}

/// One timer: sleep a period, record how late the wake was, and sleep again until the deadline.
///
/// The span a fire is measured against is read on this thread before the sleep, as rotor reads it
/// before it arms. So a task's own scheduling delay before it sleeps counts as lateness here, the
/// same way rotor's counts against rotor.
fn one_timer(io: Io, period_ns: u64, deadline_ns: u64) Io.Cancelable!void {
    while (true) {
        const due_ns = now_ns() + period_ns;
        try io.sleep(.fromNanoseconds(period_ns), .awake);
        const at_ns = now_ns();
        record(due_ns, at_ns);
        if (at_ns >= deadline_ns) return;
    }
}

/// Counts one fire and keeps its lateness, while slots are left.
fn record(due_ns: u64, at_ns: u64) void {
    const slot = fired.fetchAdd(1, .monotonic);
    if (slot >= samples_max) return;
    lateness_ns[slot] = lateness_of(due_ns, at_ns);
}

/// How late a fire was. A wake before the deadline would be wrong, and this reads it as zero
/// rather than as a negative the subtraction cannot hold, which is what every candidate of this
/// workload does.
fn lateness_of(due_ns: u64, at_ns: u64) u64 {
    return if (at_ns > due_ns) at_ns - due_ns else 0;
}

/// The name a row carries, which is the name `bench/echo/echo_runner.zig` gives the same two
/// implementations. One interface with two implementations is two candidates, because a number
/// that averaged them would describe neither.
fn candidate_name(backend: Backend) []const u8 {
    return switch (backend) {
        .threaded => "std.Io.Threaded",
        .uring => "std.Io.Uring",
    };
}

/// The bytes one result line needs. A line is a few hundred; this is room to spare.
const output_buffer_bytes = 1024;

fn report(init: std.process.Init, options: Options, span_ns: u64) !void {
    const count = fired.load(.monotonic);
    const samples = lateness_ns[0..@intCast(@min(count, samples_max))];
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const duration_ns = @max(span_ns, 1);

    const result: Result = .{
        .workload = "timer-churn",
        .candidate = candidate_name(options.backend),
        .candidate_version = version,
        .configuration = .{
            // This workload places no thread and opens no connection. `connections` carries the
            // timers armed at once, as rotor_timers' row does.
            .cores = 0,
            .connections = options.timers,
            .payload_bytes = 0,
            .load = .even,
        },
        .duration_ns = duration_ns,
        .operations = count,
        .operations_per_second = harness.report.per_second(count, duration_ns),
        .p50_ns = percentile.nearest_rank(samples, percentile.p50),
        .p99_ns = percentile.nearest_rank(samples, percentile.p99),
        .p999_ns = percentile.nearest_rank(samples, percentile.p999),
        .p9999_ns = percentile.nearest_rank(samples, percentile.p9999),
        // Nothing is clamped: a sample is kept as it was measured.
        .overflow = 0,
    };

    var buffer: [output_buffer_bytes]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try result.render_json_line(&out.interface);
    try out.interface.flush();
}

fn parse(init: std.process.Init) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingValue;
        try apply(&options, arguments[index], arguments[index + 1]);
    }
    try check(options);
    return options;
}

fn apply(options: *Options, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "--timers")) {
        options.timers = try std.fmt.parseInt(u32, value, 10);
    } else if (std.mem.eql(u8, name, "--period-us")) {
        options.period_us = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        options.seconds = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--backend")) {
        options.backend = try parse_backend(value);
    } else {
        return error.UnknownArgument;
    }
}

fn parse_backend(value: []const u8) !Backend {
    if (std.mem.eql(u8, value, "threaded")) return .threaded;
    if (std.mem.eql(u8, value, "uring")) return .uring;
    return error.UnknownArgument;
}

/// What a run refuses. It is a function of its own so a test can reach it, which is the shape
/// `bench/files/reads_runner.zig` uses for the same reason.
fn check(options: Options) !void {
    if (options.timers == 0) return error.EmptyConfiguration;
    if (options.period_us == 0) return error.EmptyConfiguration;
    if (options.seconds == 0) return error.EmptyConfiguration;
    if (options.timers > timers_max) return error.TooManyTimers;
}

const testing = std.testing;

test "a run with nothing to measure is refused, and so is one over the timer limit" {
    try check(.{ .timers = 1, .period_us = 1000, .seconds = 3 });
    try check(.{ .timers = timers_max, .period_us = 1, .seconds = 1 });

    try testing.expectError(error.EmptyConfiguration, check(.{ .timers = 0 }));
    try testing.expectError(error.EmptyConfiguration, check(.{ .period_us = 0 }));
    try testing.expectError(error.EmptyConfiguration, check(.{ .seconds = 0 }));
    try testing.expectError(error.TooManyTimers, check(.{ .timers = timers_max + 1 }));
}

test "a period this candidate can state is not refused, because std.Io takes nanoseconds" {
    // libuv and libxev refuse a period they cannot state as whole milliseconds. `Io.sleep` takes
    // nanoseconds, so this candidate refuses none of them, and a check that did would make the
    // interface look more restricted than it is.
    try check(.{ .timers = 256, .period_us = 1, .seconds = 1 });
    try check(.{ .timers = 256, .period_us = 999, .seconds = 1 });
    try check(.{ .timers = 256, .period_us = 1500, .seconds = 1 });
}

test "a fire before its deadline reads as zero and not as a negative" {
    try testing.expectEqual(@as(u64, 0), lateness_of(1000, 1000));
    try testing.expectEqual(@as(u64, 0), lateness_of(1000, 900));
    try testing.expectEqual(@as(u64, 1), lateness_of(1000, 1001));
    try testing.expectEqual(@as(u64, 500), lateness_of(1000, 1500));
}

test "the two implementations are two candidates, named as the echo runner names them" {
    // `bench/echo/echo_runner.zig` carries these two names. A row this program prints and a row
    // that runner prints have to name the same candidate, or a reader would read them as three.
    try testing.expectEqualStrings("std.Io.Threaded", candidate_name(.threaded));
    try testing.expectEqualStrings("std.Io.Uring", candidate_name(.uring));
    try testing.expect(!std.mem.eql(u8, candidate_name(.threaded), candidate_name(.uring)));
}

test "a backend is named exactly, and an unknown one is refused" {
    try testing.expectEqual(Backend.threaded, try parse_backend("threaded"));
    try testing.expectEqual(Backend.uring, try parse_backend("uring"));
    try testing.expectError(error.UnknownArgument, parse_backend(""));
    try testing.expectError(error.UnknownArgument, parse_backend("thread"));
    try testing.expectError(error.UnknownArgument, parse_backend("threadedx"));
}

test "one counter hands out every slot once, and stops storing past the sample limit" {
    // `record` is the one place the fire count and the sample slot meet, and the property that
    // matters is that no two fires take one slot. This drives it from several threads, because
    // that is how the run drives it.
    const fires_per_thread = 1000;
    const threads_len = 4;
    const fires = fires_per_thread * threads_len;

    // Zero first, and every fire stores a lateness of 1. So a slot two fires took leaves another
    // slot at 0, and the loop below finds it.
    @memset(lateness_ns[0..fires], 0);
    fired.store(0, .monotonic);

    var threads: [threads_len]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, record_many, .{fires_per_thread});
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(u64, fires), fired.load(.monotonic));
    for (lateness_ns[0..fires]) |value| try testing.expectEqual(@as(u64, 1), value);

    // Past the limit a fire counts and stores nothing. Without the guard this writes one past the
    // array, which is a panic and not a wrong number.
    fired.store(samples_max, .monotonic);
    record(1000, 1001);
    try testing.expectEqual(@as(u64, samples_max + 1), fired.load(.monotonic));
}

fn record_many(count: u32) void {
    var index: u32 = 0;
    while (index < count) : (index += 1) record(1000, 1001);
}
