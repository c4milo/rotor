//! Rows C10 and C11: what one `kevent` call costs, and what one more change in it costs. macOS
//! only. Row C18 borrows the EVFILT_USER helpers at the top.
//!
//!   - C10: one call that submits one change and returns one event. The change triggers an
//!     EVFILT_USER filter on the same kqueue with NOTE_TRIGGER, and the same call reports it. The
//!     filter carries EV_CLEAR, so reporting resets it and the next call does the same work.
//!   - C11: `(t32 - t1) / 31`, where t1 is the C10 call and t32 is the same call with 31 more
//!     changes behind the trigger. Both return the one user event, so the 31 changes are the only
//!     difference. Each of the 31 re-arms EVFILT_READ with `EV_ADD | EV_ENABLE` on an idle
//!     loopback TCP socket whose filter already exists: the change a readiness loop submits most.
//!
//! What C11 cannot show: the first EV_ADD of a descriptor, which allocates the filter, and
//! EV_DELETE. Both calls pass a zero timeout, so a probe that goes wrong returns 0 events and
//! fails; it cannot block.
const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const measure = @import("../measure.zig");
const sys = @import("../sys.zig");
const Environment = measure.Environment;
const Error = measure.Error;
const Plan = measure.Plan;
const Result = measure.Result;
const Kevent = posix.Kevent;

pub const probes = [_]measure.Probe{
    .{
        .row = 10,
        .operation = "kevent round trip, 1 change submitted and 1 event returned",
        .run = run_round_trip,
    },
    .{
        .row = 11,
        .operation = "one more change in a kevent changelist of 32, per change",
        .run = run_one_more_change,
    },
};

/// The ident of the one EVFILT_USER filter a probe's kqueue holds.
const user_ident = 1;

/// The changelist C11 compares against a changelist of 1.
const changes_max = 32;

/// The sockets C11 re-arms: every change but the trigger.
const sockets_max = changes_max - 1;

/// A kevent timeout of zero: report what is ready and return.
const no_wait: posix.timespec = .{ .sec = 0, .nsec = 0 };

const round_trip_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 32 };
const one_more_plan: Plan = .{ .warmup = 64, .samples = 2000, .batch = 16 };

/// The change that fires the user filter.
pub const trigger_change: Kevent = .{
    .ident = user_ident,
    .filter = c.EVFILT.USER,
    .flags = 0,
    .fflags = c.NOTE.TRIGGER,
    .data = 0,
    .udata = 0,
};

/// A kqueue that holds one EVFILT_USER filter with EV_CLEAR.
pub fn open_with_user_filter() Error!sys.fd_t {
    const kq = c.kqueue();
    if (kq < 0) return error.SystemCallFailed;
    errdefer sys.close(kq);
    const add = [1]Kevent{.{
        .ident = user_ident,
        .filter = c.EVFILT.USER,
        .flags = c.EV.ADD | c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    try submit(kq, &add);
    return kq;
}

/// Submits `changes` and asks for no event back.
pub fn submit(kq: sys.fd_t, changes: []const Kevent) Error!void {
    var no_events: [1]Kevent = undefined;
    const rc = c.kevent(kq, changes.ptr, @intCast(changes.len), &no_events, 0, &no_wait);
    if (rc != 0) return error.SystemCallFailed;
}

const Queue = struct {
    kq: sys.fd_t,
    changes: [changes_max]Kevent = @splat(trigger_change),
    events: [1]Kevent = undefined,

    /// One kevent call: the first `change_count` changes in, the user event out.
    fn call(queue: *Queue, change_count: c_int) Error!void {
        const rc = c.kevent(queue.kq, &queue.changes, change_count, &queue.events, 1, &no_wait);
        if (rc != 1) return error.UnexpectedResult;
        if (queue.events[0].filter != c.EVFILT.USER) return error.UnexpectedResult;
    }

    pub fn run_batch(queue: *Queue, calls: u32) Error!void {
        var remaining = calls;
        while (remaining != 0) : (remaining -= 1) try queue.call(1);
    }

    pub const run_first = run_batch;

    pub fn run_second(queue: *Queue, calls: u32) Error!void {
        var remaining = calls;
        while (remaining != 0) : (remaining -= 1) try queue.call(changes_max);
    }
};

fn run_round_trip(environment: *Environment) Error!Result {
    const kq = try open_with_user_filter();
    defer sys.close(kq);
    var queue: Queue = .{ .kq = kq };
    const plan = round_trip_plan;
    const summary = try measure.sample(Queue, &queue, plan, environment.values[0]);
    return .{
        .summary = summary,
        .plan = plan,
        .unit = "calls",
        .note = "the change triggers an EVFILT_USER filter (NOTE_TRIGGER, EV_CLEAR) on the same" ++
            " kqueue and the same call returns it; zero timeout; every call's event is checked",
    };
}

const Sockets = struct {
    pairs: [sockets_max]sys.Pair = undefined,
    open: u32 = 0,

    fn connect_all(sockets: *Sockets) Error!void {
        while (sockets.open < sockets_max) : (sockets.open += 1) {
            sockets.pairs[sockets.open] = try sys.tcp_pair();
        }
    }

    fn deinit(sockets: *Sockets) void {
        for (sockets.pairs[0..sockets.open]) |pair| pair.deinit();
    }
};

fn run_one_more_change(environment: *Environment) Error!Result {
    const kq = try open_with_user_filter();
    defer sys.close(kq);
    var sockets: Sockets = .{};
    defer sockets.deinit();
    try sockets.connect_all();

    var queue: Queue = .{ .kq = kq };
    for (sockets.pairs, queue.changes[1..]) |pair, *change| {
        change.* = .{
            .ident = @intCast(pair.far),
            .filter = c.EVFILT.READ,
            .flags = c.EV.ADD | c.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
    }
    // The first submission allocates the 31 filters; every timed call finds them there.
    try submit(kq, queue.changes[1..]);

    const plan = one_more_plan;
    const timed = try measure.sample_pairs(Queue, &queue, plan, &environment.values);
    const note = environment.note(
        "(t32 - t1) / {d} per sample: t1 {d:.0} ns is the C10 call, t32 {d:.0} ns adds {d}" ++
            " changes that re-arm EVFILT_READ (EV_ADD | EV_ENABLE) on idle loopback TCP" ++
            " sockets whose filters exist; both calls return the one user event",
        .{ sockets_max, timed.first.median_ns, timed.second.median_ns, sockets_max },
    );
    return .{
        .summary = timed.difference.scaled(1.0 / @as(f64, sockets_max)),
        .plan = plan,
        .unit = "calls per changelist length",
        .is_difference = true,
        .note = note,
    };
}
