//! The oracle of the seeded library program (`conformance_program.zig`). It keeps one entry for each
//! operation the program submits and one mirror for each task, and checks these rules:
//!
//! - Each operation ends with exactly one final event, and a `more` event comes only before it, and
//!   only for a multishot kind (decision 5).
//! - An event of an operation with a record reaches that record, with `dispatched` set. Every other
//!   event reaches the caller of `tick` exactly once, with `dispatched` clear (decision 26).
//! - Each `schedule` gives exactly one run or one discard, in the tick that decision 27 names.
//! - After every tick, `callbacks_outstanding` is the count of records in flight plus the tasks queued.
//!
//! A record and a task cannot return an error, so a check that fails inside one stores its error
//! in the program, and the program returns it after the tick.
const std = @import("std");
const core = @import("core");
const program_module = @import("conformance_program.zig");
const actions = @import("conformance_program_actions.zig");

const Event = core.Event;
const Program = program_module.Program;

/// The most operations the program holds in flight at one time. The harness loop has 64 slots.
pub const entries_max = 48;

/// The tasks of all the libraries together.
pub const jobs_max = 18;

/// The bits of a plain operation's `user_data` that hold its entry's index. The bits above hold
/// the entry's generation, so an event of an older use of the entry is caught.
const index_bits = 32;
const index_mask: u64 = (1 << index_bits) - 1;

pub const Kind = enum { timer, timer_repeat, tcp_receive, tcp_send, udp_receive, udp_send, post };

/// Where an event arrived: at the caller of `tick`, or at the operation's record.
pub const Route = enum { caller, record };

/// One operation of the program, from its submit to its final event.
pub const Entry = struct {
    completion: core.Completion = .init(Entry, "completion", called),
    program: *Program,
    index: u32,
    /// Counts the uses of this entry, so a plain event of an older use does not match.
    generation: u32 = 0,
    in_flight: bool = false,
    kind: Kind = .timer,
    record: bool = false,
    cancel_requested: bool = false,
    /// The operation has a deadline (`timeout_ns`).
    timeout_set: bool = false,
    /// The deadline must win: no byte could arrive for the receive when it was submitted.
    timeout_forced: bool = false,
    handle: core.Handle = undefined,
    /// The bytes of a send, or the room of a receive.
    bytes: u32 = 0,
    /// The id of a datagram or the payload of a post.
    id: u64 = 0,
    /// The 8 bytes a datagram carries: its id.
    payload: [8]u8 = @splat(0),

    fn called(entry: *Entry, event: Event) void {
        const program = entry.program;
        program.ledger.on_event(entry, event, .record) catch |err| return program.fail(err);
        actions.after_record(program);
    }

    /// The `user_data` of a plain operation of this entry.
    pub fn user_data(entry: *const Entry) u64 {
        return (@as(u64, entry.generation) << index_bits) | entry.index;
    }
};

fn multishot(kind: Kind) bool {
    return kind == .timer_repeat or kind == .udp_receive;
}

pub const Ledger = struct {
    entries: [entries_max]Entry,
    in_flight: u32 = 0,
    records_in_flight: u32 = 0,
    /// The final events seen, and the `more` events seen, for the report of a soak.
    finals: u64 = 0,
    mores: u64 = 0,

    pub fn init(ledger: *Ledger, program: *Program) void {
        ledger.* = .{ .entries = undefined };
        for (&ledger.entries, 0..) |*entry, index| entry.* = .{ .program = program, .index = @intCast(index) };
    }

    /// A free entry, searched from a drawn index, or null when every entry is in flight.
    pub fn claim(ledger: *Ledger, random: *core.random.Random) ?*Entry {
        const start = random.below(entries_max);
        for (0..entries_max) |offset| {
            const entry = &ledger.entries[(start + offset) % entries_max];
            if (!entry.in_flight) return entry;
        }
        return null;
    }

    /// An entry in flight whose cancel the program has not asked for yet, or null.
    pub fn pick_in_flight(ledger: *Ledger, random: *core.random.Random) ?*Entry {
        const start = random.below(entries_max);
        for (0..entries_max) |offset| {
            const entry = &ledger.entries[(start + offset) % entries_max];
            if (entry.in_flight and !entry.cancel_requested) return entry;
        }
        return null;
    }

    /// Marks `entry` in flight once the loop took its operation.
    pub fn started(ledger: *Ledger, entry: *Entry, handle: core.Handle) void {
        std.debug.assert(!entry.in_flight);
        entry.in_flight = true;
        entry.handle = handle;
        ledger.in_flight += 1;
        if (entry.record) ledger.records_in_flight += 1;
    }

    /// An event that the tick handed to its caller, and that is not a message.
    pub fn on_plain(ledger: *Ledger, event: Event) !void {
        if (event.flags.dispatched) return error.DispatchedEventAtCaller;
        const index = event.user_data & index_mask;
        if (index >= entries_max) return error.UnknownUserData;
        const entry = &ledger.entries[index];
        if (entry.generation != event.user_data >> index_bits) return error.EventOfAnEndedOperation;
        try ledger.on_event(entry, event, .caller);
    }

    pub fn on_event(ledger: *Ledger, entry: *Entry, event: Event, route: Route) !void {
        if (!entry.in_flight) return error.EventOfAnEndedOperation;
        try check_route(entry, event, route);
        if (event.flags.more) {
            if (!multishot(entry.kind)) return error.MoreEventOfSingleShot;
            ledger.mores += 1;
            return actions.on_more(entry.program, entry, event);
        }
        // The entry ends before the check of its result, so a failed check leaves the counts true.
        entry.in_flight = false;
        entry.generation +%= 1;
        ledger.in_flight -= 1;
        if (entry.record) ledger.records_in_flight -= 1;
        ledger.finals += 1;
        try actions.on_final(entry.program, entry, event);
    }

    /// Ends each plain entry still in flight without its final event: `drain` discarded those
    /// events. Each record entry must have ended through its record.
    pub fn forget_drained(ledger: *Ledger) !void {
        if (ledger.records_in_flight != 0) return error.RecordNotCalledInDrain;
        for (&ledger.entries) |*entry| {
            if (!entry.in_flight) continue;
            entry.in_flight = false;
            entry.generation +%= 1;
            ledger.in_flight -= 1;
            actions.on_drained(entry.program, entry);
        }
    }
};

fn check_route(entry: *const Entry, event: Event, route: Route) !void {
    if (event.flags.message) return error.MessageForAnOperation;
    switch (route) {
        .record => {
            if (!entry.record) return error.RecordCalledForPlainOperation;
            if (!event.flags.dispatched) return error.RecordEventWithoutFlag;
            if (event.user_data != @intFromPtr(&entry.completion)) return error.RecordGotOtherEvent;
        },
        .caller => if (entry.record) return error.RecordEventAtCaller,
    }
}

/// Who queued a task. It decides the tick in which the task must run (decision 27).
pub const Origin = enum { program, poller, record, task };

/// One task of a library, and what the program knows of it.
pub const Job = struct {
    task: core.Task = .init(Job, "task", ran),
    program: *Program,
    queued: bool = false,
    /// The number of the tick whose `end` must run the task.
    due_tick: u64 = 0,
    /// The place of the last `schedule` among all the program's `schedule` calls, from 1.
    sequence: u64 = 0,
    scheduled: u32 = 0,
    runs: u32 = 0,
    discarded: u32 = 0,

    fn ran(job: *Job) void {
        const program = job.program;
        program.jobs.on_run(program, job) catch |err| return program.fail(err);
        actions.after_task(program);
    }
};

pub const Jobs = struct {
    jobs: [jobs_max]Job,
    queued: u32 = 0,
    scheduled: u64 = 0,
    ran: u64 = 0,
    discarded: u64 = 0,
    /// The `sequence` of the task that ran last. The queue is a FIFO, so each run has a higher one.
    last_run_sequence: u64 = 0,

    pub fn init(jobs: *Jobs, program: *Program) void {
        jobs.* = .{ .jobs = undefined };
        for (&jobs.jobs) |*job| job.* = .{ .program = program };
    }

    /// Queues a task that is not queued, searched from a drawn index. Does nothing when every task
    /// is queued.
    pub fn schedule_any(jobs: *Jobs, program: *Program, origin: Origin) !void {
        const start = program.random.below(jobs_max);
        for (0..jobs_max) |offset| {
            const job = &jobs.jobs[(start + offset) % jobs_max];
            if (!job.queued) return jobs.schedule(program, job, origin);
        }
    }

    fn schedule(jobs: *Jobs, program: *Program, job: *Job, origin: Origin) !void {
        if (program.main.loop.is_scheduled(&job.task)) return error.TaskQueuedTwice;
        try program.main.loop.schedule(&job.task);
        job.queued = true;
        job.scheduled += 1;
        jobs.queued += 1;
        jobs.scheduled += 1;
        job.sequence = jobs.scheduled;
        // A task that a task queued runs one tick later; every other one runs in the next `end`.
        job.due_tick = program.tick_number + @intFromBool(origin == .task);
    }

    fn on_run(jobs: *Jobs, program: *Program, job: *Job) !void {
        if (!program.in_tick) return error.TaskRanOutsideATick;
        if (!job.queued) return error.TaskRanWithoutSchedule;
        job.queued = false;
        job.runs += 1;
        jobs.queued -= 1;
        jobs.ran += 1;
        if (job.sequence <= jobs.last_run_sequence) return error.TaskRanOutOfOrder;
        jobs.last_run_sequence = job.sequence;
        if (!program.draining and job.due_tick != program.tick_number) return error.TaskRanInAnotherTick;
    }

    /// `discard_tasks`, between ticks: it must unlink every queued task and call none.
    pub fn discard(jobs: *Jobs, program: *Program) !void {
        const discarded = program.main.loop.discard_tasks();
        if (discarded != jobs.queued) return error.DiscardCountDrift;
        for (&jobs.jobs) |*job| {
            if (!job.queued) continue;
            job.queued = false;
            job.discarded += 1;
        }
        jobs.discarded += discarded;
        jobs.queued = 0;
    }

    fn check(jobs: *const Jobs, program: *Program) !void {
        const loop = &program.main.loop;
        if (loop.tasks_queued() != jobs.queued) return error.TasksQueuedDrift;
        for (&jobs.jobs) |*job| {
            if (loop.is_scheduled(&job.task) != job.queued) return error.TaskQueueDrift;
            const settled = job.runs + job.discarded + @intFromBool(job.queued);
            if (job.scheduled != settled) return error.TaskOnceRuleBroken;
        }
        if (jobs.scheduled != jobs.ran + jobs.discarded + jobs.queued) return error.TaskCountDrift;
        loop.tables.dispatch.tasks.assert_queue();
    }
};

/// The checks after every tick of the program's loop, and after `drain`.
pub fn check_after_tick(program: *Program) !void {
    if (program.failure) |failure| return failure;
    const loop = &program.main.loop;
    const dispatch = &loop.tables.dispatch;
    if (dispatch.phase != .idle) return error.TickStillMarked;
    const owed = program.ledger.records_in_flight + program.jobs.queued;
    if (dispatch.callbacks_outstanding != owed) return error.CallbacksOwedDrift;
    if (loop.in_flight() != program.ledger.in_flight) return error.InFlightDrift;
    try program.jobs.check(program);
}
