//! The timing method every cost probe shares, and what a probe hands back (docs/costs.md, rule 5).
//!
//! A probe is timed in batches. After `Plan.warmup` batches that are timed and thrown away, the
//! clock is read before and after each of `Plan.samples` batches of `Plan.batch` operations, and a
//! sample is the elapsed time divided by the batch. The row is the median of the samples, with
//! the p99 in parentheses (docs/costs.md, rule 2).
//!
//! What the p99 means depends on the batch. One clock read costs as much as a dozen L1 loads or
//! more, and on Apple silicon the clock steps in units of 41.67 ns, so an operation shorter than
//! that cannot be timed alone: it is timed in a batch, and the p99 is then the p99 of batch means,
//! which hides a slow single operation inside its batch. An operation of several microseconds is
//! timed alone, `Plan.batch` is 1, and the p99 is the p99 of single operations.
//!
//! Two rows are differences of two loops (C4, C11), and two more are reported beside a baseline
//! (C5, C21). `sample_pairs` times the two loops back to back inside every sample, so that drift
//! in clock frequency or in machine load lands on both, and summarises the per-sample difference.
//!
//! Nothing here allocates after `Environment.init`, which maps every large array once, before any
//! timing.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;

/// The monotonic clock every probe is timed with, and the one row C20 measures. It is the clock
/// std.Io reads for its `.awake` clock: CLOCK_UPTIME_RAW on macOS, because CLOCK_MONOTONIC there
/// steps in whole microseconds, and CLOCK_MONOTONIC elsewhere.
pub const clock_id: posix.clockid_t = switch (builtin.os.tag) {
    .macos => .UPTIME_RAW,
    else => .MONOTONIC,
};

/// The name of `clock_id`, for the report.
pub const clock_name = switch (builtin.os.tag) {
    .macos => "clock_gettime(CLOCK_UPTIME_RAW)",
    else => "clock_gettime(CLOCK_MONOTONIC)",
};

/// The compiler mode the probes were built in, for the report. build/bench.zig fixes it to
/// ReleaseSafe, the mode rotor ships in.
pub const compiler_mode = @tagName(builtin.mode);

/// Clock reads `clock_resolution_ns` makes while it looks for the smallest step.
const resolution_reads = 200_000;

/// How long `settle` spins before the first probe, in nanoseconds: time for the macOS scheduler
/// to move a user-interactive thread onto a performance core and for the core to reach its full
/// clock rate. Without the spin, the first probe of a development run on an M1 Pro took about
/// 1.5 times as long per L1 load as the probes after it. The length is a guess that worked.
const settle_ns = 300 * std.time.ns_per_ms;

/// The most clock reads `spin_until` makes: at 5 ns a read, the fastest clock seen, that is more
/// than 20 seconds, and every caller waits for far less.
const spin_reads_max = 1 << 32;

/// The most samples a plan may ask for: the length of each buffer in `Environment.values`.
pub const samples_max = 1 << 14;

/// The bytes `Environment.arena` maps: the largest working set a probe uses, the 512 MiB that row
/// C3 chases through.
pub const arena_bytes = 512 * 1024 * 1024;

/// The bytes a probe's note may hold.
pub const note_bytes_max = 512;

/// A result under this many nanoseconds per operation has measured nothing: it is less than one
/// cycle of a 6 GHz core, so the optimizer deleted the work or folded the loop. The report turns
/// it into a failure and never into a number.
pub const sanity_floor_ns = 0.15;

/// The 99 of "p99", as a fraction of 100.
const percentile_rank = 99;
const percentile_scale = 100;

pub const Error = error{
    /// A system call the probe depends on failed, so the row has no number.
    SystemCallFailed,
    /// The measured work did not do what the probe expects: a short read, a wrong event, a lost
    /// message. The number would describe something else, so the row has none.
    UnexpectedResult,
    /// A helper thread did not answer within its spin limit.
    HelperStalled,
};

/// Nanoseconds on `clock_id`.
pub fn now_ns() u64 {
    var time: posix.timespec = undefined;
    const rc = posix.system.clock_gettime(clock_id, &time);
    assert(posix.errno(rc) == .SUCCESS);
    assert(time.sec >= 0);
    const seconds: u64 = @intCast(time.sec);
    const nanoseconds: u64 = @intCast(time.nsec);
    return seconds * std.time.ns_per_s + nanoseconds;
}

/// The smallest step the clock was seen to make, in nanoseconds. `clock_getres` reports the same
/// figure on macOS; the step is measured because it is what bounds a timed interval.
pub fn clock_resolution_ns() u64 {
    var smallest: u64 = std.math.maxInt(u64);
    var previous = now_ns();
    var read: u32 = 0;
    while (read < resolution_reads) : (read += 1) {
        const current = now_ns();
        assert(current >= previous);
        const step = current - previous;
        if (step != 0 and step < smallest) smallest = step;
        previous = current;
    }
    assert(smallest != std.math.maxInt(u64));
    return smallest;
}

/// Spins on the clock until `deadline_ns`. A sleep would let the core go idle, which is the state
/// the probes must not start from.
pub fn spin_until(deadline_ns: u64) void {
    var reads: u64 = 0;
    while (now_ns() < deadline_ns) : (reads += 1) {
        assert(reads < spin_reads_max);
    }
}

/// What this process could do about where a thread runs.
pub const Placement = enum {
    /// macOS: the QoS class was raised to user-interactive, which keeps the thread on
    /// performance cores when one is free. Apple silicon has no hard affinity.
    qos_user_interactive,
    /// macOS refused the QoS class, so the scheduler may use an efficiency core.
    qos_refused,
    /// No placement was attempted on this OS.
    scheduler_default,

    pub fn text(placement: Placement) []const u8 {
        return switch (placement) {
            .qos_user_interactive => "thread not pinned (macOS on Apple silicon has no hard" ++
                " affinity), QoS class user-interactive requested",
            .qos_refused => "thread not pinned, and the user-interactive QoS class was refused",
            .scheduler_default => "thread not pinned: this probe pins nothing on this OS, run it" ++
                " under taskset",
        };
    }
};

/// Does what the OS allows to keep the calling thread on a fast core, and says what that was.
/// Every thread a probe starts calls it too.
pub fn place_current_thread() Placement {
    switch (builtin.os.tag) {
        .macos => {
            const rc = std.c.pthread_set_qos_class_self_np(.USER_INTERACTIVE, 0);
            return if (rc == 0) .qos_user_interactive else .qos_refused;
        },
        else => return .scheduler_default,
    }
}

/// Places the calling thread and spins for `settle_ns`, so the first probe does not start on a
/// core that is still slow or on the wrong kind of core.
pub fn settle() Placement {
    const placement = place_current_thread();
    spin_until(now_ns() + settle_ns);
    return placement;
}

pub const Plan = struct {
    /// Timed batches that run first and are thrown away.
    warmup: u32,
    /// Timed batches that are kept.
    samples: u32,
    /// Operations per timed batch. 1 means every operation is timed alone.
    batch: u32,

    fn check(plan: Plan) void {
        assert(plan.samples >= 1);
        assert(plan.samples <= samples_max);
        assert(plan.batch >= 1);
    }
};

/// Nanoseconds per operation over one probe's samples.
pub const Summary = struct {
    median_ns: f64,
    p99_ns: f64,
    min_ns: f64,

    /// The same summary of samples that were each multiplied by `factor`. A positive factor keeps
    /// the order of the samples, so it keeps every percentile.
    pub fn scaled(summary: Summary, factor: f64) Summary {
        assert(factor > 0);
        return .{
            .median_ns = summary.median_ns * factor,
            .p99_ns = summary.p99_ns * factor,
            .min_ns = summary.min_ns * factor,
        };
    }
};

/// Sorts `values` in place and summarises them. The median of an even count is the mean of the
/// two middle values. The p99 is the nearest rank: the smallest value with at least 99 percent of
/// the values at or under it.
pub fn summarize(values: []f64) Summary {
    assert(values.len >= 1);
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const middle = values.len / 2;
    const median = if (values.len % 2 == 1)
        values[middle]
    else
        (values[middle - 1] + values[middle]) / 2;
    const rank = (values.len * percentile_rank + percentile_scale - 1) / percentile_scale;
    assert(rank >= 1);
    assert(rank <= values.len);
    return .{ .median_ns = median, .p99_ns = values[rank - 1], .min_ns = values[0] };
}

fn ns_per_operation(elapsed_ns: u64, batch: u32) f64 {
    assert(batch >= 1);
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(batch));
}

/// Times `plan.samples` batches and summarises them, in nanoseconds per operation.
///
/// `Context` declares `run_batch(*Context, u32) Error!void`, which performs that many operations
/// and nothing else. It may declare `prepare(*Context) Error!void`, which runs before every batch
/// and is not timed.
pub fn sample(comptime Context: type, context: *Context, plan: Plan, values: []f64) Error!Summary {
    plan.check();
    assert(values.len >= plan.samples);
    var index: u32 = 0;
    while (index < plan.warmup + plan.samples) : (index += 1) {
        if (@hasDecl(Context, "prepare")) try context.prepare();
        const start_ns = now_ns();
        try context.run_batch(plan.batch);
        const elapsed_ns = now_ns() - start_ns;
        if (index >= plan.warmup) {
            values[index - plan.warmup] = ns_per_operation(elapsed_ns, plan.batch);
        }
    }
    return summarize(values[0..plan.samples]);
}

/// Two loops timed back to back, and the second minus the first.
pub const PairSummary = struct {
    first: Summary,
    second: Summary,
    /// Per sample, the second loop's nanoseconds per operation minus the first's. A sample may be
    /// negative; the median of a real difference is not.
    difference: Summary,
};

/// Times `run_first` and then `run_second` inside every sample, `plan.batch` operations each.
/// `Context` declares both, with the signature of `run_batch` above.
pub fn sample_pairs(
    comptime Context: type,
    context: *Context,
    plan: Plan,
    values: *const [3][]f64,
) Error!PairSummary {
    plan.check();
    for (values) |buffer| assert(buffer.len >= plan.samples);
    var index: u32 = 0;
    while (index < plan.warmup + plan.samples) : (index += 1) {
        const start_ns = now_ns();
        try context.run_first(plan.batch);
        const middle_ns = now_ns();
        try context.run_second(plan.batch);
        const end_ns = now_ns();
        if (index < plan.warmup) continue;
        const kept = index - plan.warmup;
        values[0][kept] = ns_per_operation(middle_ns - start_ns, plan.batch);
        values[1][kept] = ns_per_operation(end_ns - middle_ns, plan.batch);
        values[2][kept] = values[1][kept] - values[0][kept];
    }
    return .{
        .first = summarize(values[0][0..plan.samples]),
        .second = summarize(values[1][0..plan.samples]),
        .difference = summarize(values[2][0..plan.samples]),
    };
}

/// What a probe hands back for the report.
pub const Result = struct {
    summary: Summary,
    plan: Plan,
    /// What one operation is, in the plural: "loads", "calls".
    unit: []const u8,
    /// True when `summary` comes from `PairSummary.difference`: the report then says that the
    /// smallest sample is a difference, which an interrupt in the first loop can make negative.
    is_difference: bool = false,
    /// What the number includes and what it cannot show, on one line. It lives in
    /// `Environment.note_buffer`.
    note: []const u8,
};

/// The memory every probe measures in, mapped once before any timing.
pub const Environment = struct {
    /// The large arrays: the nodes rows C1 to C3 chase through, the branch bits of row C4.
    arena: []align(std.heap.page_size_min) u8,
    /// Three sample buffers of `samples_max` each; `sample_pairs` fills all three.
    values: [3][]f64,
    note_buffer: [note_bytes_max]u8 = undefined,

    pub fn init() Error!Environment {
        const values_bytes = 3 * samples_max * @sizeOf(f64);
        const arena = map(arena_bytes) orelse return error.SystemCallFailed;
        const values_memory = map(values_bytes) orelse return error.SystemCallFailed;
        const values: [*]f64 = @ptrCast(values_memory.ptr);
        return .{
            .arena = arena,
            .values = .{
                values[0..samples_max],
                values[samples_max .. 2 * samples_max],
                values[2 * samples_max .. 3 * samples_max],
            },
        };
    }

    /// Anonymous private memory. The kernel backs it with zero pages on first touch, so mapping
    /// 512 MiB costs nothing until a probe touches it.
    fn map(bytes: usize) ?[]align(std.heap.page_size_min) u8 {
        return posix.mmap(
            null,
            bytes,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch null;
    }

    /// Formats a probe's note into `note_buffer`. A note that does not fit is a programmer error.
    pub fn note(
        environment: *Environment,
        comptime format: []const u8,
        arguments: anytype,
    ) []const u8 {
        return std.fmt.bufPrint(&environment.note_buffer, format, arguments) catch
            @panic("note_bytes_max is too small for this note");
    }
};

/// One row of docs/costs.md and the function that measures it.
pub const Probe = struct {
    /// The number in the row id: 6 for C6.
    row: u32,
    /// The row's operation, in the words of docs/costs.md.
    operation: []const u8,
    run: *const fn (environment: *Environment) Error!Result,
};

// Tests. `zig build test` compiles the probes and does not run these; run them with
// `zig test bench/costs/measure.zig`.

const testing = std.testing;

test "summarize takes the median of an odd and of an even count" {
    var odd = [_]f64{ 9, 1, 5 };
    try testing.expectEqual(@as(f64, 5), summarize(&odd).median_ns);
    var even = [_]f64{ 8, 2, 4, 6 };
    try testing.expectEqual(@as(f64, 5), summarize(&even).median_ns);
    try testing.expectEqual(@as(f64, 2), summarize(&even).min_ns);
}

test "summarize takes the nearest-rank p99" {
    var hundred: [100]f64 = undefined;
    for (&hundred, 0..) |*value, index| value.* = @floatFromInt(100 - index);
    // 99 of the 100 values are at or under 99, so the p99 is 99 and not the maximum.
    try testing.expectEqual(@as(f64, 99), summarize(&hundred).p99_ns);
    var two_hundred: [200]f64 = undefined;
    for (&two_hundred, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    try testing.expectEqual(@as(f64, 198), summarize(&two_hundred).p99_ns);
    var one = [_]f64{7};
    try testing.expectEqual(@as(f64, 7), summarize(&one).p99_ns);
}

const CountingContext = struct {
    operations: u64 = 0,
    prepared: u32 = 0,

    pub fn prepare(context: *CountingContext) Error!void {
        context.prepared += 1;
    }

    pub fn run_batch(context: *CountingContext, batch: u32) Error!void {
        context.operations += batch;
    }
};

test "sample runs the warm-up and every sample, and prepares each one" {
    var context: CountingContext = .{};
    var values: [8]f64 = undefined;
    const plan: Plan = .{ .warmup = 3, .samples = 8, .batch = 5 };
    _ = try sample(CountingContext, &context, plan, &values);
    try testing.expectEqual(@as(u64, (3 + 8) * 5), context.operations);
    try testing.expectEqual(@as(u32, 3 + 8), context.prepared);
}

test "the clock moves forward and its step is under a microsecond" {
    const first = now_ns();
    const second = now_ns();
    try testing.expect(second >= first);
    try testing.expect(clock_resolution_ns() < std.time.ns_per_us);
}

const PairContext = struct {
    first_operations: u64 = 0,
    second_operations: u64 = 0,

    pub fn run_first(context: *PairContext, batch: u32) Error!void {
        context.first_operations += batch;
    }

    pub fn run_second(context: *PairContext, batch: u32) Error!void {
        context.second_operations += batch;
        // Long enough to outlast the first loop by more than a clock step.
        spin_until(now_ns() + std.time.ns_per_ms);
    }
};

test "sample_pairs runs both loops every sample and reports the second minus the first" {
    var context: PairContext = .{};
    var storage: [3][4]f64 = undefined;
    const values: [3][]f64 = .{ &storage[0], &storage[1], &storage[2] };
    const plan: Plan = .{ .warmup = 1, .samples = 4, .batch = 10 };
    const pair = try sample_pairs(PairContext, &context, plan, &values);
    try testing.expectEqual(@as(u64, (1 + 4) * 10), context.first_operations);
    try testing.expectEqual(@as(u64, (1 + 4) * 10), context.second_operations);
    try testing.expect(pair.difference.median_ns > 0);
    try testing.expect(pair.second.median_ns > pair.first.median_ns);
}
