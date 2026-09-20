//! The rows only Linux has: C7, C8 and C9, what io_uring charges for one operation and for one
//! more in a batch. C12, C13 and C17 are in the files beside this one, which this list joins.
//!
//!   - C7: one `io_uring_enter` that submits one NOP and reaps its completion, no wait. The whole
//!     round trip of the smallest operation there is: the kernel does nothing, so what is left is
//!     the ring's own cost, which is what decision 3's arithmetic divides by the batch.
//!   - C8: `(t32 - t1) / 31` on the submission side. Both calls reap everything they submitted,
//!     so the difference carries one more submission and one more completion per entry. C9
//!     measures the completion half alone, and C8's note reports the subtraction.
//!   - C9: 32 completions that have already arrived, copied out of the ring. Not a difference
//!     of two enters: a call that reaps fewer leaves the rest for the next one, so both loops
//!     end up doing the same work. The first version of this probe measured nothing, and said
//!     so, which is why it is written this way.
//!
//! Every ring here is set up the way `src/uring` sets one up, SINGLE_ISSUER and DEFER_TASKRUN
//! included, because those flags change what an enter does. A probe that measured a plain ring
//! would measure a loop rotor does not run.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const measure = @import("../measure.zig");
const sys = @import("../sys.zig");

const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;

pub const probes = [_]measure.Probe{
    .{
        .row = 7,
        .operation = "io_uring_enter, 1 NOP submitted and its completion reaped, no wait",
        .run = run_round_trip,
    },
    .{
        .row = 8,
        .operation = "one more NOP in a batch of 32, submission side, per entry",
        .run = run_one_more_entry,
    },
    .{
        .row = 9,
        .operation = "one more completion in a reap of 32, per entry",
        .run = run_one_more_completion,
    },
} ++ @import("probes_linux_message.zig").probes ++
    @import("probes_linux_file.zig").probes;

/// The batch C8 and C9 compare against a batch of one.
pub const entries_max = 32;

/// Ring entries. Twice the batch, so C9's first call can leave a batch behind and the next one
/// still has room to submit.
const ring_entries = 2 * entries_max;

const round_trip_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 32 };
const one_more_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 16 };

/// The setup flags of `src/uring/uring_ring.zig`, so the probe measures the ring rotor runs.
pub const setup_flags = linux.IORING_SETUP_SINGLE_ISSUER |
    linux.IORING_SETUP_DEFER_TASKRUN |
    linux.IORING_SETUP_TASKRUN_FLAG |
    linux.IORING_SETUP_SUBMIT_ALL;

/// A ring set up as rotor sets one up. The probes drive it through `IoUring` rather than the raw
/// syscall, because that is the path `src/uring` takes.
pub const Ring = struct {
    io: linux.IoUring,

    pub fn init(entries: u16) Error!Ring {
        var parameters = std.mem.zeroInit(linux.io_uring_params, .{ .flags = setup_flags });
        const io = linux.IoUring.init_params(entries, &parameters) catch {
            return error.SystemCallFailed;
        };
        return .{ .io = io };
    }

    pub fn deinit(ring: *Ring) void {
        ring.io.deinit();
    }

    /// Queues `count` NOPs. The ring is sized so this never runs out of entries.
    pub fn queue_nops(ring: *Ring, count: u32) Error!void {
        var queued: u32 = 0;
        while (queued < count) : (queued += 1) {
            const sqe = ring.io.get_sqe() catch return error.UnexpectedResult;
            sqe.* = std.mem.zeroes(linux.io_uring_sqe);
            sqe.opcode = .NOP;
            sqe.user_data = queued;
        }
    }

    /// Submits what is queued and waits for nothing, then takes `reap` completions. Fails unless
    /// exactly `submit` entries went in and `reap` came out, so a probe cannot report a number
    /// for work that did not happen.
    pub fn enter(ring: *Ring, submit: u32, reap: u32) Error!void {
        const submitted = ring.io.submit() catch return error.SystemCallFailed;
        if (submitted != submit) return error.UnexpectedResult;
        try ring.take(reap);
    }

    /// Takes exactly `count` completions, and fails when fewer are ready.
    pub fn take(ring: *Ring, count: u32) Error!void {
        var taken: u32 = 0;
        while (taken < count) : (taken += 1) {
            const cqe = ring.io.copy_cqe() catch return error.SystemCallFailed;
            if (cqe.res != 0) return error.UnexpectedResult;
        }
    }
};

const RoundTrip = struct {
    ring: Ring,

    pub fn run_batch(context: *RoundTrip, calls: u32) Error!void {
        var remaining = calls;
        while (remaining != 0) : (remaining -= 1) {
            try context.ring.queue_nops(1);
            try context.ring.enter(1, 1);
        }
    }
};

fn run_round_trip(environment: *Environment) Error!Result {
    var context: RoundTrip = .{ .ring = try Ring.init(ring_entries) };
    defer context.ring.deinit();
    const plan = round_trip_plan;
    const summary = try measure.sample(RoundTrip, &context, plan, environment.values[0]);
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "calls",
        .note = "SINGLE_ISSUER, DEFER_TASKRUN, TASKRUN_FLAG and SUBMIT_ALL, as src/uring sets" ++
            " them; the kernel does nothing for a NOP, so this is the ring's own cost; every" ++
            " call's completion is checked",
    };
}

/// C8: one NOP submitted and reaped, against `entries_max` submitted and reaped.
const OneMoreEntry = struct {
    ring: Ring,

    pub fn run_first(context: *OneMoreEntry, calls: u32) Error!void {
        var remaining = calls;
        while (remaining != 0) : (remaining -= 1) {
            try context.ring.queue_nops(1);
            try context.ring.enter(1, 1);
        }
    }

    pub fn run_second(context: *OneMoreEntry, calls: u32) Error!void {
        var remaining = calls;
        while (remaining != 0) : (remaining -= 1) {
            try context.ring.queue_nops(entries_max);
            try context.ring.enter(entries_max, entries_max);
        }
    }
};

const added = entries_max - 1;

fn run_one_more_entry(environment: *Environment) Error!Result {
    var context: OneMoreEntry = .{ .ring = try Ring.init(ring_entries) };
    defer context.ring.deinit();
    const plan = one_more_plan;
    const timed = try measure.sample_pairs(OneMoreEntry, &context, plan, &environment.values);
    const note = environment.note(
        "(t32 - t1) / {d} per sample: t1 {d:.0} ns is the C7 call, t32 {d:.0} ns submits and" ++
            " reaps {d} NOPs in one call; the difference carries one submission and one" ++
            " completion, so C9 is the part of it that is the completion",
        .{ added, timed.first.median_ns, timed.second.median_ns, entries_max },
    );
    return .{
        .summary = timed.difference.scaled(1.0 / @as(f64, added)),
        .plan = plan,
        .unit = "calls per batch entry",
        .is_difference = true,
        .note = note,
    };
}

/// C9: the completions are already in the ring when the timing starts. `prepare` puts them
/// there, untimed, and the timed loop takes them out. A difference of two `enter` calls cannot
/// show this: a call that reaps fewer leaves the rest for the next one, so both loops end up
/// doing the same work and the difference measured nothing.
const OneMoreCompletion = struct {
    ring: Ring,

    /// Untimed: submits `entries_max` NOPs and waits for every completion to arrive.
    pub fn prepare(context: *OneMoreCompletion) Error!void {
        try context.ring.queue_nops(entries_max);
        const submitted = context.ring.io.submit_and_wait(entries_max) catch {
            return error.SystemCallFailed;
        };
        if (submitted != entries_max) return error.UnexpectedResult;
        if (context.ring.io.cq_ready() != entries_max) return error.UnexpectedResult;
    }

    /// Takes them out of the completion ring, and nothing else.
    pub fn run_batch(context: *OneMoreCompletion, completions: u32) Error!void {
        try context.ring.take(completions);
    }
};

const completion_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = entries_max };

fn run_one_more_completion(environment: *Environment) Error!Result {
    var context: OneMoreCompletion = .{ .ring = try Ring.init(ring_entries) };
    defer context.ring.deinit();
    const plan = completion_plan;
    const summary = try measure.sample(OneMoreCompletion, &context, plan, environment.values[0]);
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "completions",
        .note = "the 32 completions are in the ring before the timing starts, put there by an" ++
            " untimed submit_and_wait; the timed loop copies them out and checks each, so this" ++
            " is the reap alone and carries no part of the enter that C7 measures",
    };
}
