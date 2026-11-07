//! The reference model of `Dispatch` (decisions 26 and 27) for the seeded property test in
//! `dispatch_test.zig`. It holds plain arrays and a plain FIFO, and it names no address. The test
//! gives it and the real `Dispatch` the same inputs, then compares what each one did.
//!
//! It also holds the types that both sides of the test share: the pool sizes, the call trace, what
//! a task does when it runs, and what a poller does in `begin`.
const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const Event = @import("../event.zig").Event;
const Random = @import("../random.zig").Random;

/// Pollers in the pool: more than the table holds, so an add can find the table full.
pub const pollers_pool = constants.pollers_max + 2;
/// Records in the pool, one for each operation in flight at a time.
pub const operations_pool = 24;
/// Tasks in the pool: more than one run starts, so the budget of a run is reached.
pub const tasks_pool = constants.tasks_per_tick_max + 96;
/// The most events in one batch that `end` takes.
pub const batch_max = 32;
/// The most calls in one step: every poller, every event of a batch and one full run of tasks.
pub const trace_step_max = constants.pollers_max + batch_max + constants.tasks_per_tick_max;

/// A record's plan, in the `result` of its event: bit 0 queues a free task, and bit 1 notes one
/// more operation with a record in flight.
pub const plan_schedule: i32 = 1;
pub const plan_submit: i32 = 2;
/// One past the largest plan.
pub const plans_count = 4;

pub const Kind = enum(u8) { poller = 'p', record = 'r', task = 't' };

/// The calls of one step, in order. Each mark is a kind and an id.
pub const Trace = struct {
    marks: [trace_step_max]u32 = undefined,
    len: u32 = 0,

    pub fn note(trace: *Trace, kind: Kind, id: u32) void {
        assert(trace.len < trace_step_max);
        assert(id < std.math.maxInt(u16));
        trace.marks[trace.len] = (@as(u32, @intFromEnum(kind)) << 16) | id;
        trace.len += 1;
    }

    pub fn items(trace: *const Trace) []const u32 {
        return trace.marks[0..trace.len];
    }
};

/// What a poller does in one `begin`. The test draws it before each tick and gives the same plan
/// to both sides.
pub const PollerPlan = struct {
    worked: bool = false,
    queues: bool = false,
};

/// What a task does when it runs. It is a function of the seed, the task's id and its count of
/// runs alone, so both sides agree without a shared random stream.
pub const Behaviour = struct {
    /// Free tasks it queues.
    children: u32,
    /// True: it queues itself again, when it is free.
    again: bool,

    pub fn of(seed: u64, id: u32, runs: u32) Behaviour {
        const id_mix: u64 = 0x9E37_79B9_7F4A_7C15;
        const runs_mix: u64 = 0xC2B2_AE3D_27D4_EB4F;
        var random = Random.init(seed ^ (@as(u64, id) *% id_mix) ^ (@as(u64, runs) *% runs_mix));
        const draw = random.below(8);
        const children: u32 = if (draw < 5) 0 else if (draw < 7) 1 else 2;
        return .{ .children = children, .again = random.chance(1, 8) };
    }
};

/// The first index at or after `start`, in a circle, where `taken` is false.
pub fn first_free(taken: []const bool, start: usize) ?u32 {
    for (0..taken.len) |offset| {
        const index = (start + offset) % taken.len;
        if (!taken[index]) return @intCast(index);
    }
    return null;
}

pub const Model = struct {
    seed: u64,
    /// The added pollers' ids, in the order the table must hold them.
    pollers: [constants.pollers_max]u32 = undefined,
    poller_count: u32 = 0,
    added: [pollers_pool]bool = @splat(false),
    in_flight: [operations_pool]bool = @splat(false),
    in_flight_count: u32 = 0,
    /// The queued task ids, oldest first.
    queue: [tasks_pool]u32 = undefined,
    queue_len: u32 = 0,
    queued: [tasks_pool]bool = @splat(false),
    runs: [tasks_pool]u32 = @splat(0),
    trace: Trace = .{},
    /// The events without a record that the last `end` keeps, in order.
    kept: [batch_max]Event = undefined,
    kept_len: u32 = 0,
    /// The tasks a poller queued in the last `begin` that the run of its `end` must reach (P9).
    poller_tasks: [constants.pollers_max]u32 = undefined,
    poller_tasks_len: u32 = 0,
    ticking: bool = false,

    /// True when the table took the poller, and false when it was full.
    pub fn add_poller(model: *Model, id: u32) bool {
        assert(!model.added[id] and !model.ticking);
        if (model.poller_count == constants.pollers_max) return false;
        model.pollers[model.poller_count] = id;
        model.poller_count += 1;
        model.added[id] = true;
        return true;
    }

    /// Removes the poller at `index` of the table. The pollers after it keep their order.
    pub fn remove_poller(model: *Model, index: u32) u32 {
        assert(index < model.poller_count and !model.ticking);
        const id = model.pollers[index];
        const count = model.poller_count;
        std.mem.copyForwards(u32, model.pollers[index .. count - 1], model.pollers[index + 1 .. count]);
        model.poller_count = count - 1;
        model.added[id] = false;
        return id;
    }

    pub fn schedule(model: *Model, id: u32) void {
        assert(!model.queued[id]);
        model.queue[model.queue_len] = id;
        model.queue_len += 1;
        model.queued[id] = true;
    }

    pub fn submit(model: *Model, operation: u32) void {
        assert(!model.in_flight[operation]);
        model.in_flight[operation] = true;
        model.in_flight_count += 1;
    }

    /// What the loop has outstanding: the operations with a record in flight and the queued tasks (P7).
    pub fn owed(model: *const Model) u32 {
        return model.in_flight_count + model.queue_len;
    }

    pub fn idle(model: *const Model) bool {
        return model.poller_count == 0 and model.owed() == 0;
    }

    /// Calls each poller in table order and returns the wait: 0 when a poller worked or a
    /// task is queued, and `wait_ns` otherwise.
    pub fn begin(model: *Model, plans: *const [pollers_pool]PollerPlan, wait_ns: u64) u64 {
        assert(!model.ticking);
        model.ticking = true;
        model.poller_tasks_len = 0;
        var worked = false;
        for (model.pollers[0..model.poller_count]) |id| {
            model.trace.note(.poller, id);
            if (plans[id].queues) model.poller_queue();
            if (plans[id].worked) worked = true;
        }
        return if (worked or model.queue_len != 0) 0 else wait_ns;
    }

    fn poller_queue(model: *Model) void {
        const id = first_free(&model.queued, 0) orelse return;
        // A task inside the budget of the run runs in this tick's `end` (P9).
        if (model.queue_len < constants.tasks_per_tick_max) {
            model.poller_tasks[model.poller_tasks_len] = id;
            model.poller_tasks_len += 1;
        }
        model.schedule(id);
    }

    /// Calls the record of each event that names one, in order, keeps the rest, then runs the
    /// tasks queued at that point, at most `tasks_per_tick_max` of them.
    pub fn end(model: *Model, events: []const Event, operations: []const u32) void {
        assert(model.ticking);
        assert(events.len == operations.len);
        model.kept_len = 0;
        for (events, operations) |event, operation| {
            if (!event.flags.dispatched) {
                model.kept[model.kept_len] = event;
                model.kept_len += 1;
                continue;
            }
            model.record(operation, event);
        }
        const started = @min(model.queue_len, constants.tasks_per_tick_max);
        for (0..started) |_| model.run_head();
        model.ticking = false;
    }

    fn record(model: *Model, operation: u32, event: Event) void {
        assert(model.in_flight[operation]);
        model.trace.note(.record, operation);
        if (!event.flags.more) {
            model.in_flight[operation] = false;
            model.in_flight_count -= 1;
        }
        if (event.result & plan_schedule != 0) {
            if (first_free(&model.queued, 0)) |id| model.schedule(id);
        }
        if (event.result & plan_submit != 0) {
            if (first_free(&model.in_flight, 0)) |next| model.submit(next);
        }
    }

    fn run_head(model: *Model) void {
        assert(model.queue_len >= 1);
        const id = model.queue[0];
        std.mem.copyForwards(u32, model.queue[0 .. model.queue_len - 1], model.queue[1..model.queue_len]);
        model.queue_len -= 1;
        model.queued[id] = false;
        model.trace.note(.task, id);
        model.runs[id] += 1;
        const behaviour = Behaviour.of(model.seed, id, model.runs[id]);
        for (0..behaviour.children) |_| {
            const child = first_free(&model.queued, 0) orelse break;
            model.schedule(child);
        }
        if (behaviour.again and !model.queued[id]) model.schedule(id);
    }

    pub fn abandon(model: *Model) void {
        assert(model.ticking);
        model.ticking = false;
    }

    /// Unlinks every queued task without a call, and returns the count.
    pub fn discard(model: *Model) u32 {
        assert(!model.ticking);
        const discarded = model.queue_len;
        model.queue_len = 0;
        model.queued = @splat(false);
        return discarded;
    }
};
