//! Rows C4, C5 and C21: what the core's predictors and one call cost, with memory held in L1.
//!
//! Each row times two loops back to back inside every sample (`measure.sample_pairs`), because
//! each number only means something beside its baseline:
//!   - C4 is a difference: the same loop over bits the predictor always gets right and over
//!     random bits. It is the one row here whose cell is the difference.
//!   - C5 and C21 report the absolute time of the loop the row names, and the note carries the
//!     baseline. A predicted indirect call costs what a direct call costs, and on Linux a
//!     thread-local read costs what a global read costs, so their differences can be zero, and
//!     a zero cell is what the report refuses as a probe that measured nothing.
//!
//! The loops here are a few instructions long, and a core's front end does not treat loops that
//! short evenly. C5's direct loop and C21's global loop both call a never-inlined function and
//! return; on an M1 Pro the first took 5 cycles a call and the second 3, in one build. Read C5
//! and C21 as "between 1 and 2 ns", not to the digit.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const measure = @import("../measure.zig");
const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;

pub const probes = [_]measure.Probe{
    .{ .row = 4, .operation = "branch mispredict", .run = run_branch },
    .{
        .row = 5,
        .operation = "indirect call through a function pointer, predicted",
        .run = run_indirect_call,
    },
    .{ .row = 21, .operation = "thread-local variable read and compare", .run = run_threadlocal },
};

// Row C4.

/// The outcomes each variant streams through. A predictor with a long history can learn a short
/// sequence that repeats, so the random bits are long enough that a window of them comes round
/// again only after 128 batches, and both variants read the same number of bytes in the same
/// order, so they differ in the branch alone.
const outcomes_bytes = 1 << 20;

/// The seed of the random outcomes.
const outcomes_seed = 0x51ed_270b_a5c1_e5a7;

/// The share of random branches that mispredict. The bits are independent and fair, so no
/// predictor beats or loses to chance on them. The row is the per-branch difference divided by
/// this. The probe cannot count mispredicts: macOS gives the counters to root alone.
const mispredict_share = 0.5;

/// The random outcomes must be this close to fair, in parts per hundred, or the share is wrong.
const fair_percent_min = 49;
const fair_percent_max = 51;

const branch_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 8192 };

/// What the two arms add and mix in. They are read through volatile pointers, and that is what
/// keeps the branch a branch: the compiler may not run a volatile load the program would not
/// have run, so it cannot compute both arms and select one (`csel`, `cmov`).
var taken_addend: u64 = 3;
var not_taken_mask: u64 = 5;

/// One conditional branch per outcome. Each arm is one load that hits L1 and one operation, and
/// the loop carries one add or xor from iteration to iteration, so the predicted loop is bound by
/// nothing but the branch itself.
noinline fn run_branches(outcomes: []const u8, start: u64) u64 {
    const addend: *volatile u64 = &taken_addend;
    const mask: *volatile u64 = &not_taken_mask;
    var sum = start;
    for (outcomes) |outcome| {
        if (outcome != 0) {
            sum +%= addend.*;
        } else {
            sum ^= mask.*;
        }
    }
    return sum;
}

const Branches = struct {
    constant: []const u8,
    random: []const u8,
    cursor: usize = 0,
    sum: u64 = 0,

    /// The branch always goes the same way.
    pub fn run_first(branches: *Branches, batch: u32) Error!void {
        branches.sum = run_branches(branches.constant[branches.cursor..][0..batch], branches.sum);
    }

    /// The same machine code over random outcomes; then both variants move to the next window.
    pub fn run_second(branches: *Branches, batch: u32) Error!void {
        branches.sum = run_branches(branches.random[branches.cursor..][0..batch], branches.sum);
        branches.cursor += batch;
        if (branches.cursor + batch > branches.random.len) branches.cursor = 0;
    }
};

fn run_branch(environment: *Environment) Error!Result {
    assert(environment.arena.len >= 2 * outcomes_bytes);
    const constant = environment.arena[0..outcomes_bytes];
    const random = environment.arena[outcomes_bytes .. 2 * outcomes_bytes];
    @memset(constant, 0);
    fill_fair_bits(random);

    var branches: Branches = .{ .constant = constant, .random = random };
    const pair = try measure.sample_pairs(Branches, &branches, branch_plan, &environment.values);
    std.mem.doNotOptimizeAway(branches.sum);
    const note = environment.note(
        "twice the per-branch gap between random outcomes ({d:.2} ns a branch) and constant" ++
            " ones ({d:.2} ns), since half of the random branches mispredict; the branch tests" ++
            " a byte loaded from L1, so the cost includes that load's latency after the flush",
        .{ pair.second.median_ns, pair.first.median_ns },
    );
    return .{
        .summary = pair.difference.scaled(1 / mispredict_share),
        .plan = branch_plan,
        .unit = "branches per variant",
        .is_difference = true,
        .note = note,
    };
}

fn fill_fair_bits(outcomes: []u8) void {
    var generator = std.Random.DefaultPrng.init(outcomes_seed);
    generator.random().bytes(outcomes);
    var ones: usize = 0;
    for (outcomes) |*outcome| {
        outcome.* &= 1;
        ones += outcome.*;
    }
    assert(ones * 100 >= outcomes.len * fair_percent_min);
    assert(ones * 100 <= outcomes.len * fair_percent_max);
}

// Row C5.

const call_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 16384 };

/// The callee of both loops. Its result feeds its next argument, so no call can be hoisted out of
/// the loop or folded into a sum.
noinline fn add_one(value: u64) u64 {
    return value +% 1;
}

/// Where the indirect loop finds its target. It is read through a volatile pointer, so the
/// compiler cannot know the target and turn `blr` back into `bl`.
var callee_slot: *const fn (u64) u64 = &add_one;

const Calls = struct {
    value: u64 = 0,

    /// The baseline: the same callee, called directly, with inlining forbidden.
    pub fn run_first(calls: *Calls, batch: u32) Error!void {
        var value = calls.value;
        var remaining = batch;
        while (remaining != 0) : (remaining -= 1) value = @call(.never_inline, add_one, .{value});
        calls.value = value;
    }

    /// The row: a call through a pointer whose target never changes, so the predictor is right.
    pub fn run_second(calls: *Calls, batch: u32) Error!void {
        const slot: *volatile *const fn (u64) u64 = &callee_slot;
        const callee = slot.*;
        var value = calls.value;
        var remaining = batch;
        while (remaining != 0) : (remaining -= 1) value = callee(value);
        calls.value = value;
    }
};

fn run_indirect_call(environment: *Environment) Error!Result {
    var calls: Calls = .{};
    const pair = try measure.sample_pairs(Calls, &calls, call_plan, &environment.values);
    // Every call of both loops added one.
    const total = @as(u64, call_plan.warmup + call_plan.samples) * call_plan.batch * 2;
    if (calls.value != total) return error.UnexpectedResult;
    const note = environment.note(
        "one loop iteration: the call through the pointer, a callee that adds 1 and keeps a" ++
            " frame record as every ReleaseSafe function does, and the return; the same callee" ++
            " called directly took {d:.2} ns and the median per-sample gap was {d:.2} ns",
        .{ pair.first.median_ns, pair.difference.median_ns },
    );
    return .{ .summary = pair.second, .plan = call_plan, .unit = "calls per loop", .note = note };
}

// Row C21.

const threadlocal_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 16384 };

/// What docs/decisions/0004-threading.md has every entry point compare: the loop this thread
/// owns. On macOS every access to a thread-local calls the `tlv_get_addr` thunk through a
/// pointer; on Linux with a static executable it is one load off the thread pointer.
threadlocal var owner_threadlocal: usize = 0;

/// The baseline: the same value in an ordinary global.
var owner_global: usize = 0;

/// Stands for a public entry point: never inlined, so the address of the thread-local is
/// resolved on every call, as it is when a caller enters the library. Inlined into the timing
/// loop, the compiler would resolve the address once for the whole batch. The read is volatile so
/// that the function has an effect and its calls cannot be merged or hoisted.
noinline fn entered_by_owner_threadlocal(expected: usize) bool {
    const owner: *volatile usize = &owner_threadlocal;
    return owner.* == expected;
}

noinline fn entered_by_owner_global(expected: usize) bool {
    const owner: *volatile usize = &owner_global;
    return owner.* == expected;
}

const Entries = struct {
    expected: usize,
    matches: u64 = 0,

    pub fn run_first(entries: *Entries, batch: u32) Error!void {
        var matches: u64 = 0;
        var remaining = batch;
        while (remaining != 0) : (remaining -= 1) {
            matches +%= @intFromBool(entered_by_owner_global(entries.expected));
        }
        entries.matches += matches;
    }

    pub fn run_second(entries: *Entries, batch: u32) Error!void {
        var matches: u64 = 0;
        var remaining = batch;
        while (remaining != 0) : (remaining -= 1) {
            matches +%= @intFromBool(entered_by_owner_threadlocal(entries.expected));
        }
        entries.matches += matches;
    }
};

fn run_threadlocal(environment: *Environment) Error!Result {
    // Any value the compiler cannot know: the address of this run's environment.
    const owner = @intFromPtr(environment);
    owner_threadlocal = owner;
    owner_global = owner;
    var entries: Entries = .{ .expected = owner };
    const plan = threadlocal_plan;
    const pair = try measure.sample_pairs(Entries, &entries, plan, &environment.values);
    // Every compare of both loops read the owner and matched.
    const total = @as(u64, plan.warmup + plan.samples) * plan.batch * 2;
    if (entries.matches != total) return error.UnexpectedResult;
    const note = environment.note(
        "one call of a never-inlined entry point that reads the thread-local and compares it," ++
            " call and return included; the same function over a plain global took {d:.2} ns" ++
            " and the median per-sample gap was {d:.2} ns, which is what thread-local" ++
            " addressing adds on this OS",
        .{ pair.first.median_ns, pair.difference.median_ns },
    );
    return .{ .summary = pair.second, .plan = plan, .unit = "calls per loop", .note = note };
}
